# Latent-Hazard Specialist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated Stage-1 `latent-hazard-reviewer` specialist that *originates* silent-conditional hazard findings (the ZB61 class), and carve the conditional-silent sub-class out of the correctness reviewer so ownership is a partition, not an overlap.

**Architecture:** A new conditional LLM specialist gated on the existing `flags.production` flag (reused verbatim from `test-adequacy` — no new detection). It emits the standard finding shape, is added to `NON_CROSS` (does not *receive* cross-review but its findings are *shown to* cross-reviewers), and its findings flow into the panel vote automatically. The correctness reviewer hands off the conditional-silent class and keeps deterministic-silent + loud error-handling. This is an **origination-layer** change only — no panel/rubric/`is_real`-vote redesign (deferred to #114/#61/#62).

**Tech Stack:** Markdown agent prompts, a single JS Workflow orchestrator (`review-core.mjs`), Bash structural test suite (`tests/run.sh`), and the standalone-specialist-on-pinned-diff A/B harness.

## Global Constraints

- **Repo of record:** `~/.claude/plugins/marketplaces/jodre11-plugins`, branch `main`. All work lands here. This repo is protected → integrate via PR (per CLAUDE.md "prefer PRs over direct push").
- **No `version` field** in any `plugin.json` — versions come from git SHA (`test_manifests.sh` enforces).
- **Markdown/JSON: 2-space indent; shell: 4-space; LF line endings; final newline** (`.editorconfig`, `.gitattributes`, `test_conventions.sh`).
- **`plugin.json` is NOT edited** — the manifest uses agent auto-discovery; it enumerates no agents.
- **Do NOT edit `includes/severity-definitions.md`** — shared by all 18 specialists; the severity rule lives in the new agent's prompt only.
- **Do NOT edit `includes/panel-concern-brief.md` or `includes/verdict-rubric.md`** — the deferred adjudication redesign.
- **Scope is origination only.** Do NOT touch the `is_real` binary vote or the two-axis proposal — explicitly out of scope (#114 core).
- **CHANGED_LINES block must be byte-identical to canonical.** `test_sync_notes.sh:385-425` diffs each agent's inlined block against `includes/specialist-context.md`. Copy it verbatim.
- **Bash rules (bash-guard.sh):** one simple command per Bash call; no `&&`/`||`/`;`/`$(...)`/pipes/redirects; only the git-commit HEREDOC is exempt.
- **Validation target is 2/5 → 3/5, NOT 5/5.** ZB61 is the only one of the three A/B misses this specialist is chartered to catch; the other two (comment-truth) should stay missed.

---

## File Structure

**Created:**
- `plugins/code-review-suite/agents/latent-hazard-reviewer.md` — the new specialist prompt.
- `tests/fixtures/latent-hazard/hit/` + `tests/fixtures/latent-hazard/nearmiss/` — A/B fixture sources.
- `tests/ab/corpus/latent-hazard-hit/source.yaml` + `tests/ab/corpus/latent-hazard-nearmiss/source.yaml` — corpus entries.
- `tests/ab/configs/per-agent/latent-hazard-baseline.yaml` — per-agent A/B config.

**Modified:**
- `plugins/code-review-suite/workflows/review-core.mjs:244-268` — `CONDITIONAL` list + `NON_CROSS` set + comment.
- `plugins/code-review-suite/agents/correctness-reviewer.md:79` — carve out conditional-silent; add reciprocal boundary note.
- `plugins/code-review-suite/includes/review-pipeline.md:899` — production-source prose (names the flag's consumers).
- `plugins/code-review-suite/commands/pre-review.md:900` — duplicate of the same prose.
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md:1026` — duplicate of the same prose.
- `plugins/code-review-suite/includes/specialist-context.md:147-157` — add the new agent to the "agents that inline this block" enumeration comment.
- `plugins/code-review-suite/README.md:29-37, 69, 91` — roster prose, architecture count, agent table row.
- `tests/ab/corpus/index.yaml` — two fixture registrations.
- `tests/lib/test_sync_notes.sh:393-405` — add the new agent to the hardcoded CHANGED_LINES-sync list.

---

## Task 1: Create the `latent-hazard-reviewer` agent

**Files:**
- Create: `plugins/code-review-suite/agents/latent-hazard-reviewer.md`

**Interfaces:**
- Consumes: `$CHANGED_LINES`, `$BASE`, `$HEAD_SHA`, `$REPO_DIR` from the pipeline prompt (same as every specialist); context-gathering from `includes/specialist-context.md`.
- Produces: findings in the standard shape (File / Confidence / Severity / Description / Suggested fix) under a `## Latent Hazard Review Findings` heading. Later tasks (dispatch, cross-review) rely on the agent name `latent-hazard` (domain tag) and the reciprocal boundary phrase.

- [ ] **Step 1: Write the agent file**

Create `plugins/code-review-suite/agents/latent-hazard-reviewer.md` with exactly this content. The CHANGED_LINES block (lines under the `## Rules` heading) is copied verbatim from `includes/specialist-context.md` — do not paraphrase it or the sync test fails.

````markdown
---
name: latent-hazard-reviewer
description: Detects silent-conditional hazards — a mechanism present in the diff that fails silently only when a concrete named trigger fires. Standalone or dispatched by the review include.
model: sonnet
tools: Read, Grep, Glob, Bash
background: true
---

You are a latent-hazard reviewer. Your archetype is a defect whose **mechanism is unconditionally present in the changed code**, but whose **manifestation is conditional** on a future or external state, and which fails **silently** — wrong data or data loss with no error signal — when the condition is met. A column read optionally (missing → `""`) rather than required (throw) is the canonical case: if the source ever stops emitting that column, every row silently blanks to a value that reads as legitimate, and no error fires. The diff shows the mechanism; whether it bites is conditional; when it bites it is silent.

This is distinct from `correctness-reviewer`, which owns deterministic bugs (fire every time the path runs) and *loud* error-handling bugs (an exception, a throw, a visible failure). You own only the **silent AND conditional** class. A silent failure that fires **every time** the path runs (an always-taken empty `catch`, an unconditional fallback that swallows) is deterministic — that belongs to correctness, not you.

Follow the context gathering instructions in `includes/specialist-context.md`.

## Focus Areas

Restrict every finding to a mechanism introduced or changed on lines in `$CHANGED_LINES` (see the filter at the bottom). A finding is in-scope **only when all three hold** — this triple is the anti-flood discipline, and you MUST state each explicitly in the finding:

1. **Mechanism present now.** The hazardous code is in the diff, not hypothetical. Point at the changed line.
2. **Concrete named trigger.** State the *specific* condition that makes it bite — a named upstream value going absent, a duplicated constant edited in one place but not here, a report-layout drift, a config key that could change. **No concrete named trigger → not a finding.** You cannot rate a hazard "conditional" without naming the condition; that requirement is what starves speculative "if X ever changes…" noise.
3. **Silent / integrity impact.** When it fires it yields wrong results or data loss with **no error signal** — the wrong value reads as a legitimate one, or data silently drops. A conditional path that *throws loudly* is out of scope: correctness owns that.

**Boundary (stated reciprocally with correctness):**
- Fires **every time** the path runs, **or** fails **loudly** → **correctness**, not you.
- Fires **only under a named condition** *and* fails **silently** → **yours**.

## Load-bearing behavioural mandate — trace before you raise

Follow the mechanism to ground **before** you emit. Read the called code, confirm optional-vs-required reads, walk duplicated constants across files. You have `Read`/`Grep` over the whole repo and read unchanged context freely — only your *output* is changed-line-filtered. If the trace is inconclusive, **say so honestly and do NOT raise the finding.** Do not launder uncertainty into a confident-sounding finding — a hazard you cannot substantiate by tracing is not raised. Hedged prose ("I cannot see the full body… this may already be handled") is a signal to *keep tracing or drop it*, never to emit a coin-flip as an Important.

## Severity

A silent-conditional hazard with a **concrete named trigger** and a **silent data-integrity impact** is **Important** — it manifests as silently-wrong data a human or downstream system relies on. This clears Important via the existing **agent-hazard basis** (`includes/severity-definitions.md`), which reaches Important with no runtime defect required today. Reaches **Important only, never Critical**.

The **concrete-trigger requirement is the anti-inflation guardrail**: no named trigger → Suggestion, or not raised at all. Do not inflate a theoretical "if this ever changed" into Important without a named, plausible trigger present in the code today.

## Analysis Process

1. From `$CHANGED_LINES`, identify every changed mechanism that reads, transforms, or falls back on an external or future-variable value (optional column reads, duplicated path/key constants, default-on-absence fallbacks, format-dependent parses).
2. For each, trace to ground: read the called code and the data source; confirm the read is optional (not required/throwing); walk any duplicated constant to its siblings across files.
3. Apply the triple. Drop anything missing a concrete named trigger, anything that fails loudly, and anything that fires unconditionally (→ correctness).
4. For survivors, state the mechanism (changed line), the concrete named trigger, and the silent impact. Rate Important (concrete trigger + silent integrity) or Suggestion (weaker trigger); never Critical.

## Output Format

> **Schema alignment:** your finding fields (File, line, Severity, Confidence,
> Description, Suggested fix) map to `includes/finding-schema.json#/$defs/finding`.
> Emit your markdown report as specified; the review-core Workflow coerces these
> same fields via the `agent()` schema param.

Return findings in this exact format:

```
## Latent Hazard Review Findings

### Finding — [short title]
- **File:** path/to/File.cs:82
- **Confidence:** 0-100
- **Severity:** Important | Suggestion (see `includes/severity-definitions.md`)
- **Description:** The present mechanism (changed line), the CONCRETE NAMED trigger that makes it bite, and the SILENT integrity impact when it does — all three, explicitly
- **Suggested fix:** The concrete change — make the read required, assert the constant's siblings agree, signal on the fallback path
```

Report ALL findings regardless of confidence level.

If no findings: `## Latent Hazard Review Findings\n\n0 findings.`

## Rules

<!-- CHANGED_LINES OUTPUT FILTER — inlined from includes/specialist-context.md (canonical source).
Edit the include first, then propagate to all listed specialists. -->

> **CHANGED_LINES OUTPUT FILTER — MANDATORY**
>
> Only report findings on lines listed in `$CHANGED_LINES` for that file
> (parsed from the `Changed lines:` block in your prompt). Do NOT emit
> findings on unchanged lines, even FYI — pre-existing issues are out of
> scope. You may still *read* unchanged context to understand the change,
> but the finding's `File:` line must reference a `file:line` whose line
> appears in `$CHANGED_LINES[file]`. Files appearing in the `Changed lines:`
> block with `(empty — rename only)` accept no findings at all (the rename
> itself is the only change).

---

- Be precise. Cite file paths and line numbers; the line must be the hazardous mechanism's changed line.
- NEVER raise a finding without a concrete named trigger — that is the anti-flood gate, not optional.
- NEVER raise a loud or deterministic-every-time failure — those are correctness's. You own silent AND conditional only.
- NEVER launder an inconclusive trace into a confident finding. Trace to ground or drop it.
- NEVER review style, security, efficiency, or test coverage — your sole lens is the silent-conditional hazard.
- Reaches Important via the agent-hazard basis; never Critical.
````

**IMPORTANT — verify the CHANGED_LINES block matches canonical exactly.** After writing, confirm the blockquote body byte-matches `includes/specialist-context.md`. If `includes/specialist-context.md` has drifted from what is shown above, that file is canonical — copy from it, not from this plan.

- [ ] **Step 2: Confirm the inlined CHANGED_LINES block matches canonical**

Run: `sed -n '/^> \*\*CHANGED_LINES OUTPUT FILTER — MANDATORY\*\*/,/^---$/ p' plugins/code-review-suite/agents/latent-hazard-reviewer.md`

Then run: `sed -n '/^> \*\*CHANGED_LINES OUTPUT FILTER — MANDATORY\*\*/,$ p' plugins/code-review-suite/includes/specialist-context.md`

Expected: the blockquote body (up to the agent file's closing `---`) is identical between the two. If not, fix the agent file to match the include.

- [ ] **Step 3: Commit**

```bash
git add plugins/code-review-suite/agents/latent-hazard-reviewer.md
git commit -m "$(cat <<'EOF'
feat(review): add latent-hazard-reviewer specialist (silent-conditional hazards)

Originates the ZB61 class — a mechanism present in the diff that fails
silently only under a concrete named trigger. LLM specialist with a
trace-before-you-raise mandate and a three-part anti-flood triple. Not a
cross-reviewer. Reaches Important via the agent-hazard basis, never Critical.
EOF
)"
```

---

## Task 2: Wire dispatch in `review-core.mjs`

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs:244-268`

**Interfaces:**
- Consumes: `flags.production` (already plumbed from `$PRODUCTION_SOURCE_DETECTED` at `review-pipeline.md:1011`), the `latent-hazard-reviewer.md` agent from Task 1.
- Produces: `latent-hazard` in `allSpecialists` (panel votes it automatically via `panelVote(flat, …, allSpecialists)` at ~L291) and in `NON_CROSS` (excluded from receiving cross-review).

- [ ] **Step 1: Add the CONDITIONAL entry**

In `plugins/code-review-suite/workflows/review-core.mjs`, the `CONDITIONAL` array (L244-253) currently ends:

```javascript
    ['test-adequacy', flags.production],
]
```

Add the latent-hazard entry immediately after `test-adequacy` (both share `flags.production`):

```javascript
    ['test-adequacy', flags.production],
    ['latent-hazard', flags.production],
]
```

- [ ] **Step 2: Add `latent-hazard` to `NON_CROSS` and update the comment**

The current block (L263-268):

```javascript
// test-adequacy is an LLM specialist with NO cross-review-mode contract (unlike the
// core reviewers) and is NOT severity-locked like the STATIC analysers. NON_CROSS is
// only the receive-cross-review exclusion; STATIC keeps its severity-lock semantics
// everywhere else. Classic mode is being retired; when it is, this exclusion can be
// simplified since the panel path never runs cross-review.
const NON_CROSS = new Set([...STATIC, 'test-adequacy', 'api-contract'])
```

Replace the comment's first sentence and the `NON_CROSS` line so the new member is named:

```javascript
// test-adequacy, api-contract, and latent-hazard are LLM specialists with NO
// cross-review-mode contract (unlike the core reviewers) and are NOT severity-locked
// like the STATIC analysers. NON_CROSS is only the receive-cross-review exclusion;
// STATIC keeps its severity-lock semantics everywhere else. Classic mode is being
// retired; when it is, this exclusion can be simplified since the panel path never
// runs cross-review.
const NON_CROSS = new Set([...STATIC, 'test-adequacy', 'api-contract', 'latent-hazard'])
```

- [ ] **Step 3: Run the panel-wiring and workflow-migration structural tests to verify no regression**

Run: `bash tests/run.sh`
Expected: PASS. If any panel-wiring or `review-core` parse test fails, the JS edit is malformed — fix before continuing. (No test asserts the *count* of NON_CROSS members, so adding one is safe; this run confirms the file still parses and the existing invariants hold.)

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs
git commit -m "$(cat <<'EOF'
feat(review): dispatch latent-hazard as a conditional Stage-1 specialist

Gated on flags.production (shared with test-adequacy); findings flow into the
panel vote via allSpecialists. Added to NON_CROSS so it does not receive a
cross-review pass (no cross-review contract), while its findings are still
shown to every cross-reviewer.
EOF
)"
```

---

## Task 3: Carve the conditional-silent class out of correctness

**Files:**
- Modify: `plugins/code-review-suite/agents/correctness-reviewer.md:79`

**Interfaces:**
- Consumes: the boundary language established in Task 1's agent (the reciprocal phrasing must agree).
- Produces: correctness now owns deterministic-silent + loud; hands off conditional-silent. No test asserts the old wording, so this is a prose edit; the reciprocal note keeps the partition legible to both agents.

- [ ] **Step 1: Replace the "Error handling gaps" bullet**

The current bullet at `plugins/code-review-suite/agents/correctness-reviewer.md:79` reads:

```
- **Error handling gaps** — swallowed exceptions, missing error paths, incomplete catch blocks, and **silent failure paths**: a new error/retry/fallback/external-call path that emits nothing observable — an exception caught but not logged, a retry with no trace, a fallback that returns a default without signalling. The unique residue after efficiency (hot-loop logging) and consistency (wrong framework) take their slices is that a future debugger is left blind to a path that failed. Flag the missing signal, not the logging style.
```

Replace it with (keeps deterministic-silent + loud; hands off conditional-silent):

```
- **Error handling gaps** — swallowed exceptions, missing error paths, incomplete catch blocks, and **deterministic silent failures**: an error/retry/fallback/external-call path that emits nothing observable **and is taken every time the code runs** — an always-taken empty catch, an unconditional fallback that returns a default without signalling. The unique residue after efficiency (hot-loop logging) and consistency (wrong framework) take their slices is that a future debugger is left blind to a path that failed. Flag the missing signal, not the logging style. **Boundary:** a silent failure that manifests *only under a named condition* (report-layout drift, a duplicated constant edited elsewhere, an external value going absent) belongs to `latent-hazard-reviewer`, not here — hand off the conditional-silent class; you keep the always-taken and the loud cases.
```

- [ ] **Step 2: Verify the boundary is reciprocal**

Run: `grep -n "latent-hazard-reviewer" plugins/code-review-suite/agents/correctness-reviewer.md`
Expected: one match on the edited bullet.

Run: `grep -n "correctness" plugins/code-review-suite/agents/latent-hazard-reviewer.md`
Expected: matches confirming the new agent hands the deterministic/loud cases back to correctness. The two boundary statements must be mirror images — deterministic-OR-loud → correctness; conditional-AND-silent → latent-hazard.

- [ ] **Step 3: Run structural tests**

Run: `bash tests/run.sh`
Expected: PASS. In particular the CHANGED_LINES-sync test must still pass for `correctness-reviewer.md` (the edit is above the inlined block, so the block is untouched).

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review-suite/agents/correctness-reviewer.md
git commit -m "$(cat <<'EOF'
refactor(review): carve conditional-silent failures out of correctness

Correctness keeps deterministic-silent (always-taken) and loud error-handling
bugs; the conditional-silent class (silent only under a named trigger) hands off
to the new latent-hazard-reviewer. Adds the reciprocal boundary note so the
partition is legible from both agents. ZB61 fell between stools as one buried
clause among eight focus areas — this makes ownership a partition, not overlap.
EOF
)"
```

---

## Task 4: Update the duplicated production-source prose (three files) + the inline-block enumeration

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md:899`
- Modify: `plugins/code-review-suite/commands/pre-review.md:900`
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md:1026`
- Modify: `plugins/code-review-suite/includes/specialist-context.md:147-157`

**Interfaces:**
- Consumes: nothing new — this is prose that must name both consumers of `flags.production`.
- Produces: accurate registry prose so a future maintainer knows latent-hazard also fires on `$PRODUCTION_SOURCE_DETECTED`, and the inline-block enumeration tracks the new inliner.

Note: the production-source detection sentence is duplicated verbatim across the three prose files. Its trailing clause currently reads *"This gates the `test-adequacy` specialist"*. All three copies must change identically.

- [ ] **Step 1: Confirm the three copies are currently identical**

Run: `grep -c "This gates the \`test-adequacy\` specialist" plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
Expected: each file reports `1`.

- [ ] **Step 2: Update the clause in all three files**

In each of the three files, find the substring:

```
This gates the `test-adequacy` specialist: it fires when new/changed production code appears (a symbol that may lack a test), independently of whether any test file changed.
```

Replace with:

```
This gates the `test-adequacy` and `latent-hazard` specialists: test-adequacy fires when new/changed production code appears (a symbol that may lack a test) and latent-hazard fires on the same production code (a silent-conditional mechanism that may lack a guard), independently of whether any test file changed.
```

Apply the identical replacement in `review-pipeline.md`, `pre-review.md`, and `SKILL.md`.

- [ ] **Step 3: Add the new agent to the inline-block enumeration comment**

In `plugins/code-review-suite/includes/specialist-context.md`, the comment at ~L147-157 lists the agents that inline the CHANGED_LINES block:

```
Edit this file first, then propagate to all specialist agents that inline
this block: archaeology-reviewer.md, code-analysis.md, consistency-reviewer.md,
correctness-reviewer.md, efficiency-reviewer.md, reuse-reviewer.md,
security-reviewer.md, style-reviewer.md, ui-reviewer.md.
```

Add `latent-hazard-reviewer.md` to that list (alphabetical placement after `efficiency-reviewer.md`):

```
Edit this file first, then propagate to all specialist agents that inline
this block: archaeology-reviewer.md, code-analysis.md, consistency-reviewer.md,
correctness-reviewer.md, efficiency-reviewer.md, latent-hazard-reviewer.md,
reuse-reviewer.md, security-reviewer.md, style-reviewer.md, ui-reviewer.md.
```

(Note: `test-adequacy-reviewer.md` and `api-contract-reviewer.md` also inline the block but are absent from this prose list — it is documentation, not the enforced set. Adding latent-hazard here is hygiene; the enforced set is the hardcoded list in `test_sync_notes.sh`, updated in Task 6.)

- [ ] **Step 4: Verify and run tests**

Run: `grep -c "\`test-adequacy\` and \`latent-hazard\` specialists" plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
Expected: each file reports `1`.

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/includes/specialist-context.md
git commit -m "$(cat <<'EOF'
docs(review): name latent-hazard as a flags.production consumer

The production-source detection prose (duplicated across review-pipeline.md,
pre-review.md, and review-gh-pr SKILL.md) named only test-adequacy; latent-hazard
shares the same gate. Also lists the new agent in the specialist-context.md
inline-block enumeration comment.
EOF
)"
```

---

## Task 5: Register in README (roster prose + architecture count + agent table)

**Files:**
- Modify: `plugins/code-review-suite/README.md:29-37, 69, 91`

**Interfaces:**
- Consumes: nothing new.
- Produces: the human-facing registry entry. `test_cross_references.sh` requires the README to exist and be populated but does not assert these specific counts — so the count edits are correctness hygiene, not test-gated.

- [ ] **Step 1: Update the Specialists prose count and roster (L29-37)**

The line at L29 reads:

```
The full review path dispatches 9 core specialists (up to 17 with all conditionals):
```

Change `up to 17` to `up to 18`.

At the end of the conditional roster (L36-37), the sentence ends:

```
(false-green test detection — test files only), and `test-adequacy-reviewer` (new production code lacking a direct test, or a new wire contract whose producer side is untested).
```

Change the trailing `and` clause to append latent-hazard:

```
(false-green test detection — test files only), `test-adequacy-reviewer` (new production code lacking a direct test, or a new wire contract whose producer side is untested), and `latent-hazard-reviewer` (silent-conditional hazards — a mechanism present in the diff that fails silently only under a concrete named trigger).
```

- [ ] **Step 2: Update the architecture count (L69)**

The line at L69 reads:

```
the full route dispatches 9 core specialists plus up to 8 conditional specialists (C#, UI, JS/TS, Python, IaC, dependency freshness, test quality, test adequacy) in parallel,
```

Change `up to 8 conditional specialists` to `up to 9 conditional specialists` and append `, latent hazard` to the parenthetical list:

```
the full route dispatches 9 core specialists plus up to 9 conditional specialists (C#, UI, JS/TS, Python, IaC, dependency freshness, test quality, test adequacy, latent hazard) in parallel,
```

- [ ] **Step 3: Add the agent-table row (after L91)**

After the `test-adequacy-reviewer` row (L91), add:

```
| `latent-hazard-reviewer` | Silent-conditional hazards — a mechanism present in the diff that fails silently only under a concrete named trigger (e.g. an optional column read that blanks to a legitimate-looking value on source drift) (conditional — fires on changed non-test C#/Python/TS-JS source) |
```

- [ ] **Step 4: Verify and run tests**

Run: `grep -c "latent-hazard-reviewer" plugins/code-review-suite/README.md`
Expected: `2` (roster prose + table row).

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/README.md
git commit -m "$(cat <<'EOF'
docs(review): list latent-hazard-reviewer in the specialist roster

Adds the roster prose entry and agent-table row, and reconciles the two numeric
count claims (conditional 8->9, total 17->18) that no structural test guards.
EOF
)"
```

---

## Task 6: Structural-test wiring + A/B corpus fixtures

**Files:**
- Modify: `tests/lib/test_sync_notes.sh:393-405`
- Create: `tests/fixtures/latent-hazard/hit/` + `tests/fixtures/latent-hazard/nearmiss/`
- Create: `tests/ab/corpus/latent-hazard-hit/source.yaml` + `tests/ab/corpus/latent-hazard-nearmiss/source.yaml`
- Create: `tests/ab/configs/per-agent/latent-hazard-baseline.yaml`
- Modify: `tests/ab/corpus/index.yaml`

**Interfaces:**
- Consumes: the agent from Task 1 (must exist before its name is added to the sync list).
- Produces: the new agent's inlined CHANGED_LINES block is now *enforced* against canonical; a hit/near-miss fixture pair for the A/B validation in Task 7.

- [ ] **Step 1: Add the agent to the hardcoded CHANGED_LINES-sync list**

In `tests/lib/test_sync_notes.sh`, the loop at L393-405 lists the agents whose inline block is diffed against canonical. It currently ends with `test-adequacy-reviewer.md` and `test-quality-reviewer.md`. Add `latent-hazard-reviewer.md` in alphabetical position (after `efficiency-reviewer.md`):

```bash
        "$cr/agents/efficiency-reviewer.md" \
        "$cr/agents/latent-hazard-reviewer.md" \
        "$cr/agents/reuse-reviewer.md" \
