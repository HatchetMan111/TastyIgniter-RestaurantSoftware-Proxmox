#!/usr/bin/env bash
#
# Smoke test for an installed TastyIgniter LXC on a Proxmox VE host.
#
# Usage (as root on the Proxmox host):
#   ./tests/proxmox-smoke-test.sh --ctid 123
#   ./tests/proxmox-smoke-test.sh --ctid 123 --reboot
#   ./tests/proxmox-smoke-test.sh            # auto-detect by tag/hostname
#
set -Eeuo pipefail

CT_ID="${CT_ID:-}"
PORT="${var_web_port:-}"
REBOOT=0
FAIL=0
PASS=0

ok()   { PASS=$((PASS + 1)); printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; }
info() { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERR ]\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [--ctid ID] [--port PORT] [--reboot]

  --ctid ID    Container ID (default: auto-detect tag/hostname tastyigniter)
  --port PORT  HTTP port (default: read /etc/default/tastyigniter)
  --reboot     Reboot the container first and wait for the UI to return
EOF
}

while (($# > 0)); do
  case "$1" in
    --ctid)   CT_ID="${2:-}"; shift 2 ;;
    --ctid=*) CT_ID="${1#*=}"; shift ;;
    --port)   PORT="${2:-}"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --reboot) REBOOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
command -v pct >/dev/null 2>&1 || die "pct not found — is this a Proxmox VE host?"

ct_hostname() {
  pct config "$1" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2; exit}'
}

ct_tags() {
  pct config "$1" 2>/dev/null | awk -F': ' '/^tags:/ {print $2; exit}'
}

find_ct() {
  local id host tags
  while read -r id; do
    [[ -z "$id" ]] && continue
    host="$(ct_hostname "$id")"
    tags="$(ct_tags "$id")"
    if [[ "$host" == "tastyigniter" || ",${tags}," == *,tastyigniter,* ]]; then
      echo "$id"
      return 0
    fi
  done < <(pct list 2>/dev/null | awk 'NR > 1 {print $1}')
  return 1
}

if [[ -z "$CT_ID" ]]; then
  CT_ID="$(find_ct || true)"
  [[ -n "$CT_ID" ]] || die "No TastyIgniter container found. Pass --ctid ID."
  info "Auto-detected CT ${CT_ID}."
fi

[[ "$CT_ID" =~ ^[0-9]+$ ]] || die "CT ID must be numeric."
pct status "$CT_ID" >/dev/null 2>&1 || die "CT ${CT_ID} does not exist."

if [[ "$(pct status "$CT_ID" | awk '{print $2}')" != "running" ]]; then
  die "CT ${CT_ID} is not running. Start it with: pct start ${CT_ID}"
fi

if [[ -z "$PORT" ]]; then
  PORT="$(pct exec "$CT_ID" -- awk -F= '/^APP_PORT=/ {print $2; exit}' /etc/default/tastyigniter 2>/dev/null || true)"
fi
[[ "$PORT" =~ ^[0-9]+$ ]] || PORT=8080

container_ip() {
  pct exec "$CT_ID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

wait_for_http() {
  local tries="${1:-90}" i
  for ((i = 1; i <= tries; i++)); do
    if pct exec "$CT_ID" -- curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${PORT}/status/" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

run_checks() {
  local ip state
  state="$(pct status "$CT_ID" | awk '{print $2}')"
  ip="$(container_ip || true)"

  echo
  printf '\033[1mTastyIgniter smoke test — CT %s\033[0m\n' "$CT_ID"
  echo "  Hostname : $(ct_hostname "$CT_ID")"
  echo "  State    : ${state}"
  echo "  IP       : ${ip:-unknown}"
  echo "  Port     : ${PORT}"
  echo

  [[ "$state" == "running" ]] && ok "container is running" || bad "container is not running"
  [[ -n "$ip" ]] && ok "container has IPv4 address ${ip}" || bad "container has no IPv4 address"

  if pct config "$CT_ID" | grep -q '^onboot: 1'; then
    ok "onboot=1 (survives host reboot)"
  else
    bad "onboot is not enabled"
  fi

  local svc
  for svc in tastyigniter nginx mariadb; do
    if pct exec "$CT_ID" -- systemctl is-active --quiet "$svc"; then
      ok "${svc}.service is active"
    else
      bad "${svc}.service is NOT active"
    fi
    if pct exec "$CT_ID" -- systemctl is-enabled --quiet "$svc"; then
      ok "${svc}.service is enabled"
    else
      bad "${svc}.service is NOT enabled"
    fi
  done

  local path code expected
  for path in / /admin/login /status/ /status/api/status; do
    code="$(pct exec "$CT_ID" -- curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}${path}" 2>/dev/null || true)"
    if [[ "$path" == "/" ]]; then
      expected='^(200|301|302)$'
    else
      expected='^200$'
    fi
    if [[ "$code" =~ $expected ]]; then
      ok "HTTP ${code} ${path}"
    else
      bad "HTTP ${code:-000} ${path}"
    fi
  done

  if pct exec "$CT_ID" -- jq -e '.ok and .services.php_fpm and .services.nginx and .services.mariadb and .database.ok' \
      >/dev/null 2>&1 <<<"$(pct exec "$CT_ID" -- curl -sS --max-time 10 "http://127.0.0.1:${PORT}/status/api/status" 2>/dev/null || true)"; then
    ok "status API reports a healthy stack"
  else
    bad "status API reports an unhealthy stack"
  fi

  if pct exec "$CT_ID" -- test -f /root/tastyigniter-credentials.txt; then
    ok "credentials file exists"
    local perms
    perms="$(pct exec "$CT_ID" -- stat -c '%a' /root/tastyigniter-credentials.txt 2>/dev/null || true)"
    [[ "$perms" == "600" ]] && ok "credentials file is chmod 600" || bad "credentials file permissions: ${perms:-unknown}"
  else
    bad "credentials file is missing"
  fi

  if [[ -n "$ip" ]] && curl -fsS -o /dev/null --max-time 10 "http://${ip}:${PORT}/status/" 2>/dev/null; then
    ok "UI reachable over container IP http://${ip}:${PORT}/status/"
  else
    bad "UI not reachable over container IP (check Proxmox firewall/bridge)"
  fi
}

if [[ "$REBOOT" == "1" ]]; then
  info "Rebooting CT ${CT_ID} …"
  pct reboot "$CT_ID"
  info "Waiting for the UI to come back (max. 3 minutes) …"
  wait_for_http 90 || die "UI did not return after reboot."
  ok "UI returned after reboot"
fi

run_checks

echo
printf 'Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
printf '\033[0;32mSmoke test passed.\033[0m\n'
