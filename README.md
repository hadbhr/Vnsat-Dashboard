# VPS Traffic Dashboard

A lightweight, self-hosted, login-protected traffic monitoring dashboard for
any Linux VPS — powered by vnStat, Flask, and Gunicorn. No database, no
Node.js, no React. Just Python + vanilla JS.

## Features

- Real vnStat-backed download/upload monitoring (RX = download, TX = upload)
- Monthly limit, remaining traffic, overage cost in your currency
- Hourly / daily / weekly / monthly history — chart and table each with
  their own independent tabs
- English, فارسی (RTL), 中文, and Русский — switch instantly, no reload
- Dark / light theme
- Configurable dashboard name, monthly limit, overage price, currency —
  editable from the UI
- Auto-refresh every 30 seconds
- Fully responsive (desktop + mobile)

## One-line install

Run this on a fresh Ubuntu/Debian VPS as root:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/install.sh | bash
```

The installer will:

1. Install system dependencies (Python, vnStat, Nginx, Certbot)
2. Auto-detect your network interface and public IPv4
3. Ask for a username and password (stored as a salted hash, never plaintext)
4. Ask if you have a domain — issues a real Let's Encrypt certificate if yes,
   or a self-signed certificate for your IP if no
5. Ask your preferred external port, monthly traffic limit, VPS expiration
   date, language, and overage price
6. Set up Gunicorn behind Nginx (TLS termination) as a systemd service
7. Auto-renew the TLS certificate via a systemd timer (domain installs only)

At the end you'll get a ready-to-use HTTPS URL and login credentials.

## Manual install

See [INSTALL_MANUAL.md](INSTALL_MANUAL.md) for a fully manual, step-by-step
setup if you'd rather not use the installer.

## Updating settings later

Everything the installer asks (name, limit, price, currency) can also be
changed anytime from the dashboard's Settings (⚙) button — no server access
needed.

To add or rotate a login user:

```bash
cd /opt/vps-traffic-dashboard
venv/bin/python create_user.py USERNAME
```

## Security notes

- The dashboard is intended to be private. Even with a real domain +
  Let's Encrypt cert, don't expose credentials or share the URL publicly.
- Self-signed certificates (IP-only installs) will trigger a browser warning
  — this is expected and does not mean anything is broken.
- Passwords are hashed with Werkzeug's `generate_password_hash` (scrypt) —
  never stored in plaintext.

## License

MIT — do whatever you want with it.
