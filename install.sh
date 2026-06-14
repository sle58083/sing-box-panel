#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="sing-box-panel"
APP_DIR="/opt/${APP_NAME}"
CONFIG_DIR="/etc/${APP_NAME}"
DB_PATH="${CONFIG_DIR}/panel.db"
SECRET_PATH="${CONFIG_DIR}/session_secret"
ADMIN_FILE="${CONFIG_DIR}/admin.txt"
BACKEND_HOST="127.0.0.1"
BACKEND_PORT="54321"
DEFAULT_PANEL_PORT="2053"
PANEL_PORT="${PANEL_PORT:-}"
OWNER="${PANEL_OWNER:-sle58083}"
REPO="${PANEL_REPO:-sing-box-panel}"
BRANCH="${PANEL_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}"
GITHUB_REPO_URL="https://github.com/${OWNER}/${REPO}"
ARCHIVE_URL="https://github.com/${OWNER}/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
SING_BOX_INSTALL_URL="https://github.com/233boy/sing-box/raw/main/install.sh"

OS_ID=""
OS_NAME=""
OS_VERSION=""
OS_VERSION_ID=""
ARCH=""
ARCH_FAMILY=""
PKG_MANAGER=""
PYTHON_BIN=""
SOURCE_DIR=""
TMP_DIR=""
NGINX_CONFIG_PATH=""
SERVER_IP=""
ADMIN_USERNAME="${PANEL_ADMIN_USERNAME:-}"
ADMIN_PASSWORD=""

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*"
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  local reason="${1:-unknown error}"
  log_error "$reason"
  if [ -n "${OS_NAME:-}" ] || [ -n "${ARCH:-}" ]; then
    log_error "System: ${OS_NAME:-unknown} ${OS_VERSION:-unknown}, arch: ${ARCH:-unknown}"
  fi
  exit 1
}

has_tty() {
  { true </dev/tty; } >/dev/null 2>&1
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer=""
  local suffix="[y/N]"
  [ "$default" = "y" ] && suffix="[Y/n]"

  if has_tty; then
    read -r -p "${prompt} ${suffix} " answer </dev/tty || true
  else
    log_warn "No interactive tty available; using default answer '${default}' for: ${prompt}"
    answer="$default"
  fi

  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

detect_os() {
  if [ "$(uname -s)" != "Linux" ]; then
    OS_NAME="$(uname -s)"
    OS_VERSION="$(uname -r)"
    die "Unsupported OS: only Linux VPS systems with systemd are supported."
  fi

  if [ ! -r /etc/os-release ]; then
    die "Cannot detect Linux distribution: /etc/os-release is missing. Minimal containers are not supported."
  fi

  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_NAME="${NAME:-$OS_ID}"
  OS_VERSION="${VERSION:-${VERSION_ID:-unknown}}"
  OS_VERSION_ID="${VERSION_ID:-}"

  case "$OS_ID" in
    debian|ubuntu|centos|rhel|rocky|almalinux|ol|fedora|arch|manjaro|opensuse-leap|opensuse-tumbleweed|opensuse|sles)
      ;;
    alpine)
      die "Unsupported distribution: Alpine is not supported because this panel requires systemd."
      ;;
    openwrt)
      die "Unsupported distribution: OpenWrt is not supported."
      ;;
    *)
      if [ "${ID_LIKE:-}" ]; then
        case " ${ID_LIKE} " in
          *" debian "*|*" ubuntu "*|*" rhel "*|*" fedora "*|*" arch "*|*" suse "*)
            ;;
          *)
            die "Unsupported distribution."
            ;;
        esac
      else
        die "Unsupported distribution."
      fi
      ;;
  esac
}

detect_arch() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)
      ARCH_FAMILY="amd64"
      ;;
    aarch64|arm64)
      ARCH_FAMILY="arm64"
      ;;
    *)
      die "Unsupported CPU architecture. Only x86_64/amd64 and aarch64/arm64 are supported."
      ;;
  esac
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This installer must be run as root."
  fi
}

check_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl was not found. Docker minimal containers and non-systemd systems are not supported."
  fi
  if [ ! -d /run/systemd/system ]; then
    die "systemd is not running. Docker minimal containers and non-systemd systems are not supported."
  fi
}

