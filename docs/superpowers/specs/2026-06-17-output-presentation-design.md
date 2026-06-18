# Output Presentation & Mechanical Filtering

**Thread:** Forward programme #1 — output presentation.
**Status:** Design approved.
**Date:** 2026-06-17.

## Governing Principle

The posted body is an **action document for the reviewee**: the verdict and the
findings that justify it. Flourish is permitted only where it earns *trust*;
everything else is noise and belongs in the log, not the body.

All body shaping is **mechanical and deterministic** — no model removes detail
or reinterprets findings. Content is *relocated*, never discarded or rewritten.

## Three Artefacts, Three Audiences

| Artefact | Contents | Audience |
|---|---|---|
| **PR body** | verdict + reason; promoted Synthesiser Assessment; compact finding index (summary lines); dependency freshness | reviewee |
| **Inline comments** | full detail per finding (unchanged format) | reviewee + agentic fixer |
| **Full log** | everything — all tiers, all confidences, contested, dismissed, cost, per-phase instrumentation | maintainer (analysis, phase-efficacy thread #2) |

## Posted Set (body + inline share the same set)

Body and inline are the **same set of findings** — they differ only in depth.
Every finding in the set appears as one summary line in the body AND one
detailed inline comment on its file/line.

The set is decided by the **existing verdict-driven posting filter** (no new
rule):

| Verdict | Posted set |
|---|---|
| `REQUEST_CHANGES` | every consensus + synthesiser-tier finding |
| `APPROVE` | consensus + synthesiser-tier findings with **confidence ≥ 75** |

This is identical to today's inline-comment posting filter for consensus,
extended to include synthesiser-tier findings (which previously posted only
in the body prose but never as inline comments).

Contested and dismissed findings are **never** in the posted set. They are
log-only.

When a finding appears in both the consensus and contested tiers (e.g. a
severity dispute), the consensus copy posts at the synthesiser's **settled
severity**. The dispute is log-only.

## Verdict Rubric — Unchanged

The verdict rubric is presentation-independent and is NOT modified by this
design:

| # | Condition | Verdict |
|---|---|---|
| 1 | Intent-ledger goal not achieved | `REQUEST_CHANGES` |
| 2 | Any consensus Critical (any confidence) | `REQUEST_CHANGES` |
| 3 | Any consensus Important with confidence ≥ 70 | `REQUEST_CHANGES` |
| 4 | Otherwise | `APPROVE` |

The user-confirmation gate (Class A) is also unchanged.

## Posted Body Shape

```markdown
**REQUEST_CHANGES** — <one-line rubric reason>

<Synthesiser Assessment prose — NOT block-quoted>

### Findings

- **[Critical]** <short title> — `path/file.cs:42` ↳ inline
- **[Important]** <short title> — `path/file.cs:221` ↳ inline
- **[Suggestion]** <short title> — `path/file.cs:104` ↳ inline

### Dependency Freshness

<reformatted table — see below>
```

### Sections explained

1. **Verdict + reason** — top, bold, first thing read. A **headline only**:
   identical to today's `Verdict:` / `Rubric row applied:` / `Reason:` content,
   rendered as a single prominent header line rather than a fenced code block.
   It states the outcome and the one-line reason — it never carries finding
   detail.

2. **Synthesiser Assessment** — promoted out of block-quote (today it renders
   greyed). This is the centrepiece prose: intent-vs-implementation analysis,
   risk profile, the analytical throughline. No formatting change except
   removing the `>` quoting.

3. **Findings index** — one compact line per finding in the posted set:
   `[severity]` + short title (from the synthesiser's existing
   `#### Finding #N — [short title]` header) + anchor + pointer.
   **No prose expansion** for line-anchored and file-anchored findings — their
   detail lives in the inline/file comment, and the body line ends `↳ inline`.
   For fileless findings the body line carries the full detail (there is no
   inline home — see Anchor Ladder). This is mechanically rendered from the
   structured envelope's `tiers.consensus` and `tiers.synthesiser` arrays — the
   host reads severity, file, line, and description from each finding object.

4. **Dependency Freshness** — reformatted for legibility (see below). Under
   APPROVE with no drift: `✓ Dependencies checked — all current`. When no
   dep-bearing files were touched (docs-only, etc.): section omitted entirely.

### Sections dropped from body → log

- Summary counts (`X file(s) changed | Y finding(s) | Z contested`)
- Contested Findings
- Dismissed Findings
- Cost / token instrumentation
- The "N additional finding(s) below threshold" footer

### APPROVE-path body

Under APPROVE the "Findings" section lists only the confidence ≥ 75 findings
that pass the filter. If the filter produces an empty set (common for clean
PRs), the body carries:

```markdown
**APPROVE** — no high-confidence Critical/Important findings

<Synthesiser Assessment prose>

### Dependency Freshness
✓ Dependencies checked — all current
```

No "Findings" section rendered when the list is empty.

## Inline Comments — Unchanged Format

Every finding in the posted set gets an inline comment with the existing format:

```markdown
**<Severity>** (confidence <N>)

<Description>

**Suggested fix:** <fix>

<reference URL if present>
```

This format is unchanged from today. The only change is that synthesiser-tier
findings now join the inline-comment set (previously body-prose-only).

## Anchor Ladder — Unanchorable Findings

### Principles

1. **Tighter anchors are better.** A finding pinned to a line is more
   actionable than one pinned to a file, which is more actionable than one in
   the body. Specialists and the synthesiser should anchor a finding as
   specifically as the evidence allows; the host then posts it at that level.
   The body fallback is the *last resort* for findings that genuinely have no
   file, never a convenience.

2. **Each finding is its own posting, independently resolvable.** Every
   line-level and file-level finding becomes its own GitHub comment with its own
   resolve-thread, so the author (or the agentic fixer) can address and resolve
   each one independently. Detail is resolved per-finding, not as one monolith.
   This is itself an argument for the ladder: pushing each finding to its own
   comment makes it independently trackable.

3. **The body is a headline, not a record.** The verdict line plus the
   Synthesiser Assessment plus a one-line-per-finding index — that is all. The
   body never carries per-finding detail (the sole exception being a fileless
   finding, which has no comment to hold it). The detail always lives in the
   per-finding comment.

### Cases

Not every finding maps to a specific line. A specialist or the synthesiser may
raise a concern that cannot be pinned to one part of the diff:

- **Cross-cutting / architectural** — e.g. "this approach duplicates the
  existing X subsystem", "error handling is inconsistent across these files".
- **Absence findings** — e.g. "no test covers the SUPERSEDED path", "this
  public API is missing its required header docs". The problem is something
  that *should* exist but does not, so there is no line to point at.
- **File-level, line-less** — e.g. "this whole file belongs elsewhere".
- **Repo-wide, fileless** — e.g. "the PR is missing a changelog entry".

A posted finding anchors at the **most specific level it can**. GitHub PR
reviews support three anchor levels, and the host selects mechanically based
on the finding's `file` / `line`:

| Finding has | Anchor | Detail home | Body line |
|---|---|---|---|
| `file` + real `line` (> 0, or a deletion anchor) | line-level inline comment | inline comment | summary + `↳ inline` |
| `file`, no usable line (`line` ≤ 0, not a deletion anchor) | **file-level** comment (`subject_type: "file"`) | file-level comment | summary + `↳ file comment` |
| no `file` | none | **the body itself** | full detail (the one exception to "body = summary only") |

This preserves the invariant: **detail always has a home**, and the body
carries detail only for the genuinely fileless minority — where there is no
inline home to point at.

### Schema change

The finding schema's `file` field becomes **optional** so a genuinely fileless
finding can be represented without a fabricated path. `FINDING_SHAPE` in
`review-core.mjs` and the canonical `includes/finding-schema.json` both drop
`file` from `required` (the parity test must stay green — change both). `line`
remains as-is. A finding with no `file` is valid; the host routes it to the
body. A finding with `file` but no usable `line` is valid; the host routes it
to a file-level comment.

The synthesiser may legitimately raise fileless findings (e.g. a missing
changelog). No prompt change is required — the schema relaxation is permissive,
and the existing output format already tolerates findings whose `File:` line
names a concern rather than a precise location.

### Posting mechanics

- **File-level comment** — posted via `gh api` with `subject_type: "file"` and
  the `path` set, no `line` / `side`. The bundle's `comments[]` entries gain an
  optional discriminator so the posting step knows to omit line/side for these.
- **Fileless finding in body** — rendered as a full finding block in the body's
  Findings section (severity, description, suggested fix), not a one-line
  summary. No `↳` pointer (nothing to point to).

## Dependency Freshness — Reformatted

### Column order

Numeric columns first at full width — **numbers must never wrap**. The `Notes`
column is demoted to last position (natural-wrapping) or a footnote list below
the table.

| Package / Action | Current | Latest GA | Drift | Notes |
|---|---|---|---|---|
| AWSSDK.SecretsManager | 4.0.4.24 | 4.0.5.6 | patch | … |

### States

- **Has drift**: table renders with the reformat above.
- **No drift**: `✓ Dependencies checked — all current`
- **No dep-bearing files touched**: section omitted entirely (no false
  "verified" claim).

### Grouping

If more than ~10 rows, group by namespace/ecosystem (NuGet, npm, Docker,
GitHub Actions) with sub-headings. Avoid wrapping numbers into an unreadable
mass. Exact formatting will be refined during implementation based on
real-world table widths.

## Full Log — Format & Location

Persists in `$CLAUDE_TEMP_DIR` (session-scoped). Two files:

### `review-full.md`

The complete synthesiser report — today's verbatim `bodyText` (all sections
including Contested, Dismissed, Cost, Summary). Human-readable. This is the
analytical record.

