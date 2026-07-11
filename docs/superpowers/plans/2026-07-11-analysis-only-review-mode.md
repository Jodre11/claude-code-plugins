# Analysis-only Review Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `analysis_only` orchestration mode that runs the full `/review-gh-pr` pipeline to completion on a `CLOSED`/`MERGED` PR but renders the report to stdout instead of posting to GitHub, unblocking the panel-vs-classic A/B arm-tell capture.

**Architecture:** A single host-side config key (`orchestration.analysis_only`, two-layer resolution, default `false`) resolved at Stage 1. When `true`, an explicit instruction defeats the model's emergent "a merged PR isn't worth reviewing" short-circuit at Stage 1, and every GitHub-write site (Phase 0.4 narrative-halt post, Stage 6 verdict + inline comments) renders to stdout instead of calling `gh`. No change to `review-core.mjs`, specialists, or the sealed-bundle contract.

**Tech Stack:** Markdown skill prose (`skills/review-gh-pr/SKILL.md` + two byte-synced twins), Bash A/B harness (`tests/ab/lib/orchestration.sh`), Bash structural test suite (`tests/run.sh`).

## Global Constraints

- **No default behaviour change.** `analysis_only` defaults `false`; when the key is absent, production review behaviour is byte-unchanged. Every new instruction is gated on `$ANALYSIS_ONLY = true`.
- **No `review-core.mjs` change.** The Workflow core does not post — the host skill does. All posting-suppression edits are host-side (SKILL.md / synced twins). Do not touch `workflows/review-core.mjs`, specialists, the synthesiser, or the sealed-bundle contract `{verdict, bodyText, comments[]}`.
- **No Phase 0 narrative-bar or CI-green bypass.** `analysis_only` defeats only the emergent MERGED short-circuit and suppresses posting. Phase 0 (narrative) and Phase 0.6 (CI-green) gates still halt cleanly if they fire. The operator picks corpus PRs that pass them.
- **Two-layer config resolution, first match wins:** (1) reviewed repo `.claude/code-review.toml`, then (2) user-level `~/.claude/code-review.toml`. Missing/malformed file = key not set. An explicit `false` in the repo-level file wins over a `true` in the user-level file. Default `false`. This mirrors `full_log` resolution (Step 3.6) verbatim.
- **The byte-synced range is load-bearing.** The pipeline body from `Follow these instructions exactly. Do not skip steps or reorder.` through `Present the synthesiser's formatted report to the user.` is byte-identical across three files: `includes/review-pipeline.md` (canonical), `skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`. `tests/lib/test_sync_notes.sh::test_sync_pipeline_inline_matches_canonical` enforces this. Phase 0.4 sits **inside** this range (Edit C1 → all-3-files, byte-identical). Stage 1 and Stage 6 sit **outside** it (Edits A/B/C2 → SKILL.md only).
- **Feature work goes via a PR on a branch** (branch-protection rule) — NOT direct-push to `main`. Create a branch before Task 1.
- **Markdown uses 2-space indentation; shell uses 4-space; LF line endings** (see `.editorconfig` / `.gitattributes`).
- **Baseline is green:** `tests/run.sh` reports `700 tests: 699 passed, 1 skipped` at `2f9442d`. Housekeeping (runners `ubuntu-24.04`, actions SHA-pinned to current majors, no dependency manifests) is clean — no pre-PR needed.

## File Structure

- **Modify:** `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — Stage 1 (resolve `$ANALYSIS_ONLY` + defeat short-circuit), Phase 0.4 (suppress narrative-halt post), Stage 6 (suppress verdict/comment posting, render to stdout).
- **Modify:** `plugins/code-review-suite/includes/review-pipeline.md` — Phase 0.4 suppress clause only (byte-identical to SKILL.md's Phase 0.4 edit; inside synced range).
- **Modify:** `plugins/code-review-suite/commands/pre-review.md` — Phase 0.4 suppress clause only (byte-identical; inside synced range; inert dead-prose in local mode but required for byte-sync).
- **Modify:** `tests/ab/lib/orchestration.sh` — add `analysis_only = true` to the `orchestration_apply_arm` heredoc.
- **Modify:** `tests/lib/test_sync_notes.sh` — add grep-guard test functions for the Stage 1, Phase 0.4, and Stage 6 prose.
- **Modify:** `tests/lib/test_ab_orchestration.sh` — extend the apply round-trip test to assert `analysis_only = true` is written.

## Edit-site anchors (re-derived at `2f9442d`)

- Synced range in SKILL.md: line 123 (`Follow these instructions exactly`) → line 1126 (`Present the synthesiser's formatted report`).
- Stage 1 heading: `SKILL.md:15`. Gather commands end ~line 57; `### Detect self-re-review` at line 59. **Insert Edit A+B between them.**
- Phase 0.4 pr-mode canned body: `SKILL.md:321-327`; posting logic `SKILL.md:329-345`. Byte-synced twins: `review-pipeline.md:216` / `pre-review.md:217` (canned body). **Insert Edit C1 after the canned body's closing fence, before `Before posting, fetch the most recent review`.**
- Stage 6 heading: `SKILL.md:1351`; intro bullets end ~line 1390; `### Class A` at line 1392. **Insert Edit C2 between them.**

