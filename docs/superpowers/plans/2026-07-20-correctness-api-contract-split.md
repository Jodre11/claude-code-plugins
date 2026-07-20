# Correctness / API-Contract Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the API/contract-truth lens out of `correctness-reviewer` into a new always-on Stage-1 specialist `api-contract-reviewer`, so on code-heavy PRs the two halves run in parallel instead of one correctness agent grinding through both serially.

**Architecture:** A new LLM specialist agent (`api-contract-reviewer`, tools `Read, Grep, Glob, Bash`) carries the API-usage / hallucinated-API / wrong-signature / comment-truth lens lifted verbatim from `correctness-reviewer.md`. It is a **core (always-on)** domain — added to `review-core.mjs`'s `CORE` array alongside `correctness`, NOT flag-gated — because API/contract-truth is language-agnostic and correctness carries it on every PR today; gating it on the 3-language `$PRODUCTION_SOURCE_DETECTED` flag would silently drop it on Go/Ruby/Rust/etc PRs (a net finding loss that fails the ship-gate). It is **not** a cross-reviewer (per the maintainer's directive; classic mode is being retired), so it inlines the specialist-context CHANGED_LINES filter but **not** the cross-review-mode block, and is excluded from `crossDomains` via the `NON_CROSS` set. Its findings enter the normal `findingsByDomain` flow, so the panel votes on them.

**Tech Stack:** Markdown agent definitions + includes; a Node/JS Workflow engine (`workflows/review-core.mjs`, plain JS — no TypeScript); a shell-based test harness (`tests/run.sh`, `tests/lib/*.sh`); a YAML A/B corpus (`tests/ab/`).

## Global Constraints

- **No `version` field** in any `plugin.json` (versions resolve from git SHA) — not touched here, but never add one.
- **Markdown & JSON: 2-space indentation; LF line endings; final newline** (`.editorconfig`, `.gitattributes`).
- **Shell scripts: 4-space indentation.**
- **Bash rules (user CLAUDE.md, enforced by `bash-guard.sh`):** never use `&&`, `||`, `;`, `$(...)`, backticks, subshells, or pipes/redirects in a single Bash call — one simple command per call. The only exempt form is the `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC.
- **Agent name convention:** `<domain>-reviewer`. Domain = `api-contract`; agent file = `agents/api-contract-reviewer.md`; the engine builds `agentType: code-review-suite:api-contract-reviewer` from the domain string.
- **Reviewer read-only mandate:** the agent must never mutate the repo; its Bash grant is for read-only inspection only (`git diff/log/show`, `grep`, `rg`, `curl` for docs). Inherited via `includes/specialist-context.md`.
- **Verbatim lift, not rewrite (spec Findings-loss mitigation #1).** Move the Focus Areas byte-for-byte where possible. Prose changes around an instruction shift small-model behaviour, so only add the standalone framing the agent needs to run alone. Do NOT reword the moved lens.
- **No cross-review block.** `api-contract` is Stage-1 only. Do NOT inline the `> **MODE SWITCH — MANDATORY**` block, and do NOT enroll it in `test_sync_cross_review_mode_inline_matches_canonical`.
- **README count reconciliation (merge hazard).** Current `main` says "8 core specialists (up to 15 with all conditionals)". This plan adds one **core** specialist → **9 core**, total **up to 16**. The sibling test-adequacy plan adds one **conditional** specialist → 8 conditional, total up to 16. They edit the same README count sentences on separate branches, so **whichever PR merges second must reconcile to 9 core + 8 conditional = up to 17 total.** Each plan alone is internally correct; the conflict surfaces only at the second merge. Flag it in that PR.

## Validating your work

Run the full structural suite from the marketplace repo root after each task that edits plugin files or tests:

```bash
bash tests/run.sh
```

Expected on a clean tree: all tests pass (the suite prints a `PASS`/`FAIL` tally and exits non-zero on any failure). A new agent enrolled in the wrong sync-test roster — or omitted from one it must join — surfaces here, as does a `CORE`/concern-brief drift.

---

### Task 1: Create the `api-contract-reviewer` agent definition

The agent is an LLM specialist that consumes `includes/specialist-context.md` for context gathering (base resolution, diff, changed-lines filter) but is **not** a cross-reviewer — it inlines the CHANGED_LINES filter block but **not** the cross-review-mode block. Its findings anchor to a **changed line** (the offending call site, or the new/modified comment), so the CHANGED_LINES filter applies normally.

**Files:**
- Create: `plugins/code-review-suite/agents/api-contract-reviewer.md`
- Test: `tests/lib/test_sync_notes.sh` (extend `test_sync_changed_lines_rule_matches_canonical`)

**Interfaces:**
- Consumes: `includes/specialist-context.md` (context gathering + CHANGED_LINES filter, inlined), `includes/severity-definitions.md` (severity + agent-hazard basis), `includes/finding-schema.json#/$defs/finding` (finding fields).
- Produces: markdown findings under a `## API Contract Review Findings` heading with fields `File / Confidence / Severity / Description / Suggested fix`, coerced by the engine's `SPECIALIST_SCHEMA`. Domain string is `api-contract`.

