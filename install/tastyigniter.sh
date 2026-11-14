#!/usr/bin/env bash
#
# TastyIgniter – Proxmox VE Community-Script style installer
#
# One-liner:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TastyIgniter-RestaurantSoftware-Proxmox/main/install/tastyigniter.sh)"
#
# Actions:
#   install     Create or update a TastyIgniter LXC (default)
#   update      Re-provision an existing container (OS packages, migrations, permissions)
#   status      Show container/service/HTTP status
#   uninstall   Stop and destroy the container (asks for confirmation)
#
# Everything can be configured with environment variables, e.g.:
#   CT_ID=123 var_cpu=4 var_ram=4096 var_disk=16 bash -c "$(wget -qLO - ...)"
#
# Debugging:
#   DEBUG=1 bash -c "$(wget -qLO - ...)"   # full bash -x trace
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (Community-Scripts style variables)
# ---------------------------------------------------------------------------
APP="TastyIgniter"
APP_DESCRIPTION="Open-source restaurant ordering and management system"
GITHUB_REPO="${GITHUB_REPO:-HatchetMan111/TastyIgniter-RestaurantSoftware-Proxmox}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
REPO_TARBALL_URL="${REPO_TARBALL_URL:-https://codeload.github.com/${GITHUB_REPO}/tar.gz/refs/heads/${GITHUB_BRANCH}}"

var_hostname="${var_hostname:-tastyigniter}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_bridge="${var_bridge:-vmbr0}"
PORT_EXPLICIT=0
if [[ -n "${var_web_port:-}" ]]; then
  PORT_EXPLICIT=1
fi
var_web_port="${var_web_port:-8080}"
RESTAURANT_EXPLICIT=0
if [[ -n "${var_restaurant_name:-}" ]]; then
  RESTAURANT_EXPLICIT=1
fi
var_restaurant_name="${var_restaurant_name:-My Restaurant}"
ADMIN_EMAIL_EXPLICIT=0
if [[ -n "${var_admin_email:-}" ]]; then
  ADMIN_EMAIL_EXPLICIT=1
fi
var_admin_email="${var_admin_email:-admin@tastyigniter.local}"
TIMEZONE_EXPLICIT=0
if [[ -n "${var_timezone:-}" ]]; then
  TIMEZONE_EXPLICIT=1
fi
var_timezone="${var_timezone:-Europe/Berlin}"
var_os_type="${var_os_type:-debian}"
var_features="${var_features:-nesting=1,keyctl=1}"

# Optional static networking: var_ip=192.168.1.50 var_gw=192.168.1.1 var_cidr=24
var_ip="${var_ip:-}"
var_gw="${var_gw:-}"
var_cidr="${var_cidr:-24}"
var_vlan="${var_vlan:-}"

# TastyIgniter release. Set to "latest" to resolve via the GitHub API.
var_ti_version="${var_ti_version:-4.5.0}"

CT_ID="${CT_ID:-}"
DEBUG="${DEBUG:-0}"
FORCE="${FORCE:-0}"
LOG_FILE="${LOG_FILE:-/var/log/tastyigniter-install.log}"
PAYLOAD_FILE=""
PAYLOAD_TMPDIR=""

cleanup_payload() {
  if [[ -n "$PAYLOAD_TMPDIR" && -d "$PAYLOAD_TMPDIR" ]]; then
    rm -rf "$PAYLOAD_TMPDIR"
  fi
  return 0
}
trap cleanup_payload EXIT

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RD=$'\033[0;31m'; GN=$'\033[0;32m'; YW=$'\033[0;33m'; BL=$'\033[0;34m'
  BGN=$'\033[1;32m'; BLD=$'\033[1m'; CL=$'\033[0m'
else
  RD=""; GN=""; YW=""; BL=""; BGN=""; BLD=""; CL=""
fi

# Log messages go to stderr so command substitutions can safely return values.
msg_info()  { echo -e "${BL}[INFO]${CL}  $*" >&2; }
msg_ok()    { echo -e "${GN}[ OK ]${CL}  $*" >&2; }
msg_warn()  { echo -e "${YW}[WARN]${CL}  $*" >&2; }
msg_error() { echo -e "${RD}[ERR ]${CL}  $*" >&2; }
die()       { msg_error "$*"; trap - ERR; exit 1; }

