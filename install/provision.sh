#!/usr/bin/env bash
#
# TastyIgniter container provisioning.
# This script runs INSIDE the Debian LXC created by install/tastyigniter.sh.
#
set -Eeuo pipefail

APP="TastyIgniter"
APP_DIR="/opt/tastyigniter"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH_DIR="/opt/tastyigniter-dashboard"
DASH_WWW="${DASH_DIR}/www"
CRED_FILE="/root/tastyigniter-credentials.txt"
LOG_FILE="/var/log/tastyigniter-provision.log"
MARKER="${APP_DIR}/.installed"

APP_CTID="${APP_CTID:-unknown}"
APP_IP="${APP_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
APP_PORT="${APP_PORT:-8080}"
APP_TIMEZONE="${APP_TIMEZONE:-Europe/Berlin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@tastyigniter.local}"
RESTAURANT_NAME="${RESTAURANT_NAME:-My Restaurant}"
TI_VERSION="${TI_VERSION:-4.5.0}"
PROVISION_ACTION="${PROVISION_ACTION:-install}"

PHP_VER="8.4"
PHP_BIN="/usr/bin/php${PHP_VER}"
PHP_FPM_BIN="/usr/sbin/php-fpm${PHP_VER}"
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

export DEBIAN_FRONTEND=noninteractive
export COMPOSER_ALLOW_SUPERUSER=1
export COMPOSER_MEMORY_LIMIT=-1

# ---------------------------------------------------------------------------
# Logging + colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RD=$'\033[0;31m'; GN=$'\033[0;32m'; YW=$'\033[0;33m'; BL=$'\033[0;34m'
  BGN=$'\033[1;32m'; BLD=$'\033[1m'; CL=$'\033[0m'
else
  RD=""; GN=""; YW=""; BL=""; BGN=""; BLD=""; CL=""