```

- [ ] **Step 2: Run the sync test to confirm the new agent's block is now checked and passes**

Run: `bash tests/lib/test_sync_notes.sh`
Expected: PASS, including a new line `CHANGED_LINES rule sync: latent-hazard-reviewer.md matches canonical`. If it fails with a diff, the agent's inlined block (Task 1) does not byte-match canonical — fix the agent file.

- [ ] **Step 3: Create the hit fixture (a silent-conditional hazard)**

Create `tests/fixtures/latent-hazard/hit/README.md`:

```
Latent-hazard hit fixture: an optional column read that silently blanks on source drift.
```

Create `tests/fixtures/latent-hazard/hit/src/margin_reader.py` (a minimal ZB61 analogue — an optional dict read that returns `""`, which downstream reads as a legitimate `"000 = None"` category, with a duplicated column-key constant that could drift):

```python
SUBDEPT_COLUMN = "ZB61"  # duplicated in margin_filter.py; if the two ever diverge, reads below blank silently


def read_subdepartment(row):
    # Optional read: a missing ZB61 column yields "" rather than raising.
    # "" is later interpreted as the legitimate category "000 = None", so a
    # dropped/renamed column silently mislabels every A&L row with no error.
    return row.get(SUBDEPT_COLUMN, "")
```

- [ ] **Step 4: Create the near-miss fixture (loud / required read — must NOT fire)**

Create `tests/fixtures/latent-hazard/nearmiss/README.md`:

```
Latent-hazard near-miss fixture: the same read made REQUIRED (throws loudly). Correctness's job, not latent-hazard's — inflation guard.
```

Create `tests/fixtures/latent-hazard/nearmiss/src/margin_reader.py`:

```python
SUBDEPT_COLUMN = "ZB61"