### `review-findings.jsonl`

One JSON record per finding, plus per-phase cost rows:

```jsonl
{"type":"finding","tier":"consensus","domain":"correctness","severity":"Important","confidence":88,"file":"...","line":240,"description":"...","verdict_relevant":true}
{"type":"finding","tier":"synthesiser","domain":"synthesiser","severity":"Suggestion","confidence":65,"file":"...","line":42,"description":"...","verdict_relevant":false}
{"type":"finding","tier":"contested","domain":"security","severity":"Critical","confidence":82,"file":"...","line":240,"description":"...","verdict_relevant":false}
{"type":"finding","tier":"dismissed","domain":"correctness","severity":"Suggestion","confidence":65,"file":"...","line":10,"description":"...","verdict_relevant":false}
{"type":"phase","phase":"dispatch","duration_s":42,"token_count":15000}
{"type":"phase","phase":"cross","duration_s":28,"token_count":9000}
{"type":"phase","phase":"synth","duration_s":35,"token_count":22000}
```

Fields: `type`, `tier`, `domain`, `severity`, `confidence`, `file`
(absent/empty for fileless findings), `line`, `description`, `suggested_fix`,
`verdict_relevant` (boolean — true iff the finding drove the rubric row).
Phase records carry `duration_s` and `token_count`. Feeds thread #2
(phase-efficacy analysis).

