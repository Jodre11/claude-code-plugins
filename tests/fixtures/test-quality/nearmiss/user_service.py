"""User service — creation flow."""

import sqlite3


def create_user(conn: sqlite3.Connection, email: str, name: str) -> int:
    """Create a user and return the new row ID."""
    cursor = conn.execute(
        "INSERT INTO users (email, name) VALUES (?, ?)",
        (email, name),
    )
    return cursor.lastrowid