banner() {
  echo -e "${BLD}"
  cat <<'EOF'
  _____         _         _____       _       _
 |_   _|_ _ ___| |_ _   _|_   _|__ __(_) __ _| |__   ___ _ __
   | |/ _` / __| __| | | | | |/ _ \ '_| |/ _` | '_ \ / _ \ '__|
   | | (_| \__ \ |_| |_| | | |  __/ | | | (_| | | | |  __/ |
   |_|\__,_|___/\__|\__, | |_|\___|_| |_|\__, |_| |_|\___|_|
                    |___/                |___/
EOF
  echo -e "${CL}${APP} – Proxmox VE installer${CL}"
  echo
}

# ---------------------------------------------------------------------------
# Error handling: full chain, never just the last line
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" line="$2" cmd="$3"
  trap - ERR
  set +e

  echo
  msg_error "Installation failed."
  echo "  Exit-Code : ${exit_code}"
  echo "  Zeile     : ${line}"
  echo "  Befehl    : ${cmd}"
  echo "  Host-Log  : ${LOG_FILE}"
  echo
  echo "----- Letzte 150 Zeilen Host-Log -----"
  # Give tee a moment to flush the lines above into the log file.
  sleep 0.5
  [[ -f "$LOG_FILE" ]] && tail -n 150 "$LOG_FILE"
  echo "--------------------------------------"

  if [[ "${CT_ID:-}" =~ ^[0-9]+$ ]] && pct status "$CT_ID" >/dev/null 2>&1; then
    echo
    echo "----- Container-Log (/var/log/tastyigniter-provision.log) -----"
    pct exec "$CT_ID" -- tail -n 200 /var/log/tastyigniter-provision.log 2>&1 || true
    echo "---------------------------------------------------------------"
    echo "----- systemctl status tastyigniter nginx mariadb -----"
    pct exec "$CT_ID" -- systemctl --no-pager --full status tastyigniter nginx mariadb 2>&1 || true
    echo "-------------------------------------------------------"
    echo "----- journalctl (letzte 100 Zeilen) -----"
    pct exec "$CT_ID" -- journalctl -u tastyigniter -u nginx -u mariadb --no-pager -n 100 2>&1 || true
    echo "------------------------------------------"
    echo "----- Laravel-Log -----"
    pct exec "$CT_ID" -- tail -n 120 /opt/tastyigniter/storage/logs/laravel.log 2>&1 || true
    echo "-----------------------"
    echo "----- nginx error.log -----"
    pct exec "$CT_ID" -- tail -n 80 /var/log/nginx/tastyigniter-error.log 2>&1 || true
    echo "---------------------------"
  fi

  echo
  echo "Für einen vollständigen Trace erneut ausführen mit:"
  echo "  GITHUB_REPO=${GITHUB_REPO} DEBUG=1 bash -c \"\$(wget -qLO - <INSTALL-URL>)\""
  echo
  exit "$exit_code"
}
if [[ "$DEBUG" == "1" ]]; then
  export PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}:${FUNCNAME[0]:-main}: '
  set -x
fi
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ACTION="${ACTION:-install}"
for arg in "$@"; do
  case "$arg" in
    install|update|status|uninstall) ACTION="$arg" ;;
    --debug) DEBUG=1 ;;
    --force) FORCE=1 ;;
    --ctid=*) CT_ID="${arg#*=}" ;;
    --port=*) var_web_port="${arg#*=}"; PORT_EXPLICIT=1 ;;
    --help|-h)
      cat <<EOF
${APP} Proxmox installer

Usage:
  bash tastyigniter.sh [install|update|status|uninstall] [options]

Options:
  --ctid=ID        Container ID (default: next free ID / existing tastyigniter CT)
  --port=PORT      Web UI port (default: ${var_web_port})
  --force          Do not ask for confirmation on uninstall
  --debug          Enable bash -x tracing
  -h, --help       Show this help

Environment variables:
  var_cpu var_ram var_disk var_bridge var_ip var_gw var_cidr
  var_web_port var_admin_email var_restaurant_name var_timezone
  var_ti_version GITHUB_REPO GITHUB_BRANCH FORCE DEBUG
EOF
      exit 0
      ;;
    *) die "Unbekanntes Argument: $arg (siehe --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  die "Dieses Script muss als root auf dem Proxmox-Host ausgeführt werden."
