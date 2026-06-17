"""Shared string utilities."""


def slugify(text: str) -> str:
    """Return a URL-safe slug for *text*."""
    return text.lower().replace(" ", "-")
