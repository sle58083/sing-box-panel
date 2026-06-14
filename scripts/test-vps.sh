#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL=0
SMOKE=0
FAILURES=0

OWNER="sle58083"
REPO="sing-box-panel"
BRANCH="main"
RAW_INSTALL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/install.sh"
RAW_UNINSTALL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/uninstall.sh"
ARCHIVE_URL="https://github.com/${OWNER}/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --smoke) SMOKE=1 ;;
    -h|--help)
      cat <<EOF
Usage: bash scripts/test-vps.sh [--install] [--smoke]

Default: static checks only.
  --install  Run bash install.sh after static checks.
  --smoke    Run service, nginx, port, and HTTP smoke checks.
EOF
      exit 0
      ;;
    *)
      echo "FAIL Unknown argument: $arg"
      exit 1
      ;;
  esac
done

pass() {
  printf 'PASS %s\n' "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL %s\n' "$*" >&2
}

run_check() {
  local message="$1"
  shift
  if "$@"; then
    pass "$message"
  else
    fail "$message"
  fi
}

require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    pass "Running as root"
  else
    fail "This VPS test script must be run as root"
  fi
}

file_exists() {
  [ -f "$1" ]
}

contains() {
  local file="$1"
  local pattern="$2"
  grep -Eq "$pattern" "$file"
}

check_required_files() {
  local files=(
    "install.sh"
    "uninstall.sh"
    "README.md"
    "LICENSE"
    "backend/app.py"
    "backend/db.py"
    "backend/auth.py"
    "backend/singbox.py"
    "backend/expire_worker.py"
    "backend/requirements.txt"
    "backend/static/index.html"
    "backend/static/login.html"
    "backend/static/app.js"
    "backend/static/style.css"
    "systemd/sing-box-panel.service"
    "systemd/sing-box-panel-expire.service"
    "systemd/sing-box-panel-expire.timer"
  )

  for file in "${files[@]}"; do
    run_check "Found ${file}" file_exists "$file"
  done
}

check_requirements() {
  run_check "requirements.txt contains fastapi" contains "backend/requirements.txt" '^fastapi=='
  run_check "requirements.txt contains uvicorn" contains "backend/requirements.txt" '^uvicorn'
}

check_no_placeholders() {
  if grep -R -nE '我的GitHub用户名|你的GitHub用户名|仓库名' install.sh README.md >/tmp/sing-box-panel-placeholders.txt 2>/dev/null; then
    cat /tmp/sing-box-panel-placeholders.txt >&2
    fail "GitHub placeholders still exist"
  else
    pass "No GitHub placeholders found in install.sh or README.md"
  fi
}

check_github_downloads() {
  run_check "install.sh defines OWNER=sle58083" contains "install.sh" 'OWNER="\$\{PANEL_OWNER:-sle58083\}"'
  run_check "install.sh defines REPO=sing-box-panel" contains "install.sh" 'REPO="\$\{PANEL_REPO:-sing-box-panel\}"'
  run_check "install.sh defines BRANCH=main" contains "install.sh" 'BRANCH="\$\{PANEL_BRANCH:-main\}"'
  run_check "install.sh defines GitHub archive URL" contains "install.sh" 'ARCHIVE_URL="https://github.com/\$\{OWNER\}/\$\{REPO\}/archive/refs/heads/\$\{BRANCH\}\.tar\.gz"'
  run_check "install.sh uses /tmp/sing-box-panel-install" contains "install.sh" '/tmp/sing-box-panel-install'
  run_check "README.md contains raw install command" contains "README.md" "https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/install.sh"
  run_check "README.md contains raw uninstall command" contains "README.md" "https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/uninstall.sh"
}

check_systemd_files() {
  local services=("systemd/sing-box-panel.service" "systemd/sing-box-panel-expire.service")
  for service in "${services[@]}"; do
    run_check "${service} has [Unit]" contains "$service" '^\[Unit\]$'
    run_check "${service} has [Service]" contains "$service" '^\[Service\]$'
  done
  run_check "sing-box-panel.service has [Install]" contains "systemd/sing-box-panel.service" '^\[Install\]$'
  run_check "expire timer has [Unit]" contains "systemd/sing-box-panel-expire.timer" '^\[Unit\]$'
  run_check "expire timer has [Timer]" contains "systemd/sing-box-panel-expire.timer" '^\[Timer\]$'
  run_check "expire timer has [Install]" contains "systemd/sing-box-panel-expire.timer" '^\[Install\]$'
}

check_nginx_logic() {
  run_check "install.sh writes Nginx server block" contains "install.sh" 'server \{'
  run_check "install.sh proxies to 127.0.0.1:54321" contains "install.sh" 'proxy_pass http://\$\{BACKEND_HOST\}:\$\{BACKEND_PORT\}'
  run_check "install.sh supports conf.d" contains "install.sh" '/etc/nginx/conf\.d'
  run_check "install.sh supports sites-available" contains "install.sh" '/etc/nginx/sites-available'
  run_check "install.sh supports sites-enabled" contains "install.sh" '/etc/nginx/sites-enabled'
  run_check "install.sh runs nginx -t" contains "install.sh" 'nginx -t'
  run_check "backend host is loopback only" contains "install.sh" 'BACKEND_HOST="127\.0\.0\.1"'
}

static_checks() {
  require_root
  check_required_files
  run_check "bash -n install.sh" bash -n install.sh
  run_check "bash -n uninstall.sh" bash -n uninstall.sh
  run_check "python3 syntax check backend/*.py" python3 -m py_compile backend/*.py
  check_requirements
  check_no_placeholders
  check_github_downloads
  check_systemd_files
  check_nginx_logic
}

run_install() {
  if [ "$INSTALL" -eq 1 ]; then
    run_check "bash install.sh" bash install.sh
  else
    pass "Skipping install.sh execution; pass --install to install"
  fi
}

smoke_checks() {
  if [ "$SMOKE" -ne 1 ]; then
    pass "Skipping smoke checks; pass --smoke to run them"
    return
  fi

  run_check "systemctl status sing-box-panel" systemctl status sing-box-panel --no-pager
  run_check "systemctl status sing-box-panel-expire.timer" systemctl status sing-box-panel-expire.timer --no-pager
  run_check "systemctl status nginx" systemctl status nginx --no-pager
  run_check "nginx -t" nginx -t
  run_check "ports 2053 or 54321 are listening" bash -c "ss -lntp | grep -E '2053|54321'"
  run_check "curl panel backend" curl -I http://127.0.0.1:54321
}

main() {
  static_checks
  run_install
  smoke_checks

  if [ "$FAILURES" -eq 0 ]; then
    pass "VPS test completed with 0 failures"
    exit 0
  fi

  fail "VPS test completed with ${FAILURES} failure(s)"
  exit 1
}

main "$@"
