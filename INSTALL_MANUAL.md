# VPS Traffic Dashboard — Manual Deployment Guide

> **Tip:** Most people should just use the one-line installer instead:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/install.sh | bash
> ```
> Use this manual guide only if you want full control over each step, or if
> your OS/setup differs from the installer's assumptions (Ubuntu/Debian + apt).

## 1. Copy files to the server

```bash
sudo mkdir -p /opt/vps-traffic-dashboard
git clone https://github.com/YOUR_USER/YOUR_REPO.git /tmp/vps-dashboard-src
sudo cp -r /tmp/vps-dashboard-src/* /opt/vps-traffic-dashboard/
cd /opt/vps-traffic-dashboard
```

## 2. Create the virtualenv

```bash
python3 -m venv venv
venv/bin/pip install --upgrade pip
venv/bin/pip install -r requirements.txt
```

## 3. Configure

Edit `config.json`:

- `dashboard_name`, `monthly_limit_gb`, `overage_price`, `currency` — can also be
  changed later from the dashboard Settings modal.
- `interface` — set to your vnStat-monitored interface name (e.g. `eth0`). Leave
  empty (`""`) to auto-select the first interface vnStat reports.
- `billing_start_day` — day of month (1–28) your billing cycle resets.
- `vps_expiration_date` — optional, e.g. `"2026-12-31"`. Leave empty to show `--`.
- `secret_key` — **replace with a long random string** before going to production:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```
Paste the result into `secret_key` in `config.json`.

## 4. Create your login user

A default user `admin` / `changeme123` is included in `users.json` so the app is
runnable immediately — **replace it before exposing the dashboard**:

```bash
venv/bin/python create_user.py admin
```
This prompts for a new password (hidden input) and safely rewrites `users.json`
with a hashed password. You can add more usernames the same way.

## 5. Verify vnStat is running and has data

```bash
vnstat --json
```
Confirm the interface name here matches `interface` in `config.json` (or leave
`interface` empty to auto-select).

## 6. Install the systemd service

```bash
sudo cp vps-dashboard.service /etc/systemd/system/vps-dashboard.service
sudo systemctl daemon-reload
sudo systemctl enable vps-dashboard
sudo systemctl start vps-dashboard
```

## 7. Verify

```bash
systemctl status vps-dashboard --no-pager
journalctl -u vps-dashboard -n 100 --no-pager
curl -I http://127.0.0.1:8000/
```

Expected response (dashboard is login-protected):

```
HTTP/1.1 302 FOUND
Location: /login?next=%2F
```

Open `http://YOUR_SERVER_IP:8000/login` in a browser and sign in.

## Debugging checklist

1. `systemctl status vps-dashboard --no-pager`
2. `journalctl -u vps-dashboard -n 100 --no-pager`
3. `venv/bin/python -m py_compile app.py`
4. `curl -s http://127.0.0.1:8000/api/traffic` (while logged in / with session cookie)
5. `vnstat --json` directly, to rule out a vnStat-side problem before touching app code.

## Notes on `User=root` in the systemd unit

`vnstat --json` normally only needs read access to `/var/lib/vnstat`. If your
vnStat database is readable by a non-root user (e.g. group `vnstat`), you can
run the service as a dedicated unprivileged user instead — change `User=root`
to that user and ensure it can read the vnStat database and execute
`/usr/bin/vnstat`. Keep `User=root` only if your setup requires it.
