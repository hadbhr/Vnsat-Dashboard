#!/usr/bin/env python3
"""
VPS Traffic Dashboard - Flask backend.

Reads traffic data from vnStat, exposes a JSON API, and serves a
login-protected dashboard. RX is always treated as download, TX is
always treated as upload.
"""

import calendar
import json
import logging
import re
import subprocess
from datetime import datetime, date, timedelta
from pathlib import Path

from flask import Flask, request, jsonify, render_template, redirect
from flask_login import (
    LoginManager,
    UserMixin,
    login_user,
    logout_user,
    login_required,
    current_user,
)
from werkzeug.security import check_password_hash

# ============================================================
# CONFIGURATION
# ============================================================

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.json"
USERS_PATH = BASE_DIR / "users.json"

DEFAULT_CONFIG = {
    "dashboard_name": "Traffic Dashboard",
    "monthly_limit_gb": 250,
    "overage_price": 1800,
    "currency": "Toman",
    "interface": "",
    "billing_start_day": 1,
    "vps_expiration_date": "",
    "secret_key": "change-me-please",
    "language": "en",
    "dashboard_path": "dashboard",
}

ALLOWED_CURRENCIES = {"USD", "Toman", "RUB", "CNY"}
ALLOWED_LANGUAGES = {"en", "fa", "zh", "ru"}

DASHBOARD_PATH_RE = re.compile(r"^[A-Za-z0-9_-]{3,32}$")
RESERVED_SLUGS = {"api", "static", "logout", "login"}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("vps-dashboard")


def load_config():
    """Load config.json, falling back to defaults for any missing key."""
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            cfg.update(data)
    except FileNotFoundError:
        logger.warning("config.json not found, using defaults")
        save_config(cfg)
    except (json.JSONDecodeError, OSError) as exc:
        logger.error("Failed to read config.json: %s", exc)
    return cfg


def save_config(cfg):
    """Persist config.json atomically."""
    try:
        tmp_path = CONFIG_PATH.with_suffix(".tmp")
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        tmp_path.replace(CONFIG_PATH)
        return True
    except OSError as exc:
        logger.error("Failed to write config.json: %s", exc)
        return False


