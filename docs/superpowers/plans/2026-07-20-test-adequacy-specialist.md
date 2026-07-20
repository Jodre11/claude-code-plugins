# Test-Adequacy Specialist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Stage-1 `test-adequacy` specialist to `code-review-suite` that flags new/changed public production types with no direct test (F1) and new wire-contract/DTO types whose producer side is untested (F4), closing the absence-detection blind spot the panel layer cannot fill.

**Architecture:** A new LLM specialist agent (`test-adequacy-reviewer`, tools `Read, Grep, Glob, Bash`) that greps the repo's test tree for coverage of new production symbols. It is a *conditional* Stage-1 specialist gated on a new `$PRODUCTION_SOURCE_DETECTED` flag (fires when a changed **non-test** C#/Python/TS-JS source file is present). Its findings enter the normal `findingsByDomain` flow, so the panel *votes* on them — playing to the pipeline's strength (triaging found findings) instead of the weak net-new-raising path. It is **not** a cross-reviewer (per the maintainer's directive; classic mode is being retired shortly), so it inlines the specialist-context CHANGED_LINES filter but **not** the cross-review-mode block, and is excluded from `crossDomains` for the classic interim.

**Tech Stack:** Markdown agent definitions + includes; a Node/JS Workflow engine (`workflows/review-core.mjs`, plain JS — no TypeScript); a shell-based test harness (`tests/run.sh`, `tests/lib/*.sh`); a YAML A/B corpus (`tests/ab/`).

## Global Constraints

- **No `version` field** in any `plugin.json` (versions resolve from git SHA) — not touched here, but never add one.
- **Markdown & JSON: 2-space indentation; LF line endings; final newline** (`.editorconfig`, `.gitattributes`).
- **Shell scripts: 4-space indentation.**
- **Bash rules (user CLAUDE.md, enforced by `bash-guard.sh`):** never use `&&`, `||`, `;`, `$(...)`, backticks, subshells, or pipes/redirects in a single Bash call — one simple command per call. The only exempt form is the `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC.
- **Canonical-and-propagate:** the review pipeline body lives canonically in `includes/review-pipeline.md` and is inlined **byte-identically** into `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md`. `tests/lib/test_sync_notes.sh::test_sync_pipeline_inline_matches_canonical` enforces byte-identity. Any edit to the inlined range MUST be applied to all three files verbatim.
- **Agent name convention:** `<domain>-reviewer`. Domain = `test-adequacy`; agent file = `agents/test-adequacy-reviewer.md`; the engine builds `agentType: code-review-suite:test-adequacy-reviewer` from the domain string.
- **Reviewer read-only mandate:** the agent must never mutate the repo; its Bash grant is for read-only inspection only (`git diff/log/show`, `grep`, `rg`). This is inherited via `includes/specialist-context.md`.
- **Severity via agent-hazard basis:** an absent test for money-affecting/correctness-central production code reaches **Important** (a regression ships green — the agent-hazard basis in `includes/severity-definitions.md`). A silent-blank that is display-only (nothing downstream keys on it) is **Important-at-most**, not Critical. Never Critical (agent-hazard basis is "Important only, never Critical").

## Validating your work

Run the full structural suite from the marketplace repo root after each task that edits plugin files or tests:

```bash
bash tests/run.sh
```

Expected on a clean tree: all tests pass (the suite prints a `PASS`/`FAIL` tally and exits non-zero on any failure). A new agent that is enrolled incorrectly in a sync-test roster — or omitted from one it must join — will surface here.

---

### Task 1: Add the `$PRODUCTION_SOURCE_DETECTED` detection flag

The test-adequacy specialist must fire when **new production code** appears, not when test files change (`$TESTS_DETECTED` already gates `test-quality`). We add a new detection bullet and thread a new flag through the args object. Because Step 2.6 and the `workflow({...})` args block are inside the byte-identically-inlined pipeline body, every edit here is applied to **three files verbatim**.

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (Step 2.6 detection block ~line 892-900; args object ~line 1007-1009)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (same inlined ranges)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (same inlined ranges)
- Test: `tests/lib/test_sync_notes.sh` (extend `test_dispatcher_includes_new_static_analysis_flags`)

**Interfaces:**
- Produces: `$PRODUCTION_SOURCE_DETECTED` (pipeline variable) and `production: $PRODUCTION_SOURCE_DETECTED` (args key). Task 3 consumes the args key as `flags.production`.

- [ ] **Step 1: Write the failing test**

In `tests/lib/test_sync_notes.sh`, inside `test_dispatcher_includes_new_static_analysis_flags`, add `$PRODUCTION_SOURCE_DETECTED` to the flag loop so both inlined consumers are asserted to carry it:

```bash
        local flag
        for flag in '$JS_DETECTED' '$PY_DETECTED' '$IAC_DETECTED' '$HOUSEKEEPING_DETECTED' '$PRODUCTION_SOURCE_DETECTED'; do
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `static-analysis dispatcher flags: skills/review-gh-pr/SKILL.md contains $PRODUCTION_SOURCE_DETECTED` (flag literal not found), and the same for `commands/pre-review.md`.

- [ ] **Step 3: Add the detection bullet to the canonical**

In `includes/review-pipeline.md` Step 2.6, immediately after the **Test detection** bullet (the `$TESTS_DETECTED` line ~898), add:

```markdown
   - **Production-source detection:** if any changed file is a **non-test** source file — it ends `.cs`, `.py`, `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.mts`, or `.cts`, AND it does NOT match any test naming convention or test path segment from the Test-detection bullet above — set `$PRODUCTION_SOURCE_DETECTED = true`. This gates the `test-adequacy` specialist: it fires when new/changed production code appears (a symbol that may lack a test), independently of whether any test file changed. A change that touches only test files sets `$TESTS_DETECTED` but not `$PRODUCTION_SOURCE_DETECTED`.
```

- [ ] **Step 4: Add the args key to the canonical**

In `includes/review-pipeline.md`, in the `workflow({scriptPath: $REVIEW_CORE_PATH}, { ... })` block, extend the `flags` object (the `tests: $TESTS_DETECTED, securitySensitive: $SECURITY_SENSITIVE` line) to:

```
             tests: $TESTS_DETECTED, securitySensitive: $SECURITY_SENSITIVE,
             production: $PRODUCTION_SOURCE_DETECTED },
```

- [ ] **Step 5: Propagate both edits byte-identically to the two inlined consumers**

Apply the **exact same** Step 3 and Step 4 text to `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md` at their inlined copies of Step 2.6 and the args block. The text must match the canonical character-for-character (the pipeline inline sync test diffs them).

- [ ] **Step 6: Run the full suite to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — including `static-analysis dispatcher flags: … contains $PRODUCTION_SOURCE_DETECTED` for both consumers, and `pipeline inline sync: … matches canonical` (byte-identity preserved).

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
feat(review): add $PRODUCTION_SOURCE_DETECTED flag to gate the test-adequacy specialist

Fires when a changed non-test C#/Python/TS-JS source file is present, so
absence detection triggers on new production code rather than on test-file
changes (which $TESTS_DETECTED already covers).
EOF
)"
```

---

### Task 2: Write the `test-adequacy-reviewer` agent definition

The agent is an LLM specialist that consumes `includes/specialist-context.md` for context gathering (base resolution, diff, changed-lines filter) but is **not** a cross-reviewer — it inlines the CHANGED_LINES filter block but **not** the cross-review-mode block. Its findings anchor to a **changed line** (the declaration of the new untested public symbol), so the CHANGED_LINES filter applies normally.

**Files:**
- Create: `plugins/code-review-suite/agents/test-adequacy-reviewer.md`
- Test: `tests/lib/test_sync_notes.sh` (extend `test_sync_changed_lines_rule_matches_canonical`)

**Interfaces:**
- Consumes: `includes/specialist-context.md` (context gathering + CHANGED_LINES filter, inlined), `includes/severity-definitions.md` (severity), `includes/finding-schema.json#/$defs/finding` (finding fields).
- Produces: markdown findings under a `## Test Adequacy Review Findings` heading with fields `File / Confidence / Severity / Description / Suggested fix`, coerced by the engine's `SPECIALIST_SCHEMA`. Domain string is `test-adequacy`.