- [ ] **Step 1: Write the failing test**

In `tests/lib/test_sync_notes.sh`, add `"$cr/agents/api-contract-reviewer.md"` to the agent loop inside `test_sync_changed_lines_rule_matches_canonical`. Place it **first** (alphabetical: `api` sorts before `archaeology`), before `archaeology-reviewer.md`:

```bash
    for agent in \
        "$cr/agents/api-contract-reviewer.md" \
        "$cr/agents/archaeology-reviewer.md" \
        "$cr/agents/code-analysis.md" \
        "$cr/agents/consistency-reviewer.md" \
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `CHANGED_LINES rule sync: api-contract-reviewer.md` (file not found), because the agent does not exist yet.

- [ ] **Step 3: Write the agent definition**

Create `plugins/code-review-suite/agents/api-contract-reviewer.md`. The Focus Areas are lifted verbatim from `correctness-reviewer.md` (the line-82 `Incorrect API usage` bullet plus the `:84-97` Hallucinated-APIs and Comment-truth blocks). The CHANGED_LINES filter block (between the `> **CHANGED_LINES OUTPUT FILTER — MANDATORY**` header and the next `---`) must be **byte-identical** to the canonical block in `includes/specialist-context.md` — copy it verbatim, including the inline maintenance HTML comment used by the other specialists.

```markdown
---
name: api-contract-reviewer
description: Reviews code changes for hallucinated APIs, wrong signatures/versions, deprecated API usage, and comment-truth (comments that misdescribe the code). Standalone or dispatched by the review include.
model: sonnet
tools: Read, Grep, Glob, Bash
background: true
---

You are an API-contract reviewer. Your single lens is whether the code's use of external contracts is truthful: do the library/framework calls exist with the signatures used at the pinned version, and do the comments/docstrings tell the truth about what the code does. This is the most self-contained and I/O-heavy part of a correctness pass — it reads lockfiles and manifests and may fetch docs — which is why it runs as its own parallel specialist rather than inside the correctness agent.

This is distinct from `correctness-reviewer`, which reasons over the diff's *behaviour* (logic, null-derefs, boundaries, concurrency, silent-failure paths). You reason over *external contracts* — signatures, pinned versions, and comments-vs-code. Keep the boundary crisp: never flag a logic/null/boundary/concurrency bug — that is correctness's job.

Follow the context gathering instructions in `includes/specialist-context.md`.

## Focus Areas

Restrict every finding to lines in `$CHANGED_LINES` (see the filter at the bottom). Review every change for:

- **Incorrect API usage** — wrong method signatures, deprecated APIs, misunderstood contracts
- **Hallucinated APIs / wrong signatures / wrong API versions** — when the diff calls a
  library or framework function, verify the signature against the version pinned in the
  project's lockfile or manifest (read the lockfile if present, e.g. `package-lock.json`,
  `*.csproj`, `requirements.txt`, `go.sum`). When in doubt, web-fetch the current docs for
  that version. Flag confident-looking calls that don't exist or whose signature doesn't
  match the pinned version.
- **Comment-truth verification** — read each new or modified comment, docstring, or `///`
  summary against the code it describes. Flag claims that don't match the actual behaviour
  (e.g. a docstring says "returns null on missing key" but the implementation throws).
  This is a Critical or Important finding only when the inaccurate documentation would
  mislead a caller into writing wrong code; otherwise Suggestion. A misleading comment is
  an instance of the **agent-hazard basis** in `includes/severity-definitions.md` — it
  predictably induces a future maintainer to write wrong code — which is why it reaches
  Important even though the comment itself causes no runtime defect today.

## Analysis Process

1. From `$CHANGED_LINES`, identify every changed line that calls an external library/framework API or adds/modifies a comment, docstring, or `///` summary.
2. For each external call, locate the pinned version in the project's lockfile/manifest and verify the signature. When the pinned version's API is unclear, web-fetch the current docs for that version before flagging.
3. For each new/modified comment, read the code it describes and check the claim against actual behaviour.
4. Decide severity: a call that does not exist / wrong signature that would fail at runtime is Important (or Critical if it is on a load-bearing path). A misleading comment reaches Important via the agent-hazard basis only when it would mislead a caller into writing wrong code; otherwise Suggestion.

## Output Format

