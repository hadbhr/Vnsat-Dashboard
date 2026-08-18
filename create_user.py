#!/usr/bin/env python3
"""
Helper CLI to create or update a dashboard user with a securely hashed
password. Run this manually on the VPS - it is NOT imported by app.py.

Usage:
    venv/bin/python create_user.py <username>

You will be prompted for a password (input hidden).
"""

import json
import sys
import getpass
from pathlib import Path

from werkzeug.security import generate_password_hash

USERS_PATH = Path(__file__).resolve().parent / "users.json"


def main():
    if len(sys.argv) != 2:
        print("Usage: create_user.py <username>")
        sys.exit(1)

    username = sys.argv[1].strip()
    if not username:
        print("Username must not be empty")
        sys.exit(1)

    password = getpass.getpass("Password: ")
    password_confirm = getpass.getpass("Confirm password: ")

    if password != password_confirm:
        print("Passwords do not match")
        sys.exit(1)
    if len(password) < 8:
        print("Password should be at least 8 characters")
        sys.exit(1)

    if USERS_PATH.exists():
        try:
            with open(USERS_PATH, "r", encoding="utf-8") as f:
                users = json.load(f)
        except (json.JSONDecodeError, OSError):
            users = {}
    else:
        users = {}

    users[username] = {"password_hash": generate_password_hash(password)}

    tmp_path = USERS_PATH.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(users, f, indent=2, ensure_ascii=False)
    tmp_path.replace(USERS_PATH)

    print(f"User '{username}' saved to {USERS_PATH}")


if __name__ == "__main__":
    main()
