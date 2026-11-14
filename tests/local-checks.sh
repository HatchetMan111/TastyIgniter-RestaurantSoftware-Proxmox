#!/usr/bin/env bash
#
# Local quality gate — runs without a Proxmox host.
#
# Usage:
#   ./tests/local-checks.sh
#   SKIP_BUILD=1 ./tests/local-checks.sh   # skip the Vite build
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
PASS=0

ok()   { PASS=$((PASS + 1)); printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; }
skip() { printf '\033[0;33m[SKIP]\033[0m  %s\n' "$*"; }

section() {
  printf '\n\033[1m%s\033[0m\n' "$*"
}

section "Shell syntax"
for script in install/tastyigniter.sh install/provision.sh config/tastyigniter-url.sh tests/local-checks.sh tests/proxmox-smoke-test.sh; do
  [[ -f "$script" ]] || { bad "missing: $script"; continue; }
  if bash -n "$script"; then ok "bash -n $script"; else bad "bash -n $script"; fi
done

section "ShellCheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning install/tastyigniter.sh install/provision.sh config/tastyigniter-url.sh; then
    ok "shellcheck (warning level)"
  else
    bad "shellcheck reported findings"
  fi
else
  skip "shellcheck not installed"
fi

section "PHP lint"
PHP_BIN="$(command -v php || true)"
if [[ -n "$PHP_BIN" ]]; then
  for file in app/scripts/create-admin.php app/dashboard/api/status.php; do
    if "$PHP_BIN" -l "$file" >/dev/null; then ok "php -l $file"; else bad "php -l $file"; fi
  done
else
  skip "php not installed"
fi

section "Required files"
required=(
  install/tastyigniter.sh
  install/provision.sh
  config/nginx-tastyigniter.conf
  config/tastyigniter-url.sh
  config/tastyigniter.default
  systemd/tastyigniter.service
  app/scripts/create-admin.php
  app/dashboard/api/status.php
  app/dashboard/dist/index.html
  README.md
  LICENSE
)
for file in "${required[@]}"; do
  [[ -s "$file" ]] && ok "present: $file" || bad "missing/empty: $file"
done

section "Template placeholders"
check_contains() {
  local file="$1" needle="$2"
  if grep -Fq -- "$needle" "$file"; then ok "$file contains $needle"; else bad "$file lacks $needle"; fi
}
check_contains config/nginx-tastyigniter.conf '__PORT__'
check_contains config/nginx-tastyigniter.conf '__PHP_SOCK__'
check_contains config/nginx-tastyigniter.conf '/status/api/status'
check_contains systemd/tastyigniter.service '__PHP_FPM_BIN__'
check_contains systemd/tastyigniter.service 'Restart=always'
check_contains systemd/tastyigniter.service 'After=network-online.target'

section "Reboot safety"
check_contains install/tastyigniter.sh '--onboot 1'
check_contains install/provision.sh 'systemctl enable tastyigniter'
check_contains config/tastyigniter-url.sh 'APP_URL'

section "Dashboard build"
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  skip "SKIP_BUILD=1"
elif command -v npm >/dev/null 2>&1; then
  if (cd app/dashboard && npm run build >/tmp/tastyigniter-local-build.log 2>&1); then
    ok "npm run build"
  else
    bad "npm run build (see /tmp/tastyigniter-local-build.log)"
    tail -n 30 /tmp/tastyigniter-local-build.log || true
  fi
else
  skip "npm not installed"
fi

if [[ -f app/dashboard/dist/index.html ]]; then
  if grep -Fq '/status/assets/' app/dashboard/dist/index.html; then
    ok "dashboard uses /status/ base path"
  else
    bad "dashboard build does not use /status/ base path"
  fi
else
  bad "app/dashboard/dist/index.html missing"
fi

section "GitHub payload normalisation"
# Regression guard: GitHub tar.gz archives have a single top-level directory
# (REPO-BRANCH/). The installer must strip it, otherwise provision.sh ends up
# at /opt/tastyigniter-proxmox/REPO-BRANCH/install/provision.sh and the
# install fails with exit code 127.
if grep -Fq 'payload_from_github_archive()' install/tastyigniter.sh; then
  ok "installer defines payload_from_github_archive()"
else
  bad "installer lacks payload_from_github_archive()"
fi

fixture="$(mktemp -d /tmp/tastyigniter-payload-check.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/src/repo-main"
cp -a install config systemd "$fixture/src/repo-main"
tar -C "$fixture/src" -czf "$fixture/github-style.tar.gz" repo-main

if bash -c '
  set -Eeuo pipefail
  PATH_PAYLOAD_EXCLUDES=(--exclude=.git --exclude=node_modules --exclude=app/dashboard/node_modules)
  '"$(sed -n '/^payload_from_github_archive()/,/^}/p' install/tastyigniter.sh)"'
  payload_from_github_archive "$1" "$2" "$3"
' _ "$fixture/github-style.tar.gz" "$fixture/payload.tar.gz" "$fixture"; then
  ok "normalisation exits 0 for a GitHub-style archive"
else
  bad "normalisation failed for a GitHub-style archive"
fi

if tar -tzf "$fixture/payload.tar.gz" | grep -qx './install/provision.sh'; then
  ok "payload root contains install/provision.sh"
else
  bad "payload root lacks install/provision.sh (top-level dir not stripped)"
fi

if tar -tzf "$fixture/payload.tar.gz" | grep -q '^\./repo-main/'; then
  bad "payload still contains the GitHub top-level directory"
else
  ok "GitHub top-level directory removed"
fi

mkdir -p "$fixture/bad/repo-main"
tar -C "$fixture/bad" -czf "$fixture/no-provision.tar.gz" repo-main
if bash -c '
  set -Eeuo pipefail
  PATH_PAYLOAD_EXCLUDES=()
  '"$(sed -n '/^payload_from_github_archive()/,/^}/p' install/tastyigniter.sh)"'
  payload_from_github_archive "$1" "$2" "$3"
' _ "$fixture/no-provision.tar.gz" "$fixture/bad-payload.tar.gz" "$fixture" >/dev/null 2>&1; then
  bad "normalisation accepted an archive without install/provision.sh"
else
  ok "normalisation rejects an archive without install/provision.sh"
fi

section "Summary"
printf 'Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
printf '\033[0;32mAll local checks passed.\033[0m\n'