detect_package_manager() {
  case "$OS_ID" in
    debian|ubuntu)
      PKG_MANAGER="apt"
      PYTHON_BIN="python3"
      ;;
    centos|rhel|rocky|almalinux|ol|fedora)
      if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
      elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
      else
        die "Neither dnf nor yum was found."
      fi
      PYTHON_BIN="python3"
      ;;
    arch|manjaro)
      PKG_MANAGER="pacman"
      PYTHON_BIN="python"
      ;;
    opensuse-leap|opensuse-tumbleweed|opensuse|sles)
      PKG_MANAGER="zypper"
      PYTHON_BIN="python3"
      ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*)
          PKG_MANAGER="apt"
          PYTHON_BIN="python3"
          ;;
        *" rhel "*|*" fedora "*)
          if command -v dnf >/dev/null 2>&1; then
            PKG_MANAGER="dnf"
          elif command -v yum >/dev/null 2>&1; then
            PKG_MANAGER="yum"
          else
            die "Neither dnf nor yum was found."
          fi
          PYTHON_BIN="python3"
          ;;
        *" arch "*)
          PKG_MANAGER="pacman"
          PYTHON_BIN="python"
          ;;
        *" suse "*)
          PKG_MANAGER="zypper"
          PYTHON_BIN="python3"
          ;;
        *)
          die "Cannot select a supported package manager for this distribution."
          ;;
      esac
      ;;
  esac
}

install_dependencies() {
  log_info "Installing dependencies with ${PKG_MANAGER}..."
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y python3 python3-venv python3-pip nginx curl wget sqlite3 openssl tar gzip ca-certificates
      ;;
    dnf)
      dnf install -y python3 python3-pip nginx curl wget sqlite openssl tar gzip ca-certificates
      ;;
    yum)
      yum install -y python3 python3-pip nginx curl wget sqlite openssl tar gzip ca-certificates
      ;;
    pacman)
      pacman -Sy --needed --noconfirm python python-pip nginx curl wget sqlite openssl tar gzip ca-certificates
      ;;
    zypper)
      zypper --non-interactive refresh
      zypper --non-interactive install python3 python3-pip nginx curl wget sqlite3 openssl tar gzip ca-certificates
      ;;
    *)
      die "Unsupported package manager: ${PKG_MANAGER}"
      ;;
  esac
}

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1 || [ -x /usr/local/bin/sing-box ]; then
    log_info "233boy/sing-box management command already exists; skipping install."
    return
  fi
  log_info "Installing 233boy/sing-box..."
  bash <(wget -qO- "$SING_BOX_INSTALL_URL")
}

choose_panel_port() {
  if [ -n "$PANEL_PORT" ]; then
    return
  fi

  local input=""
  if has_tty; then
    read -r -p "Panel port [${DEFAULT_PANEL_PORT}]: " input </dev/tty || true
  fi
  PANEL_PORT="${input:-$DEFAULT_PANEL_PORT}"

  if ! printf '%s' "$PANEL_PORT" | grep -Eq '^[0-9]{1,5}$'; then
    die "Invalid panel port: ${PANEL_PORT}"
  fi
  if [ "$PANEL_PORT" -lt 1 ] || [ "$PANEL_PORT" -gt 65535 ]; then
    die "Panel port must be between 1 and 65535."
  fi
}

prompt_admin_credentials() {
  if [ -n "$ADMIN_USERNAME" ] && [ -n "$ADMIN_PASSWORD" ]; then
    return
  fi

  if [ -z "$ADMIN_USERNAME" ]; then
    local input_username=""
    if has_tty; then
      read -r -p "Panel admin username [admin]: " input_username </dev/tty || true
    fi
    ADMIN_USERNAME="${input_username:-admin}"
  fi

  if ! printf '%s' "$ADMIN_USERNAME" | grep -Eq '^[A-Za-z0-9_.-]{1,64}$'; then
    die "Invalid admin username. Use 1-64 chars: letters, numbers, underscore, dash or dot."
  fi

  if [ -n "${PANEL_ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASSWORD="$PANEL_ADMIN_PASSWORD"
    return
  fi

  if has_tty; then
    local password_one=""
    local password_two=""
    while true; do
      read -r -s -p "Panel admin password: " password_one </dev/tty || true
      printf '\n' >/dev/tty
      read -r -s -p "Confirm panel admin password: " password_two </dev/tty || true
      printf '\n' >/dev/tty

      if [ -z "$password_one" ]; then
        log_warn "Password cannot be empty."
        continue
      fi
      if [ "$password_one" != "$password_two" ]; then
        log_warn "Passwords do not match. Please try again."
        continue
      fi
      ADMIN_PASSWORD="$password_one"
      break
    done
  else
    ADMIN_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
    log_warn "No interactive tty available; generated a random admin password."
  fi
}

prepare_source() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || true)"
  if [ -n "$script_dir" ] && [ -d "${script_dir}/backend" ]; then
    SOURCE_DIR="$script_dir"
    log_info "Using local project source: ${SOURCE_DIR}"
    return
  fi

  TMP_DIR="/tmp/sing-box-panel-install"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  local archive="${TMP_DIR}/source.tar.gz"
  log_info "Downloading project source: ${ARCHIVE_URL}"
  wget -qO "$archive" "$ARCHIVE_URL" || die "Failed to download project source. Check ${GITHUB_REPO_URL} and branch ${BRANCH}."
  tar -xzf "$archive" -C "$TMP_DIR"
  SOURCE_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -d "${SOURCE_DIR}/backend" ] || die "Downloaded project archive does not contain backend/."
}