> **Schema alignment:** your finding fields (File, line, Severity, Confidence,
> Description, Suggested fix) map to `includes/finding-schema.json#/$defs/finding`.
> Emit your markdown report as specified; the review-core Workflow coerces these
> same fields via the `agent()` schema param.

Return findings in this exact format:

```
## API Contract Review Findings

### Finding — [short title]
- **File:** path/to/file:42
- **Confidence:** 0-100
- **Severity:** Critical | Important | Suggestion (see `includes/severity-definitions.md`)
- **Description:** What contract is violated — the non-existent/wrong-signature call and its pinned version, or the comment claim vs the actual behaviour — and why it matters
- **Suggested fix:** Concrete code change or the correct signature/comment
```

Report ALL findings regardless of confidence level.

If no findings: `## API Contract Review Findings\n\n0 findings.`

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

- Be precise. Cite file paths and line numbers; the line must be a changed line (the offending call site or the new/modified comment).
- Note certainty level and reasoning for each finding.
- NEVER review logic errors, null-derefs, boundary conditions, concurrency, resource leaks, or silent-failure paths — those stay with `correctness-reviewer`.
- NEVER review style, security, consistency, or efficiency — leave those to the other specialists. Your sole lens is contract-truth: API existence/signature/version and comment-vs-code.
- Don't flag idiomatic or intentional API patterns; verify against the pinned version before concluding a call is wrong.
```

- [ ] **Step 4: Verify the CHANGED_LINES block is byte-identical to canonical**

The `test_sync_changed_lines_rule_matches_canonical` test diffs the inlined block against `includes/specialist-context.md`. Confirm the block you pasted matches (Step 6 of this task runs the check). Do NOT paste the cross-review-mode `MODE SWITCH` block — this agent has none.

- [ ] **Step 5: Verify frontmatter/layout conventions**

Confirm: `name` matches the filename stem (`api-contract-reviewer`); there is a blank line after the closing `---`; 2-space indentation; LF endings; final newline. Tools match `correctness-reviewer` (`Read, Grep, Glob, Bash`) — no new WebFetch grant (the web-fetch instruction is inherited verbatim and, as in correctness today, is served by Bash `curl`; adding a tool would be out-of-scope behaviour change).

- [ ] **Step 6: Run the full suite to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — including `CHANGED_LINES rule sync: api-contract-reviewer.md matches canonical`. Note: `test_sync_cross_review_mode_inline_matches_canonical` does **not** list this agent, so its absence of a `MODE SWITCH` block is correct and does not fail.

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review-suite/agents/api-contract-reviewer.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
feat(review): add api-contract-reviewer specialist (contract-truth lens lifted from correctness)

Carries incorrect-API-usage, hallucinated-API/wrong-signature/version, and
comment-truth lenses verbatim from correctness-reviewer. LLM specialist with
Read/Grep/Bash; not a cross-reviewer. Wiring + correctness removal follow.
EOF
)"
```

---

### Task 2: Wire `api-contract` into review-core as a core domain

Add the domain to the always-on `CORE` list so it dispatches on every full-route review, and to `NON_CROSS` so classic-mode runs never dispatch it with `Mode: cross-review` (it has no cross-review-mode contract). Because `CORE` changes, the panel-concern-brief's `CORE-DOMAINS` marker must be updated in lockstep — a structural test enforces parity.

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (`CORE` ~line 236-239; `STATIC`/`crossDomains` ~line 261-265)
- Modify: `plugins/code-review-suite/includes/panel-concern-brief.md` (`CORE-DOMAINS` marker ~line 3)
- Test: `tests/lib/test_sync_notes.sh` (update `test_sync_static_analysis_cross_feed_documented` assertion 1 regex)

**Interfaces:**
- Consumes: nothing new — `api-contract` is unconditional, not threaded through `flags`.
- Produces: `api-contract` in `CORE` → in `coreList`/`allSpecialists` (hence in `ranDomains` to the panel and in `flattenFindings`), and absent from `crossDomains` via `NON_CROSS`.

- [ ] **Step 1: Update the failing sync-test assertion**

`test_sync_static_analysis_cross_feed_documented` (assertion 1) currently greps for the literal `const crossDomains = allSpecialists\.filter\(d => !STATIC\.has\(d\)\)`. Since we introduce a `NON_CROSS` set, update that assertion's second grep pattern (line ~860):

```bash
    if grep -qE 'const STATIC = new Set\(\[' "$review_core" \
            && grep -qE 'const crossDomains = allSpecialists\.filter\(d => !NON_CROSS\.has\(d\)\)' "$review_core"; then
```

Also update its fail-message text (line ~864) from `!STATIC.has(d)` to `!NON_CROSS.has(d)` so the diagnostic stays accurate.

