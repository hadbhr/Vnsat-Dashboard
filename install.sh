#!/usr/bin/env bash
# ============================================================
# VPS Traffic Dashboard - One-line installer
#
# Usage: run this script from inside the project folder
# (the folder that contains app.py, requirements.txt, etc).
#
#   sudo bash install.sh
#
# Must be run as root on a fresh Ubuntu/Debian VPS.
# No GitHub account or repo URL is needed - the script just
# copies the files from the folder it's run from.
# ============================================================

set -euo pipefail

# ---- Fallback source if app.py isn't found next to this script ----
REPO_URL="https://github.com/hadbhr/Vnsat-Dashboard.git"
REPO_BRANCH="main"
# ---------------------------------------------------------------------

INSTALL_DIR="/opt/vps-traffic-dashboard"
SERVICE_NAME="vps-dashboard"
SSL_DIR="/etc/vps-dashboard/ssl"

# Internal gunicorn port - picked randomly in the 20000-29999 range so it
# can never collide with whatever external port the user chooses below
# (external ports are picked from 10000-65535). Kept out of that range
# entirely on purpose, then double-checked for collision anyway.
GUNICORN_BIND_PORT=$(( (RANDOM % 10000) + 20000 ))

# ---------- helpers ----------
c_reset="\033[0m"; c_bold="\033[1m"; c_green="\033[32m"; c_red="\033[31m"; c_blue="\033[34m"

log()  { echo -e "${c_blue}[*]${c_reset} $1"; }
ok()   { echo -e "${c_green}[OK]${c_reset} $1"; }
err()  { echo -e "${c_red}[ERROR]${c_reset} $1" >&2; }

# Always read prompts from the real terminal, even when this script is
# executed via `curl | bash` (where stdin is the script itself).
ask() {
  local prompt="$1"
  local __resultvar="$2"
  local default="${3:-}"
  local answer
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " answer </dev/tty
    answer="${answer:-$default}"
  else
    read -r -p "$prompt: " answer </dev/tty
  fi
  printf -v "$__resultvar" '%s' "$answer"
}

ask_hidden() {
  local prompt="$1"
  local __resultvar="$2"
  local answer
  read -r -s -p "$prompt: " answer </dev/tty
  echo
  printf -v "$__resultvar" '%s' "$answer"
}

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

# ============================================================
# 0. Pre-flight
# ============================================================
require_root

echo -e "${c_bold}=== VPS Traffic Dashboard Installer ===${c_reset}"
echo "This wizard will ask a few questions and then install everything automatically."
echo

# ============================================================
# 1. System dependencies
# ============================================================
log "Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq python3 python3-venv python3-pip vnstat curl unzip git nginx openssl >/dev/null
systemctl enable vnstat >/dev/null 2>&1 || true
systemctl start vnstat >/dev/null 2>&1 || true
ok "Dependencies installed"

# ============================================================
# 2. Auto-detect network interface + public IPv4
# ============================================================
log "Auto-detecting network interface and public IP..."

DETECTED_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)"
if [ -z "$DETECTED_IFACE" ]; then
  DETECTED_IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | head -n1)"
fi

DETECTED_IP=""
for svc in "https://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip" "https://api.ipify.org"; do
  DETECTED_IP="$(curl -4 -fsSL --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$DETECTED_IP" ]; then break; fi
done

ok "Detected interface: ${DETECTED_IFACE:-unknown}"
ok "Detected public IP: ${DETECTED_IP:-unknown}"

if [ -n "$DETECTED_IFACE" ]; then
  ask "Confirm/edit network interface" IFACE "$DETECTED_IFACE"
else
  ask "Could not auto-detect network interface, please enter it manually" IFACE ""
fi

if [ -n "$DETECTED_IP" ]; then
  ask "Confirm/edit server public IP" PUBLIC_IP "$DETECTED_IP"
else
  ask "Could not auto-detect public IP, please enter it manually" PUBLIC_IP ""
fi

# ============================================================
# 3. Username & password
# ============================================================
echo
log "Dashboard login account"
ask "Username" DASH_USERNAME "admin"