install_project_files() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  if [ -d "$APP_DIR" ]; then
    log_warn "Existing installation found at ${APP_DIR}."
    if ask_yes_no "Overwrite program files? The database in ${CONFIG_DIR} will be kept." "n"; then
      rm -rf "${APP_DIR}.old"
      mv "$APP_DIR" "${APP_DIR}.old"
    else
      die "Installation cancelled by user."
    fi
  fi

  mkdir -p "$APP_DIR"
  cp -a "${SOURCE_DIR}/backend" "${APP_DIR}/backend"
  if [ -d "${SOURCE_DIR}/systemd" ]; then
    cp -a "${SOURCE_DIR}/systemd" "${APP_DIR}/systemd"
  fi
  cp -f "${SOURCE_DIR}/install.sh" "${APP_DIR}/install.sh" 2>/dev/null || true
  cp -f "${SOURCE_DIR}/uninstall.sh" "${APP_DIR}/uninstall.sh" 2>/dev/null || true
  chmod +x "${APP_DIR}/install.sh" "${APP_DIR}/uninstall.sh" 2>/dev/null || true
}

setup_python_venv() {
  log_info "Creating Python virtual environment..."
  if ! "$PYTHON_BIN" -m venv "$APP_DIR/venv" >/dev/null 2>&1; then
    if [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
      log_warn "python venv module is missing; installing python3-virtualenv."
      "$PKG_MANAGER" install -y python3-virtualenv
    fi
    "$PYTHON_BIN" -m venv "$APP_DIR/venv"
  fi
  "${APP_DIR}/venv/bin/python" -m pip install --upgrade pip
  "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/backend/requirements.txt"
}

init_database_and_admin() {
  prompt_admin_credentials
  PANEL_DB_PATH="$DB_PATH" PANEL_SECRET_PATH="$SECRET_PATH" \
    "${APP_DIR}/venv/bin/python" "${APP_DIR}/backend/app.py" --init-admin --username "$ADMIN_USERNAME" --password "$ADMIN_PASSWORD"
  [ -f "$SECRET_PATH" ] || openssl rand -base64 48 > "$SECRET_PATH"
  chmod 600 "$DB_PATH" "$SECRET_PATH"
}

setup_systemd_services() {
  log_info "Installing systemd services..."
  cat > /etc/systemd/system/sing-box-panel.service <<EOF
[Unit]
Description=sing-box-panel FastAPI service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}/backend
Environment=PANEL_DB_PATH=${DB_PATH}
Environment=PANEL_SECRET_PATH=${SECRET_PATH}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${APP_DIR}/venv/bin/uvicorn app:app --host ${BACKEND_HOST} --port ${BACKEND_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/sing-box-panel-expire.service <<EOF
[Unit]
Description=sing-box-panel expire worker
After=network.target

[Service]
Type=oneshot
User=root
WorkingDirectory=${APP_DIR}/backend
Environment=PANEL_DB_PATH=${DB_PATH}
Environment=PANEL_SECRET_PATH=${SECRET_PATH}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${APP_DIR}/venv/bin/python expire_worker.py
EOF

  cat > /etc/systemd/system/sing-box-panel-expire.timer <<EOF
[Unit]
Description=Run sing-box-panel expire worker every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Unit=sing-box-panel-expire.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
}

setup_nginx() {
  log_info "Configuring Nginx reverse proxy..."
  local config_body
  config_body=$(cat <<EOF
server {
    listen ${PANEL_PORT};
    server_name _;

    location / {
        proxy_pass http://${BACKEND_HOST}:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
)

  rm -f /etc/nginx/conf.d/sing-box-panel.conf
  rm -f /etc/nginx/sites-enabled/sing-box-panel
  rm -f /etc/nginx/sites-available/sing-box-panel

  if [ -d /etc/nginx/conf.d ]; then
    NGINX_CONFIG_PATH="/etc/nginx/conf.d/sing-box-panel.conf"
    printf '%s\n' "$config_body" > "$NGINX_CONFIG_PATH"
  elif [ -d /etc/nginx/sites-available ] && [ -d /etc/nginx/sites-enabled ]; then
    NGINX_CONFIG_PATH="/etc/nginx/sites-available/sing-box-panel"
    printf '%s\n' "$config_body" > "$NGINX_CONFIG_PATH"
    ln -sf "$NGINX_CONFIG_PATH" /etc/nginx/sites-enabled/sing-box-panel
  else
    mkdir -p /etc/nginx/conf.d
    NGINX_CONFIG_PATH="/etc/nginx/conf.d/sing-box-panel.conf"
    printf '%s\n' "$config_body" > "$NGINX_CONFIG_PATH"
  fi

  systemctl enable --now nginx
  nginx -t
  systemctl reload nginx
}

enable_services() {
  log_info "Starting panel services..."
  systemctl enable --now sing-box-panel.service
  systemctl enable --now sing-box-panel-expire.timer
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ask_yes_no "ufw is active. Open TCP port ${PANEL_PORT}?" "n"; then
      ufw allow "${PANEL_PORT}/tcp"
    else
      log_warn "ufw is active; open TCP port ${PANEL_PORT} manually if needed."
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    if ask_yes_no "firewalld is active. Open TCP port ${PANEL_PORT}?" "n"; then
      firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp"
      firewall-cmd --reload
    else
      log_warn "firewalld is active; open TCP port ${PANEL_PORT} manually if needed."
    fi
  fi
}

configure_selinux() {
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || true)" = "Enforcing" ]; then
    log_warn "SELinux is Enforcing. Nginx may need permission to proxy to 127.0.0.1:${BACKEND_PORT}."
    if command -v setsebool >/dev/null 2>&1; then
      if setsebool -P httpd_can_network_connect 1; then
        log_info "Enabled SELinux boolean httpd_can_network_connect."
      else
        log_warn "Failed to enable httpd_can_network_connect. You may need to configure SELinux manually."
      fi
    else
      log_warn "setsebool not found. You may need to install policycoreutils-python-utils and run: setsebool -P httpd_can_network_connect 1"
    fi
  fi
}

detect_server_ip() {
  SERVER_IP="$(curl -fsS4 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [ -n "$SERVER_IP" ] || SERVER_IP="SERVER_IP"
}

print_install_summary() {
  detect_server_ip
  cat > "$ADMIN_FILE" <<EOF
URL: http://${SERVER_IP}:${PANEL_PORT}
Username: ${ADMIN_USERNAME}
Password: ${ADMIN_PASSWORD}
EOF
  chmod 600 "$ADMIN_FILE"

  cat <<EOF

sing-box-panel installed successfully.

Panel URL:      http://${SERVER_IP}:${PANEL_PORT}
Username:       ${ADMIN_USERNAME}
Password:       ${ADMIN_PASSWORD}
Install path:   ${APP_DIR}
Database path:  ${DB_PATH}
Nginx config:   ${NGINX_CONFIG_PATH}
Credentials:    ${ADMIN_FILE}

Common commands:
  systemctl status sing-box-panel
  systemctl restart sing-box-panel
  systemctl status sing-box-panel-expire.timer
  journalctl -u sing-box-panel --no-pager -n 100
  bash ${APP_DIR}/uninstall.sh

EOF
}

cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

main() {
  detect_arch
  detect_os
  check_root
  check_systemd
  detect_package_manager
  choose_panel_port
  prompt_admin_credentials
  install_dependencies
  install_sing_box
  prepare_source
  install_project_files
  setup_python_venv
  init_database_and_admin
  setup_systemd_services
  enable_services
  setup_nginx
  configure_firewall
  configure_selinux
  print_install_summary
}

main "$@"