fi

for bin in pct pvesh pveam pvesm curl tar; do
  command -v "$bin" >/dev/null 2>&1 || die "Benötigtes Proxmox-Werkzeug fehlt: $bin"
done

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
if command -v stdbuf >/dev/null 2>&1; then
  # Line-buffer tee so on_error can read the log while the script is running.
  exec > >(stdbuf -o0 -e0 tee -a "$LOG_FILE") 2>&1
else
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

banner
msg_info "Aktion: ${ACTION}"
msg_info "Host-Log: ${LOG_FILE}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ct_hostname() {
  pct config "$1" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2; exit}'
}

ct_tags() {
  pct config "$1" 2>/dev/null | awk -F': ' '/^tags:/ {print $2; exit}'
}

# An existing CT belongs to us when it carries our tag, or (for containers
# created before tags existed) when its hostname matches.
is_app_ct() {
  local id="$1" host tags
  host="$(ct_hostname "$id")"
  [[ "$host" == "$var_hostname" ]] && return 0
  tags="$(ct_tags "$id")"
  [[ ",${tags}," == *,tastyigniter,* ]] && return 0
  return 1
}

# Custom ports survive updates/status calls: read the persisted value unless
# the caller explicitly passed --port/var_web_port.
ct_app_port() {
  local id="$1" port="" tmp=""
  port="$(pct exec "$id" -- awk -F= '/^APP_PORT=/ {print $2; exit}' /etc/default/tastyigniter 2>/dev/null || true)"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    tmp="$(mktemp)"
    if pct pull "$id" /etc/default/tastyigniter "$tmp" >/dev/null 2>&1; then
      port="$(awk -F= '/^APP_PORT=/ {print $2; exit}' "$tmp")"
    fi
    rm -f "$tmp"
  fi
  if [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "$port"
  fi
  return 0
}

refresh_port_from_ct() {
  local id="$1" saved=""
  [[ "$PORT_EXPLICIT" == "1" ]] && return 0
  saved="$(ct_app_port "$id")"
  if [[ -n "$saved" && "$saved" != "$var_web_port" ]]; then
    msg_info "Übernehme gespeicherten Web-Port ${saved} aus CT ${id}."
    var_web_port="$saved"
  fi
}

# Keep install-time choices (restaurant, admin e-mail, timezone) when the
# update one-liner is run without repeating every variable.
refresh_settings_from_ct() {
  local id="$1" value="" meta="/opt/tastyigniter-dashboard/install.json"
  [[ "$RESTAURANT_EXPLICIT" == "1" && "$ADMIN_EMAIL_EXPLICIT" == "1" && "$TIMEZONE_EXPLICIT" == "1" ]] && return 0

  if [[ "$RESTAURANT_EXPLICIT" != "1" ]]; then
    value="$(pct exec "$id" -- jq -r '.restaurant // empty' "$meta" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then var_restaurant_name="$value"; fi
  fi
  if [[ "$ADMIN_EMAIL_EXPLICIT" != "1" ]]; then
    value="$(pct exec "$id" -- jq -r '.admin_email // empty' "$meta" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then var_admin_email="$value"; fi
  fi
  if [[ "$TIMEZONE_EXPLICIT" != "1" ]]; then
    value="$(pct exec "$id" -- cat /etc/timezone 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "$value" ]]; then var_timezone="$value"; fi
  fi
  return 0
}

find_app_ct() {
  local id
  while read -r id; do
    [[ -z "$id" ]] && continue
    if is_app_ct "$id"; then
      echo "$id"
      return 0
    fi
  done < <(pct list 2>/dev/null | awk 'NR > 1 {print $1}')
  return 1
}

next_free_ctid() {
  local id="" i
  id="$(pvesh get /cluster/nextid --output-format json 2>/dev/null | tr -d '"[:space:]' || true)"
  if [[ ! "$id" =~ ^[0-9]+$ ]]; then
    for i in $(seq 100 999); do
      if ! pct status "$i" >/dev/null 2>&1 && ! qm status "$i" >/dev/null 2>&1; then
        id="$i"
        break
      fi
    done
  fi
  [[ "$id" =~ ^[0-9]+$ ]] || die "Konnte keine freie Container-ID ermitteln."
  echo "$id"
}

detect_bridge() {
  local b
  if ip link show "$var_bridge" >/dev/null 2>&1; then
    echo "$var_bridge"
    return
  fi
  b="$(awk '/^auto vmbr[0-9]+/ {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)"
  [[ -n "$b" ]] || b="vmbr0"
  echo "$b"
}

detect_rootfs_storage() {
  local first
  first="$(pvesm status -content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')"
  [[ -n "$first" ]] || die "Kein aktiver Storage mit Content-Typ 'rootdir' gefunden."
  if pvesm status -content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}' | grep -qx 'local-lvm'; then
    echo "local-lvm"
  else
    echo "$first"
  fi
}