> **If the test-adequacy PR landed first:** this assertion and the `NON_CROSS` set already exist. Then Step 1 is a no-op (verify the assertion already matches `!NON_CROSS.has(d)`), and Step 3 extends the existing `NON_CROSS` set instead of creating it. Check `git grep -n NON_CROSS plugins/code-review-suite/workflows/review-core.mjs` first.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `static-analysis cross-feed: review-core.mjs excludes STATIC from receiving cross-review`, because `review-core.mjs` still says `!STATIC.has(d)`, not `!NON_CROSS.has(d)` (unless test-adequacy already landed — then this test passes and you go straight to Step 3).

- [ ] **Step 3: Add `api-contract` to CORE, and add the NON_CROSS exclusion**

In `review-core.mjs`, extend the `CORE` array (place `api-contract` right after `correctness`, its sibling):

```javascript
const CORE = [
    'security', 'correctness', 'api-contract', 'consistency', 'style',
    'archaeology', 'reuse', 'efficiency', 'alignment',
]
```

Then, just below the `STATIC` set definition (~line 261), add a `NON_CROSS` set and switch the `crossDomains` filter to use it. **If `NON_CROSS` already exists** (test-adequacy landed first), instead add `'api-contract'` to its contents: `const NON_CROSS = new Set([...STATIC, 'test-adequacy', 'api-contract'])`. Otherwise create it:

```javascript
const STATIC = new Set(['jbinspect', 'eslint', 'ruff', 'trivy', 'housekeeper'])
// api-contract is an LLM specialist with NO cross-review-mode contract (unlike the
// core reviewers) and is NOT severity-locked like the STATIC analysers. NON_CROSS is
// only the receive-cross-review exclusion; STATIC keeps its severity-lock semantics
// everywhere else. Classic mode is being retired; when it is, this exclusion can be
// simplified since the panel path never runs cross-review.
const NON_CROSS = new Set([...STATIC, 'api-contract'])
```

Then change the `crossDomains` line (~line 265) from:

```javascript
const crossDomains = allSpecialists.filter(d => !STATIC.has(d))
```

to:

```javascript
const crossDomains = allSpecialists.filter(d => !NON_CROSS.has(d))
```

- [ ] **Step 4: Update the panel-concern-brief CORE-DOMAINS marker**

`test_panel_concern_brief_domains_match_core` (in `tests/lib/test_panel_wiring.sh`) asserts the brief's `CORE-DOMAINS` comment lists the same domains, in the same order, as the engine's `CORE` array. Edit `includes/panel-concern-brief.md` line ~3 to insert `api-contract` after `correctness`:

```markdown
<!-- CORE-DOMAINS: security, correctness, api-contract, consistency, style, archaeology, reuse, efficiency, alignment -->
```

- [ ] **Step 5: Confirm the engine parses**

Run: `node --check plugins/code-review-suite/workflows/review-core.mjs`
Expected: no output, exit 0.

- [ ] **Step 6: Run the full suite to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — including `static-analysis cross-feed: review-core.mjs excludes STATIC from receiving cross-review` (now matching `!NON_CROSS.has(d)`), `concern-brief domain list tracks review-core.mjs CORE`, and the STATIC enumeration checks (STATIC still names all five static analysers).

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs plugins/code-review-suite/includes/panel-concern-brief.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
feat(review): dispatch api-contract as an always-on core specialist

Added to CORE (language-agnostic contract-truth runs on every full review, as
it did inside correctness) and to NON_CROSS so classic-mode runs never dispatch
it into a cross-review mode it has no contract for. Concern-brief CORE-DOMAINS
marker updated in lockstep.
EOF
)"
```

---

### Task 3: Remove the moved lens from `correctness-reviewer` and re-point the agent-hazard test

The API/contract-truth lens now lives in `api-contract-reviewer`. Delete it from correctness so the two agents do not double-report and correctness sheds its slowest sub-task. The `agent-hazard basis` citation moves with comment-truth, so the sync test that pins that anchor **in** correctness must be re-pointed to the new agent — not merely extended, or the correctness assertion fails.

**Files:**
- Modify: `plugins/code-review-suite/agents/correctness-reviewer.md` (delete line 82 `Incorrect API usage` bullet and lines 84-97 Hallucinated-APIs + Comment-truth blocks)
- Modify: `tests/lib/test_sync_notes.sh` (`test_sync_agent_hazard_severity_basis`: change the `$corr` assertion to target `api-contract-reviewer.md`)

**Interfaces:**
- Produces: correctness-reviewer with no API/contract-truth lens; its remaining Focus Areas are logic/off-by-one/null/race/leak/error-handling(incl. silent-failure)/boundary/type/async. The `agent-hazard basis` anchor now lives only in `api-contract-reviewer.md` (among the specialists) and `review-synthesiser.md`.

- [ ] **Step 1: Re-point the failing sync-test assertion**

In `tests/lib/test_sync_notes.sh`, `test_sync_agent_hazard_severity_basis` currently declares `local corr="$cr/agents/correctness-reviewer.md"` (line ~1533) and asserts `agent-hazard basis` appears in `$corr` (line ~1568). Re-point it to the new agent. Change the variable (line ~1533):

```bash
    local apic="$cr/agents/api-contract-reviewer.md"
