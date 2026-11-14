#!/usr/bin/env bash
#
# Updates APP_URL in TastyIgniter's .env to the current container IP.
# Called as ExecStartPre by tastyigniter.service, so a container reboot with a
# new DHCP lease still produces the correct storefront/admin links.
#
set -euo pipefail

APP_DIR="/opt/tastyigniter"
ENV_FILE="${APP_DIR}/.env"

# shellcheck disable=SC1091
[[ -f /etc/default/tastyigniter ]] && source /etc/default/tastyigniter

APP_PORT="${APP_PORT:-8080}"
AUTO_APP_URL="${AUTO_APP_URL:-1}"

[[ -f "$ENV_FILE" ]] || exit 0
[[ "$AUTO_APP_URL" == "1" ]] || exit 0

if [[ -n "${APP_URL_OVERRIDE:-}" ]]; then
  new_url="$APP_URL_OVERRIDE"
else
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || exit 0
  new_url="http://${ip}:${APP_PORT}"
fi

current="$(grep -E '^APP_URL=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
[[ "$current" == "$new_url" ]] && exit 0

escaped="$(printf '%s' "$new_url" | sed 's/[&|]/\\&/g')"
if grep -qE '^APP_URL=' "$ENV_FILE"; then
  sed -i "s|^APP_URL=.*|APP_URL=${escaped}|" "$ENV_FILE"
else
  printf '\nAPP_URL=%s\n' "$new_url" >> "$ENV_FILE"
fi

chown www-data:www-data "$ENV_FILE" 2>/dev/null || true
chmod 640 "$ENV_FILE" 2>/dev/null || true