detect_template_storage() {
  local s
  s="$(pvesm status -content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')"
  [[ -n "$s" ]] || die "Kein aktiver Storage mit Content-Typ 'vztmpl' gefunden."
  echo "$s"
}

ensure_template() {
  local storage="$1" existing="" available=""
  local pattern="debian-${var_version}-standard"

  existing="$(pveam list "$storage" 2>/dev/null | awk -v p="$pattern" 'index($0,p) {print $1}' | sort -V | tail -1)"
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return 0
  fi

  msg_info "Debian-${var_version}-Template wird heruntergeladen …"
  pveam update >/dev/null 2>&1 || msg_warn "pveam update fehlgeschlagen – versuche Download trotzdem."
  available="$(pveam available --section system 2>/dev/null | awk -v p="$pattern" 'index($2,p) == 1 {print $2}' | sort -V | tail -1)"
  [[ -n "$available" ]] || die "Kein Debian-${var_version}-Template in 'pveam available' gefunden. Benötigt wird Debian ${var_version} (Proxmox VE 9)."
  pveam download "$storage" "$available"

  existing="$(pveam list "$storage" 2>/dev/null | awk -v p="$pattern" 'index($0,p) {print $1}' | sort -V | tail -1)"
  [[ -n "$existing" ]] || die "Debian-${var_version}-Template konnte nicht bereitgestellt werden."
  echo "$existing"
}

wait_for_ip() {
  local id="$1" i ip=""
  for i in $(seq 1 90); do
    ip="$(pct exec "$id" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    sleep 2
  done
  return 1
}