```

Update the file-presence loop (line ~1536) to check `"$apic"` instead of `"$corr"`, and change the final assertion block (lines ~1567-1573) to grep `$apic` with re-worded pass/fail labels:

```bash
    # Additive re-point lock: comment-truth (now in api-contract) must cite the basis.
    if grep -qF 'agent-hazard basis' "$apic"; then
        pass "agent-hazard severity basis: comment-truth cites the agent-hazard basis"
    else
        fail "agent-hazard severity basis: comment-truth cites the agent-hazard basis" \
            "anchor 'agent-hazard basis' not found in $apic"
    fi
```

- [ ] **Step 2: Run test to verify current state**

Run: `bash tests/run.sh`
Expected: at this point the test greps `api-contract-reviewer.md` for `agent-hazard basis`, which IS present (Task 1 added it), so this specific assertion PASSES. The test is now correctly guarding the new home of the anchor. (This step confirms the re-point is valid before we delete from correctness — if you had left the assertion on `$corr`, Step 3's deletion would break it.)

- [ ] **Step 3: Delete the moved lens from correctness-reviewer**

In `plugins/code-review-suite/agents/correctness-reviewer.md`, delete the line-82 bullet:

```markdown
- **Incorrect API usage** — wrong method signatures, deprecated APIs, misunderstood contracts
```

and delete the entire Hallucinated-APIs + Comment-truth block (lines 84-97), i.e. remove both bullets:

```markdown
- **Hallucinated APIs / wrong signatures / wrong API versions** — when the diff calls a
  library or framework function, verify the signature against the version pinned in the
  project's lockfile or manifest (read the lockfile if present, e.g. `package-lock.json`,
  `*.csproj`, `requirements.txt`, `go.sum`). When in doubt, web-fetch the current docs for
  that version. Flag confident-looking calls that don't exist or whose signature doesn't
  match the pinned version.
- **Comment-truth verification** — read each new or modified comment, docstring, or `///`
  summary against the code it describes. Flag claims that don't match the actual behaviour
  (e.g. a docstring says "returns null on missing key" but the implementation throws).
  This is a Critical or Important finding only when the inaccurate documentation would
  mislead a caller into writing wrong code; otherwise Suggestion. A misleading comment is
  an instance of the **agent-hazard basis** in `includes/severity-definitions.md` — it
  predictably induces a future maintainer to write wrong code — which is why it reaches
  Important even though the comment itself causes no runtime defect today.
```

The `Async/await pitfalls` bullet (line 83) stays as the last bullet before what was line 84; the Focus Areas list now ends at `Async/await pitfalls`. Leave everything else (silent-failure at line 79, output format, CHANGED_LINES filter, cross-review-mode block) untouched.

- [ ] **Step 4: Verify no dangling API references remain in correctness**

Run: `grep -nE 'API|signature|comment-truth|Comment-truth|hallucinat' plugins/code-review-suite/agents/correctness-reviewer.md`
Expected: no matches (the lens is fully removed; correctness no longer mentions API-truth or comment-truth).

- [ ] **Step 5: Run the full suite to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — `agent-hazard severity basis: comment-truth cites the agent-hazard basis` now guards `api-contract-reviewer.md`; correctness's CHANGED_LINES and cross-review-mode sync blocks are unchanged so their tests still pass; `test_sync_agent_hazard_severity_basis` no longer requires the anchor in correctness.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/agents/correctness-reviewer.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
refactor(review): remove API/contract-truth lens from correctness (moved to api-contract)

Deletes the incorrect-API-usage, hallucinated-API, and comment-truth bullets;
correctness keeps logic/null/boundary/concurrency/silent-failure. Re-points the
agent-hazard-basis sync test to api-contract-reviewer, the new home of the
comment-truth citation.
EOF
)"
```

---

### Task 4: Update the roster enumerations (README) in lockstep

The README is the human-facing roster. `api-contract` is a new **core** specialist, so it joins the core prose sentence, the domain table, and the two numeric count claims. Correctness's table row does not mention API/comment-truth today, so it needs no wording change — but confirm that.

Adding a core specialist takes the core count from **8 to 9** and the all-conditionals total from **15 to 16** (see Global Constraints for the merge-reconciliation hazard with the test-adequacy plan).

