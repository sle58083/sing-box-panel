#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="sing-box-panel"
APP_DIR="/opt/${APP_NAME}"
CONFIG_DIR="/etc/${APP_NAME}"

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
  log_error "$*"
  exit 1
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer=""
  local suffix="[y/N]"
  [ "$default" = "y" ] && suffix="[Y/n]"

  if [ -r /dev/tty ]; then
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

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This uninstaller must be run as root."
  fi
}

stop_and_remove_services() {
  log_info "Stopping and removing systemd services..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now sing-box-panel-expire.timer >/dev/null 2>&1 || true
    systemctl stop sing-box-panel-expire.service >/dev/null 2>&1 || true
    systemctl disable --now sing-box-panel.service >/dev/null 2>&1 || true
  fi
  rm -f /etc/systemd/system/sing-box-panel.service
  rm -f /etc/systemd/system/sing-box-panel-expire.service
  rm -f /etc/systemd/system/sing-box-panel-expire.timer
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi
}

remove_nginx_config() {
  log_info "Removing Nginx config..."
  rm -f /etc/nginx/conf.d/sing-box-panel.conf
  rm -f /etc/nginx/sites-enabled/sing-box-panel
  rm -f /etc/nginx/sites-available/sing-box-panel
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t; then
      if command -v systemctl >/dev/null 2>&1; then
        systemctl reload nginx || true
      else
        nginx -s reload || true
      fi
    else
      log_warn "nginx -t failed after removing panel config; nginx was not reloaded."
    fi
  fi
}

remove_program_files() {
  log_info "Removing ${APP_DIR}..."
  rm -rf "$APP_DIR"
}

maybe_remove_config() {
  if [ -d "$CONFIG_DIR" ]; then
    if ask_yes_no "Delete ${CONFIG_DIR} including database and saved credentials?" "n"; then
      rm -rf "$CONFIG_DIR"
      log_info "Deleted ${CONFIG_DIR}."
    else
      log_info "Kept ${CONFIG_DIR}."
    fi
  fi
}

maybe_uninstall_sing_box() {
  if command -v sing-box >/dev/null 2>&1 || [ -x /usr/local/bin/sing-box ]; then
    if ask_yes_no "Also uninstall 233boy/sing-box main program? This may remove existing proxy configs." "n"; then
      local cmd="sing-box"
      command -v sing-box >/dev/null 2>&1 || cmd="/usr/local/bin/sing-box"
      "$cmd" uninstall || log_warn "sing-box uninstall command failed. Please remove it manually if needed."
    else
      log_info "Kept 233boy/sing-box main program."
    fi
  fi
}

main() {
  check_root
  stop_and_remove_services
  remove_nginx_config
  remove_program_files
  maybe_remove_config
  maybe_uninstall_sing_box
  log_info "sing-box-panel uninstall completed."
}

main "$@"