Match edits on the surrounding text quoted below, not on line numbers (they drift).

---

### Task 1: Stage 1 — resolve `analysis_only` and defeat the MERGED short-circuit

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (Stage 1, ~line 57–59; outside synced range)
- Test: `tests/lib/test_sync_notes.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `$ANALYSIS_ONLY` (boolean, default `false`), resolved at Stage 1 and read later by Task 3 (Stage 6). The exact literals `Resolve \`orchestration.analysis_only\`` and `Do not short-circuit on PR state under analysis-only` are asserted by Task 1's test and referenced by no other task.

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_sync_notes.sh` (place after `test_skill_md_step6_references_rubric_and_classes`):

```bash
test_analysis_only_stage1_resolve_and_no_short_circuit() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "analysis-only Stage 1 resolve + no-short-circuit" "code-review-suite plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "analysis-only Stage 1: SKILL.md present" "missing: $skill"
        return
    fi

    # Extract Stage 1's body (from its heading to Stage 2) so the assertions can't
    # be satisfied by matching text elsewhere in the file.
    local stage1
    stage1=$(sed -n '/^## Stage 1: Gather PR Information/,/^## Stage 2:/p' "$skill")

    if grep -qF 'Resolve `orchestration.analysis_only`' <<<"$stage1"; then
        pass "analysis-only Stage 1: resolves orchestration.analysis_only"
    else
        fail "analysis-only Stage 1: resolves orchestration.analysis_only" \
            "Stage 1 must resolve \$ANALYSIS_ONLY from orchestration.analysis_only (two-layer, default false) before any PR-state decision — the anti-short-circuit and Stage 6 suppression both depend on the variable being bound here"
    fi

    if grep -qF 'Do not short-circuit on PR state under analysis-only' <<<"$stage1"; then
        pass "analysis-only Stage 1: forbids the MERGED/CLOSED short-circuit"
    else
        fail "analysis-only Stage 1: forbids the MERGED/CLOSED short-circuit" \
            "Stage 1 must carry the explicit 'Do not short-circuit on PR state under analysis-only' instruction — without it the model rationalises a halt on a merged PR before dispatching any specialist (the root-cause failure this mode fixes)"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A3 "analysis only stage1"`
Expected: FAIL on both assertions ("resolves orchestration.analysis_only" / "forbids the MERGED/CLOSED short-circuit") — the prose does not exist yet.

- [ ] **Step 3: Add the Stage 1 subsection (Edit A + B)**

In `SKILL.md`, find the end of the Stage 1 gather block — the line `Follow the \`gh --jq\` guidance in \`includes/gh-jq-pitfalls.md\`.` immediately followed by a blank line and `### Detect self-re-review`. Insert this new subsection **between** them (after the gh-jq line, before `### Detect self-re-review`):

```markdown
### Analysis-only mode

**Resolve `orchestration.analysis_only`.** Resolve from two config layers, first match wins,
exactly as `full_log` resolves (Step 3.6): (1) the reviewed repo's `.claude/code-review.toml`,
then (2) the user-level `~/.claude/code-review.toml`. Treat a missing/malformed file as not
setting the key. If neither layer sets `analysis_only`, `$ANALYSIS_ONLY = false`; otherwise it
is the resolved boolean. An explicit `false` in the repo-level file wins over a `true` in the
user-level file.

`$ANALYSIS_ONLY = true` runs the **full** review pipeline to completion but renders the report
to stdout instead of posting to GitHub (see Phase 0.4 and Stage 6). It exists so a
retrospective analysis can run against a `CLOSED`/`MERGED` PR — the report is never submitted,
so a non-open state is expected and valid.

**Do not short-circuit on PR state under analysis-only.** When `$ANALYSIS_ONLY = true`, a
`state` of `CLOSED` or `MERGED` in the PR data above MUST NOT halt the pipeline: proceed
through every stage to synthesis exactly as for an open PR. Do not reason that "a merged PR has
no actionable target" or that "any verdict would be refused" — under analysis-only the verdict
is rendered to stdout, not submitted. State-based posting refusal still applies at Stage 6,
where it belongs.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A3 "analysis only stage1"`
Expected: PASS on both assertions.