build_payload() {
  local tmpdir
  tmpdir="$(mktemp -d /tmp/tastyigniter-payload.XXXXXX)"
  PAYLOAD_TMPDIR="$tmpdir"
  PAYLOAD_FILE="${tmpdir}/repo.tar.gz"

  local local_root=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    local candidate
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -f "${candidate}/install/provision.sh" ]]; then
      local_root="$candidate"
    fi
  fi

  if [[ -n "$local_root" ]]; then
    msg_info "Verwende lokales Repository: ${local_root}"
    tar -C "$local_root" \
      --exclude='.git' \
      --exclude='node_modules' \
      --exclude='app/dashboard/node_modules' \
      -czf "$PAYLOAD_FILE" .
  else
    [[ "$GITHUB_REPO" == */* ]] || \
      die "GITHUB_REPO muss die Form USER/REPO haben (aktuell: '${GITHUB_REPO}')."
    msg_info "Lade Repository-Archiv von GitHub: ${GITHUB_REPO}@${GITHUB_BRANCH}"
    curl -fsSL --retry 3 --connect-timeout 15 "$REPO_TARBALL_URL" -o "${tmpdir}/repo.tar.gz"
    tar -tzf "${tmpdir}/repo.tar.gz" >/dev/null || die "Heruntergeladenes Repository-Archiv ist ungültig."
  fi

  [[ -s "$PAYLOAD_FILE" ]] || die "Repository-Payload konnte nicht erstellt werden."
}

container_exec() {
  local id="$1"; shift
  pct exec "$id" -- "$@"
}

verify_installation() {
  local id="$1" ip="$2" port="$3"
  local ok=0

  msg_info "Verifiziere systemd-Services …"
  for svc in tastyigniter nginx mariadb; do
    if container_exec "$id" systemctl is-active --quiet "$svc"; then
      msg_ok "Service ${svc}: active"
    else
      msg_error "Service ${svc}: NICHT active"
      ok=1
    fi
    if container_exec "$id" systemctl is-enabled --quiet "$svc"; then
      msg_ok "Service ${svc}: enabled (reboot-safe)"
    else
      msg_error "Service ${svc}: NICHT enabled"
      ok=1
    fi
  done

  if pct config "$id" | grep -q '^onboot: 1'; then
    msg_ok "Container CT ${id}: onboot=1 (startet nach Host-Reboot)"
  else
    msg_error "Container CT ${id}: onboot ist nicht aktiviert"
    ok=1
  fi

  msg_info "Verifiziere HTTP-Endpunkte …"
  local url
  for url in \
    "http://127.0.0.1:${port}/" \
    "http://127.0.0.1:${port}/admin/login" \
    "http://127.0.0.1:${port}/status/" \
    "http://127.0.0.1:${port}/status/api/status"; do
    local code=""
    code="$(container_exec "$id" curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^(200|302|301)$ ]]; then
      msg_ok "HTTP ${code} – ${url}"
    else
      msg_error "HTTP ${code:-000} – ${url}"
      ok=1
    fi
  done

  if [[ "$ok" -ne 0 ]]; then
    msg_error "Verifikation fehlgeschlagen. Logs: ${LOG_FILE} und /var/log/tastyigniter-provision.log im Container."
    return 1
  fi

  msg_info "Prüfe Erreichbarkeit über Container-IP …"
  if curl -fsS -o /dev/null --max-time 10 "http://${ip}:${port}/" 2>/dev/null; then
    msg_ok "Web-UI über http://${ip}:${port}/ erreichbar"
  else
    msg_warn "Web-UI über die Container-IP nicht erreichbar – prüfe Proxmox-Firewall / Bridge."
  fi
}

credentials_summary() {
  local id="$1" ip="$2" port="$3"
  echo
  echo -e "${BGN}══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BGN} ${APP} ist bereit${CL}"
  echo -e "${BGN}══════════════════════════════════════════════════════════════${CL}"
  echo -e "  Container     : ${BLD}${id}${CL} (${var_hostname})"
  echo -e "  IP-Adresse    : ${BLD}${ip}${CL}"
  echo -e "  Storefront    : ${BGN}http://${ip}:${port}/${CL}"
  echo -e "  Admin         : ${BGN}http://${ip}:${port}/admin${CL}"
  echo -e "  Status-UI     : ${BGN}http://${ip}:${port}/status/${CL}"
  echo
  echo -e "  Zugangsdaten  : ${BLD}/root/tastyigniter-credentials.txt${CL} (im Container)"
  echo -e "  Anzeigen      : pct exec ${id} -- cat /root/tastyigniter-credentials.txt"
  echo
  echo -e "  Services      : systemctl status tastyigniter nginx mariadb"
  echo -e "  App-Log       : pct exec ${id} -- tail -f /opt/tastyigniter/storage/logs/laravel.log"
  echo -e "  Install-Log   : ${LOG_FILE}"
  echo -e "${BGN}══════════════════════════════════════════════════════════════${CL}"
}

# ---------------------------------------------------------------------------
# Resolve container
# ---------------------------------------------------------------------------
resolve_ct() {
  local require_existing="${1:-0}"
  if [[ -z "$CT_ID" ]]; then
    local existing
    existing="$(find_app_ct || true)"
    if [[ -n "$existing" ]]; then
      CT_ID="$existing"
      msg_ok "Bestehenden ${APP}-Container gefunden: CT ${CT_ID}"
      REUSED=1
    elif [[ "$require_existing" == "1" ]]; then
      die "Kein ${APP}-Container gefunden. CT-ID mit --ctid=ID angeben oder zuerst installieren."
    else
      CT_ID="$(next_free_ctid)"
      msg_info "Nächste freie CT-ID: ${CT_ID}"
      REUSED=0
    fi
  else
    [[ "$CT_ID" =~ ^[0-9]+$ ]] || die "CT_ID muss numerisch sein."
    if pct status "$CT_ID" >/dev/null 2>&1; then
      if ! is_app_ct "$CT_ID" && [[ "$FORCE" != "1" ]]; then
        die "CT ${CT_ID} existiert bereits mit Hostname '$(ct_hostname "$CT_ID")'. Nutze eine andere ID oder FORCE=1."
      fi
      msg_ok "Verwende bestehenden Container CT ${CT_ID}"
      REUSED=1
    elif [[ "$require_existing" == "1" ]]; then
      die "Container CT ${CT_ID} existiert nicht."
    else
      REUSED=0
    fi
  fi
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_install() {
  resolve_ct

  local ip
  if pct status "$CT_ID" >/dev/null 2>&1; then
    if [[ "$(pct status "$CT_ID" | awk '{print $2}')" != "running" ]]; then
      msg_info "Starte Container CT ${CT_ID} …"
      pct start "$CT_ID"
    fi
  else
    local template storage bridge net0
    storage="$(detect_rootfs_storage)"
    bridge="$(detect_bridge)"
    msg_info "Rootfs-Storage : ${storage}"
    msg_info "Bridge         : ${bridge}"
    template="$(ensure_template "$(detect_template_storage)")"
    msg_info "Template       : ${template}"

    if [[ -n "$var_ip" ]]; then
      [[ -n "$var_gw" ]] || die "var_ip gesetzt, aber var_gw fehlt."
      net0="name=eth0,bridge=${bridge},ip=${var_ip}/${var_cidr},gw=${var_gw},type=veth"
    else
      net0="name=eth0,bridge=${bridge},ip=dhcp,type=veth"
    fi
    [[ -n "$var_vlan" ]] && net0="${net0},tag=${var_vlan}"

    msg_info "Erstelle LXC CT ${CT_ID} (${var_cpu} vCPU, ${var_ram} MB RAM, ${var_disk} GB Disk) …"
    pct create "$CT_ID" "$template" \
      --hostname "$var_hostname" \
      --cores "$var_cpu" \
      --memory "$var_ram" \
      --swap "$var_ram" \
      --rootfs "${storage}:${var_disk}" \
      --net0 "$net0" \
      --unprivileged "$var_unprivileged" \
      --features "$var_features" \
      --onboot 1 \
      --ostype "$var_os_type" \
      --description "${APP} – ${APP_DESCRIPTION} (managed by tastyigniter-proxmox)" \
      --start 0

    pct set "$CT_ID" --onboot 1 --tags "tastyigniter,restaurant" >/dev/null 2>&1 || \
      msg_warn "Tags konnten nicht gesetzt werden (ältere Proxmox-Version)."
    msg_ok "Container CT ${CT_ID} erstellt."

    msg_info "Starte Container …"
    pct start "$CT_ID"
  fi

  msg_info "Warte auf Netzwerk im Container …"
  ip="$(wait_for_ip "$CT_ID" || true)"
  if [[ -z "$ip" ]]; then
    if [[ -n "$var_ip" ]]; then
      ip="$var_ip"
    else
      die "Container hat keine IPv4-Adresse erhalten. Prüfe Bridge/DHCP oder setze var_ip/var_gw."
    fi
  fi
  msg_ok "Container-IP: ${ip}"
  refresh_port_from_ct "$CT_ID"
  refresh_settings_from_ct "$CT_ID"

  local payload
  build_payload
  payload="$PAYLOAD_FILE"
  msg_info "Übertrage Installationsdateien in den Container …"
  pct push "$CT_ID" "$PAYLOAD_FILE" /tmp/tastyigniter-proxmox.tar.gz --perms 600
  msg_ok "Dateien übertragen."

  msg_info "Provisioniere ${APP} (dies kann einige Minuten dauern) …"
  local provision_action="install"
  [[ "${REUSED:-0}" == "1" ]] && provision_action="update"

  pct exec "$CT_ID" -- env \
    APP_CTID="$CT_ID" \
    APP_IP="$ip" \
    APP_PORT="$var_web_port" \
    APP_TIMEZONE="$var_timezone" \
    ADMIN_EMAIL="$var_admin_email" \
    RESTAURANT_NAME="$var_restaurant_name" \
    TI_VERSION="$var_ti_version" \
    PROVISION_ACTION="$provision_action" \
    bash -lc '
      set -Eeuo pipefail
      rm -rf /opt/tastyigniter-proxmox
      mkdir -p /opt/tastyigniter-proxmox
      tar -xzf /tmp/tastyigniter-proxmox.tar.gz -C /opt/tastyigniter-proxmox
      bash /opt/tastyigniter-proxmox/install/provision.sh
    '

  msg_ok "Provisionierung abgeschlossen."
  verify_installation "$CT_ID" "$ip" "$var_web_port"
  credentials_summary "$CT_ID" "$ip" "$var_web_port"
}

do_update() {
  resolve_ct 1
  if ! pct status "$CT_ID" >/dev/null 2>&1; then
    die "Container CT ${CT_ID} existiert nicht."
  fi
  if [[ "$(pct status "$CT_ID" | awk '{print $2}')" != "running" ]]; then
    pct start "$CT_ID"
  fi
  local ip
  ip="$(wait_for_ip "$CT_ID" || true)"
  [[ -n "$ip" ]] || die "Container hat keine IPv4-Adresse."
  refresh_port_from_ct "$CT_ID"
  refresh_settings_from_ct "$CT_ID"

  local payload
  build_payload
  payload="$PAYLOAD_FILE"
  pct push "$CT_ID" "$payload" /tmp/tastyigniter-proxmox.tar.gz --perms 600

  msg_info "Aktualisiere ${APP} in CT ${CT_ID} …"
  pct exec "$CT_ID" -- env \
    APP_CTID="$CT_ID" \
    APP_IP="$ip" \
    APP_PORT="$var_web_port" \
    APP_TIMEZONE="$var_timezone" \
    ADMIN_EMAIL="$var_admin_email" \
    RESTAURANT_NAME="$var_restaurant_name" \
    TI_VERSION="$var_ti_version" \
    PROVISION_ACTION="update" \
    bash -lc '
      set -Eeuo pipefail
      rm -rf /opt/tastyigniter-proxmox
      mkdir -p /opt/tastyigniter-proxmox
      tar -xzf /tmp/tastyigniter-proxmox.tar.gz -C /opt/tastyigniter-proxmox
      bash /opt/tastyigniter-proxmox/install/provision.sh
    '

  verify_installation "$CT_ID" "$ip" "$var_web_port"
  credentials_summary "$CT_ID" "$ip" "$var_web_port"
}

do_status() {
  resolve_ct 1
  echo
  echo -e "${BLD}${APP} Status${CL}"
  echo "  CT-ID      : ${CT_ID}"
  echo "  Hostname   : $(ct_hostname "$CT_ID" 2>/dev/null || echo '-')"
  local state
  state="$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}' || echo '-')"
  echo "  Status     : ${state:-'-'}"
  local ip=""
  refresh_port_from_ct "$CT_ID"
  if [[ "$state" == "running" ]]; then
    ip="$(wait_for_ip "$CT_ID" 2>/dev/null || true)"
  fi
  echo "  IP         : ${ip:-'-'}"
  echo "  Storefront : http://${ip:-<IP>}:${var_web_port}/"
  echo "  Admin      : http://${ip:-<IP>}:${var_web_port}/admin"
  echo "  Status-UI  : http://${ip:-<IP>}:${var_web_port}/status/"
  echo
  if [[ -n "$ip" ]]; then
    echo "Services:"
    for svc in tastyigniter nginx mariadb; do
      printf '  %-14s %s\n' "$svc" "$(container_exec "$CT_ID" systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    done
    echo
    echo "HTTP:"
    for path in / /admin/login /status/; do
      printf '  %-14s %s\n' "$path" "$(container_exec "$CT_ID" curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${var_web_port}${path}" 2>/dev/null || echo 000)"
    done
  fi
}

do_uninstall() {
  resolve_ct 1
  if [[ "$FORCE" != "1" ]]; then
    echo
    echo "ACHTUNG: CT ${CT_ID} (${var_hostname}) und alle Daten werden gelöscht."
    if [[ -r /dev/tty ]]; then
      read -r -p "Zum Bestätigen 'DELETE ${CT_ID}' eingeben: " answer </dev/tty
    else
      read -r -p "Zum Bestätigen 'DELETE ${CT_ID}' eingeben: " answer
    fi
    [[ "$answer" == "DELETE ${CT_ID}" ]] || die "Abgebrochen."
  fi
  if pct status "$CT_ID" >/dev/null 2>&1; then
    msg_info "Stoppe Container …"
    pct stop "$CT_ID" || true
    msg_info "Zerstöre Container …"
    pct destroy "$CT_ID"
  fi
  msg_ok "${APP} CT ${CT_ID} wurde entfernt."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$ACTION" in
  install)   do_install ;;
  update)    do_update ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
  *)         die "Unbekannte Aktion: $ACTION" ;;
esac