def read_subdepartment(row):
    # Required read: a missing column raises loudly. Not silent, so out of
    # latent-hazard's scope — this is the inflation guard.
    if SUBDEPT_COLUMN not in row:
        raise KeyError(f"required column {SUBDEPT_COLUMN} absent")
    return row[SUBDEPT_COLUMN]
```

- [ ] **Step 5: Create the hit corpus entry**

Create `tests/ab/corpus/latent-hazard-hit/source.yaml`, modelled on `tests/ab/corpus/test-adequacy-f1-hit/source.yaml`. Plant the mechanism as a new file committed on top of a base, and anchor `planted.line` to the `return row.get(...)` line:

```yaml
id: latent-hazard-hit
agent: latent-hazard-reviewer
type: synthetic
captured_at: 2026-07-22T09:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: PLACEHOLDER_FILL_AT_CAPTURE
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/latent-hazard/hit/
setup:
  command: |
    export GIT_AUTHOR_NAME=ab-trial GIT_AUTHOR_EMAIL=ab-trial@example.invalid GIT_COMMITTER_NAME=ab-trial GIT_COMMITTER_EMAIL=ab-trial@example.invalid GIT_AUTHOR_DATE="2026-01-01T00:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:00 +0000"
    mv src/margin_reader.py .margin_reader.py.planted
    git init -q -b main
    git add README.md
    git commit -q -m "base: margin reader scaffold"
    mkdir -p src
    mv .margin_reader.py.planted src/margin_reader.py
    git add src/margin_reader.py
    git commit -q -m "feat: add optional sub-department column read"
