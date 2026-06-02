## Ruff Findings

### Finding — `sys` imported but unused
- **File:** bad.py:1
- **Confidence:** 100
- **Severity:** Important
- **Rule:** F401 (Pyflakes)
- **Description:** `sys` imported but unused
- **Suggested fix:** Remove the `import sys` statement on line 1; ruff's safe auto-fix removes the import entirely.
