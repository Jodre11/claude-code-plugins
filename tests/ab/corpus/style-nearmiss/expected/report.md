## Style Review Findings

### Finding — Field set duplicated across three parallel blocks
- **File:** lib/report.py:43
- **Confidence:** 45
- **Severity:** Suggestion
- **Description:** Each audit field is enumerated three times in lockstep: the `AuditRecord` dataclass attribute (lines 11–30, outside the diff), the `*_label` definitions (lines 43–62), and the `lines.append(...)` calls (lines 71–90). Adding, removing, or renaming a field requires synchronised edits in all three places, and the label block and append block must stay in the same order to render correctly — a silent mis-pairing (e.g. a label and value drifting out of order) would not be caught by any structural check. A single driver list of `(label, attribute)` tuples iterated once would collapse blocks two and three into one source of truth. This is in-diff duplication (all copies visible in one screen, so the misread risk for an agent is low), which is why this is only a suggestion rather than a stronger flag. The function is otherwise flat, linear, and honestly named — no concern with its length per se.
- **Suggested fix:** Replace the 20 `*_label` variables and 20 `append` calls with a list of `(label, attr_name)` pairs, then loop: `for label, attr in FIELDS: lines.append(f"{label.ljust(col)}: {getattr(record, attr)}")`. This keeps label and value definitionally paired and reduces the per-field maintenance points from three to two.

The remaining changed code reads cleanly: `build_audit_report` accurately names what it does, there is no commented-out code, no clever/dense constructs, no misleading names, and nesting is shallow (one loop, one level).