"""User settings helpers."""

import sqlite3


_DB_PATH = "settings.db"


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(_DB_PATH)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS settings (
            user_id INTEGER PRIMARY KEY,
            theme   TEXT    NOT NULL DEFAULT 'light',
            locale  TEXT    NOT NULL DEFAULT 'en'
        )
        """
    )
    return conn


def save_user_settings(user_id: int, theme: str, locale: str) -> None:
    """Persist user preference overrides."""
    with _connect() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO settings (user_id, theme, locale) VALUES (?, ?, ?)",
            (user_id, theme, locale),
        )


def get_user_settings(user_id: int) -> dict:
    """Return settings dict for the given user."""
    with _connect() as conn:
        row = conn.execute(
            "SELECT theme, locale FROM settings WHERE user_id = ?", (user_id,)
        ).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO settings (user_id, theme, locale) VALUES (?, 'light', 'en')",
                (user_id,),
            )
            return {"theme": "light", "locale": "en"}
        return {"theme": row[0], "locale": row[1]}
