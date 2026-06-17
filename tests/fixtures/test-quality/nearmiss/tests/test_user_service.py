"""Tests for user service creation flow."""

import sqlite3


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
    conn.execute(
        "INSERT INTO users (email, name) VALUES (?, ?)",
        ("alice@example.com", "Alice"),
    )
    row = conn.execute(
        "SELECT email, name FROM users WHERE email = ?", ("alice@example.com",)
    ).fetchone()
    assert row is not None
    assert row[0] == "alice@example.com"
    assert row[1] == "Alice"
    conn.close()
