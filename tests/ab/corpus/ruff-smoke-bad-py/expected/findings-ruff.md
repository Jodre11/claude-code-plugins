## Ruff Findings

**1 finding** — 1 Python file analysed.

---

**Finding 1**

- **File:** `bad.py`
- **Line:** 1
- **Rule:** `F401` (Pyflakes)
- **Severity:** Important
- **Confidence:** 100
- **Message:** `` `sys` imported but unused ``
- **Detail:** The `import sys` statement on line 1 is never referenced in the file. Ruff has a safe auto-fix available: remove the import entirely.
