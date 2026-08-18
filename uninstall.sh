#!/usr/bin/env bash
# ============================================================
# VPS Traffic Dashboard - One-line uninstaller
#
# Usage (once published on GitHub):
#   curl -fsSL https://raw.githubusercontent.com/hadbhr/Vnsat-Dashboard/main/uninstall.sh | bash
#
# Must be run as root on the VPS where the dashboard is installed.
# Removes the systemd service, nginx config, app files, and
# (optionally) the Let's Encrypt certificate and firewall rules.
# System packages (nginx, python3, vnstat, certbot) are left in
# place since other things on the server may depend on them.
# ============================================================

set -euo pipefail

INSTALL_DIR="/opt/vps-traffic-dashboard"
SERVICE_NAME="vps-dashboard"
SSL_DIR="/etc/vps-dashboard/ssl"
NGINX_CONF="/etc/nginx/sites-available/vps-dashboard.conf"
NGINX_LINK="/etc/nginx/sites-enabled/vps-dashboard.conf"
RENEW_SERVICE="/etc/systemd/system/certbot-renew-dashboard.service"
RENEW_TIMER="/etc/systemd/system/certbot-renew-dashboard.timer"

c_reset="\033[0m"; c_bold="\033[1m"; c_green="\033[32m"; c_red="\033[31m"; c_blue="\033[34m"

log()  { echo -e "${c_blue}[*]${c_reset} $1"; }
ok()   { echo -e "${c_green}[OK]${c_reset} $1"; }
err()  { echo -e "${c_red}[ERROR]${c_reset} $1" >&2; }

ask_yn() {
  local prompt="$1"
  local __resultvar="$2"
  local answer
  while true; do
    read -r -p "$prompt (y/n): " answer </dev/tty
    case "$answer" in
      [Yy]*) printf -v "$__resultvar" '%s' "yes"; break ;;
      [Nn]*) printf -v "$__resultvar" '%s' "no"; break ;;
      *) echo "Please answer y or n" ;;
    esac
  done
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (sudo -i, then re-run)."
    exit 1
  fi
}

require_root

echo -e "${c_bold}=== VPS Traffic Dashboard Uninstaller ===${c_reset}"
echo "This will remove the dashboard service, its nginx config, and its files."
echo

# ============================================================
# 1. Stop and remove the systemd service
# ============================================================
log "Stopping and removing the ${SERVICE_NAME} service..."
systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
ok "Service removed"

# ============================================================
# 2. Remove the certbot renewal timer (if it exists)
# ============================================================
if [ -f "$RENEW_TIMER" ] || [ -f "$RENEW_SERVICE" ]; then
  log "Removing certbot auto-renew timer..."
  systemctl stop certbot-renew-dashboard.timer >/dev/null 2>&1 || true
  systemctl disable certbot-renew-dashboard.timer >/dev/null 2>&1 || true
  rm -f "$RENEW_SERVICE" "$RENEW_TIMER"
  ok "Renewal timer removed"
fi

systemctl daemon-reload >/dev/null 2>&1 || true

# ============================================================
# 3. Remove the nginx site config
# ============================================================
if [ -f "$NGINX_CONF" ] || [ -L "$NGINX_LINK" ]; then
  log "Removing nginx site configuration..."
  rm -f "$NGINX_CONF" "$NGINX_LINK"
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || true
  fi
  ok "Nginx config removed"
else
  log "No nginx config found for the dashboard, skipping."
fi

# ============================================================
# 4. Remove app files and self-signed SSL directory
# ============================================================
if [ -d "$INSTALL_DIR" ]; then
  log "Removing application files at ${INSTALL_DIR}..."
  rm -rf "$INSTALL_DIR"
  ok "Application files removed"
else
  log "No application directory found at ${INSTALL_DIR}, skipping."
fi

if [ -d "$SSL_DIR" ]; then
  rm -rf "$SSL_DIR"
  ok "Self-signed SSL directory removed"
fi

# ============================================================
# 5. Optional: Let's Encrypt certificate
# ============================================================
if command -v certbot >/dev/null 2>&1; then
  EXISTING_CERTS="$(certbot certificates 2>/dev/null | grep "Certificate Name:" | awk '{print $3}' || true)"
  if [ -n "$EXISTING_CERTS" ]; then
    echo
    echo "Found the following Let's Encrypt certificate(s) on this server:"
    echo "$EXISTING_CERTS"
    ask_yn "Do you want to delete a Let's Encrypt certificate used by the dashboard?" DELETE_CERT
    if [ "$DELETE_CERT" = "yes" ]; then
      read -r -p "Enter the exact certificate name to delete: " CERT_NAME </dev/tty
      if [ -n "$CERT_NAME" ]; then
        certbot delete --cert-name "$CERT_NAME" --non-interactive || err "Failed to delete certificate $CERT_NAME"
      fi
    fi
  fi
fi

# ============================================================
# 6. Optional: firewall rule cleanup
# ============================================================
if command -v ufw >/dev/null 2>&1; then
  echo
  read -r -p "Enter the external port the dashboard was using, to close it in ufw (leave blank to skip): " OLD_PORT </dev/tty
  if [ -n "$OLD_PORT" ]; then
    ufw delete allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
    ok "Closed port ${OLD_PORT}/tcp in ufw"
  fi
  ask_yn "Also close port 80/tcp (only used for Let's Encrypt HTTP challenge)?" CLOSE_80
  if [ "$CLOSE_80" = "yes" ]; then
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
    ok "Closed port 80/tcp in ufw"
  fi
fi

# ============================================================
# Done
# ============================================================
echo
echo -e "${c_bold}${c_green}=== Uninstall complete ===${c_reset}"
echo
echo "The following were left untouched, since other things on this"
echo "server may depend on them:"
echo "  - nginx, python3, vnstat, certbot (system packages)"
echo "  - any other websites/services running on this VPS"
echo