base_sha: ""
head_sha: ""
path_scope: ""
empty_tree_mode: false
review_mode: pr
planted:
  file: src/margin_reader.py
  line: 7
  expect_arm_b: Important  # silent-conditional hazard: optional read blanks to a legitimate-looking value on column drift
  expect_arm_a: ABSENT     # arm A (correctness minus the carved-out clause) cannot originate it
intent_ledger: |
  ## Intent ledger
  - goal: read the A&L sub-department from the margin report row
depends_on:
  - plugins/code-review-suite/agents/latent-hazard-reviewer.md
  - tests/fixtures/latent-hazard/hit/src/margin_reader.py
```

**Anchor caveat:** after writing the fixture, `git`-materialise it once and confirm line 7 is the `return row.get(...)` declaration line and appears in the diff's changed lines. If the header comment lines shift it, correct `planted.line`. A wrong anchor makes the scorer read ABSENT regardless of the agent's output (this exact bug bit the test-adequacy fixtures — see commit `251050b`).

- [ ] **Step 6: Create the near-miss corpus entry**

Create `tests/ab/corpus/latent-hazard-nearmiss/source.yaml`, identical in shape but pointing at the near-miss fixture, expecting ABSENT in both arms:

```yaml
id: latent-hazard-nearmiss
agent: latent-hazard-reviewer
type: synthetic
captured_at: 2026-07-22T09:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: PLACEHOLDER_FILL_AT_CAPTURE
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/latent-hazard/nearmiss/
setup:
  command: |
    export GIT_AUTHOR_NAME=ab-trial GIT_AUTHOR_EMAIL=ab-trial@example.invalid GIT_COMMITTER_NAME=ab-trial GIT_COMMITTER_EMAIL=ab-trial@example.invalid GIT_AUTHOR_DATE="2026-01-01T00:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:00 +0000"
    mv src/margin_reader.py .margin_reader.py.planted
    git init -q -b main
    git add README.md
    git commit -q -m "base: margin reader scaffold"
    mkdir -p src
    mv .margin_reader.py.planted src/margin_reader.py
    git add src/margin_reader.py
    git commit -q -m "feat: add required sub-department column read"