## Mechanical Implementation (summary)

All changes are in the **host layer** (`review-core.mjs` + the posting step
in the skill/command files). The synthesiser agent is NOT modified — it
continues producing the same structured envelope and the same `bodyText`.

The host:
1. Writes `review-full.md` (the raw `bodyText`) and `review-findings.jsonl`
   to `$CLAUDE_TEMP_DIR`.
2. Builds the posted body by mechanically reading the structured envelope:
   - Verdict + reason from `envelope.verdict` / `rubricRowApplied` /
     `rubricReason`.
   - Assessment extracted from `bodyText` (the text between `## Synthesiser
     Assessment` and the next `## ` heading), with block-quote `>` prefix
     stripped.
   - Finding index rendered from `tiers.consensus` + `tiers.synthesiser`
     arrays (severity, file, line, description). Each finding routed per the
     Anchor Ladder: line/file-anchored → summary line + pointer; fileless →
     full detail in the body.
   - Dependency Freshness extracted from `bodyText` (the text between
     `## Dependency Freshness` and the next `## ` heading), reformatted.
3. Builds comments from the same finding arrays (unchanged inline format).
   Line-anchored findings produce line-level comments; file-anchored findings
   produce file-level comments (`subject_type: "file"`); fileless findings
   produce no comment (they live in the body).
4. Returns the sealed bundle `{ verdict, bodyText, comments }`, where each
   `comments[]` entry carries an optional anchor discriminator so the posting
   step omits `line`/`side` for file-level comments.

No model re-judges, re-summarises, or reinterprets any content.

## What Is NOT Changed

- Verdict rubric (same logic, same thresholds).
- User-confirmation gate (Class A prompt).
- Inline comment format (same depth, same structure).
- The synthesiser agent's prompt and output format. (The envelope **schema**
  changes in one respect only: `file` becomes optional — see Anchor Ladder.
  The agent's prose output format is otherwise untouched.)
- The confidence ≥ 75 APPROVE filter (same number).
- The REQUEST_CHANGES = post everything rule.
- Lightweight/trivial-mode routing (out of scope — pre-existing divergence).