**Files:**
- Modify: `plugins/code-review-suite/README.md` (count claims ~line 29 and ~line 69; core prose ~line 30-31; domain table ~line 76-91)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add the specialist to the core roster prose**

In `README.md` line ~30-31, the core list reads `\`security-reviewer\`, \`correctness-reviewer\`, \`consistency-reviewer\`, \`style-reviewer\`, \`archaeology-reviewer\`, \`reuse-reviewer\`, \`efficiency-reviewer\`, \`alignment-reviewer\`, plus`. Insert `\`api-contract-reviewer\`,` after `\`correctness-reviewer\`,`:

```markdown
`security-reviewer`, `correctness-reviewer`, `api-contract-reviewer`, `consistency-reviewer`, `style-reviewer`,
`archaeology-reviewer`, `reuse-reviewer`, `efficiency-reviewer`, `alignment-reviewer`, plus
```

- [ ] **Step 2: Add the table row**

In the domain table, add a row after the `correctness-reviewer` row (line ~77):

```markdown
| `api-contract-reviewer` | Hallucinated/nonexistent APIs, wrong signatures/versions, deprecated API usage, and comment-truth (comments that misdescribe the code) — always-on core |
```

- [ ] **Step 3: Update the two numeric count claims**

- ~line 29: `The full review path dispatches 8 core specialists (up to 15 with all conditionals):` → change `8 core specialists` to `9 core specialists` and `up to 15` to `up to 16`.
- ~line 69: `the full route dispatches 8 core specialists plus up to 7 conditional specialists (...)` → change `8 core specialists` to `9 core specialists`.

- [ ] **Step 4: Confirm correctness's table row needs no edit**

Run: `grep -n 'correctness-reviewer' plugins/code-review-suite/README.md`
Expected: the table row (line ~77) reads `Logic errors, off-by-one, null derefs, race conditions, async/await pitfalls` — no API/comment mention, so it correctly needs no change after the lens moved out.

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `bash tests/run.sh`
Expected: PASS (README changes are not asserted by structural tests, but confirm nothing else broke).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/README.md
git commit -m "$(cat <<'EOF'
docs(review): list api-contract-reviewer in the core specialist roster
EOF
)"
```

---

### Task 5: Add A/B corpus fixtures and per-agent config for validation

Mirror the existing `silentfail-*` corpus pattern so the split can be depth-validated (the arms must catch everything the pre-split correctness agent caught — zero net loss — and near-miss guards stay silent). Scope: an API-truth hit, a comment-truth hit, and a near-miss inflation guard.

**Files:**
- Create: `tests/ab/corpus/api-contract-apitruth-hit/source.yaml`
- Create: `tests/ab/corpus/api-contract-commenttruth-hit/source.yaml`
- Create: `tests/ab/corpus/api-contract-nearmiss/source.yaml`
- Create: fixture source trees under `tests/fixtures/api-contract/{apitruth-hit,commenttruth-hit,nearmiss}/`
- Modify: `tests/ab/corpus/index.yaml` (register the three fixtures)
- Create: `tests/ab/configs/per-agent/api-contract-baseline.yaml`

**Interfaces:**
- Consumes: the fixture `source.yaml` schema used by the existing corpus (see `tests/ab/corpus/silentfail-hit/source.yaml` for the exact keys: `id, agent, type, captured_at, baseline_revision, captured_under, working_dir_strategy, source_path, setup.command, base_sha, head_sha, path_scope, empty_tree_mode, review_mode, planted.{file,line,expect_arm_a,expect_arm_b}, intent_ledger, depends_on`).
- Produces: corpus entries dispatched at `agent: api-contract-reviewer`.

- [ ] **Step 1: Read the reference fixture to copy its exact schema**

Read `tests/ab/corpus/silentfail-hit/source.yaml` (structure) and `tests/ab/configs/per-agent/correctness-baseline.yaml` (config shape). Note: `source_path` points at a tree under `tests/fixtures/…`; `setup.command` git-inits a base commit then commits the planted file so the diff is the second commit; `depends_on` lists the agent file plus the planted source file(s) and every path must resolve (the `test_ab_corpus_smoke_depends_on_paths_resolve` pattern).

- [ ] **Step 2: Register the fixtures in the corpus index**

Append to `tests/ab/corpus/index.yaml` under `fixtures:`:

```yaml
  - id: api-contract-apitruth-hit
    agent: api-contract-reviewer
    type: synthetic
    description: New call to a library function with a wrong/nonexistent signature for the pinned version. Arm B expected Important; arm A ABSENT (pre-split correctness minus the moved lens cannot see it). Zero-net-loss proof.
    tags: [api-contract, api-truth]
  - id: api-contract-commenttruth-hit
    agent: api-contract-reviewer
    type: synthetic
    description: New docstring that contradicts the implementation (says returns null on missing key; code throws). Arm B expected Important via agent-hazard basis; arm A ABSENT.
    tags: [api-contract, comment-truth, agent-hazard]
  - id: api-contract-nearmiss
    agent: api-contract-reviewer
    type: synthetic
    description: New library call with a correct signature for the pinned version and an accurate docstring. Inflation guard — expected ABSENT in both arms.
    tags: [api-contract, inflation-guard]