fi
msg_info()  { echo -e "${BL}[INFO]${CL}  $*" >&2; }
msg_ok()    { echo -e "${GN}[ OK ]${CL}  $*" >&2; }
msg_warn()  { echo -e "${YW}[WARN]${CL}  $*" >&2; }
msg_error() { echo -e "${RD}[ERR ]${CL}  $*" >&2; }
die()       { msg_error "$*"; trap - ERR; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
if command -v stdbuf >/dev/null 2>&1; then
  exec > >(stdbuf -o0 -e0 tee -a "$LOG_FILE") 2>&1
else
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

on_error() {
  local exit_code="$1" line="$2" cmd="$3"
  trap - ERR
  set +e
  echo
  msg_error "Provisionierung fehlgeschlagen."
  echo "  Exit-Code : ${exit_code}"
  echo "  Zeile     : ${line}"
  echo "  Befehl    : ${cmd}"
  echo "  Log       : ${LOG_FILE}"
  echo
  echo "----- Letzte 150 Zeilen Provision-Log -----"
  # Give tee a moment to flush the lines above into the log file.
  sleep 0.5
  tail -n 150 "$LOG_FILE" || true
  echo "-------------------------------------------"
  echo "----- systemctl status -----"
  systemctl --no-pager --full status tastyigniter nginx mariadb 2>&1 || true
  echo "----------------------------"
  echo "----- journalctl -----"
  journalctl -u tastyigniter -u nginx -u mariadb --no-pager -n 120 2>&1 || true
  echo "----------------------"
  echo "----- Laravel-Log -----"
  tail -n 150 "${APP_DIR}/storage/logs/laravel.log" 2>&1 || true
  echo "-----------------------"
  echo "----- nginx error.log -----"
  tail -n 100 /var/log/nginx/tastyigniter-error.log 2>&1 || true
  echo "---------------------------"
  exit "$exit_code"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Basic checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Provisionierung muss als root laufen."
[[ -f /etc/debian_version ]] || die "Dieses Script unterstützt nur Debian-basierte Container."
[[ -n "$APP_IP" ]] || die "Container-IP konnte nicht ermittelt werden."
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || die "Ungültiger Port: ${APP_PORT}"

echo
echo -e "${BLD}${APP} – Container-Provisionierung${CL}"
echo "  CT-ID        : ${APP_CTID}"
echo "  IP            : ${APP_IP}"
echo "  Port          : ${APP_PORT}"
echo "  Aktion        : ${PROVISION_ACTION}"
echo "  TastyIgniter  : ${TI_VERSION}"
echo

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Paketlisten …"
apt-get update -qq

# Avoid needrestart prompts inside non-interactive provisioning.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/99-tastyigniter.conf <<'EOF'
$nrconf{restart} = 'a';
EOF

PACKAGES=(
  ca-certificates curl git jq unzip zip tar openssl
  nginx mariadb-server cron ufw
  "php${PHP_VER}-fpm" "php${PHP_VER}-cli" "php${PHP_VER}-bcmath"
  "php${PHP_VER}-curl" "php${PHP_VER}-gd" "php${PHP_VER}-intl"
  "php${PHP_VER}-mbstring" "php${PHP_VER}-mysql" "php${PHP_VER}-xml"
  "php${PHP_VER}-zip" "php${PHP_VER}-opcache"
)

msg_info "Installiere Pakete (nginx, MariaDB, PHP ${PHP_VER}, Tools) …"
if ! apt-get install -y --no-install-recommends "${PACKAGES[@]}"; then
  msg_error "Paketinstallation fehlgeschlagen. Verfügbare PHP-Pakete:"
  apt-cache search "^php${PHP_VER}-" | sort || true
  die "apt-get install ist fehlgeschlagen (siehe oben)."
fi
# exif is normally part of php-common; install it explicitly when packaged.
apt-get install -y --no-install-recommends "php${PHP_VER}-exif" >/dev/null 2>&1 || true

if [[ "$PROVISION_ACTION" == "update" ]]; then
  msg_info "Aktualisiere installierte Pakete …"
  apt-get -y upgrade
fi

msg_info "Konfiguriere PHP ${PHP_VER} …"
for ini_dir in "/etc/php/${PHP_VER}/fpm/conf.d" "/etc/php/${PHP_VER}/cli/conf.d"; do
  mkdir -p "$ini_dir"
  cat > "${ini_dir}/99-tastyigniter.ini" <<EOF
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
max_input_vars = 5000
date.timezone = ${APP_TIMEZONE}
expose_php = Off
EOF
done

# Ensure the FPM pool listens on the socket nginx expects.
POOL_CONF="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
if [[ -f "$POOL_CONF" ]]; then
  sed -i "s|^listen = .*|listen = ${PHP_SOCK}|" "$POOL_CONF"
  sed -i 's|^;listen.owner = .*|listen.owner = www-data|' "$POOL_CONF"
  sed -i 's|^;listen.group = .*|listen.group = www-data|' "$POOL_CONF"
  sed -i 's|^;listen.mode = .*|listen.mode = 0660|' "$POOL_CONF"
  grep -q '^listen.owner' "$POOL_CONF" || echo 'listen.owner = www-data' >> "$POOL_CONF"
  grep -q '^listen.group' "$POOL_CONF" || echo 'listen.group = www-data' >> "$POOL_CONF"
  grep -q '^listen.mode' "$POOL_CONF" || echo 'listen.mode = 0660' >> "$POOL_CONF"
fi

# Verify required PHP extensions early, with a useful message.
REQUIRED_EXT=(bcmath ctype curl dom exif fileinfo gd intl json mbstring openssl pdo pdo_mysql tokenizer xml zip)
PHP_MODULES="$("$PHP_BIN" -m)"
MISSING=()
for ext in "${REQUIRED_EXT[@]}"; do
  grep -qi "^${ext}$" <<< "$PHP_MODULES" || MISSING+=("$ext")
done
if ((${#MISSING[@]} > 0)); then
  msg_error "Fehlende PHP-Extensions: ${MISSING[*]}"
  "$PHP_BIN" -m || true
  die "Bitte PHP-Extensions prüfen (siehe Liste oben)."
fi
msg_ok "PHP ${PHP_VER} und Extensions bereit."

# Composer 2.9+ (required by newer TastyIgniter marketplace auth).
if ! command -v composer >/dev/null 2>&1 || ! composer --version 2>/dev/null | grep -qE 'Composer version 2\.(9|[1-9][0-9])'; then
  msg_info "Installiere aktuellen Composer …"
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  "$PHP_BIN" /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f /tmp/composer-setup.php
fi
msg_ok "Composer: $(composer --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
# Timezone
# ---------------------------------------------------------------------------
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "$APP_TIMEZONE" >/dev/null 2>&1 || msg_warn "Timezone konnte nicht gesetzt werden."
fi

# ---------------------------------------------------------------------------
# MariaDB
# ---------------------------------------------------------------------------
msg_info "Starte MariaDB …"
systemctl enable --now mariadb >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  if mysqladmin ping --silent >/dev/null 2>&1; then break; fi
  sleep 1
done
mysqladmin ping --silent >/dev/null 2>&1 || die "MariaDB ist nicht erreichbar."

# Load or create credentials. Everything is generated locally.
if [[ -f "$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
fi

gen_pass() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }

DB_NAME="${DB_NAME:-tastyigniter}"
DB_USER="${DB_USER:-tastyigniter}"
DB_PASS="${DB_PASS:-$(gen_pass 28)}"
ADMIN_PASS="${ADMIN_PASS:-Tasty!$(gen_pass 16)A1}"

if [[ ! -f "$CRED_FILE" ]]; then
  umask 077
  cat > "$CRED_FILE" <<EOF
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
ADMIN_EMAIL='${ADMIN_EMAIL}'
ADMIN_PASS='${ADMIN_PASS}'
EOF
  chmod 600 "$CRED_FILE"
fi

msg_info "Konfiguriere Datenbank ${DB_NAME} …"
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
msg_ok "Datenbank und Benutzer bereit."

# ---------------------------------------------------------------------------
# TastyIgniter application
# ---------------------------------------------------------------------------
resolve_ti_version() {
  local version="$TI_VERSION"
  if [[ "$version" == "latest" ]]; then
    version="$(curl -fsSL --max-time 20 https://api.github.com/repos/tastyigniter/TastyIgniter/releases/latest 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')"
    [[ -n "$version" ]] || version="4.5.0"
  fi
  echo "$version"
}

TI_VERSION="$(resolve_ti_version)"
TI_ZIP_URL="https://github.com/tastyigniter/TastyIgniter/releases/download/v${TI_VERSION}/tastyigniter-${TI_VERSION}.zip"

install_app_files() {
  msg_info "Lade TastyIgniter ${TI_VERSION} (Release mit vendor/) …"
  curl -fL --retry 3 --connect-timeout 20 "$TI_ZIP_URL" -o /tmp/tastyigniter.zip

  rm -rf /tmp/tastyigniter-unpack
  mkdir -p /tmp/tastyigniter-unpack
  unzip -q /tmp/tastyigniter.zip -d /tmp/tastyigniter-unpack

  local src="/tmp/tastyigniter-unpack/tastyigniter-${TI_VERSION}"
  if [[ ! -d "$src" ]]; then
    src="$(find /tmp/tastyigniter-unpack -mindepth 1 -maxdepth 1 -type d | head -1)"
  fi
  [[ -d "$src" ]] || die "TastyIgniter-Archiv hat keine erwartete Verzeichnisstruktur."

  if [[ -d "$APP_DIR" && ! -f "${APP_DIR}/artisan" ]]; then
    mv "$APP_DIR" "${APP_DIR}.broken.$(date +%s)"
  fi
  rm -rf "$APP_DIR"
  mv "$src" "$APP_DIR"
  rm -rf /tmp/tastyigniter-unpack /tmp/tastyigniter.zip
  msg_ok "TastyIgniter ${TI_VERSION} entpackt."
}

if [[ ! -f "${APP_DIR}/artisan" ]]; then
  install_app_files
else
  msg_ok "Bestehende TastyIgniter-Installation gefunden – Dateien bleiben erhalten."
  if [[ "$PROVISION_ACTION" == "update" ]]; then
    msg_info "Aktualisiere Composer-Abhängigkeiten (Release-Struktur) …"
    (cd "$APP_DIR" && composer install --no-dev --no-interaction --prefer-dist --no-progress) || \
      msg_warn "composer install fehlgeschlagen – bestehende vendor/-Struktur wird verwendet."
  fi
fi

# Preserve/generate Laravel APP_KEY.
APP_KEY="$(grep -E '^APP_KEY=' "${APP_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)"
if [[ -z "$APP_KEY" || "$APP_KEY" == "base64:" ]]; then
  APP_KEY="base64:$(openssl rand -base64 32)"
fi

env_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

msg_info "Schreibe .env …"
umask 077
cat > "${APP_DIR}/.env" <<EOF
APP_NAME="$(env_escape "$RESTAURANT_NAME")"
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=http://${APP_IP}:${APP_PORT}
APP_TIMEZONE=${APP_TIMEZONE}
APP_LOCALE=en
APP_FALLBACK_LOCALE=en

LOG_CHANNEL=stack
LOG_LEVEL=warning

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD="$(env_escape "$DB_PASS")"
DB_PREFIX=

CACHE_DRIVER=file
CACHE_STORE=file
SESSION_DRIVER=file
SESSION_LIFETIME=120
QUEUE_CONNECTION=sync

BROADCAST_DRIVER=log
FILESYSTEM_DISK=local

MAIL_MAILER=log
MAIL_HOST=null
MAIL_PORT=null
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS="${ADMIN_EMAIL}"
MAIL_FROM_NAME="\${APP_NAME}"

IGNITER_CARTE_KEY=
IGNITER_LOCATION_MODE=multiple
EOF
chown www-data:www-data "${APP_DIR}/.env"
chmod 640 "${APP_DIR}/.env"

# The release zip may not include all writable directories on old versions.
mkdir -p "${APP_DIR}/storage/app/public/media/uploads" \
         "${APP_DIR}/storage/app/public/media/attachments" \
         "${APP_DIR}/storage/framework/cache/data" \
         "${APP_DIR}/storage/framework/sessions" \
         "${APP_DIR}/storage/framework/views" \
         "${APP_DIR}/storage/logs" \
         "${APP_DIR}/bootstrap/cache"

# TastyIgniter's own updater keeps core, extensions and their migrations in
# sync. It needs a working .env and database, which exist at this point.
if [[ "$PROVISION_ACTION" == "update" && -f "$MARKER" ]]; then
  msg_info "Prüfe auf TastyIgniter- und Extension-Updates …"
  if (cd "$APP_DIR" && "$PHP_BIN" artisan igniter:update --force --no-interaction); then
    msg_ok "TastyIgniter-Update-Prüfung abgeschlossen."
  else
    msg_warn "igniter:update fehlgeschlagen – führe Migrationen trotzdem aus."
  fi
fi

# Detect an empty/partial database independently from the marker file.
TABLE_COUNT="$(mysql --protocol=socket -N -B -u"$DB_USER" -p"$DB_PASS" -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo 0)"
if [[ "${TABLE_COUNT:-0}" -eq 0 ]]; then
  rm -f "$MARKER"
fi

if [[ ! -f "$MARKER" ]]; then
  msg_info "Führe TastyIgniter-Installation aus (Migrationen, Demo-Daten, Theme) …"
  (cd "$APP_DIR" && "$PHP_BIN" artisan igniter:install --no-interaction --force)
  touch "$MARKER"
  chown www-data:www-data "$MARKER"
  msg_ok "TastyIgniter-Installation abgeschlossen."
else
  msg_info "TastyIgniter ist bereits installiert – führe Migrationen aus …"
  (cd "$APP_DIR" && "$PHP_BIN" artisan migrate --force --no-interaction)
fi

# The CLI installer rewrites APP_NAME/APP_URL with its defaults; restore ours.
msg_info "Setze App-URL und Restaurantname …"
sed -i "s|^APP_NAME=.*|APP_NAME=\"$(sed_replacement "$RESTAURANT_NAME")\"|" "${APP_DIR}/.env"
sed -i "s|^APP_URL=.*|APP_URL=http://${APP_IP}:${APP_PORT}|" "${APP_DIR}/.env"
sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" "${APP_DIR}/.env"

# Ensure the public storage link exists (igniter:install normally creates it).
if [[ ! -L "${APP_DIR}/public/storage" ]]; then
  (cd "$APP_DIR" && "$PHP_BIN" artisan storage:link) || msg_warn "storage:link konnte nicht erstellt werden."
fi

# Create the first admin user programmatically (the v4 installer no longer asks).
msg_info "Lege Admin-Benutzer an …"
"$PHP_BIN" "${REPO_DIR}/app/scripts/create-admin.php" \
  "$APP_DIR" "$ADMIN_EMAIL" "$ADMIN_PASS" "Administrator" "$RESTAURANT_NAME"

msg_info "Räume Caches auf …"
(cd "$APP_DIR" && "$PHP_BIN" artisan optimize:clear >/dev/null 2>&1) || true

msg_info "Setze Dateirechte …"
chown -R www-data:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;
chmod 640 "${APP_DIR}/.env"
chmod -R 775 "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"
chmod 755 "${APP_DIR}/artisan"
msg_ok "Dateirechte gesetzt."

# ---------------------------------------------------------------------------
# systemd: TastyIgniter PHP-FPM unit
# ---------------------------------------------------------------------------
msg_info "Installiere systemd-Unit tastyigniter.service …"
install -m 0755 "${REPO_DIR}/config/tastyigniter-url.sh" /usr/local/bin/tastyigniter-update-url
install -m 0644 "${REPO_DIR}/config/tastyigniter.default" /etc/default/tastyigniter
sed -i "s|^APP_PORT=.*|APP_PORT=${APP_PORT}|" /etc/default/tastyigniter

sed -e "s|__PHP_FPM_BIN__|${PHP_FPM_BIN}|g" \
    -e "s|__PHP_VER__|${PHP_VER}|g" \
    "${REPO_DIR}/systemd/tastyigniter.service" > /etc/systemd/system/tastyigniter.service
chmod 644 /etc/systemd/system/tastyigniter.service

# nginx must not race the PHP-FPM socket.
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/tastyigniter.conf <<'EOF'
[Unit]
After=tastyigniter.service
Wants=tastyigniter.service

[Service]
Restart=always
RestartSec=3
EOF

mkdir -p /etc/systemd/system/mariadb.service.d
cat > /etc/systemd/system/mariadb.service.d/tastyigniter.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
EOF

# The distro php-fpm unit would fight us for the same socket.
systemctl disable --now "php${PHP_VER}-fpm" >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable tastyigniter >/dev/null 2>&1
systemctl restart tastyigniter

for _ in $(seq 1 30); do
  [[ -S "$PHP_SOCK" ]] && break
  sleep 1
done
[[ -S "$PHP_SOCK" ]] || die "PHP-FPM-Socket ${PHP_SOCK} wurde nicht erstellt."
msg_ok "tastyigniter.service aktiv, Socket ${PHP_SOCK} vorhanden."

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
msg_info "Konfiguriere nginx auf Port ${APP_PORT} …"
sed -e "s|__APP_DIR__|${APP_DIR}|g" \
    -e "s|__DASH_DIR__|${DASH_DIR}|g" \
    -e "s|__PORT__|${APP_PORT}|g" \
    -e "s|__PHP_SOCK__|${PHP_SOCK}|g" \
    "${REPO_DIR}/config/nginx-tastyigniter.conf" > /etc/nginx/sites-available/tastyigniter
ln -sfn /etc/nginx/sites-available/tastyigniter /etc/nginx/sites-enabled/tastyigniter
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
msg_ok "nginx läuft auf Port ${APP_PORT}."

# ---------------------------------------------------------------------------
# React/Vite status dashboard
# ---------------------------------------------------------------------------
msg_info "Installiere React-Status-Dashboard unter /status/ …"
[[ -d "${REPO_DIR}/app/dashboard/dist" ]] || die "Dashboard-Build fehlt: app/dashboard/dist. Bitte 'npm run build' ausführen."
rm -rf "${DASH_WWW}/status"
mkdir -p "${DASH_WWW}/status" "${DASH_DIR}/api"
cp -a "${REPO_DIR}/app/dashboard/dist/." "${DASH_WWW}/status/"
install -m 0644 "${REPO_DIR}/app/dashboard/api/status.php" "${DASH_DIR}/api/status.php"

INSTALLED_AT=""
if [[ -f "${DASH_DIR}/install.json" ]]; then
  INSTALLED_AT="$(jq -r '.installed_at // empty' "${DASH_DIR}/install.json" 2>/dev/null || true)"
fi
[[ -n "$INSTALLED_AT" ]] || INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg app "$APP" \
  --arg ctid "$APP_CTID" \
  --arg ip "$APP_IP" \
  --arg port "$APP_PORT" \
  --arg version "$TI_VERSION" \
  --arg installed_at "$INSTALLED_AT" \
  --arg admin_email "$ADMIN_EMAIL" \
  --arg restaurant "$RESTAURANT_NAME" \
  '{app:$app, ctid:$ctid, ip:$ip, port:($port|tonumber), version:$version, installed_at:$installed_at, admin_email:$admin_email, restaurant:$restaurant}' \
  > "${DASH_DIR}/install.json"
chmod 644 "${DASH_DIR}/install.json"
chown -R www-data:www-data "$DASH_DIR"
find "$DASH_DIR" -type d -exec chmod 755 {} \;
find "$DASH_DIR" -type f -exec chmod 644 {} \;
msg_ok "Status-Dashboard installiert."

# ---------------------------------------------------------------------------
# Scheduler + firewall
# ---------------------------------------------------------------------------
msg_info "Konfiguriere Task-Scheduler …"
cat > /etc/cron.d/tastyigniter <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * www-data ${PHP_BIN} ${APP_DIR}/artisan schedule:run >> /var/log/tastyigniter-scheduler.log 2>&1
EOF
chmod 644 /etc/cron.d/tastyigniter
touch /var/log/tastyigniter-scheduler.log
chown www-data:www-data /var/log/tastyigniter-scheduler.log
systemctl enable --now cron >/dev/null 2>&1 || true

msg_info "Öffne Firewall-Port ${APP_PORT}/tcp (best effort) …"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow "${APP_PORT}/tcp" >/dev/null 2>&1 || true
  if ufw --force enable >/dev/null 2>&1; then
    msg_ok "ufw aktiv, Port ${APP_PORT}/tcp erlaubt."
  else
    msg_warn "ufw konnte im LXC nicht aktiviert werden (häufig fehlende NET_ADMIN-Rechte). Port ggf. auf dem Proxmox-Host öffnen."
  fi
fi

# ---------------------------------------------------------------------------
# Final verification (inside container)
# ---------------------------------------------------------------------------
msg_info "Warte auf Web-UI …"
HTTP_OK=0
for _ in $(seq 1 45); do
  if curl -fsS -o /dev/null --max-time 10 "http://127.0.0.1:${APP_PORT}/"; then
    HTTP_OK=1
    break
  fi
  sleep 2
done
if [[ "$HTTP_OK" -ne 1 ]]; then
  msg_error "Web-UI antwortet nicht auf http://127.0.0.1:${APP_PORT}/"
  systemctl --no-pager --full status tastyigniter nginx mariadb || true
  tail -n 120 "${APP_DIR}/storage/logs/laravel.log" 2>/dev/null || true
  tail -n 80 /var/log/nginx/tastyigniter-error.log 2>/dev/null || true
  die "Verifikation der Web-UI fehlgeschlagen."
fi

HTTP_FAIL=0
for path in / /admin/login /status/ /status/api/status; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${APP_PORT}${path}" || true)"
  if [[ "$path" == "/" ]]; then
    [[ "$code" =~ ^(200|301|302)$ ]] || HTTP_FAIL=1
  else
    [[ "$code" == "200" ]] || HTTP_FAIL=1
  fi
  msg_ok "HTTP ${code} – ${path}"
done

if [[ "$HTTP_FAIL" -ne 0 ]]; then
  die "Mindestens ein HTTP-Endpunkt antwortet nicht mit dem erwarteten Status."
fi

# Storefront and admin load their CSS through the PHP-generated /_assets/
# bundle. A 404 there leaves the UI unstyled while every page still returns
# 200, so it has to be verified explicitly.
verify_asset_bundle() {
  local page="$1" label="$2"
  local html path code bytes
  html="$(curl -sS --max-time 10 "http://127.0.0.1:${APP_PORT}${page}" || true)"
  path="$(grep -oE '/_assets/[A-Za-z0-9._-]+\.(css|js)' <<< "$html" | head -1 || true)"
  if [[ -z "$path" ]]; then
    msg_warn "${label}: kein /_assets/-Bundle im HTML gefunden (übersprungen)."
    return 0
  fi
  read -r code bytes < <(curl -sS -o /dev/null -w '%{http_code} %{size_download}' \
    --max-time 10 "http://127.0.0.1:${APP_PORT}${path}" || echo "000 0")
  if [[ "$code" == "200" && "${bytes:-0}" -gt 10000 ]]; then
    msg_ok "${label}: Asset-Bundle HTTP 200 (${bytes} Byte) – ${path}"
    return 0
  fi
  msg_error "${label}: Asset-Bundle ${path} -> HTTP ${code}, ${bytes:-0} Byte"
  return 1
}

ASSET_FAIL=0
verify_asset_bundle / "Storefront" || ASSET_FAIL=1
verify_asset_bundle /admin/login "Admin-Login" || ASSET_FAIL=1
if [[ "$ASSET_FAIL" -ne 0 ]]; then
  die "CSS/JS-Bundles werden nicht ausgeliefert – die UI erscheint unformatiert. Prüfe die nginx-Regeln für /_assets/ und /livewire/."
fi

STATUS_JSON="$(curl -sS --max-time 10 "http://127.0.0.1:${APP_PORT}/status/api/status" || true)"
if ! jq -e '.database.ok and .services.php_fpm and .services.nginx and .services.mariadb' \
     >/dev/null 2>&1 <<< "$STATUS_JSON"; then
  msg_error "Status-API meldet einen unhealthy Zustand:"
  echo "$STATUS_JSON" || true
  die "Status-API-Verifikation fehlgeschlagen."
fi
msg_ok "Status-API bestätigt Datenbank, PHP-FPM, nginx und MariaDB."

echo
echo -e "${BGN}Provisionierung abgeschlossen.${CL}"
echo "  Storefront : http://${APP_IP}:${APP_PORT}/"
echo "  Admin      : http://${APP_IP}:${APP_PORT}/admin"
echo "  Status-UI  : http://${APP_IP}:${APP_PORT}/status/"
echo "  Credentials: ${CRED_FILE}"