while true; do
  ask_hidden "Password" DASH_PASSWORD
  ask_hidden "Confirm password" DASH_PASSWORD_CONFIRM
  if [ "$DASH_PASSWORD" != "$DASH_PASSWORD_CONFIRM" ]; then
    err "Passwords don't match, try again."
    continue
  fi
  if [ "${#DASH_PASSWORD}" -lt 8 ]; then
    err "Password must be at least 8 characters."
    continue
  fi
  break
done

# ============================================================
# 4. Domain or IP + certificate
# ============================================================
echo
log "Domain / SSL certificate configuration"
ask_yn "Do you have a domain?" HAS_DOMAIN

if [ "$HAS_DOMAIN" = "yes" ]; then
  ask "Enter your domain (e.g. dashboard.example.com)" DOMAIN
  SERVER_NAME="$DOMAIN"
  log "Make sure the domain's A record for $DOMAIN points to this server's IP ($PUBLIC_IP), otherwise certificate issuance will fail."
  ask_yn "Ready to continue?" DOMAIN_READY
  if [ "$DOMAIN_READY" != "yes" ]; then
    err "Installation stopped. Re-run this script once DNS is ready."
    exit 1
  fi
else
  SERVER_NAME="$PUBLIC_IP"
  DOMAIN=""
fi

# ============================================================
# 5. Preferred external port
# ============================================================
echo
log "Picking a random external port for the dashboard (avoids the obvious 443/8443/8080 that get scanned constantly)..."

RANDOM_PORT=""
for _ in 1 2 3 4 5; do
  candidate=$(( (RANDOM % 55536) + 10000 ))   # 10000-65535 range
  if [ "$candidate" != "$GUNICORN_BIND_PORT" ] && ! ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${candidate}\$"; then
    RANDOM_PORT="$candidate"
    break
  fi
done
[ -z "$RANDOM_PORT" ] && RANDOM_PORT=$(( (RANDOM % 55536) + 10000 ))

ok "Suggested port: $RANDOM_PORT (currently free on this server)"
while true; do
  ask "External port to access the dashboard on (HTTPS) - press Enter to accept the suggestion, or type your own" EXTERNAL_PORT "$RANDOM_PORT"
  if [ "$EXTERNAL_PORT" = "$GUNICORN_BIND_PORT" ]; then
    err "Port $EXTERNAL_PORT is reserved internally, pick a different one."
    continue
  fi
  break
done

# ============================================================
# 6. Monthly traffic limit
# ============================================================
echo
is_positive_number() {
  python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if v > 0 else 1)" "$1" 2>/dev/null
}

is_nonnegative_number() {
  python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if v >= 0 else 1)" "$1" 2>/dev/null
}

while true; do
  ask "Monthly traffic limit in GB (e.g. 250)" MONTHLY_LIMIT_GB "250"
  if is_positive_number "$MONTHLY_LIMIT_GB"; then
    break
  fi
  err "Enter a valid number greater than zero."
done

# ============================================================
# 7. VPS expiration date (optional)
# ============================================================
echo
ask "Server expiration date (YYYY-MM-DD) - leave blank if not applicable" VPS_EXPIRATION ""

# ============================================================
# 8. Language
# ============================================================
echo
echo "Choose the dashboard's default language:"
echo "  1) Persian (Fa)"
echo "  2) English (En)"
echo "  3) Chinese (Ch)"
echo "  4) Russian (Ru)"
while true; do
  ask "Option number" LANG_CHOICE "2"
  case "$LANG_CHOICE" in
    1) DASH_LANG="fa"; DASH_CURRENCY="Toman"; break ;;
    2) DASH_LANG="en"; DASH_CURRENCY="USD"; break ;;
    3) DASH_LANG="zh"; DASH_CURRENCY="CNY"; break ;;
    4) DASH_LANG="ru"; DASH_CURRENCY="RUB"; break ;;
    *) err "Enter a number between 1 and 4." ;;
  esac
done
ok "Language: $DASH_LANG   |   Default currency: $DASH_CURRENCY (changeable later from dashboard settings)"

# ============================================================
# 9. Overage price per GB
# ============================================================
echo
while true; do
  ask "Price per GB of overage usage (in $DASH_CURRENCY)" OVERAGE_PRICE "0"
  if is_nonnegative_number "$OVERAGE_PRICE"; then
    break
  fi
  err "Enter a valid number (>= 0)."