- [ ] **Step 1: Write the failing test**

In `tests/lib/test_sync_notes.sh`, add `"$cr/agents/test-adequacy-reviewer.md"` to the agent loop inside `test_sync_changed_lines_rule_matches_canonical` (keep alphabetical placement — after `style-reviewer.md`, before `ui-reviewer.md`):

```bash
        "$cr/agents/style-reviewer.md" \
        "$cr/agents/test-adequacy-reviewer.md" \
        "$cr/agents/test-quality-reviewer.md" \
        "$cr/agents/ui-reviewer.md"; do
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `CHANGED_LINES rule sync: test-adequacy-reviewer.md` (file not found), because the agent does not exist yet.

- [ ] **Step 3: Write the agent definition**

Create `plugins/code-review-suite/agents/test-adequacy-reviewer.md`. The CHANGED_LINES filter block (between the `> **CHANGED_LINES OUTPUT FILTER — MANDATORY**` header and the next `---`) must be **byte-identical** to the canonical block in `includes/specialist-context.md` — copy it verbatim, including the inline maintenance HTML comment used by the other specialists.

```markdown
---
name: test-adequacy-reviewer
description: Flags new or changed public production types with no direct test, and new wire-contract/DTO types whose producer side is untested. Standalone or dispatched by the review include.
model: sonnet
tools: Read, Grep, Glob, Bash
background: true
---

