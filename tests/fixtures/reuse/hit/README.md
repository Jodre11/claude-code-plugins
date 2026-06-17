# Reuse HIT fixture

Non-trivial canonical helper reimplemented instead of reused.

A well-tested shared utility with currency-formatting logic (symbol lookup,
negative values, zero, locale suffix) exists in the `utils/` package.
A separate module in `lib/` reimplements the same logic inline rather than
importing from `utils`.

The reuse-reviewer should catch this: blast-radius is real (a bug in the shared
logic must be fixed in two places) and cold-start amnesia applies (an agent would
not know the canonical version exists without grepping).
