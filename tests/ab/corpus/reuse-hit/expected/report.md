I'll review the changed code for missed reuse of existing utilities. Let me start by reading the changed file and exploring the codebase.
The new code does currency symbol lookup and amount formatting inline. Let me search for existing formatting utilities.
This is a near-exact reimplementation of an existing canonical utility. The new code in `lib/invoice.py:18-27` duplicates `format_currency` from `utils/formatting.py:7-21` line-for-line.

## Reuse Review Findings

### Finding — Inline currency formatting duplicates `format_currency`
- **File:** lib/invoice.py:18
- **New code:** `render_invoice_summary` reimplements currency formatting inline (lines 18–27): the `{"USD": "$", "GBP": "£", "EUR": "€"}` symbol map, the unsupported-currency `ValueError`, and the negative/zero/positive `,.2f` formatting branches.
- **Existing equivalent:** utils/formatting.py:7-21 — `format_currency(amount, currency="USD")` is a canonical, tested helper that performs the identical symbol lookup, identical `ValueError` on unsupported currency, and identical negative/zero/positive `,.2f` formatting.
- **Confidence:** 98
- **Severity:** Important
- **Description:** The inline logic is a line-for-line duplicate of the existing `format_currency` utility (same symbol dict, same error message format, same three formatting branches). This is non-trivial, branching logic with real blast radius: a bug or a new currency added in one copy will silently diverge from the other, and each future fix must be applied in two places. The module docstring explicitly designates `utils/formatting.py` as the "canonical, tested" home for display-layer string conversion, so the duplication directly contradicts the project's stated intent.
- **Suggested fix:** Import and delegate to the existing helper:
  ```python
  from utils.formatting import format_currency

  def render_invoice_summary(invoice: Invoice) -> str:
      """Format the invoice line items for display."""
      formatted = format_currency(invoice.amount, invoice.currency)
      return f"Invoice {invoice.invoice_id} for {invoice.customer}: {formatted}"
  ```
  This removes the duplicated symbol map, validation, and formatting branches (lines 18–27), preserving identical behaviour including the `ValueError` for unsupported currencies.