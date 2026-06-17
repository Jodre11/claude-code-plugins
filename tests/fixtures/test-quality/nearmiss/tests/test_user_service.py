"""Tests for user service creation flow."""

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from user_service import create_user


def _create_test_db():
    conn = sqlite3.connect(":memory:")
    conn.execute(
        """
        CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL
        )
        """
    )
    return conn


def test_create_user_stores_record():
    """Verify that creating a user persists the record in the database."""
    conn = _create_test_db()
    create_user(conn, email="alice@example.com", name="Alice")
    row = conn.execute(
        "SELECT email, name FROM users WHERE email = ?", ("alice@example.com",)
    ).fetchone()
    assert row is not None
    assert row[0] == "alice@example.com"
    assert row[1] == "Alice"
    conn.close()