done

# ============================================================
# 10. Copy application code
# ============================================================
echo
log "Copying application files..."
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || echo "")"

SOURCE_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/app.py" ]; then
  SOURCE_DIR="$SCRIPT_DIR"
  ok "Found app.py next to the script ($SOURCE_DIR)"
else
  log "app.py not found next to the script - cloning project from GitHub instead..."
  CLONE_DIR="$(mktemp -d)"
  if ! git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR" >/dev/null 2>&1; then
    err "Failed to clone $REPO_URL. Check your internet connection / repo URL."
    exit 1
  fi
  # app.py might be at the repo root, or nested one level down (e.g. a wrapper folder)
  FOUND_APP_PY="$(find "$CLONE_DIR" -maxdepth 3 -name "app.py" | head -n1)"
  if [ -z "$FOUND_APP_PY" ]; then
    err "Cloned $REPO_URL but couldn't find app.py anywhere in it."
    exit 1
  fi
  SOURCE_DIR="$(dirname "$FOUND_APP_PY")"
  ok "Found app.py in cloned repo at $SOURCE_DIR"
fi

cp -r "$SOURCE_DIR"/* "$INSTALL_DIR"/ 2>/dev/null || true
ok "Application files copied to $INSTALL_DIR"

# ============================================================
# 11. Python virtualenv
# ============================================================
log "Creating virtualenv and installing Python packages..."
cd "$INSTALL_DIR"
python3 -m venv venv
venv/bin/pip install --upgrade pip -q
venv/bin/pip install -r requirements.txt -q
ok "Python packages installed"

# ============================================================
# 12. Write config.json
# ============================================================
log "Creating config.json..."
SECRET_KEY="$(venv/bin/python3 -c 'import secrets; print(secrets.token_hex(32))')"

venv/bin/python3 - "$INSTALL_DIR/config.json" <<PYEOF
import json, sys

path = sys.argv[1]
cfg = {
    "dashboard_name": "Traffic Dashboard",
    "monthly_limit_gb": float("$MONTHLY_LIMIT_GB"),
    "overage_price": float("$OVERAGE_PRICE"),
    "currency": "$DASH_CURRENCY",
    "interface": "$IFACE",
    "billing_start_day": 1,
    "vps_expiration_date": "$VPS_EXPIRATION",
    "secret_key": "$SECRET_KEY",
    "language": "$DASH_LANG",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PYEOF
ok "config.json created"

# ============================================================
# 13. Create the login user (password hashed, never stored in plaintext)
# ============================================================
log "Creating user account with hashed password..."
export DASH_PASSWORD
venv/bin/python3 - "$INSTALL_DIR/users.json" "$DASH_USERNAME" <<'PYEOF'
import json, os, sys
from werkzeug.security import generate_password_hash

users_path = sys.argv[1]
username = sys.argv[2]
password = os.environ["DASH_PASSWORD"]

users = {username: {"password_hash": generate_password_hash(password)}}
with open(users_path, "w", encoding="utf-8") as f:
    json.dump(users, f, indent=2, ensure_ascii=False)
PYEOF
unset DASH_PASSWORD
ok "User '$DASH_USERNAME' created"

# ============================================================
# 14. TLS certificate (Let's Encrypt for domain, self-signed for IP)
# ============================================================
mkdir -p "$SSL_DIR"

if [ "$HAS_DOMAIN" = "yes" ]; then
  log "Requesting a valid Let's Encrypt certificate for $DOMAIN..."
  apt-get install -y -qq certbot >/dev/null
  systemctl stop nginx >/dev/null 2>&1 || true
  certbot certonly --standalone --non-interactive --agree-tos \
    -m "admin@$DOMAIN" -d "$DOMAIN" --preferred-challenges http || {
      err "Let's Encrypt certificate issuance failed. Make sure the domain's DNS points to this server and port 80 is open."
      exit 1
    }
  CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  ok "Let's Encrypt certificate issued"
else
  log "Creating a self-signed certificate for IP $PUBLIC_IP (browsers will show a security warning, this is expected)..."
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "$SSL_DIR/selfsigned.key" \
    -out "$SSL_DIR/selfsigned.crt" \
    -subj "/CN=$PUBLIC_IP" >/dev/null 2>&1
  CERT_FILE="$SSL_DIR/selfsigned.crt"
  KEY_FILE="$SSL_DIR/selfsigned.key"
  ok "Self-signed certificate created"
fi

# ============================================================
# 15. Nginx reverse proxy
# ============================================================
log "Configuring Nginx on port $EXTERNAL_PORT..."

cat > /etc/nginx/sites-available/vps-dashboard.conf <<NGINXEOF
server {
    listen ${EXTERNAL_PORT} ssl;
    listen [::]:${EXTERNAL_PORT} ssl;
    server_name ${SERVER_NAME};

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 2m;

    location / {
        proxy_pass http://127.0.0.1:${GUNICORN_BIND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/vps-dashboard.conf /etc/nginx/sites-enabled/vps-dashboard.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
ok "Nginx configured and restarted"

# ============================================================
# 16. Firewall (best-effort, only if ufw is present/active)
# ============================================================
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${EXTERNAL_PORT}/tcp" >/dev/null 2>&1 || true
  if [ "$HAS_DOMAIN" = "yes" ]; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
  fi
fi

# ============================================================
# 17. systemd service for Gunicorn
# ============================================================
log "Installing systemd service..."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICEEOF
[Unit]
Description=VPS Traffic Dashboard
After=network.target

[Service]
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${INSTALL_DIR}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${INSTALL_DIR}/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:${GUNICORN_BIND_PORT} app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl restart "$SERVICE_NAME"

sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "Service $SERVICE_NAME started successfully"
else
  err "Service failed to start. Run these commands to debug:"
  echo "  systemctl status ${SERVICE_NAME} --no-pager"
  echo "  journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
  exit 1
fi

# ============================================================
# 18. Renewal hook (auto-renew Let's Encrypt + reload nginx)
# ============================================================
if [ "$HAS_DOMAIN" = "yes" ]; then
  cat > /etc/systemd/system/certbot-renew-dashboard.service <<'RENEWEOF'
[Unit]
Description=Renew Let's Encrypt cert for VPS Dashboard

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
RENEWEOF

  cat > /etc/systemd/system/certbot-renew-dashboard.timer <<'RENEWTIMEREOF'
[Unit]
Description=Run certbot renew twice a day

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
RENEWTIMEREOF

  systemctl daemon-reload
  systemctl enable --now certbot-renew-dashboard.timer >/dev/null 2>&1 || true
fi

# ============================================================
# Done
# ============================================================
echo
echo -e "${c_bold}${c_green}=== Installation completed successfully ===${c_reset}"
echo

# ---- Green info box with connection details ----
box_line1="Dashboard URL:  https://${SERVER_NAME}:${EXTERNAL_PORT}/login"
box_line2="Username:       ${DASH_USERNAME}"
box_line3="Password:       (the one you entered)"

box_width=0
for line in "$box_line1" "$box_line2" "$box_line3"; do
  [ "${#line}" -gt "$box_width" ] && box_width="${#line}"
done
box_width=$((box_width + 4))

print_box_border() {
  printf '%b+' "$c_green"
  printf '%*s' "$box_width" '' | tr ' ' '-'
  printf '+%b\n' "$c_reset"
}

print_box_line() {
  local content="$1"
  local pad=$((box_width - 2 - ${#content}))
  printf '%b| %s' "$c_green" "$content"
  printf '%*s' "$pad" ''
  printf ' |%b\n' "$c_reset"
}

print_box_border
print_box_line "$box_line1"
print_box_line "$box_line2"
print_box_line "$box_line3"
print_box_border
echo

if [ "$HAS_DOMAIN" = "no" ]; then
  echo -e "${c_bold}Note:${c_reset} Since you used an IP, the certificate is self-signed."
  echo "Your browser will show a security warning - this is expected, you can proceed."
fi
echo
echo "Useful management commands:"
echo "  systemctl status ${SERVICE_NAME} --no-pager"
echo "  journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
echo "  systemctl restart ${SERVICE_NAME}"
echo
echo "To add or change a user later:"
echo "  cd ${INSTALL_DIR} && venv/bin/python create_user.py USERNAME"
echo