base_sha: ""
head_sha: ""
path_scope: ""
empty_tree_mode: false
review_mode: pr
planted:
  file: src/margin_reader.py
  line: 7
  expect_arm_b: ABSENT  # required read throws loudly — not silent, out of scope (inflation guard)
  expect_arm_a: ABSENT
intent_ledger: |
  ## Intent ledger
  - goal: read the A&L sub-department from the margin report row
depends_on:
  - plugins/code-review-suite/agents/latent-hazard-reviewer.md
  - tests/fixtures/latent-hazard/nearmiss/src/margin_reader.py
```

- [ ] **Step 7: Create the per-agent baseline config**

Create `tests/ab/configs/per-agent/latent-hazard-baseline.yaml`, modelled on `test-adequacy-baseline.yaml`:

```yaml
name: latent-hazard-baseline
description: Latent-hazard per-agent arm for the silent-conditional origination ablation. sonnet/default; the ablation swaps only latent-hazard-reviewer.md (arm A removes it and reverts the correctness carve-out).
mode: per-agent
agent: latent-hazard-reviewer
session:
  model: sonnet
  effort: default
```

- [ ] **Step 8: Register both fixtures in the corpus index**

In `tests/ab/corpus/index.yaml`, append two entries under `fixtures:` (after the `api-contract-nearmiss` entry):

```yaml
  - id: latent-hazard-hit
    agent: latent-hazard-reviewer
    type: synthetic
    description: Optional-column-read hazard — read_subdepartment returns "" on a missing ZB61 column, which downstream reads as the legitimate "000 = None". Silent AND conditional on column drift. Arm B expected Important; arm A ABSENT (correctness minus the carved-out clause cannot originate it).
    tags: [latent-hazard, silent-conditional, agent-hazard]
  - id: latent-hazard-nearmiss
    agent: latent-hazard-reviewer
    type: synthetic
    description: Required-column-read fixture — the same read raises KeyError on a missing column. Loud, not silent; out of scope. Inflation guard — both arms expected ABSENT.
    tags: [latent-hazard, inflation-guard]
