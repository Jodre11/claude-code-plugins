"""Invoice generation helpers."""

from dataclasses import dataclass


@dataclass
class Invoice:
    """Represents a billing invoice."""

    invoice_id: str
    customer: str
    amount: float
    currency: str = "USD"


def render_invoice_summary(invoice: Invoice) -> str:
    """Format the invoice line items for display, including currency symbol lookup and sign handling."""
    symbols = {"USD": "$", "GBP": "£", "EUR": "€"}
    if invoice.currency not in symbols:
        raise ValueError(f"Unsupported currency: {invoice.currency!r}")
    symbol = symbols[invoice.currency]
    if invoice.amount < 0:
        formatted = f"-{symbol}{abs(invoice.amount):,.2f}"
    elif invoice.amount == 0:
        formatted = f"{symbol}0.00"
    else:
        formatted = f"{symbol}{invoice.amount:,.2f}"
    return f"Invoice {invoice.invoice_id} for {invoice.customer}: {formatted}"
