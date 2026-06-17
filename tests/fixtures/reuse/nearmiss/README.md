# Reuse NEAR-MISS fixture

Trivial helper duplicated — should NOT be flagged by the retargeted reviewer.

`utils/strings.py` contains a one-line `slugify` function (no branching).
`lib/reports.py` duplicates it inline.

The retargeted reuse-reviewer (arm B) must NOT flag this: the helper is ≤3 lines,
branchless, low blast-radius. Consolidating a one-liner risks the wrong abstraction.

The pre-edit reviewer (arm A) flags it as a Suggestion. The contrast between
arm A (Suggestion) and arm B (ABSENT) is the behavioural proof of the triviality
bifurcation.