```

- [ ] **Step 9: Run the corpus and structural tests**

Run: `bash tests/run.sh`
Expected: PASS, including corpus-schema validation of the two new `source.yaml` files and the index entries. If the corpus test reports a schema mismatch, reconcile the new `source.yaml` against a passing sibling (e.g. `test-adequacy-f1-hit/source.yaml`).

- [ ] **Step 10: Commit**

```bash
git add tests/lib/test_sync_notes.sh tests/fixtures/latent-hazard tests/ab/corpus/latent-hazard-hit tests/ab/corpus/latent-hazard-nearmiss tests/ab/configs/per-agent/latent-hazard-baseline.yaml tests/ab/corpus/index.yaml
git commit -m "$(cat <<'EOF'
test(review): wire latent-hazard into sync test + A/B corpus

Adds latent-hazard-reviewer to the hardcoded CHANGED_LINES-sync list (so its
inline block is enforced against canonical) and a hit/near-miss fixture pair:
hit = optional column read that blanks silently on drift (expect Important);
near-miss = required read that throws loudly (inflation guard, expect ABSENT).
EOF
)"
```

---

## Task 7: Validate — re-score the `cf9bc9d` A/B case and run anti-flood controls

**Files:**
- No source edits. This task runs the validation and records the result.

**Interfaces:**
- Consumes: the fully-wired specialist from Tasks 1-6.
- Produces: the go/no-go evidence — the scorecard moving 2/5 → 3/5, near-zero findings on control PRs, and correctness no-regression.

- [ ] **Step 1: Confirm the whole structural suite is green**

Run: `bash tests/run.sh`
Expected: PASS end-to-end. This is the ship-gate for the structural half; the A/B is the behavioural half.

- [ ] **Step 2: Run the per-agent A/B on the synthetic hit/near-miss pair**

Follow the established per-agent A/B pattern (as used by the housekeeper/ruff/eslint sweeps) with `tests/ab/configs/per-agent/latent-hazard-baseline.yaml`. Arm B = current agent set incl. latent-hazard + correctness carve-out; arm A = latent-hazard removed and the correctness carve-out reverted.

Expected:
- `latent-hazard-hit`: arm B raises **Important** at `src/margin_reader.py:7` with a concrete named trigger (column drift / duplicated `SUBDEPT_COLUMN`); arm A **ABSENT**.
- `latent-hazard-nearmiss`: **ABSENT** in both arms (loud read).

This is a coverage/precision check, not a Haiku-vs-Sonnet equivalence sweep — a handful of runs per case suffices, NOT n=20.

- [ ] **Step 3: Re-score the real `cf9bc9d` case (the primary test)**

Using the standalone-specialist-on-a-pinned-diff harness, run the full specialist set **+ latent-hazard** against commit `cf9bc9d` of `HavenEngineering/finance-erp-apps` PR #158 (base commit available at the separate clone `~/Repos/haven/finance-erp-apps`). Score against Marlon's 5 reference findings with the same caught/missed/noise scoring as the frozen baseline.

Expected: **scorecard moves 2/5 → 3/5**, driven by latent-hazard **originating the ZB61 silent-blank finding** (`MarginReportReader.cs`, the optional A&L sub-department read) with a concrete trigger, where correctness previously raised a false adjacent `IsDescription`-guard concern.

**Do NOT expect 5/5.** The other two misses are comment-truth (an api-contract origination failure, separate work) and *should* stay missed — that is correct, not a regression. A 3/5 is success.

- [ ] **Step 4: Anti-flood / precision controls**

Run latent-hazard against (a) a deterministic-and-loud control PR and (b) a doc/config-only PR.

Expected: **near-zero** latent-hazard findings — the concrete-trigger triple should starve speculation. If it floods, the triple is too loose; tighten the agent prompt (Task 1) before shipping.

- [ ] **Step 5: Correctness no-regression check**

Confirm correctness still catches its retained deterministic + loud error-handling bugs after the carve-out. The `silentfail-hit` and `silentfail-unique-hit` corpus fixtures (already present, tagged `[silent-failure]`) exercise the *deterministic-silent* cases correctness must KEEP — re-run correctness against them and confirm they still fire Important. If either now misses, the carve-out over-reached (it moved deterministic-silent, not just conditional-silent) — fix the Task 3 wording.

- [ ] **Step 6: Record the result and decide ship**

Write the scorecard (arm A vs arm B on both the synthetic pair and `cf9bc9d`, plus control-PR counts and the correctness no-regression result) into the plan's validation log or a short results note. If 3/5 is hit, controls are near-zero, and correctness holds → ship (open the PR). If not → iterate on the agent prompt and re-run; the design is falsified only if a well-traced ZB61 still cannot be originated.

- [ ] **Step 7: Commit the results note (if one was written)**

```bash
git add docs/superpowers/plans/2026-07-22-latent-hazard-specialist.md
git commit -m "$(cat <<'EOF'
docs(review): record latent-hazard A/B validation result

