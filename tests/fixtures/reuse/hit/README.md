# Reuse HIT fixture

Non-trivial canonical helper reimplemented instead of reused.

`utils/formatting.py` contains a well-tested `format_currency` function with
branching (negative values, zero, locale suffix). `lib/invoice.py` reimplements
the same logic inline rather than importing from `utils`.

The reuse-reviewer should catch this: blast-radius is real (a bug in the shared
logic must be fixed in two places) and cold-start amnesia applies (an agent would
not know the canonical version exists without grepping).