def load_users():
    """Load users.json -> { username: {password_hash: ...} }"""
    try:
        with open(USERS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except FileNotFoundError:
        logger.error("users.json not found")
    except (json.JSONDecodeError, OSError) as exc:
        logger.error("Failed to read users.json: %s", exc)
    return {}


CONFIG = load_config()

app = Flask(__name__)
app.config["SECRET_KEY"] = CONFIG.get("secret_key", "change-me-please")
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"

login_manager = LoginManager()
login_manager.init_app(app)


def get_dashboard_path(cfg):
    """Return the configured dashboard URL slug, sanitized and defaulted."""
    raw = str(cfg.get("dashboard_path") or "").strip().strip("/")
    if DASHBOARD_PATH_RE.match(raw) and raw.lower() not in RESERVED_SLUGS:
        return raw
    return "dashboard"


# ============================================================
# AUTHENTICATION
# ============================================================

class User(UserMixin):
    def __init__(self, username):
        self.id = username


@login_manager.user_loader
def load_user(username):
    users = load_users()
    if username in users:
        return User(username)
    return None


@login_manager.unauthorized_handler
def unauthorized():
    if request.path.startswith("/api/"):
        return jsonify({"error": "Unauthorized"}), 401
    cfg = load_config()
    return redirect("/" + get_dashboard_path(cfg))


@app.route("/")
def root_redirect():
    cfg = load_config()
    return redirect("/" + get_dashboard_path(cfg))


@app.route("/login")
def legacy_login_redirect():
    # The login URL is now the same as the dashboard's configured path.
    cfg = load_config()
    return redirect("/" + get_dashboard_path(cfg))


@app.route("/<slug>", methods=["GET", "POST"])
def dashboard_entry(slug):
    cfg = load_config()
    expected_slug = get_dashboard_path(cfg)
    if slug != expected_slug:
        from flask import abort
        abort(404)

    if current_user.is_authenticated:
        initial_lang = cfg.get("language", "en")
        if initial_lang not in ALLOWED_LANGUAGES:
            initial_lang = "en"
        return render_template(
            "index.html",
            initial_lang=initial_lang,
            dashboard_path=expected_slug,
        )

    error = None
    if request.method == "POST":
        username = (request.form.get("username") or "").strip()
        password = request.form.get("password") or ""
        users = load_users()
        user_record = users.get(username)

        if user_record and check_password_hash(
            user_record.get("password_hash", ""), password
        ):
            login_user(User(username))
            return redirect("/" + expected_slug)

        error = "Invalid username or password"
        logger.info("Failed login attempt for username=%r", username)

    return render_template("login.html", error=error, dashboard_path=expected_slug)


@app.route("/logout")
@login_required
def logout():
    cfg = load_config()
    logout_user()
    return redirect("/" + get_dashboard_path(cfg))


# ============================================================
# BILLING
# ============================================================

def _shift_months(d, delta):
    """Shift a date by `delta` months, clamping the day to the target month's length."""
    month_index = d.month - 1 + delta
    year = d.year + month_index // 12
    month = month_index % 12 + 1
    last_day = calendar.monthrange(year, month)[1]
    day = min(d.day, last_day)
    return date(year, month, day)


def get_billing_info(cfg):
    """
    Billing "next reset" is exactly the user-provided VPS expiration date.
    Billing "start" is exactly one month before that date.

    If no expiration date is configured, fall back to a rolling monthly
    cycle based on billing_start_day (legacy behavior).
    """
    vps_expiration_raw = (cfg.get("vps_expiration_date") or "").strip()

    if vps_expiration_raw:
        try:
            reset_date = datetime.strptime(vps_expiration_raw, "%Y-%m-%d").date()
            start_date = _shift_months(reset_date, -1)
            return {
                "start_date": start_date.isoformat(),
                "reset_date": reset_date.isoformat(),
                "vps_expiration_date": vps_expiration_raw,
            }
        except ValueError:
            logger.warning(
                "Invalid vps_expiration_date %r, falling back to rolling cycle",
                vps_expiration_raw,
            )

    # ---- Fallback: rolling monthly cycle based on billing_start_day ----
    today = date.today()
    try:
        billing_day = int(cfg.get("billing_start_day", 1))
        if billing_day < 1:
            billing_day = 1
        if billing_day > 28:
            billing_day = 28  # avoid invalid dates in short months
    except (TypeError, ValueError):
        billing_day = 1

    try:
        this_cycle_start = today.replace(day=billing_day)
    except ValueError:
        this_cycle_start = today.replace(day=1)

    if today >= this_cycle_start:
        start_date = this_cycle_start
    else:
        start_date = _shift_months(this_cycle_start, -1)

    reset_date = _shift_months(start_date, 1)

    return {
        "start_date": start_date.isoformat(),
        "reset_date": reset_date.isoformat(),
        "vps_expiration_date": "--",
    }


# ============================================================
# TRAFFIC (vnStat)
# ============================================================

BYTES_PER_GB = 1024 ** 3


def bytes_to_gb(value_bytes):
    try:
        return round(float(value_bytes) / BYTES_PER_GB, 2)
    except (TypeError, ValueError):
        return 0.0


def run_vnstat_json():
    """Call `vnstat --json` and return parsed JSON, or None on failure."""
    try:
        result = subprocess.run(
            ["vnstat", "--json"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            logger.error("vnstat exited with code %s: %s", result.returncode, result.stderr)
            return None
        return json.loads(result.stdout)
    except FileNotFoundError:
        logger.error("vnstat binary not found on this system")
        return None
    except subprocess.TimeoutExpired:
        logger.error("vnstat call timed out")
        return None
    except (json.JSONDecodeError, OSError) as exc:
        logger.error("Failed to parse vnstat output: %s", exc)
        return None


def select_interface(vnstat_data, cfg):
    """Pick the configured interface, or fall back to the first available one."""
    interfaces = vnstat_data.get("interfaces") or []
    if not interfaces:
        return None

    configured = (cfg.get("interface") or "").strip()
    if configured:
        for iface in interfaces:
            if iface.get("name") == configured:
                return iface

    return interfaces[0]


def _rx_tx_gb(entry):
    """Extract (rx_gb, tx_gb) from a vnStat traffic entry, defensively."""
    if not isinstance(entry, dict):
        return 0.0, 0.0
    rx = entry.get("rx", 0)
    tx = entry.get("tx", 0)
    return bytes_to_gb(rx), bytes_to_gb(tx)


def get_traffic(cfg):
    """
    Read vnStat data and build the full traffic payload:
    monthly download/upload, today/yesterday, and all history arrays.
    Never raises - returns safe zeroed data on any failure.
    """
    empty_download = {
        "month_gb": 0.0,
        "limit_gb": float(cfg.get("monthly_limit_gb", 0) or 0),
        "remaining_gb": float(cfg.get("monthly_limit_gb", 0) or 0),
        "overage_gb": 0.0,
        "overage_cost": 0.0,
        "currency": cfg.get("currency", "USD"),
    }
    empty_result = {
        "interface": cfg.get("interface", "") or "unknown",
        "download": empty_download,
        "upload": {"month_gb": 0.0},
        "today": {"download_gb": 0.0, "upload_gb": 0.0},
        "yesterday": {"download_gb": 0.0, "upload_gb": 0.0},
        "daily_history": [],
        "hourly_history": [],
        "weekly_history": [],
        "monthly_history": [],
    }

    data = run_vnstat_json()
    if not data:
        return empty_result

    iface = select_interface(data, cfg)
    if not iface:
        logger.error("No usable interface found in vnstat data")
        return empty_result

    traffic = iface.get("traffic", {}) or {}
    iface_name = iface.get("name", cfg.get("interface", "") or "unknown")

    # ---- Monthly ----
    month_entries = traffic.get("month", []) or []
    today = date.today()
    month_download_gb = 0.0
    month_upload_gb = 0.0
    for m in month_entries:
        d = m.get("date", {}) or {}
        try:
            if int(d.get("year", 0)) == today.year and int(d.get("month", 0)) == today.month:
                rx_gb, tx_gb = _rx_tx_gb(m)
                month_download_gb = rx_gb
                month_upload_gb = tx_gb
                break
        except (TypeError, ValueError):
            continue

    limit_gb = float(cfg.get("monthly_limit_gb", 0) or 0)
    remaining_gb = max(0.0, round(limit_gb - month_download_gb, 2))
    overage_gb = max(0.0, round(month_download_gb - limit_gb, 2))
    overage_price = float(cfg.get("overage_price", 0) or 0)
    overage_cost = round(overage_gb * overage_price, 2)

    download_block = {
        "month_gb": round(month_download_gb, 2),
        "limit_gb": limit_gb,
        "remaining_gb": remaining_gb,
        "overage_gb": overage_gb,
        "overage_cost": overage_cost,
        "currency": cfg.get("currency", "USD"),
    }
    upload_block = {"month_gb": round(month_upload_gb, 2)}

    # ---- Daily entries (used for today/yesterday, daily_history, weekly_history) ----
    day_entries = traffic.get("day", []) or []
    daily_history = []
    for d_entry in day_entries:
        d = d_entry.get("date", {}) or {}
        try:
            entry_date = date(int(d.get("year")), int(d.get("month")), int(d.get("day")))
        except (TypeError, ValueError, KeyError):
            continue
        rx_gb, tx_gb = _rx_tx_gb(d_entry)
        daily_history.append(
            {
                "date": entry_date.isoformat(),
                "download_gb": rx_gb,
                "upload_gb": tx_gb,
                "_date_obj": entry_date,
            }
        )

    daily_history.sort(key=lambda x: x["_date_obj"])

    today_gb = {"download_gb": 0.0, "upload_gb": 0.0}
    yesterday_gb = {"download_gb": 0.0, "upload_gb": 0.0}
    yesterday_date = today - timedelta(days=1)
    for entry in daily_history:
        if entry["_date_obj"] == today:
            today_gb = {"download_gb": entry["download_gb"], "upload_gb": entry["upload_gb"]}
        elif entry["_date_obj"] == yesterday_date:
            yesterday_gb = {"download_gb": entry["download_gb"], "upload_gb": entry["upload_gb"]}

    # Trim to last ~14 days for the daily_history table, strip helper key.
    recent_daily = daily_history[-14:]
    clean_daily_history = [
        {"date": e["date"], "download_gb": e["download_gb"], "upload_gb": e["upload_gb"]}
        for e in recent_daily
    ]

    # ---- Weekly history (group daily by ISO week) ----
    weekly_map = {}
    weekly_order = []
    for entry in daily_history:
        iso_year, iso_week, _ = entry["_date_obj"].isocalendar()
        key = f"{iso_year}-W{iso_week:02d}"
        if key not in weekly_map:
            weekly_map[key] = {"week": key, "download_gb": 0.0, "upload_gb": 0.0}
            weekly_order.append(key)
        weekly_map[key]["download_gb"] = round(
            weekly_map[key]["download_gb"] + entry["download_gb"], 2
        )
        weekly_map[key]["upload_gb"] = round(
            weekly_map[key]["upload_gb"] + entry["upload_gb"], 2
        )
    weekly_history = [weekly_map[k] for k in weekly_order]

    # ---- Hourly ----
    hour_entries = traffic.get("hour", []) or []
    hourly_history = []
    for h_entry in hour_entries:
        d = h_entry.get("date", {}) or {}
        try:
            entry_date = date(int(d.get("year")), int(d.get("month")), int(d.get("day")))
            hour_val = int(h_entry.get("hour", 0))
        except (TypeError, ValueError, KeyError):
            continue
        rx_gb, tx_gb = _rx_tx_gb(h_entry)
        timestamp = datetime(
            entry_date.year, entry_date.month, entry_date.day, hour_val
        )
        hourly_history.append(
            {
                "timestamp": timestamp.isoformat(),
                "date": entry_date.isoformat(),
                "hour": hour_val,
                "label": f"{hour_val:02d}:00",
                "download_gb": rx_gb,
                "upload_gb": tx_gb,
                "_ts": timestamp,
            }
        )
    hourly_history.sort(key=lambda x: x["_ts"])
    hourly_history = hourly_history[-48:]  # last 48 hours is plenty
    for e in hourly_history:
        del e["_ts"]

    # ---- Monthly history ----
    monthly_history = []
    for m in month_entries:
        d = m.get("date", {}) or {}
        try:
            year = int(d.get("year"))
            month = int(d.get("month"))
        except (TypeError, ValueError, KeyError):
            continue
        rx_gb, tx_gb = _rx_tx_gb(m)
        monthly_history.append(
            {
                "date": f"{year:04d}-{month:02d}",
                "year": year,
                "month": month,
                "label": f"{year:04d}-{month:02d}",
                "download_gb": rx_gb,
                "upload_gb": tx_gb,
            }
        )
    monthly_history.sort(key=lambda x: (x["year"], x["month"]))

    return {
        "interface": iface_name,
        "download": download_block,
        "upload": upload_block,
        "today": today_gb,
        "yesterday": yesterday_gb,
        "daily_history": clean_daily_history,
        "hourly_history": hourly_history,
        "weekly_history": weekly_history,
        "monthly_history": monthly_history,
    }


# ============================================================
# API ROUTES
# ============================================================

@app.route("/api/traffic")
@login_required
def api_traffic():
    cfg = load_config()
    try:
        traffic = get_traffic(cfg)
        billing = get_billing_info(cfg)
        response = {
            "dashboard_name": cfg.get("dashboard_name", "Traffic Dashboard"),
            "interface": traffic["interface"],
            "download": traffic["download"],
            "upload": traffic["upload"],
            "today": traffic["today"],
            "yesterday": traffic["yesterday"],
            "billing": billing,
            "daily_history": traffic["daily_history"],
            "hourly_history": traffic["hourly_history"],
            "weekly_history": traffic["weekly_history"],
            "monthly_history": traffic["monthly_history"],
        }
        return jsonify(response), 200
    except Exception as exc:  # noqa: BLE001 - must never crash the app
        logger.exception("Unexpected error building /api/traffic response: %s", exc)
        return jsonify({"error": "Failed to read traffic data"}), 500


@app.route("/api/settings", methods=["GET"])
@login_required
def api_get_settings():
    cfg = load_config()
    return (
        jsonify(
            {
                "dashboard_name": cfg.get("dashboard_name", "Traffic Dashboard"),
                "monthly_limit_gb": float(cfg.get("monthly_limit_gb", 0) or 0),
                "overage_price": float(cfg.get("overage_price", 0) or 0),
                "currency": cfg.get("currency", "USD"),
                "vps_expiration_date": cfg.get("vps_expiration_date", "") or "",
                "dashboard_path": get_dashboard_path(cfg),
            }
        ),
        200,
    )


@app.route("/api/settings", methods=["POST"])
@login_required
def api_update_settings():
    if not request.is_json:
        return jsonify({"error": "Request body must be JSON"}), 400

    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify({"error": "Invalid JSON body"}), 400

    dashboard_name = payload.get("dashboard_name")
    monthly_limit_gb = payload.get("monthly_limit_gb")
    overage_price = payload.get("overage_price")
    currency = payload.get("currency")
    vps_expiration_date = payload.get("vps_expiration_date", "")
    dashboard_path = payload.get("dashboard_path")

    # ---- Validation ----
    if not isinstance(dashboard_name, str) or not dashboard_name.strip():
        return jsonify({"error": "dashboard_name must not be empty"}), 400

    try:
        monthly_limit_gb = float(monthly_limit_gb)
    except (TypeError, ValueError):
        return jsonify({"error": "monthly_limit_gb must be a number"}), 400
    if monthly_limit_gb <= 0:
        return jsonify({"error": "monthly_limit_gb must be greater than 0"}), 400

    try:
        overage_price = float(overage_price)
    except (TypeError, ValueError):
        return jsonify({"error": "overage_price must be a number"}), 400
    if overage_price < 0:
        return jsonify({"error": "overage_price must be >= 0"}), 400

    if currency not in ALLOWED_CURRENCIES:
        return (
            jsonify(
                {"error": f"currency must be one of {sorted(ALLOWED_CURRENCIES)}"}
            ),
            400,
        )

    # VPS expiration date: optional, but if provided it must be a valid
    # date that is today or in the future - never in the past.
    vps_expiration_date = (vps_expiration_date or "").strip()
    if vps_expiration_date:
        try:
            exp_date = datetime.strptime(vps_expiration_date, "%Y-%m-%d").date()
        except ValueError:
            return jsonify({"error": "invalid_date"}), 400
        if exp_date < date.today():
            return jsonify({"error": "date_in_past"}), 400

    # Dashboard URL path: letters/digits/hyphen/underscore only, 3-32 chars,
    # and must not collide with a route the app already uses.
    if dashboard_path is not None:
        dashboard_path = str(dashboard_path).strip().strip("/")
        if not DASHBOARD_PATH_RE.match(dashboard_path):
            return jsonify({"error": "invalid_path"}), 400
        if dashboard_path.lower() in RESERVED_SLUGS:
            return jsonify({"error": "reserved_path"}), 400

    cfg = load_config()
    cfg["dashboard_name"] = dashboard_name.strip()
    cfg["monthly_limit_gb"] = monthly_limit_gb
    cfg["overage_price"] = overage_price
    cfg["currency"] = currency
    cfg["vps_expiration_date"] = vps_expiration_date
    if dashboard_path is not None:
        cfg["dashboard_path"] = dashboard_path

    if not save_config(cfg):
        return jsonify({"error": "Failed to save settings"}), 500

    global CONFIG
    CONFIG = cfg

    return (
        jsonify(
            {
                "dashboard_name": cfg["dashboard_name"],
                "monthly_limit_gb": cfg["monthly_limit_gb"],
                "overage_price": cfg["overage_price"],
                "currency": cfg["currency"],
                "vps_expiration_date": cfg.get("vps_expiration_date", ""),
                "dashboard_path": get_dashboard_path(cfg),
            }
        ),
        200,
    )


# ============================================================
# ERROR HANDLERS
# ============================================================

@app.errorhandler(404)
def not_found(_exc):
    if request.path.startswith("/api/"):
        return jsonify({"error": "Not found"}), 404
    cfg = load_config()
    return redirect("/" + get_dashboard_path(cfg))


@app.errorhandler(500)
def server_error(exc):
    logger.exception("Unhandled server error: %s", exc)
    if request.path.startswith("/api/"):
        return jsonify({"error": "Internal server error"}), 500
    return "Internal server error", 500


# ============================================================
# MAIN (development only - production uses Gunicorn)
# ============================================================

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=False)