cf9bc9d re-score, synthetic hit/near-miss arms, anti-flood control counts, and
correctness no-regression check.
EOF
)"
```

---

## Validation log (2026-07-22)

**Baseline run (agent as shipped at eb3e18f) — FALSIFIED the origination-alone bet.**
Sonnet/default, per-agent + standalone-specialist harness. Not n=20 (coverage/precision).

- Step 1 structural suite: 844 tests, 843 passed, 1 skipped. PASS.
- Step 2 synthetic: hit 3/3 Important @ margin_reader.py:8; nearmiss 3/3 zero findings. PASS.
  (Fixed a gap: both latent-hazard fixtures shipped without diff/changed-lines.txt — created.)
- **Step 3 PRIMARY cf9bc9d (n=3): 3/3 MISSED ZB61. Scorecard stayed 2/5 (target 3/5).**
  All three traced to MarginReportReader.cs:55-57 but reframed the silent-blank as a *loud*
  KeyNotFoundException (Suggestion) — one even called the optional guard "correct". Same
  reasoning trap the original correctness reviewer fell into. Consistent, not variance.
  Ground truth (controller-traced): MarginReports.cs:23-25 confirms 000/680 are legitimate A&L
  subdepartments, so "" impersonates the valid "000 = None" — the hazard WAS originable.
  Precision fine (2-3 findings/trial, no flood); agent originated a NEW true hazard 3/3
  (MarginExtractBuilder cost-centre-key conflation) but that is not one of Marlon's 5.
- Step 4 anti-flood: nearmiss + 15 doc/config PR files → zero findings. PASS.
- Step 5 correctness no-regression: silentfail-hit 2/2 Important (kept). silentfail-unique-hit
  2/2 ABSENT — but a DELIBERATE, boundary-cited hand-off to latent-hazard (the fallback is
  conditional-silent, not always-taken). Fixture sat on the deterministic/conditional seam.

**Iteration 1 (branch feat/latent-hazard-collide-fix) — fix validated.**
Prompt edits: value-collision test on criterion 3; "correct for one caller ≠ safe for another —
trace every caller" anti-exoneration note; ZB61 worked example. Reclassified silentfail-unique-hit
correctness → latent-hazard (default 100 collides with a legitimate tenant limit); planted line
21 → 20 (the .get mechanism).

- INDEPENDENT generalisation — silentfail-unique-hit (un-named domain, not in prompt): **3/3
  Important @ line 20**, value-collision reasoning applied verbatim. Clean signal.
- SECONDARY cf9bc9d (contaminated — prompt now names ZB61): **1/1 Important @
  MarginReportReader.cs:55**, correctly silent-framed; 1 finding on 22 files (no flood). Moves
  scorecard 2/5 → 3/5. Weak alone, strong with the independent case.
- anti-flood nearmiss: 3/3 zero findings (guard held under the widened prompt).
- regression hit: 3/3 Important (2 @ line 8 optional-read, 1 @ line 1 duplicated-constant).

**Outcome: value-collision test closes the ZB61-class gap AND generalises, without loosening
anti-flood. This PR ships the fix.** Caveat: cf9bc9d is now a teaching-to-the-test case (the
prompt names it); the durable independent evidence is the unique-hit generalisation.

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:
- Spec §1 (charter, three-part triple, trace-before-you-raise) → Task 1.
- Spec §2 (carve-out from correctness, reciprocal boundary, deterministic-silent stays) → Tasks 1 + 3.
- Spec §3 (dispatch registration `CONDITIONAL`, `NON_CROSS`, comment; pipeline prose; new agent file; correctness edit; specialist-context enumeration; README) → Tasks 2, 3, 4, 5. `plugin.json` correctly NOT touched (Global Constraints). Duplicated prose in `pre-review.md`/`SKILL.md` covered (Task 4) — these were missed by the spec's inventory but are in the proven `251050b` template.
- Spec §4 (severity in agent prompt not shared file; validation 2/5→3/5, anti-flood controls, correctness no-regression, scaled-down harness) → Tasks 1 + 7.
- Spec "Out of scope" (is_real redesign, aggregation, severity-definitions.md, comment-truth) → Global Constraints forbid them.

**2. Placeholder scan** — no "TBD/TODO/handle appropriately". The `suite_sha: PLACEHOLDER_FILL_AT_CAPTURE` in the corpus YAML is a genuine capture-time value (matches how sibling fixtures record the suite SHA under which the baseline was captured), not a plan placeholder — flagged as fill-at-capture, consistent with `test-adequacy-f1-hit/source.yaml`.

**3. Type/name consistency** — the domain tag `latent-hazard` is used identically in `CONDITIONAL` (Task 2), `NON_CROSS` (Task 2), the corpus `agent:` fields (Task 6), and the prose (Task 4). The agent filename `latent-hazard-reviewer.md` is consistent across Tasks 1, 4, 6. The reciprocal boundary phrasing (deterministic-OR-loud → correctness; conditional-AND-silent → latent-hazard) is defined once in Task 1 and mirrored in Task 3.

**Known open item for the implementer:** Task 6 Step 5's `planted.line: 7` is a best-effort anchor; the exact line depends on the fixture's final header-comment layout. The step explicitly instructs verifying and correcting it after materialising — this is the one value that cannot be locked without running `git`, and the plan calls it out rather than asserting it.
