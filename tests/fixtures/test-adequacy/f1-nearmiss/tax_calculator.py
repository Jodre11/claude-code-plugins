"""Tax calculator for the review-harness test-adequacy A/B trial fixture (F1 near-miss)."""

TAX_RATE = 0.20


def calculate_tax(subtotal: float, exempt: bool = False) -> float:
    """Return the tax amount for *subtotal*.

    Returns 0.0 when the transaction is tax-exempt.
    """
    if exempt:
        return 0.0
    return round(subtotal * TAX_RATE, 2)