- [ ] **Step 5: Run the full suite to confirm no regression**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `702 tests: 701 passed, 1 skipped` (baseline 699 passed + 2 new assertions). No failures. (The synced-range test is unaffected — this edit is outside the range.)

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/skills/review-gh-pr/SKILL.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
feat(review-gh-pr): resolve analysis_only + defeat MERGED short-circuit at Stage 1

Adds the orchestration.analysis_only config key (two-layer, default false)
resolved at Stage 1, and an explicit instruction that forbids the emergent
CLOSED/MERGED pipeline halt under analysis-only. Prose-guard test added.
EOF
)"
```

---

### Task 2: Phase 0.4 — suppress narrative-halt posting under analysis-only (byte-synced ×3)

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (Phase 0.4, inside synced range)
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (Phase 0.4, byte-identical)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (Phase 0.4, byte-identical)
- Test: `tests/lib/test_sync_notes.sh`

**Interfaces:**
- Consumes: `$ANALYSIS_ONLY` from Task 1 (only bound in SKILL.md; the clause is inert dead-prose in `review-pipeline.md`/`pre-review.md` because local mode never enters the pr-mode branch — but it MUST be present there byte-identically so the sync test stays green).
- Produces: the literal `Phase 0 halt (analysis-only, not posted)` in all three files. The existing `test_sync_pipeline_inline_matches_canonical` enforces byte-identity; Task 2's new test asserts presence in the canonical (guards against unanimous deletion, which byte-identity checks cannot catch).

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_sync_notes.sh` (after Task 1's function):

```bash
test_analysis_only_phase04_suppress_present_in_canonical() {
    # The existing pipeline-inline sync test enforces byte-identity across the three
    # copies, but a *unanimous* deletion would keep them identical and pass. This
    # presence check on the canonical is belt-and-braces: it fails if the analysis-only
    # Phase 0.4 suppression clause is removed from all three at once.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "analysis-only Phase 0.4 suppression" "code-review-suite plugin not found"
        return
    fi

    local canonical="$cr/includes/review-pipeline.md"
    if [[ ! -f "$canonical" ]]; then
        fail "analysis-only Phase 0.4 suppression: canonical present" "missing: $canonical"
        return
    fi

    if grep -qF 'Phase 0 halt (analysis-only, not posted)' "$canonical"; then
        pass "analysis-only Phase 0.4 suppression: canonical carries the render-not-post clause"
    else
        fail "analysis-only Phase 0.4 suppression: canonical carries the render-not-post clause" \
            "review-pipeline.md Phase 0.4 pr-mode block must, under \$ANALYSIS_ONLY = true, render the halt notice to stdout ('Phase 0 halt (analysis-only, not posted)') instead of posting a REQUEST_CHANGES review — otherwise analysis-only still writes to GitHub on a narrative-less PR"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A3 "analysis only phase04"`
Expected: FAIL — "canonical carries the render-not-post clause" (clause absent).

- [ ] **Step 3: Edit the canonical `includes/review-pipeline.md`**

Find the Phase 0.4 pr-mode canned body — the fenced block ending with the line `(This is a structural check — no AI was used to evaluate the body's quality. Any narrative paragraph that meets the bar will let the review proceed.)` and its closing ` ``` ` — immediately followed by a blank line and `Before posting, fetch the most recent review by the current user:`. Insert this paragraph **between** the closing fence and `Before posting, fetch...`:

```markdown
**Under `$ANALYSIS_ONLY = true`:** do not post. Print the canned body above to stdout,
prefixed with `> Phase 0 halt (analysis-only, not posted): no narrative description`, and
stop the pipeline cleanly. Skip the duplicate-check and the `gh pr review` submission below.
```

- [ ] **Step 4: Apply the identical edit to `skills/review-gh-pr/SKILL.md`**

Make the byte-for-byte identical insertion at the matching site in `SKILL.md` (same surrounding text: after the canned-body closing fence, before `Before posting, fetch the most recent review by the current user:`).

- [ ] **Step 5: Apply the identical edit to `commands/pre-review.md`**

Make the byte-for-byte identical insertion at the matching site in `commands/pre-review.md`.

- [ ] **Step 6: Run the sync test to verify byte-identity holds**

Run: `bash tests/run.sh 2>&1 | grep -A2 "pipeline inline sync"`
Expected: PASS for both consumers ("SKILL.md matches canonical", "pre-review.md matches canonical"). If it FAILS with a diff, the three insertions are not byte-identical — reconcile whitespace/wrapping until identical.

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `703 tests: 702 passed, 1 skipped` (Task 1's 701 + 1 new assertion). No failures.

- [ ] **Step 8: Commit**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
feat(review-gh-pr): suppress Phase 0.4 narrative-halt post under analysis_only

Under analysis_only the pr-mode narrative-halt renders the notice to stdout
instead of posting a REQUEST_CHANGES review. Edit is byte-identical across the
three synced pipeline copies; presence guard added for unanimous-deletion.
EOF
)"
```

---

### Task 3: Stage 6 — suppress verdict/comment posting, render to stdout

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (Stage 6, ~line 1390–1392; outside synced range)
- Test: `tests/lib/test_sync_notes.sh`

**Interfaces:**
- Consumes: `$ANALYSIS_ONLY` from Task 1; the sealed bundle `{verdict, bodyText, comments[]}` and `$SYNTH_VERDICT` (both already present in Stage 6).
- Produces: the literals `Analysis-only — render, do not post` and `Verdict (analysis-only, not submitted)` in SKILL.md's Stage 6, asserted by Task 3's test.

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_sync_notes.sh` (after Task 2's function):

```bash
test_analysis_only_stage6_render_not_post() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "analysis-only Stage 6 render-not-post" "code-review-suite plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "analysis-only Stage 6: SKILL.md present" "missing: $skill"
        return
    fi

    # Slice Stage 6 so the assertions can't be satisfied by text elsewhere.
    local step6
    step6=$(sed -n '/^## Stage 6: Submit Review Verdict/,/^## Stage 7/p' "$skill")

    if grep -qF 'Analysis-only — render, do not post' <<<"$step6"; then
        pass "analysis-only Stage 6: carries the render-not-post subsection"
    else
        fail "analysis-only Stage 6: carries the render-not-post subsection" \
            "Stage 6 must carry an 'Analysis-only — render, do not post' subsection that, under \$ANALYSIS_ONLY = true, skips Classes A/B/C and renders the bundle to stdout — otherwise analysis-only submits the verdict and inline comments to GitHub"
    fi

    if grep -qF 'Verdict (analysis-only, not submitted)' <<<"$step6"; then
        pass "analysis-only Stage 6: renders the verdict line to stdout"
    else
        fail "analysis-only Stage 6: renders the verdict line to stdout" \
            "the analysis-only render path must print '> Verdict (analysis-only, not submitted): \$SYNTH_VERDICT' so the verdict is visible without being submitted"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A3 "analysis only stage6"`
Expected: FAIL on both assertions.

- [ ] **Step 3: Add the Stage 6 subsection (Edit C2)**

In `SKILL.md`, find the end of the Stage 6 intro bullets — the bullet beginning `Class C posting consumes the bundle directly:` and ending `body, using the review flag chosen from \`$FINAL_VERDICT\`.` — immediately followed by a blank line and `### Class A — User confirmation flow`. Insert this new subsection **between** them (after the Class-C-preview bullet, before `### Class A`):

```markdown
### Analysis-only — render, do not post

**Under `$ANALYSIS_ONLY = true`, this stage posts nothing to GitHub.** Skip Class A
(user-confirmation), Class B (PR-thread state), and Class C (submission mechanics) in their
entirety. Do NOT call `gh pr review`, `gh api .../comments`, or present any confirmation
prompt. Instead, render the sealed bundle to stdout:

- Print `bundle.bodyText` (the constructed review body).
- Print the verdict line: `> Verdict (analysis-only, not submitted): $SYNTH_VERDICT`.
- Print each `bundle.comments[i]` as a plain block — a `path:line (side)` header (or
  `path (file)` for a file-level entry) followed by the comment body — so the full comment
  set is visible without being posted.

Then stop cleanly. The Class B `CLOSED`/`MERGED` refusal is moot here — analysis-only never
posts regardless of PR state.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A3 "analysis only stage6"`
Expected: PASS on both assertions.

- [ ] **Step 5: Run the full suite (guard the Stage 6 structural test especially)**

Run: `bash tests/run.sh 2>&1 | grep -A6 "SKILL.md step6"`
Expected: all `SKILL.md Stage 6 rubric and classes` assertions still PASS (the new subsection adds a heading but does not remove Class A/B/C headings or reintroduce the decision matrix).

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `705 tests: 704 passed, 1 skipped` (Task 2's 702 + 2 new assertions). No failures.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/skills/review-gh-pr/SKILL.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
feat(review-gh-pr): render bundle to stdout under analysis_only at Stage 6

Under analysis_only, Stage 6 skips Classes A/B/C and prints the sealed bundle
(body, verdict, comments) to stdout instead of posting to GitHub. Prose-guard
test added.
EOF
)"
```

---

### Task 4: Harness activation + round-trip test

**Files:**
- Modify: `tests/ab/lib/orchestration.sh` (the `orchestration_apply_arm` heredoc, lines 40–45)
- Test: `tests/lib/test_ab_orchestration.sh` (extend `test_orch_apply_writes_expected_toml`)

**Interfaces:**
- Consumes: nothing from earlier tasks (the harness writes the config the skill later reads at runtime; there is no in-process coupling).
- Produces: a `~/.claude/code-review.toml` `[orchestration]` block that additionally contains `analysis_only = true`, so every A/B arm runs full-pipeline-no-post. The existing backup/restore trap already covers the new key (it backs up and restores the whole file).

- [ ] **Step 1: Extend the failing test**

In `tests/lib/test_ab_orchestration.sh`, modify `test_orch_apply_writes_expected_toml` (lines 6–19) to also assert `analysis_only = true`. Replace the `if grep ...` condition and its labels:

```bash
test_orch_apply_writes_expected_toml() {
    local tmp toml
    tmp=$(mktemp -d); toml="$tmp/code-review.toml"
    ( set -euo pipefail
      _AB_RUN_DIR="$tmp"; source "$(_orch_lib)"
      orchestration_apply_arm panel 5 "$toml" )
    if grep -q 'review_mode = "panel"' "$toml" && grep -q 'panel_size = 5' "$toml" \
        && grep -q 'full_log = true' "$toml" && grep -q 'analysis_only = true' "$toml"; then
        pass "orch: apply writes review_mode/panel_size/full_log/analysis_only"
    else
        fail "orch: apply writes review_mode/panel_size/full_log/analysis_only" "$(cat "$toml")"
    fi
    rm -rf "$tmp"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 "orch apply"`
Expected: FAIL — `analysis_only = true` not yet in the heredoc.

- [ ] **Step 3: Add `analysis_only = true` to the heredoc**

In `tests/ab/lib/orchestration.sh`, in `orchestration_apply_arm`, update the comment and the heredoc (lines 38–45):

```bash
    # full_log=true and analysis_only=true are forced on for the whole experiment — the
    # durable log is the data source, and analysis_only runs the full pipeline but renders
    # to stdout instead of posting (the merged-PR corpus would otherwise short-circuit).
    # panel_size is written even for classic (the workflow ignores it).
    cat > "$toml" <<EOF
[orchestration]
review_mode = "$arm"
panel_size = $panel_size
full_log = true
analysis_only = true
EOF
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A2 "orch apply"`
Expected: PASS — "orch: apply writes review_mode/panel_size/full_log/analysis_only".

- [ ] **Step 5: Verify the restore round-trip still holds**

Run: `bash tests/run.sh 2>&1 | grep -A2 "orch restore"`
Expected: PASS for "restore removes temp file when no prior existed" and "restore reinstates prior file byte-for-byte" — the whole-file backup/restore is agnostic to the new key.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh 2>&1 | tail -3`
Expected: `705 tests: 704 passed, 1 skipped` (unchanged count — this task modifies an existing assertion rather than adding one). No failures.

- [ ] **Step 7: Commit**

```bash
git add tests/ab/lib/orchestration.sh tests/lib/test_ab_orchestration.sh
git commit -m "$(cat <<'EOF'
feat(ab-harness): force analysis_only on in orchestration arm config

Adds analysis_only = true to the temp code-review.toml the A/B harness writes,
so every classic/panel arm runs the full pipeline against merged corpus PRs and
renders to stdout instead of short-circuiting. Round-trip test extended.
EOF
)"
```

---

### Task 5: Open the PR

**Files:** none (git/gh only).

- [ ] **Step 1: Push the branch and open the PR**

Write the PR body to `${CLAUDE_TEMP_DIR}/pr-body.md` first (contextual summary for a non-technical reader, then the technical change list), then:

```bash
git push -u origin <branch>
gh pr create --title "feat(review-gh-pr): analysis-only review mode" --body-file "${CLAUDE_TEMP_DIR}/pr-body.md"
```

The PR body should open with 1–3 sentences of context: this unblocks the panel-vs-classic A/B arm-tell capture (spec #3, Follow-up B), which cannot measure merged PRs because `/review-gh-pr` emergently halts at Stage 1 on a `MERGED` PR before dispatching any specialist. Then list the four edits (Stage 1 resolve + anti-short-circuit, Phase 0.4 suppression ×3, Stage 6 render-to-stdout, harness activation) and note that production behaviour is byte-unchanged when the key is absent.

- [ ] **Step 2: Confirm CI is green on the PR**

Run: `gh pr checks <pr-number>`
Expected: `tests` and `gitleaks` both pass.

---

## After the mode ships & merges

Resume the ORIGINAL task (tracked by tasks #1/#2/#3): re-run the arm-tell capture on merged PR #98 (`HavenEngineering/finance-erp-apps`, head `55fbd27a29764539bf14b13b1ef47ea32130d504`) with `analysis_only` active. It must now produce a real multi-finding report rendered to stdout plus a harvestable durable log, not a "review halted" stub. Then hand-diff the two durable-log bodies → rewrite `tests/ab/lib/arm_tells.json` → pause for maintainer review (scope was capture-only). The model-as-judge ban is permanent — blind human ranking is the sole quality adjudicator.

## Self-Review

**Spec coverage:**
- Goal (full pipeline, render to stdout, regardless of PR state) → Tasks 1 (anti-halt) + 3 (Stage 6 render) + 2 (Phase 0.4 render). ✓
- Edit A (resolve `analysis_only`) → Task 1, relocated to Stage 1 per the maintainer decision (resolve-once, SKILL.md-only) rather than the spec's Step 3.5 synced block, because Stage 1 needs the variable first. ✓
- Edit B (defeat MERGED short-circuit) → Task 1. ✓
- Edit C (suppress posting) → split into C1 (Phase 0.4, Task 2, byte-synced ×3 — the spec wrongly marked this SKILL.md-only) and C2 (Stage 6, Task 3, SKILL.md-only). ✓
- Harness activation → Task 4. ✓
- Non-goals honoured: no `review-core.mjs` change (Global Constraints); no Phase 0 narrative / CI-green bypass (untouched); no default behaviour change (all edits gated on `$ANALYSIS_ONLY = true`, default `false`). ✓
- Testing: sync gate (existing `test_sync_pipeline_inline_matches_canonical` covers Phase 0.4 byte-identity; Task 2 adds a unanimous-deletion guard); prose guards (Tasks 1, 3); harness round-trip (Task 4). ✓

**Placeholder scan:** every step shows the actual prose/code and the exact command with expected output. No TBD/TODO. ✓

**Type consistency:** `$ANALYSIS_ONLY` (Task 1) is the single variable read by Tasks 2 and 3; `orchestration.analysis_only` is the config key used consistently in Tasks 1 and 4; the literals asserted by tests (`Resolve \`orchestration.analysis_only\``, `Do not short-circuit on PR state under analysis-only`, `Phase 0 halt (analysis-only, not posted)`, `Analysis-only — render, do not post`, `Verdict (analysis-only, not submitted)`, `analysis_only = true`) each appear verbatim in both the edit step that writes them and the test step that asserts them. ✓

**Two flagged divergences from the spec's edit-site map** (both confirmed against code at `2f9442d`, both resolved with the maintainer via AskUserQuestion): Edit A relocated to Stage 1; Edit C's Phase 0.4 portion is byte-synced ×3, not SKILL.md-only. The plan reflects the corrected reality, not the spec's stale table.
