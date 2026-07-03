I'll start by reading the changed file and understanding the codebase structure.
The changed function does string slugification. Let me check for existing string utilities — the git history mentions "string utils".
There's a `utils/strings.py`. Let me read it.
I found a clear reuse issue. The inline slug logic on line 6 reimplements the existing `slugify` helper.

## Reuse Review Findings

### Finding — Reimplemented `slugify` from shared string utils
- **File:** lib/reports.py:6
- **New code:** Inline slugification `title.lower().replace(" ", "-")` to build the filename stem.
- **Existing equivalent:** utils/strings.py:4 — `slugify(text)` returns `text.lower().replace(" ", "-")`, an identical, drop-in implementation already present as a shared utility.
- **Confidence:** 95
- **Severity:** Suggestion
- **Description:** The diff inlines the exact slugification logic that `utils/strings.py` already exports as the canonical `slugify` helper. Although the body is short, this is reimplementation of a dedicated, named utility rather than incidental duplication: the project clearly intends slug generation to live in one place. Reusing it keeps slug semantics (e.g. future handling of casing, separators, or unsafe characters) consistent across the codebase — any later hardening of `slugify` would otherwise silently skip report filenames, and the divergence is exactly the kind of thing an agent rebuilding the function from scratch would miss.
- **Suggested fix:** Import and call the shared helper:
  ```python
  from utils.strings import slugify

  def generate_report_filename(title: str) -> str:
      """Return a filesystem-safe filename for a report with *title*."""
      return f"{slugify(title)}.pdf"
  ```