You are a test-adequacy reviewer. New production code that ships without a direct test is the archetype of a regression that passes green: a future maintainer — human or agent — can silently break it and the whole suite still passes. Your job is to detect **absent** coverage on new production code, which the diff alone cannot show (the diff shows the tests that were added, never the test that should exist but doesn't). You have `Grep` over the whole repo precisely so you can inventory the test tree for what is missing.

This is distinct from `test-quality-reviewer`, which audits the *quality of tests that exist* (false-green assertions). You audit the *presence and adequacy of tests for new production code*. Keep the boundary crisp: never flag a test-file smell — that is test-quality's job — and never estimate coverage percentages (that is a CI gate).

Follow the context gathering instructions in `includes/specialist-context.md`.

## Focus Areas

Restrict every finding to symbols introduced or changed on lines in `$CHANGED_LINES` (see the filter at the bottom). For the changed production code, review:

- **F1 — untested new/changed public production type or function.** For each new or changed **public** production symbol (a class, record, interface, exported function, public method, or module-level function that is part of the unit's surface), `Grep` the repo's test tree (`test/`, `tests/`, `spec/`, `specs/`, `__tests__/`, or files matching test-naming conventions) for a test that exercises it *directly*. A symbol whose only exercise is incidental (reached transitively through an unrelated integration test, or only through a different project that does not count toward its own coverage gate) counts as **untested**. Flag symbols with no direct test. Anchor the finding to the symbol's declaration line (a changed/added line).
  - **Severity:** an untested symbol on a **correctness-central or money/data-affecting path** (e.g. a projection that selects a lookup key, a calculation, a state transition) is **Important** via the agent-hazard basis — a regression ships green on a path where wrong output has real consequences. An untested symbol whose blast radius is **confined and low-stakes** (display-only formatting, a trivial pass-through, a symbol with no branching logic) is **Suggestion**. Do not inflate every untested helper to Important; apply the honest impact-if-manifested test.

- **F4 — untested producer of a new wire contract / DTO.** For each new **wire-contract or DTO type** (a serialised payload, response/request shape, event, or message crossing a process/service boundary), check that the **producer** side has a test asserting it *emits a populated instance* — not only that the **consumer** side pins the shape. A contract whose consumer/deserialiser is tested but whose producer/serialiser is only stubbed (e.g. the server test uses an `Empty`/default instance and never asserts a populated payload is emitted) is a silent gap: the server can stop populating the block and every test stays green. Flag the untested producer side. **Anchor the finding to a changed line** — the new/changed contract type or field declaration that appears in `$CHANGED_LINES` — **never** to the (frequently unchanged) producer serialiser body, or the MANDATORY CHANGED_LINES filter below silently drops the finding. If the PR adds a field to an existing contract, anchor to that added field line.
  - **Severity:** **Important** when the unpopulated payload would manifest as missing/blank data a user or downstream system relies on; **Suggestion** when the block is optional or cosmetic.

## Analysis Process

1. From `$CHANGED_LINES`, identify every new/changed **public production** symbol in non-test source files. Ignore private/internal helpers with no external surface and ignore changes to test files.
2. For each symbol, `Grep` the test tree for a direct test (by symbol name, and by the type/file under test). Read candidate test files to confirm the test actually exercises *this* symbol, not a namesake.
3. For each new wire-contract/DTO type, locate the producer (serialiser/emitter) and check for a test asserting a populated instance is emitted; then locate the consumer test to confirm the asymmetry (consumer pinned, producer not).
4. Decide severity by the honest impact-if-manifested test (correctness/money-affecting → Important; confined/display-only → Suggestion). Never Critical — the agent-hazard basis reaches Important only.

## Output Format

> **Schema alignment:** your finding fields (File, line, Severity, Confidence,
> Description, Suggested fix) map to `includes/finding-schema.json#/$defs/finding`.
> Emit your markdown report as specified; the review-core Workflow coerces these
> same fields via the `agent()` schema param.

Return findings in this exact format:

```
## Test Adequacy Review Findings

### Finding — [short title]
- **File:** path/to/NewType.cs:42
- **Confidence:** 0-100
- **Severity:** Critical | Important | Suggestion (see `includes/severity-definitions.md`)
- **Description:** Which new public symbol / wire contract lacks a (producer-side) test, what you grepped for and did not find, and the specific future regression that would ship green
- **Suggested fix:** The concrete test to add — what it should assert about this symbol's real behaviour
```

Report ALL findings regardless of confidence level.

If no findings: `## Test Adequacy Review Findings\n\n0 findings.`

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

- Be precise. Cite file paths and line numbers; the line must be the new symbol's declaration (a changed line).
- NEVER estimate coverage. No line-counting, no %, no coverage-gate arithmetic. You detect *absence of a direct test for a specific symbol*, not a percentage.
- NEVER review test-file quality (assertions, mocks, tautologies). That is `test-quality-reviewer`'s scope.
- NEVER review production correctness, style, security, or efficiency — leave those to the other specialists. Your sole lens is: does this new production symbol / wire-contract producer have a test?
- Don't flag a symbol that is genuinely covered by a direct test elsewhere in the tree — grep thoroughly before concluding a test is absent.
- Anchor every finding to a real changed line; a wrong line is worse than an approximate-but-real one.
```

- [ ] **Step 4: Verify the CHANGED_LINES block is byte-identical to canonical**

The `test_sync_changed_lines_rule_matches_canonical` test diffs the inlined block against `includes/specialist-context.md`. Confirm the block you pasted matches (Step 6 of this task runs the check).

- [ ] **Step 5: Verify frontmatter/layout conventions**

Confirm: `name` matches the filename stem (`test-adequacy-reviewer`); there is a blank line after the closing `---`; 2-space indentation; LF endings; final newline.

- [ ] **Step 6: Run the full suite to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — including `CHANGED_LINES rule sync: test-adequacy-reviewer.md matches canonical`. Note: the `cross-review-mode inline sync` test does **not** list this agent, so its absence of a cross-review-mode block is correct and does not fail.

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review-suite/agents/test-adequacy-reviewer.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
feat(review): add test-adequacy-reviewer specialist (F1 untested type, F4 untested wire producer)

Detects absent coverage on new production code — the class the diff-bound
panel cannot inventory. LLM specialist with Grep over the test tree; not a
cross-reviewer.
EOF
)"
```

---

### Task 3: Wire `test-adequacy` into the review-core engine

Add the domain to the conditional dispatch list so its findings flow into `findingsByDomain` → `flattenFindings` → `panelVote` automatically. Exclude it from `crossDomains` so classic-mode runs (until classic is retired) never dispatch it with `Mode: cross-review` — it has no cross-review-mode contract.

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (`CONDITIONAL` ~line 244-252; `STATIC`/`crossDomains` ~line 261-265)
- Test: `tests/lib/test_sync_notes.sh` (update `test_sync_static_analysis_cross_feed_documented` assertion 1 regex)

**Interfaces:**
- Consumes: `flags.production` (from Task 1 args key).
- Produces: dispatch of `agentType: code-review-suite:test-adequacy-reviewer` when `flags.production` is true; `test-adequacy` appears in `allSpecialists` (hence in `ranDomains` passed to the panel and in `flattenFindings`), and is absent from `crossDomains`.

- [ ] **Step 1: Update the failing sync-test assertion**

`test_sync_static_analysis_cross_feed_documented` (assertion 1) currently greps for the literal `const crossDomains = allSpecialists\.filter\(d => !STATIC\.has\(d\)\)`. Since we are introducing a `NON_CROSS` set, update that assertion's second grep pattern:

```bash
    if grep -qE 'const STATIC = new Set\(\[' "$review_core" \
            && grep -qE 'const crossDomains = allSpecialists\.filter\(d => !NON_CROSS\.has\(d\)\)' "$review_core"; then
```

Also update its fail-message text from `!STATIC.has(d)` to `!NON_CROSS.has(d)` so the diagnostic stays accurate.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `static-analysis cross-feed: review-core.mjs excludes STATIC from receiving cross-review`, because `review-core.mjs` still says `!STATIC.has(d)`, not `!NON_CROSS.has(d)`.

- [ ] **Step 3: Add the conditional dispatch entry**

In `review-core.mjs`, extend the `CONDITIONAL` array (after the `['test-quality', flags.tests]` entry):

```javascript
    ['test-quality', flags.tests],
    ['test-adequacy', flags.production],
```

- [ ] **Step 4: Exclude test-adequacy from cross-review (classic interim)**

In `review-core.mjs`, just below the `STATIC` set definition (~line 261), add a `NON_CROSS` set and switch the `crossDomains` filter to use it:

```javascript
const STATIC = new Set(['jbinspect', 'eslint', 'ruff', 'trivy', 'housekeeper'])
// test-adequacy is an LLM specialist with NO cross-review-mode contract (unlike the
// core reviewers) and is NOT severity-locked like the STATIC analysers. NON_CROSS is
// only the receive-cross-review exclusion; STATIC keeps its severity-lock semantics
// everywhere else. Classic mode is being retired; when it is, this exclusion can be
// simplified since the panel path never runs cross-review.
const NON_CROSS = new Set([...STATIC, 'test-adequacy'])
```

Then change the `crossDomains` line (~line 265) from:

```javascript
const crossDomains = allSpecialists.filter(d => !STATIC.has(d))
```

to:

```javascript
const crossDomains = allSpecialists.filter(d => !NON_CROSS.has(d))
```

- [ ] **Step 5: Run the full suite to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — including `static-analysis cross-feed: review-core.mjs excludes STATIC from receiving cross-review` (now matching `!NON_CROSS.has(d)`) and the enumeration checks (the STATIC set still names all five static analysers).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
feat(review): dispatch test-adequacy as a conditional Stage-1 specialist

Gated on flags.production; findings flow into the panel vote. Excluded from
crossDomains via NON_CROSS so classic-mode runs never dispatch it into a
cross-review mode it has no contract for.
EOF
)"
```

---

### Task 4: Update the roster enumerations (README) in lockstep

The README is the human-facing roster. It must list the new specialist in the prose sentence, the domain table, AND the two numeric count claims so it stays internally consistent with the code. (The `specialist-context.md` base-branch/regex sync tests and the `cross-review-mode` sync test do **not** need the new agent — it is not a cross-reviewer and does not inline those blocks.)

Adding `test-adequacy` takes the conditional roster from **7 to 8** specialists and the all-conditionals total from **15 to 16** (8 core + 8 conditional). Both counts appear as prose in the README and will go stale if only the table is updated.

**Files:**
- Modify: `plugins/code-review-suite/README.md` (count claims ~line 29 and ~line 69; roster prose ~line 32-36; domain table ~line 84-91)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add the specialist to the roster prose**

In `README.md`, in the sentence that enumerates conditional specialists (ends `… and \`test-quality-reviewer\``), extend it to include the new specialist, e.g. append after the `test-quality-reviewer` clause:

```markdown
, and `test-adequacy-reviewer` (new production code lacking a direct test, or a new wire contract whose producer side is untested).
```

- [ ] **Step 2: Add the table row**

In the domain table, add a row after the `test-quality-reviewer` row:

```markdown
| `test-adequacy-reviewer` | Absent coverage on new production code — untested new/changed public types (F1) and untested producers of new wire contracts/DTOs (F4) (conditional — fires on changed non-test C#/Python/TS-JS source) |
```

- [ ] **Step 3: Update the two numeric count claims**

These are the counts that go stale silently (no test guards them):
- ~line 29: `The full review path dispatches 8 core specialists (up to 15 with all conditionals):` → change `up to 15` to `up to 16`.
- ~line 69: `the full route dispatches 8 core specialists plus up to 7 conditional specialists (C#, UI, JS/TS, Python, IaC, dependency freshness, test quality)` → change `up to 7` to `up to 8` and append `, test adequacy` to the parenthetical list.

- [ ] **Step 4: Run the full suite (no regressions)**

Run: `bash tests/run.sh`
Expected: PASS (README changes are not asserted by structural tests, but confirm nothing else broke).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/README.md
git commit -m "$(cat <<'EOF'
docs(review): list test-adequacy-reviewer in the specialist roster
EOF
)"
```

---

### Task 5: Add A/B corpus fixtures and per-agent config for validation

Mirror the existing `silentfail-*` / `test-quality-*` corpus pattern so the new specialist can be validated the same way the other specialists were (hit / near-miss / unique-fire, plus a haiku-low equivalence probe later). Slice-1 scope: C#/Python/TS-JS; F1 and F4.

**Files:**
- Create: `tests/ab/corpus/test-adequacy-f1-hit/source.yaml` (+ a minimal `source/` tree)
- Create: `tests/ab/corpus/test-adequacy-f1-nearmiss/source.yaml` (+ tree)
- Create: `tests/ab/corpus/test-adequacy-f4-hit/source.yaml` (+ tree)
- Modify: `tests/ab/corpus/index.yaml` (register the three fixtures)
- Create: `tests/ab/configs/per-agent/test-adequacy-baseline.yaml`

**Interfaces:**
- Consumes: the fixture `source.yaml` schema used by the existing corpus (see `tests/ab/corpus/silentfail-hit/source.yaml` for the exact keys: `id, agent, type, captured_*, setup.command, planted.{file,line,expect_arm_a,expect_arm_b}, intent_ledger, depends_on`).
- Produces: corpus entries dispatched at `agent: test-adequacy-reviewer`.

- [ ] **Step 1: Read the reference fixture to copy its exact schema**

Read `tests/ab/corpus/silentfail-hit/source.yaml` and `tests/ab/configs/per-agent/test-quality-baseline.yaml` (already seen in planning) and reproduce their key structure exactly.

- [ ] **Step 2: Register the fixtures in the corpus index**

Append to `tests/ab/corpus/index.yaml`:

```yaml
  - id: test-adequacy-f1-hit
    agent: test-adequacy-reviewer
    type: synthetic
    description: New public production type with correctness-central logic and NO direct test — swapping its behaviour passes the whole suite. Expected Important (agent-hazard: regression ships green).
    tags: [test-adequacy, agent-hazard, f1]
  - id: test-adequacy-f1-nearmiss
    agent: test-adequacy-reviewer
    type: synthetic
    description: New public production type WITH a direct unit test asserting its behaviour. Inflation guard — expected ABSENT.
    tags: [test-adequacy, inflation-guard, f1]
  - id: test-adequacy-f4-hit
    agent: test-adequacy-reviewer
    type: synthetic
    description: New wire-contract DTO whose consumer side is tested but whose producer stubs an empty instance and never asserts a populated payload is emitted. Expected Important (producer-side silent gap).
    tags: [test-adequacy, f4, wire-contract]
