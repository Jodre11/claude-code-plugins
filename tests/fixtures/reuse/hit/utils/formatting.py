"""Shared formatting utilities.

Canonical, tested helpers for display-layer string conversion.
"""


def format_currency(amount: float, currency: str = "USD") -> str:
    """Return a human-readable currency string for *amount*.

    Handles negative values, zero, and a small set of supported currency codes.
    Raises ValueError for unsupported currency codes.
    """
    symbols = {"USD": "$", "GBP": "£", "EUR": "€"}
    if currency not in symbols:
        raise ValueError(f"Unsupported currency: {currency!r}")
    symbol = symbols[currency]
    if amount < 0:
        return f"-{symbol}{abs(amount):,.2f}"
    if amount == 0:
        return f"{symbol}0.00"
    return f"{symbol}{amount:,.2f}"