```

- [ ] **Step 3: Create the fixture source trees**

Under `tests/fixtures/api-contract/`, create the smallest trees that make the contract violation unambiguous. Recommended (one language per fixture, deterministic):
- `apitruth-hit/` — a Python file that calls a stdlib/well-known function with a wrong signature (e.g. `json.loads(data, strict=...)`-style nonexistent kwarg, or a `requests` call with a param that does not exist at a pinned version), plus a `requirements.txt` pinning the version. The wrong call is on the changed line.
- `commenttruth-hit/` — a small file whose new docstring states one contract (e.g. "returns None if the key is absent") while the body does the opposite (raises `KeyError`). The docstring line is a changed line.
- `nearmiss/` — the same shape as apitruth-hit but with a correct signature and an accurate docstring.

Each fixture also needs a `README.md` (mirrors `tests/fixtures/silent-failure/hit/README.md`) so `source_path` has a committable base file, matching the silentfail setup where `README.md` is committed as the base before the planted file.

- [ ] **Step 4: Create the three `source.yaml` files**

For each fixture create a `source.yaml` mirroring `silentfail-hit/source.yaml`'s keys. Set `agent: api-contract-reviewer`, `type: synthetic`, `working_dir_strategy: copy`, `source_path: tests/fixtures/api-contract/<name>/`, a `setup.command` that (with the same deterministic `GIT_*` env exports as silentfail) git-inits, commits `README.md` as base, then moves+commits the planted file(s). Set `planted.file`/`planted.line` to the offending call or docstring line; `expect_arm_b: Important` and `expect_arm_a: ABSENT` for the two hits; `expect_arm_b: ABSENT` (and `expect_arm_a: ABSENT`) for the near-miss. `depends_on` must list `plugins/code-review-suite/agents/api-contract-reviewer.md` and the planted source file path(s) — every entry must resolve on disk.

- [ ] **Step 5: Create the per-agent baseline config**

Create `tests/ab/configs/per-agent/api-contract-baseline.yaml`:

```yaml
name: api-contract-baseline
description: API-contract per-agent arm for the split depth/latency validation. opus/default; the ablation swaps only api-contract-reviewer.md.
mode: per-agent
agent: api-contract-reviewer
session:
  model: opus
  effort: default