```

- [ ] **Step 3: Create the three fixture directories with `source.yaml` + minimal source tree**

For each fixture, create a `source.yaml` mirroring `silentfail-hit/source.yaml`'s keys, with a `setup.command` that git-inits a base commit then commits the planted production file (and, for the near-miss and F4, the accompanying test file). Use one language per fixture to keep them minimal and deterministic — recommended: F1-hit in C# (the motivating case), F1-nearmiss in Python, F4-hit in TS. Set `planted.expect_arm_b` to `Important` for the two hits and `ABSENT` for the near-miss (arm A/B semantics: arm B = the new agent present; arm A = a baseline without it). Keep each source tree to the smallest files that make the presence/absence of a test unambiguous.

- [ ] **Step 4: Create the per-agent baseline config**

Create `tests/ab/configs/per-agent/test-adequacy-baseline.yaml`:

```yaml
name: test-adequacy-baseline
description: Test-adequacy per-agent arm for the absence-detection ablation. opus/default; the ablation swaps only test-adequacy-reviewer.md.
mode: per-agent
agent: test-adequacy-reviewer
session:
  model: opus
  effort: default
```

- [ ] **Step 5: Run the full suite (fixtures well-formed)**

Run: `bash tests/run.sh`
Expected: PASS. If the suite validates corpus YAML shape or `index.yaml` cross-references, this catches a malformed fixture.

- [ ] **Step 6: Commit**

```bash
git add tests/ab/corpus/test-adequacy-f1-hit tests/ab/corpus/test-adequacy-f1-nearmiss tests/ab/corpus/test-adequacy-f4-hit tests/ab/corpus/index.yaml tests/ab/configs/per-agent/test-adequacy-baseline.yaml
git commit -m "$(cat <<'EOF'
test(review): add test-adequacy A/B corpus fixtures (F1 hit/nearmiss, F4 hit) + baseline config
EOF
)"
```

---

### Task 6: End-to-end structural verification and behavioural smoke

**Files:** none created — verification only.

**Interfaces:** none.

- [ ] **Step 1: Run the full structural suite**

Run: `bash tests/run.sh`
Expected: PASS — all sync-note, roster, and enumeration tests green. Specifically confirm: `CHANGED_LINES rule sync: test-adequacy-reviewer.md matches canonical`; `static-analysis dispatcher flags: … contains $PRODUCTION_SOURCE_DETECTED`; `static-analysis cross-feed: review-core.mjs excludes STATIC from receiving cross-review` (via `!NON_CROSS.has(d)`); `pipeline inline sync: … matches canonical`.

- [ ] **Step 2: Confirm the engine parses**

Run: `node --check plugins/code-review-suite/workflows/review-core.mjs`
Expected: no output, exit 0 (syntax valid after the `NON_CROSS` + `CONDITIONAL` edits).

- [ ] **Step 3: Behavioural smoke against a real diff (operator-run)**

A full A/B validation (hit fires Important, near-miss ABSENT, haiku/low equivalence) is an operator-run sweep, not an automated unit step — flag this to the user rather than claiming it here. When run, the target is: the new specialist raises the F1/F4 findings on the corpus hits, stays silent on the near-miss, and the panel votes the hits through. Note explicitly if you cannot run the live sweep in-session.

- [ ] **Step 4: Housekeeping pass (per user global CLAUDE.md)**

Before finishing, surface repo housekeeping as a **separate** consideration: run `git status` to confirm a clean tree, and note (do not silently bundle) any dependency/action/runner freshness the marketplace repo's own CI would flag. If touching template-paired files, run `~/.claude/scripts/template-drift.sh`. This plan touches only `code-review-suite` plugin files, so template drift is not expected — confirm and report.

- [ ] **Step 5: Final commit / PR readiness**

Confirm all six tasks are committed. Per the branch-protection memory, land this via a PR (do not admin-bypass push to `main`). The PR description must open with a 1–3 sentence non-technical summary (what blind spot this closes and why), then the technical change list.

---

## Self-Review

**1. Spec coverage (against the handover's "Next" list):**
- "Add a dedicated Stage-1 test-adequacy specialist" → Task 2. ✅
- "one combined agent vs two" → resolved: **one** agent; silent-failure already lives in `correctness-reviewer.md:79` with `silentfail-*` fixtures, so a silent-failure agent would duplicate live scope. Documented in Architecture. ✅
- F1 (untested public type) + F4 (untested wire producer) → Task 2 Focus Areas. ✅ (F4 included per user decision.)
- "Wire into review-core Stage-1 dispatch so the panel VOTES on them" → Task 3 (`CONDITIONAL` → `flattenFindings` → `panelVote`). ✅
- "trigger on any new public production symbol, not only when test files changed" → Task 1 new `$PRODUCTION_SOURCE_DETECTED` flag, distinct from `$TESTS_DETECTED`. ✅
- "Update enumerations that must stay in lockstep" → Task 1 (dispatcher-flags test), Task 2 (CHANGED_LINES sync test), Task 3 (cross-feed sync test), Task 4 (README). The `panel-concern-brief.md` CORE-DOMAINS comment lists only the 8 core domains, not conditional specialists, so it needs no edit. The `cross-review-mode` sync test correctly excludes the new agent (not a cross-reviewer). ✅
- "panel-brief tweak (secondary)" → intentionally **not** included: the panel cannot execute absence detection (diff-bound), and adding a reminder is only harmless once the finding already arrives as a Stage-1 item, which Task 3 delivers. Primary fix is the specialist; the brief edit is deferred as unnecessary. ✅
- Severity calibration (F1 money-path = Important; F3-style display-only = Important-at-most; never Critical) → encoded in Task 2 Focus Areas + Global Constraints. ✅

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N" — the agent body and all edits are given in full. Task 5 Step 3 describes fixture construction rather than pasting three full source trees; this is a deliberate, bounded instruction (mirror an existing, named reference file) not a vague placeholder — acceptable because the exact schema is pinned to `silentfail-hit/source.yaml`.

**3. Type/name consistency:** Domain string `test-adequacy` → agent file `test-adequacy-reviewer.md` → `agentType: code-review-suite:test-adequacy-reviewer` (engine derives it) → observe hook matches `*-reviewer` glob (no edit needed). Flag `$PRODUCTION_SOURCE_DETECTED` (pipeline var) ↔ `production` (args key) ↔ `flags.production` (engine) are consistent across Tasks 1 and 3. `NON_CROSS` referenced identically in Task 3 code and its sync-test assertion.