```

- [ ] **Step 6: Run the full suite (fixtures well-formed)**

Run: `bash tests/run.sh`
Expected: PASS — `A/B corpus: index.yaml present and parses` stays green (valid YAML), and no `depends_on` path is missing. If the suite reports a missing `depends_on` path or a YAML parse error, fix the offending fixture.

- [ ] **Step 7: Commit**

```bash
git add tests/ab/corpus/api-contract-apitruth-hit tests/ab/corpus/api-contract-commenttruth-hit tests/ab/corpus/api-contract-nearmiss tests/ab/corpus/index.yaml tests/ab/configs/per-agent/api-contract-baseline.yaml tests/fixtures/api-contract
git commit -m "$(cat <<'EOF'
test(review): add api-contract A/B corpus fixtures (api-truth hit, comment-truth hit, near-miss) + baseline config
EOF
)"
```

---

### Task 6: End-to-end structural verification and behavioural / latency smoke

**Files:** none created — verification only.

**Interfaces:** none.

- [ ] **Step 1: Run the full structural suite**

Run: `bash tests/run.sh`
Expected: PASS — all sync-note, roster, panel-wiring, and enumeration tests green. Specifically confirm: `CHANGED_LINES rule sync: api-contract-reviewer.md matches canonical`; `static-analysis cross-feed: review-core.mjs excludes STATIC from receiving cross-review` (via `!NON_CROSS.has(d)`); `concern-brief domain list tracks review-core.mjs CORE`; `agent-hazard severity basis: comment-truth cites the agent-hazard basis` (now on api-contract); no cross-review-mode sync failure (api-contract correctly absent from that roster).

- [ ] **Step 2: Confirm the engine parses**

Run: `node --check plugins/code-review-suite/workflows/review-core.mjs`
Expected: no output, exit 0.

- [ ] **Step 3: Behavioural + latency A/B (ship-gate, operator-run)**

This is the depth-gated, latency-led ship gate from the spec — an operator-run sweep, not an automated unit step. Flag it to the user rather than claiming it here. Two conditions must BOTH hold to ship:
- **Depth (zero net loss):** on a corpus with planted API-truth / comment-truth / silent-failure / logic findings, the split arms (correctness + api-contract) catch everything the pre-split single correctness agent caught; the near-miss guards stay silent. The two hit fixtures fire Important; the near-miss is ABSENT.
- **Latency:** per-trial `timing.json` on a code-heavy PR shows the parallel pair finishing sooner than the pre-split serial correctness agent. **If latency does not improve, HOLD the split** (per spec success criteria) — it is not worth the extra dispatch otherwise.

Note explicitly if you cannot run the live sweep in-session. No production haiku/low model flip in this change (a later probe, as with the other specialists).

- [ ] **Step 4: Housekeeping pass (per user global CLAUDE.md)**

Surface repo housekeeping as a **separate** consideration: `git status` to confirm a clean tree, and note (do not silently bundle) any dependency/action/runner freshness the marketplace repo's own CI would flag. This plan touches only `code-review-suite` plugin files, so template drift is not expected — confirm and report.

- [ ] **Step 5: Final commit / PR readiness**

Confirm all tasks are committed. Per branch-protection, land via a PR (no admin-bypass push to `main`). The PR description must open with a 1-3 sentence non-technical summary (correctness was the wall-clock long pole on code-heavy PRs; this splits its slowest self-contained lens into a parallel specialist so reviews finish sooner without losing coverage), then the technical change list. **Include the README count-reconciliation note** (Global Constraints) so the reviewer knows the count sentence conflicts with the test-adequacy PR and whichever merges second must land 9 core + 8 conditional = up to 17.

---

## Self-Review

**1. Spec coverage (against `docs/superpowers/specs/2026-07-20-correctness-api-contract-split-design.md`):**
- "Extract API/contract-truth into `api-contract-reviewer`" → Task 1. ✅
- "Verbatim lift, not rewrite" → Task 1 Step 3 lifts the bullets byte-for-byte; Global Constraints forbids rewording. ✅
- "Silent-failure STAYS in correctness" → Task 3 deletes only the API/comment bullets; silent-failure (line 79) explicitly left. ✅
- "Core (always-on), NOT flag-gated" (revised decision) → Task 2 adds to `CORE`, no `flags` threading, no pipeline-triad edit. ✅
- "NOT a cross-reviewer; excluded via NON_CROSS" → Task 1 omits the MODE SWITCH block; Task 2 adds `api-contract` to `NON_CROSS`. ✅
- "Update `test_sync_agent_hazard_severity_basis` — anchor moves out of correctness" → Task 3 re-points `$corr`→`$apic` (re-point, not add, so correctness deletion doesn't break it). ✅
- "MODIFY README roster prose + table row" → Task 4 (prose, table, and the two count claims). ✅
- "CREATE A/B corpus fixtures (api-truth hit, comment-truth hit, near-miss) + per-agent baseline" → Task 5. ✅
- "Structural every task; behavioural A/B ship-gate (depth + latency), hold if no latency win; haiku/low later" → Task 6 Step 3. ✅
- Shared machinery: only `NON_CROSS` (not `$PRODUCTION_SOURCE_DETECTED`), with land-order guards → Task 2 Step 1/Step 3 conditionals. ✅

**2. Deliberate extension beyond the spec's literal ":84-97":** The spec names lines 84-97 as the moved lens. During source verification I found line 82 (`Incorrect API usage — wrong method signatures, deprecated APIs, misunderstood contracts`) is a near-duplicate summary of the same contract concern (it uniquely carries "deprecated APIs" and "misunderstood contracts"). Task 3 moves line 82 too, so no vestigial API lens is left in correctness — the faithful reading of the spec's "clean boundary" and "no API lens in correctness" intent. If the user prefers to leave line 82 in correctness, drop it from Task 1's Focus Areas and from Task 3's deletion; nothing else changes.

**3. Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". The agent body and all engine/test edits are given in full. Task 5 Step 3-4 describes fixture construction (mirroring a named reference) rather than pasting three full source trees — a bounded instruction pinned to `silentfail-hit/source.yaml`, not a vague placeholder, consistent with the sibling test-adequacy plan's Task 5.

**4. Type/name consistency:** Domain string `api-contract` → agent file `api-contract-reviewer.md` → `agentType: code-review-suite:api-contract-reviewer` (engine derives it) → observe hook matches `*-reviewer` glob (no edit needed). `CORE`, `NON_CROSS`, and the concern-brief `CORE-DOMAINS` marker all name `api-contract` identically. The `crossDomains` filter references `NON_CROSS` in both the engine and the sync-test assertion. Heading `## API Contract Review Findings` is consistent between the agent body and the no-findings sentinel.
