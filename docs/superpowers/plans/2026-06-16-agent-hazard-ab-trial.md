# Agent-Hazard Basis — Behavioural A/B Trial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the apparatus for, and run, a minimal matched-pair ablation that proves the agent-hazard severity basis (shipped in PR #52) fires on a genuinely misleading artefact and does not inflate a merely-vague one — at the review-synthesiser, scored mechanically, analysed with Fisher's exact + a Wilson interval.

**Architecture:** Reuse the existing per-agent A/B harness (`tests/ab/`). Add one additive `specialist_findings:` reconstruction path so the harness can drive the synthesiser (not just static specialists). Author two synthetic fixtures (a lying-comment "hit" and a vague-but-honest "near-miss"). Add an offline-testable severity scorer and a stats module. Run both fixtures through two arms (basis-absent vs basis-present) via a git-file-swap ablation wrapper, and record the outcome. The live trial is manual (it dispatches real models and costs tokens); everything else is unit-tested and runs in `tests/run.sh`.

**Tech Stack:** Bash + awk (harness, reconstruction, scorer), Python 3.11+ stdlib (stats — no scipy), `yq`/`jq`, the existing `tests/lib/harness.sh` test framework, `claude -p` per-agent dispatch.

---

## Scope boundary (do not creep)

- This plan validates ONE thing: the agent-hazard basis at the synthesiser. It does NOT tune any specialist's model/effort (separate future programme), does NOT add a model-as-judge scorer (permanent harness constraint), and does NOT edit any PR #52 file, the verdict rubric, or the basis wording. A weakness found by the trial becomes a follow-up spec, not an edit folded in here.
- The full design rationale lives in `docs/superpowers/specs/2026-06-16-agent-hazard-ab-trial-design.md` (status RESOLVED). This plan implements it; do not re-litigate the decided forks (synthesiser altitude, matched hit/near-miss pair, Fisher+Wilson, 5/cell with escalation).

## Key facts already verified (so you don't re-discover them)

- **Per-agent dispatch reads the agent body as the system prompt** (`tests/ab/lib/agent_dispatch.sh:113`, reads `plugins/code-review-suite/agents/<name>.md`) and reconstructs the user-message from `source.yaml` + `diff/changed-lines.txt` (`agent_dispatch_build_user_message`, line 56). In per-agent mode the agent-under-test is the **top-level** `claude -p` process, so its full report reaches stdout — the "subagent stdout doesn't propagate" problem (`tests/ab/README.md` "Capture under `claude -p`") only bites *end-to-end* mode, NOT this trial.
- **The synthesiser validates `$BASE` (regex `^[a-zA-Z0-9/_.\-]+$`), `$HEAD_SHA` (regex `^[0-9a-f]{40}$`), and runs `git diff` itself** during Context Gathering (`agents/review-synthesiser.md:41-70`). A synthetic fixture must therefore supply a syntactically valid base + 40-hex head SHA, and the working dir must let `git diff` succeed without surfacing a *different* planted defect. **This is the central feasibility risk — Task 1 resolves it before anything is built.**
- **The synthesiser encodes severity by TIER HEADING, not a per-finding `Severity:` bullet.** Consensus findings render under `### Critical` / `### Important` / `### Suggestions` as `#### Finding #N — [title] [domain]` (`agents/review-synthesiser.md:288-306`). The scorer must map the tier heading the planted finding lands under → severity. (Only Synthesiser-Findings and Contested blocks carry an explicit `- **Severity:**` bullet.)
- **Reclassification is the load-bearing change.** Pre-PR #52 the synthesiser quoted only the runtime-defect bar and would downgrade an agent-hazard Important to Suggestion; post-PR it keeps it (subject to guardrails). So arm A (basis absent) should downgrade the hit; arm B should keep it. The three PR #52 files (`includes/severity-definitions.md`, `agents/review-synthesiser.md`, `agents/correctness-reviewer.md`) at their pre-PR state are the parent of the first PR #52 commit `a5bc62d` — i.e. `git show 0c89cf6:<path>` (main tip before the feature branch).
- **Tests auto-discover:** `tests/run.sh` sources every `tests/lib/test_*.sh` and runs every `test_*` function via `declare -F`. New test functions need no registration. Helpers `_cr_dir` (in `tests/lib/test_sync_notes.sh`), `pass`/`fail`/`skip` (in `tests/lib/harness.sh`) are in scope.
- **Fixtures are gated, not globbed** — every fixture is registered in `tests/ab/corpus/index.yaml` (`tests/ab/README.md` "Fixture corpus"). Each has `source.yaml`, `diff/changed-lines.txt`, `expected/`.

## HARD CONSTRAINTS (CLAUDE.md, hook-enforced)

- **Bash: ONE command per call.** No `&&` / `||` / `;` / `$(...)` / backticks / subshells / `{ }`. Sole carve-out: the `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC (used by the commit steps below).
- Prefer Read/Edit/Write over cat/sed/awk/echo for file authoring. Temp files go under `$CLAUDE_TEMP_DIR` (this session's dir), never bare `/tmp`.
- `.editorconfig`: `.sh`/`.py`/`.mjs` = 4-space indent; `.md`/`.json`/`.yaml` = 2-space. LF endings, final newline on every file.
- **Stage files before re-running `tests/run.sh`** — the A/B "working tree clean" test (`test_ab_run_sh_rejects_unknown_config_key`) checks a whole-tree `git diff --quiet` and false-fails on UNSTAGED edits. `git add` before each `bash tests/run.sh`.
- Executables under `tests/ab/lib/` and `tests/ab/` keep their `+x` bit (the repo convention; check with `git ls-files -s`).

## File structure

| File | Responsibility | Change |
|---|---|---|
| `docs/superpowers/notes/2026-06-16-synth-feasibility.md` | Record the Task 1 spike outcome (working-dir strategy, SHA handling, sample report) | NEW (Task 1) |
| `tests/ab/lib/agent_dispatch.sh` | Per-agent user-message reconstruction | MODIFY — additive `review_mode:` + `specialist_findings:` emission (Task 2) |
| `tests/lib/test_ab_synth_dispatch.sh` | Structural lock on the reconstruction path | NEW (Task 2) |
| `tests/ab/corpus/synth-hazard-hit/` | Lying-comment fixture (bundle + diff + provenance + expected report) | NEW (Task 3) |
| `tests/ab/corpus/synth-hazard-nearmiss/` | Vague-but-honest fixture | NEW (Task 3) |
| `tests/ab/corpus/index.yaml` | Gated fixture registry | MODIFY — register both (Task 3) |
| `tests/ab/lib/synth_score.sh` | Extract the planted finding's tier/severity from a synthesiser report | NEW (Task 4) |
| `tests/lib/test_ab_synth_score.sh` | Unit tests for the scorer against committed sample reports | NEW (Task 4) |
| `tests/ab/lib/ab_stats.py` | Fisher's exact (firing) + Wilson interval (inflation), stdlib only | NEW (Task 5) |
| `tests/python/test_ab_stats.py` | Unit tests for the stats module | NEW (Task 5) |
| `tests/ab/configs/per-agent/synthesiser-baseline.yaml` | Synthesiser arm config (model/effort fixed) | NEW (Task 6) |
| `tests/ab/run-ablation.sh` | Two-arm wrapper: snapshot→swap→run→restore with a revert trap | NEW (Task 6) |
| `docs/superpowers/notes/2026-06-16-ab-trial-results.md` | Run protocol + recorded outcome + Fisher/Wilson numbers | NEW (Task 7) |

---

### Task 1: Feasibility spike — can we drive the synthesiser synthetically?

**Files:**
- Create: `docs/superpowers/notes/2026-06-16-synth-feasibility.md`

**Why:** The synthesiser validates SHAs and runs its own `git diff`. Before building fixtures and tooling around it, prove it can be driven in per-agent mode against a hand-authored findings bundle and produce a parseable tiered report — and decide how the fixture satisfies the git/SHA dependency. This is investigative, not TDD; its output is a committed findings note and a go/no-go.

- [ ] **Step 1: Confirm the harness clean-tree precondition and per-agent invocation shape**

Read `tests/ab/run.sh` around the per-agent entry (`_ab_run_per_agent`, ~line 216) and `tests/ab/lib/launch.sh` (`launch_run_per_agent_trial`, ~line 301). Confirm: per-agent mode does NOT require a clean tree (`tests/ab/README.md` "Preflight: same as end-to-end except no clean-tree check"), and the agent body is passed via `--append-system-prompt-file` with the user-message as the positional arg.

- [ ] **Step 2: Hand-author a throwaway probe bundle and drive the synthesiser once**

Create a scratch fixture dir under `$CLAUDE_TEMP_DIR/synth-probe/` with a `source.yaml` carrying: `base_sha` = `main`, a real 40-hex `head_sha` (use the current `git rev-parse HEAD` value — capture it in one Bash call, paste it into the file), `empty_tree_mode: false`, and a `specialist_findings` block containing ONE correctness finding rated Important on a real file+line in the current tree (e.g. a line in `tests/ab/README.md`). Add `diff/changed-lines.txt` naming that file+line. Manually build the user-message by hand (mirror `agent_dispatch_build_user_message`'s output, plus a `Review mode: pr` line and the specialist-findings block) and dispatch:

```bash
command claude -p --model sonnet --permission-mode bypassPermissions --append-system-prompt-file "$CLAUDE_TEMP_DIR/synth-probe/system-prompt.md" "$(cat "$CLAUDE_TEMP_DIR/synth-probe/user-message.txt")"
```

(The repo's one-command-per-Bash-call rule applies — assemble the system prompt file with the frontmatter-stripped synthesiser body in a prior step using `agent_dispatch_strip_frontmatter` or a manual Read+Write; do NOT chain.)

Expected: a `# Code Review Report` with a `### Important` (or `### Suggestions`) tier and a `#### Finding #N — …` block, plus a `## Verdict` block. If the synthesiser aborts on SHA/diff validation, that is the key finding.

- [ ] **Step 3: Resolve the working-dir strategy and record it**

Based on Step 2, decide and document ONE of:
- **(a) Live-tree, real SHA** — fixture uses `base_sha: main`, `head_sha:` = a real commit, runs in the repo worktree; the synthesiser's own `git diff` sees real (unrelated) changes but leans on the supplied bundle for the planted finding. Acceptable only if the probe shows the synthesiser reclassifies the *supplied* finding regardless of its own diff.
- **(b) Empty-tree mode** — fixture sets `empty_tree_mode: true`; the synthesiser's diff is the whole tree vs empty. Likely too noisy.
- **(c) Scratch worktree with a committed planted file** — a `working_dir_strategy` that materialises a tiny git repo containing exactly the planted file, so the synthesiser's own diff reproduces the planted artefact. Cleanest but heaviest.

Write `docs/superpowers/notes/2026-06-16-synth-feasibility.md` recording: the probe command, whether the synthesiser ran, the captured report excerpt, the chosen strategy (a/b/c) with justification, and any constraints the fixtures in Task 3 must honour (exact SHA shape, required prompt lines).

- [ ] **Step 4: Go/no-go**

If the synthesiser cannot be driven synthetically under any of (a)/(b)/(c), STOP and escalate to the maintainer — the trial may need to move to end-to-end altitude (a spec change). Otherwise record GO and the chosen strategy.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/notes/2026-06-16-synth-feasibility.md
git commit -m "$(cat <<'EOF'
docs(ab-trial): record synthesiser per-agent feasibility spike

Resolves the central risk before building fixtures: confirms the
review-synthesiser can be driven in per-agent mode against a hand-authored
findings bundle and fixes the working-dir/SHA strategy the fixtures use.
EOF
)"
```

---

### Task 2: Additive `specialist_findings:` reconstruction path

**Files:**
- Modify: `tests/ab/lib/agent_dispatch.sh` (`agent_dispatch_build_user_message`, lines 56-97)
- Create: `tests/lib/test_ab_synth_dispatch.sh`

**Why:** The synthesiser's input is a findings bundle + review-mode, which the current reconstructor (diff-only) does not emit. Add it additively: when `source.yaml` carries `review_mode:` and/or `specialist_findings:`, append them; when absent (every static-specialist fixture), output is byte-identical. A structural test locks both directions.

- [ ] **Step 1: Write the failing structural test**

Create `tests/lib/test_ab_synth_dispatch.sh` with LF endings, 4-space indent, final newline:

```bash
#!/usr/bin/env bash
# Locks the additive specialist_findings / review_mode reconstruction path in
# tests/ab/lib/agent_dispatch.sh. Absent keys => byte-identical passthrough;
# present keys => the synthesiser-shaped block is appended.

_synthdisp_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

test_ab_synth_dispatch_absent_keys_passthrough() {
    local root
    root=$(_synthdisp_repo_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/agent_dispatch.sh" ]]; then
        skip "synth dispatch passthrough" "agent_dispatch.sh not found"
        return
    fi

    local tmp out fixture
    tmp=$(mktemp -d)
    fixture="$tmp/fix"
    mkdir -p "$fixture/diff"
    cat > "$fixture/source.yaml" <<'YAML'
base_sha: main
head_sha: 0000000000000000000000000000000000000000
path_scope: ""
empty_tree_mode: false
intent_ledger: |
  ## Intent ledger
  - probe
YAML
    printf 'Changed lines:\n  bad.py: 1\n' > "$fixture/diff/changed-lines.txt"

    # shellcheck source=/dev/null
    REPO_ROOT="$root" source "$root/tests/ab/lib/agent_dispatch.sh"
    out="$tmp/out.txt"
    agent_dispatch_build_user_message "$fixture" "$out"

    if grep -qF 'Specialist findings' "$out"; then
        fail "synth dispatch passthrough: no bundle when key absent" \
            "unexpected 'Specialist findings' block in $out"
    else
        pass "synth dispatch passthrough: no bundle when key absent"
    fi
    if grep -qF 'Review mode:' "$out"; then
        fail "synth dispatch passthrough: no review-mode line when key absent" \
            "unexpected 'Review mode:' line in $out"
    else
        pass "synth dispatch passthrough: no review-mode line when key absent"
    fi
    rm -rf "$tmp"
}

test_ab_synth_dispatch_present_keys_emit_block() {
    local root
    root=$(_synthdisp_repo_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/agent_dispatch.sh" ]]; then
        skip "synth dispatch emit" "agent_dispatch.sh not found"
        return
    fi

    local tmp out fixture
    tmp=$(mktemp -d)
    fixture="$tmp/fix"
    mkdir -p "$fixture/diff"
    cat > "$fixture/source.yaml" <<'YAML'
base_sha: main
head_sha: 0000000000000000000000000000000000000000
path_scope: ""
empty_tree_mode: false
review_mode: pr
intent_ledger: |
  ## Intent ledger
  - probe
specialist_findings: |
  ### correctness-reviewer
  #### Finding — lying comment
  - **File:** lib/cache.py:42
  - **Severity:** Important
  - **Confidence:** 90
YAML
    printf 'Changed lines:\n  lib/cache.py: 42\n' > "$fixture/diff/changed-lines.txt"

    # shellcheck source=/dev/null
    REPO_ROOT="$root" source "$root/tests/ab/lib/agent_dispatch.sh"
    out="$tmp/out.txt"
    agent_dispatch_build_user_message "$fixture" "$out"

    local needle
    for needle in 'Review mode: pr' 'Specialist findings' 'correctness-reviewer' 'lib/cache.py:42'; do
        if grep -qF "$needle" "$out"; then
            pass "synth dispatch emit: contains '$needle'"
        else
            fail "synth dispatch emit: contains '$needle'" "not found in $out"
        fi
    done
    rm -rf "$tmp"
}
```

- [ ] **Step 2: Run the test to verify it fails (RED)**

```bash
bash tests/run.sh
```
Expected: `test_ab_synth_dispatch_present_keys_emit_block` FAILS its four `contains` assertions (the reconstructor does not yet emit the block). `test_ab_synth_dispatch_absent_keys_passthrough` PASSES already (current code emits neither). No other test regresses. (The known `test_ab_run_sh_rejects_unknown_config_key` clean-tree artifact may fail because the new file is unstaged — `git add tests/lib/test_ab_synth_dispatch.sh` first if you want it green; ignore otherwise.)

- [ ] **Step 3: Implement the additive emission**

In `tests/ab/lib/agent_dispatch.sh`, edit `agent_dispatch_build_user_message`. After the existing `path_scope`/`empty_tree_mode`/`intent_ledger` extraction (after line 77), add two more reads:

```bash
    local review_mode specialist_findings
    review_mode=$(yq -r '.review_mode // ""' "$source_yaml")
    specialist_findings=$(yq -r '.specialist_findings // ""' "$source_yaml")
```

Then inside the `{ … } > "$out"` block, emit the review-mode line near the top (after the `Empty tree mode` conditional, before the intent ledger) :

```bash
        if [[ -n "$review_mode" ]]; then
            printf 'Review mode: %s\n' "$review_mode"
        fi
```

And append the specialist-findings block at the END of the block, AFTER the existing two trailing `printf` instruction lines:

```bash
        if [[ -n "$specialist_findings" ]]; then
            printf '\n'
            printf 'Specialist findings:\n'
            printf '%s\n' "$specialist_findings"
        fi
```

Leave every existing line untouched — this is purely additive so the absent-key passthrough stays byte-identical.

- [ ] **Step 4: Stage and run to verify GREEN**

```bash
git add tests/ab/lib/agent_dispatch.sh tests/lib/test_ab_synth_dispatch.sh
```
```bash
bash tests/run.sh
```
Expected: both `test_ab_synth_dispatch_*` functions fully PASS; no regression elsewhere (record the final `N tests: …` line).

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/agent_dispatch.sh tests/lib/test_ab_synth_dispatch.sh
git commit -m "$(cat <<'EOF'
feat(ab-trial): reconstruct synthesiser input (review_mode + specialist_findings)

Additive path in agent_dispatch_build_user_message: when a fixture's
source.yaml carries review_mode/specialist_findings, emit them in the shape
the synthesiser expects. Absent keys (every static-specialist fixture) keep
byte-identical output, locked by test_ab_synth_dispatch.
EOF
)"
```

---

### Task 3: Author the matched hit / near-miss fixtures

**Files:**
- Create: `tests/ab/corpus/synth-hazard-hit/source.yaml`
- Create: `tests/ab/corpus/synth-hazard-hit/diff/changed-lines.txt`
- Create: `tests/ab/corpus/synth-hazard-hit/expected/report.md` (a captured arm-B report, filled in Task 7; placeholder now is NOT allowed — see Step 4)
- Create: `tests/ab/corpus/synth-hazard-nearmiss/source.yaml`
- Create: `tests/ab/corpus/synth-hazard-nearmiss/diff/changed-lines.txt`
- Modify: `tests/ab/corpus/index.yaml`

**Why:** The two fixtures ARE the experiment. Each supplies a correctness-reviewer finding rated Important; the only difference is whether the planted comment *actively misleads* (hit) or is *merely vague* (near-miss). The synthesiser's reclassification is what we measure. Honour the working-dir/SHA strategy fixed in Task 1's note — the literals below assume strategy (a) live-tree real SHA; if Task 1 chose (b) or (c), adjust `empty_tree_mode`/working-dir keys accordingly and keep everything else.

- [ ] **Step 1: Author the HIT fixture `source.yaml`**

The planted artefact is a lying comment. The supplied finding cites a concrete misleading mechanism and a named induced defect (clears the agent-hazard guardrail). Write `tests/ab/corpus/synth-hazard-hit/source.yaml` (2-space YAML, LF, final newline). Replace `<HEAD_SHA>` with the value Task 1's note fixed:

```yaml
id: synth-hazard-hit
agent: review-synthesiser
type: synthetic
captured_at: 2026-06-16T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: ""        # filled at first capture (Task 7)
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: live
base_sha: main
head_sha: <HEAD_SHA>
path_scope: ""
empty_tree_mode: false
review_mode: pr
planted:
  file: lib/cache.py
  line: 42
  expect_arm_b: Important   # firing: basis present keeps it Important
  expect_arm_a: Suggestion  # basis absent downgrades it
intent_ledger: |
  ## Intent ledger
  - goal: add a cache eviction helper
specialist_findings: |
  ### correctness-reviewer
  #### Finding — comment contradicts implementation
  - **File:** lib/cache.py:42
  - **Severity:** Important
  - **Confidence:** 90
  - **Description:** The docstring states "evicts the least-recently-used
    entry" but the implementation pops the MOST recently inserted key
    (`cache.popitem(last=True)`). A maintainer trusting the docstring will
    wire this into an LRU path and silently get MRU eviction — a concrete
    wrong-behaviour defect induced by the misleading comment.
  - **Suggested fix:** Correct the docstring to "evicts the most-recently
    inserted entry", or change the implementation to `popitem(last=False)`.
depends_on:
  - plugins/code-review-suite/agents/review-synthesiser.md
  - plugins/code-review-suite/includes/severity-definitions.md
  - plugins/code-review-suite/agents/correctness-reviewer.md
```

- [ ] **Step 2: Author the HIT fixture changed-lines**

Write `tests/ab/corpus/synth-hazard-hit/diff/changed-lines.txt` (LF, final newline):

```
Changed lines:
  lib/cache.py: 42
```

- [ ] **Step 3: Author the NEAR-MISS fixture**

The planted artefact is a vague-but-honest comment — it does NOT actively mislead, so under the guardrails it must drop to Suggestion in BOTH arms (the basis must not inflate it). Write `tests/ab/corpus/synth-hazard-nearmiss/source.yaml`:

```yaml
id: synth-hazard-nearmiss
agent: review-synthesiser
type: synthetic
captured_at: 2026-06-16T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: ""
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: live
base_sha: main
head_sha: <HEAD_SHA>
path_scope: ""
empty_tree_mode: false
review_mode: pr
planted:
  file: lib/cache.py
  line: 42
  expect_arm_b: Suggestion  # guardrail holds: vague != misleading
  expect_arm_a: Suggestion
intent_ledger: |
  ## Intent ledger
  - goal: add a cache eviction helper
specialist_findings: |
  ### correctness-reviewer
  #### Finding — comment could be more specific
  - **File:** lib/cache.py:42
  - **Severity:** Important
  - **Confidence:** 80
  - **Description:** The docstring says "handles eviction" without naming
    the policy. It is not inaccurate — the function does handle eviction —
    but a more specific comment would help. There is no contradiction
    between the comment and the code; nothing here would induce a wrong edit.
  - **Suggested fix:** Optionally expand the docstring to name the eviction
    policy. Low priority.
depends_on:
  - plugins/code-review-suite/agents/review-synthesiser.md
  - plugins/code-review-suite/includes/severity-definitions.md
  - plugins/code-review-suite/agents/correctness-reviewer.md
```

And `tests/ab/corpus/synth-hazard-nearmiss/diff/changed-lines.txt`:

```
Changed lines:
  lib/cache.py: 42
```

- [ ] **Step 4: Defer the `expected/report.md` capture**

Do NOT hand-fabricate `expected/report.md` — captured reports are recorded from a real run (Task 7), mirroring the corpus refresh workflow (`tests/ab/README.md` "Fixture refresh workflow"). Create the `expected/` directory with a `.gitkeep` so the path exists:

```bash
mkdir -p tests/ab/corpus/synth-hazard-hit/expected tests/ab/corpus/synth-hazard-nearmiss/expected
```
```bash
touch tests/ab/corpus/synth-hazard-hit/expected/.gitkeep tests/ab/corpus/synth-hazard-nearmiss/expected/.gitkeep
```

- [ ] **Step 5: Register both in the gated index**

Edit `tests/ab/corpus/index.yaml` — append two entries under `fixtures:` (2-space indent, matching the existing entries' shape):

```yaml
  - id: synth-hazard-hit
    agent: review-synthesiser
    type: synthetic
    description: Lying-comment fixture — docstring contradicts code (LRU vs MRU). Agent-hazard hit; arm B expected to keep Important, arm A to downgrade.
    tags: [agent-hazard, synthesiser]
  - id: synth-hazard-nearmiss
    agent: review-synthesiser
    type: synthetic
    description: Vague-but-honest comment fixture — no contradiction. Inflation guard; both arms expected Suggestion.
    tags: [agent-hazard, synthesiser]
```

- [ ] **Step 6: Stage and run the suite (sanity — no behavioural test yet)**

```bash
git add tests/ab/corpus/synth-hazard-hit tests/ab/corpus/synth-hazard-nearmiss tests/ab/corpus/index.yaml
```
```bash
bash tests/run.sh
```
Expected: suite green. (If a cross-reference test validates that every `index.yaml` id has a fixture dir with `source.yaml` + `diff/changed-lines.txt`, it now passes for the two new ids. If such a test asserts `expected/findings.json` exists, see Task 4 Step 6 — we add a tolerance for synthesiser fixtures there.)

- [ ] **Step 7: Commit**

```bash
git add tests/ab/corpus/synth-hazard-hit tests/ab/corpus/synth-hazard-nearmiss tests/ab/corpus/index.yaml
git commit -m "$(cat <<'EOF'
test(ab-trial): add matched hit/near-miss synthesiser fixtures

synth-hazard-hit plants a lying comment (docstring contradicts code) that
clears the agent-hazard guardrail; synth-hazard-nearmiss plants a vague-but-
honest comment that must not inflate. Both supply a correctness Important
finding; the synthesiser's reclassification is the measured bit.
EOF
)"
```

---

### Task 4: Synthesiser severity scorer

**Files:**
- Create: `tests/ab/lib/synth_score.sh`
- Create: `tests/lib/test_ab_synth_score.sh`
- Create: `tests/ab/corpus/synth-hazard-hit/expected/sample-report-important.md` (a small hand-authored synthesiser report used ONLY as scorer test input — distinct from the live `report.md` captured in Task 7)
- Create: `tests/ab/corpus/synth-hazard-hit/expected/sample-report-suggestion.md`

**Why:** The trial's objective bit is "which tier did the planted finding land under." Scoring must be mechanical and offline-testable. The scorer reads a synthesiser report + a planted `file:line` and emits the tier-derived severity (`Critical|Important|Suggestion|Dismissed|Contested|ABSENT`). Sample reports (hand-authored, small) are the scorer's deterministic test corpus — they exercise the parser, not the model.

- [ ] **Step 1: Author the two sample reports (scorer test inputs)**

Write `tests/ab/corpus/synth-hazard-hit/expected/sample-report-important.md` (LF, final newline) — a minimal but format-faithful synthesiser report where the planted finding sits under `### Important`:

```markdown
# Code Review Report

## Summary
One correctness finding.

## Verdict
Verdict: REQUEST_CHANGES
Rubric row applied: 3
Reason: A misleading docstring will induce a wrong edit [#1].

## Consensus Findings

### Important
#### Finding #1 — comment contradicts implementation [correctness]
- **File:** lib/cache.py:42
- **Confidence:** 90
- **Description:** Docstring says LRU; code does MRU.
- **Suggested fix:** Fix the docstring.
- **Synthesiser:** Agree — agent-hazard basis applies.
```

Write `tests/ab/corpus/synth-hazard-hit/expected/sample-report-suggestion.md` — identical except the finding sits under `### Suggestions` and the verdict is APPROVE:

```markdown
# Code Review Report

## Summary
One low-severity nit.

## Verdict
Verdict: APPROVE
Rubric row applied: 4
Reason: Nothing blocks [#1].

## Consensus Findings

### Suggestions
#### Finding #1 — comment could be more specific [correctness]
- **File:** lib/cache.py:42
- **Confidence:** 80
- **Description:** Docstring is vague but accurate.
- **Suggested fix:** Optionally expand it.
- **Synthesiser:** Agree — does not mislead, Suggestion only.
```

- [ ] **Step 2: Write the failing scorer test**

Create `tests/lib/test_ab_synth_score.sh` (4-space indent, LF, final newline):

```bash
#!/usr/bin/env bash
# Unit tests for tests/ab/lib/synth_score.sh — maps the tier heading a planted
# finding lands under to a severity token. Pure parser; no model calls.

_synthscore_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

test_ab_synth_score_important() {
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score important" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report="$root/tests/ab/corpus/synth-hazard-hit/expected/sample-report-important.md"
    local got
    got=$(synth_score_severity "$report" "lib/cache.py" "42")
    if [[ "$got" == "Important" ]]; then
        pass "synth score: important report scores Important"
    else
        fail "synth score: important report scores Important" "got '$got'"
    fi
}

test_ab_synth_score_suggestion() {
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score suggestion" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report="$root/tests/ab/corpus/synth-hazard-hit/expected/sample-report-suggestion.md"
    local got
    got=$(synth_score_severity "$report" "lib/cache.py" "42")
    if [[ "$got" == "Suggestion" ]]; then
        pass "synth score: suggestion report scores Suggestion"
    else
        fail "synth score: suggestion report scores Suggestion" "got '$got'"
    fi
}

test_ab_synth_score_absent() {
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score absent" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report="$root/tests/ab/corpus/synth-hazard-hit/expected/sample-report-important.md"
    local got
    got=$(synth_score_severity "$report" "lib/other.py" "99")
    if [[ "$got" == "ABSENT" ]]; then
        pass "synth score: unplanted file scores ABSENT"
    else
        fail "synth score: unplanted file scores ABSENT" "got '$got'"
    fi
}
```

- [ ] **Step 3: Run to verify it fails (RED)**

```bash
bash tests/run.sh
```
Expected: the three `test_ab_synth_score_*` functions SKIP (scorer file absent yet) — which is not a failure. To get a true RED, create an empty `tests/ab/lib/synth_score.sh` first (so the file exists but the function is undefined), then re-run; expect FAIL "got ''". Either ordering is acceptable; the point is the test cannot pass before Step 4.

- [ ] **Step 4: Implement the scorer**

Write `tests/ab/lib/synth_score.sh` (4-space indent, LF, final newline, `+x` not required — it is sourced):

```bash
#!/usr/bin/env bash
# tests/ab/lib/synth_score.sh — extract the severity tier a planted finding
# lands under in a synthesiser report. The synthesiser encodes severity by
# tier HEADING (### Critical / ### Important / ### Suggestions), not a per-
# finding Severity bullet, so we track the current tier and the current
# ## section, then match the planted file:line inside a #### Finding block.
set -euo pipefail

# synth_score_severity <report.md> <file> <line>
# Emits one of: Critical | Important | Suggestion | Contested | Dismissed | ABSENT
synth_score_severity() {
    local report="$1"
    local pfile="$2"
    local pline="$3"
    if [[ ! -f "$report" ]]; then
        echo "synth_score_severity: $report: not found" >&2
        return 1
    fi

    awk -v pfile="$pfile" -v pline="$pline" '
        BEGIN { section=""; tier=""; result="ABSENT" }
        # Top-level sections.
        /^## Dismissed Findings$/ { section="dismissed"; tier=""; next }
        /^## Contested Findings$/ { section="contested"; tier=""; next }
        /^## Consensus Findings$/ { section="consensus"; tier=""; next }
        /^## Synthesiser Findings$/ { section="synthesiser"; tier=""; next }
        /^## / { section="other"; tier=""; next }
        # Tier sub-headings within Consensus.
        /^### Critical$/    { tier="Critical"; next }
        /^### Important$/   { tier="Important"; next }
        /^### Suggestions$/ { tier="Suggestion"; next }
        # A finding boundary resets the per-finding file capture.
        /^#### Finding / { infile=""; next }
        # File bullet — accept "path:line" or a bare "path".
        /^- \*\*File:\*\* / {
            v=$0
            sub(/^- \*\*File:\*\* /, "", v)
            gsub(/`/, "", v)
            infile=v
            # If File carries :line, check immediately.
            target=pfile ":" pline
            if (v == target) {
                if (section=="dismissed") result="Dismissed"
                else if (section=="contested") result="Contested"
                else if (tier!="") result=tier
            }
            next
        }
        # Separate Line bullet (when File had no :line suffix).
        /^- \*\*Line:\*\* / {
            v=$0
            sub(/^- \*\*Line:\*\* /, "", v)
            gsub(/`/, "", v)
            if (infile==pfile && v==pline) {
                if (section=="dismissed") result="Dismissed"
                else if (section=="contested") result="Contested"
                else if (tier!="") result=tier
            }
            next
        }
        END { print result }
    ' "$report"
}
```

- [ ] **Step 5: Stage and run to verify GREEN**

```bash
git add tests/ab/lib/synth_score.sh tests/lib/test_ab_synth_score.sh tests/ab/corpus/synth-hazard-hit/expected/sample-report-important.md tests/ab/corpus/synth-hazard-hit/expected/sample-report-suggestion.md
```
```bash
bash tests/run.sh
```
Expected: the three `test_ab_synth_score_*` PASS; suite green.

- [ ] **Step 6: If a corpus cross-reference test now fails on the synthesiser fixtures**

If `tests/run.sh` has a test asserting every fixture carries `expected/findings.json` (the static-specialist contract), it will fail for the synthesiser fixtures, which use `expected/report.md` instead. Find it:

```bash
grep -rln "findings.json" tests/lib
```
If such an assertion exists, narrow it to skip fixtures whose `index.yaml` `agent` is `review-synthesiser` (they are scored by tier, not tuple). Make the minimal edit, re-stage, re-run. If no such test exists, skip this step.

- [ ] **Step 7: Commit**

```bash
git add tests/ab/lib/synth_score.sh tests/lib/test_ab_synth_score.sh tests/ab/corpus/synth-hazard-hit/expected/sample-report-important.md tests/ab/corpus/synth-hazard-hit/expected/sample-report-suggestion.md
git commit -m "$(cat <<'EOF'
feat(ab-trial): synthesiser severity scorer (tier-heading derived)

synth_score_severity maps the tier heading a planted file:line lands under
to a severity token, with Dismissed/Contested/ABSENT handling. Unit-tested
against small hand-authored sample reports — pure parser, no model calls.
EOF
)"
```

---

### Task 5: Statistics module (Fisher's exact + Wilson interval)

**Files:**
- Create: `tests/ab/lib/ab_stats.py`
- Create: `tests/python/test_ab_stats.py`

**Why:** The firing claim needs a two-tailed Fisher's exact test on the hit-fixture 2×2; the inflation claim needs a Wilson 95% interval on the near-miss arm-B rate. Stdlib only (no scipy) — small n makes exact computation trivial. Offline, fully deterministic, unit-tested.

- [ ] **Step 1: Write the failing tests**

Create `tests/python/test_ab_stats.py` (4-space indent, LF, final newline):

```python
import math
import os
import sys

sys.path.insert(
    0,
    os.path.join(os.path.dirname(__file__), "..", "ab", "lib"),
)

import ab_stats  # noqa: E402


def test_fisher_clean_separation_is_significant():
    # arm A: 0/5 Important, arm B: 5/5 Important.
    p = ab_stats.fisher_exact_two_tailed(a=0, b=5, c=5, d=0)
    assert p < 0.05
    assert math.isclose(p, 0.007936507936507936, rel_tol=1e-9)


def test_fisher_no_difference_is_not_significant():
    # arm A: 3/5, arm B: 3/5 — identical, p == 1.0.
    p = ab_stats.fisher_exact_two_tailed(a=3, b=2, c=3, d=2)
    assert math.isclose(p, 1.0, rel_tol=1e-9)


def test_wilson_interval_zero_of_five():
    lo, hi = ab_stats.wilson_interval(successes=0, n=5)
    assert math.isclose(lo, 0.0, abs_tol=1e-9)
    assert 0.40 < hi < 0.46  # upper bound for 0/5 at 95% is ~0.4366


def test_wilson_interval_all_of_five():
    lo, hi = ab_stats.wilson_interval(successes=5, n=5)
    assert 0.54 < lo < 0.60
    assert math.isclose(hi, 1.0, abs_tol=1e-9)


def test_wilson_handles_zero_n():
    lo, hi = ab_stats.wilson_interval(successes=0, n=0)
    assert lo == 0.0 and hi == 0.0
```

- [ ] **Step 2: Run to verify it fails (RED)**

```bash
python3 -m pytest tests/python/test_ab_stats.py -v
```
Expected: collection/import error or FAIL — `ab_stats` does not exist yet.

- [ ] **Step 3: Implement the stats module**

Write `tests/ab/lib/ab_stats.py` (4-space indent, LF, final newline):

```python
"""Exact small-sample statistics for the agent-hazard A/B trial.

Stdlib only. The 2x2 table is laid out as:

                Important   not-Important
    arm A          a              b
    arm B          c              d
"""

from math import comb, sqrt


def _hypergeom_pmf(a, b, c, d):
    """P(this exact table | fixed margins), the hypergeometric weight."""
    row1 = a + b
    row2 = c + d
    col1 = a + c
    n = a + b + c + d
    return (comb(row1, a) * comb(row2, c)) / comb(n, col1)


def fisher_exact_two_tailed(a, b, c, d):
    """Two-tailed Fisher's exact p-value for a 2x2 table.

    Sums the probability of every table (with the same margins) whose
    hypergeometric weight is <= that of the observed table.
    """
    n = a + b + c + d
    if n == 0:
        return 1.0
    row1 = a + b
    col1 = a + c
    observed = _hypergeom_pmf(a, b, c, d)
    tol = observed * (1 + 1e-7)
    total = 0.0
    a_min = max(0, col1 - (c + d))
    a_max = min(row1, col1)
    for ai in range(a_min, a_max + 1):
        bi = row1 - ai
        ci = col1 - ai
        di = (c + d) - ci
        if bi < 0 or ci < 0 or di < 0:
            continue
        p = _hypergeom_pmf(ai, bi, ci, di)
        if p <= tol:
            total += p
    return min(1.0, total)


def wilson_interval(successes, n, z=1.959963984540054):
    """Wilson score 95% confidence interval for a binomial proportion."""
    if n == 0:
        return (0.0, 0.0)
    phat = successes / n
    denom = 1 + z * z / n
    centre = (phat + z * z / (2 * n)) / denom
    margin = (z * sqrt(phat * (1 - phat) / n + z * z / (4 * n * n))) / denom
    return (max(0.0, centre - margin), min(1.0, centre + margin))
```

- [ ] **Step 4: Run to verify GREEN**

```bash
python3 -m pytest tests/python/test_ab_stats.py -v
```
Expected: 5 passed.

- [ ] **Step 5: Confirm the suite picks up Python tests (or note it doesn't)**

```bash
bash tests/run.sh
```
If `tests/run.sh` runs `pytest tests/python` as part of its flow, expect it green. If it does not invoke pytest, the Python tests stand alone (run them directly) — do NOT wire pytest into `run.sh` as part of this task unless the runner already has a Python hook; that would be scope creep. Note which is the case.

- [ ] **Step 6: Commit**

```bash
git add tests/ab/lib/ab_stats.py tests/python/test_ab_stats.py
git commit -m "$(cat <<'EOF'
feat(ab-trial): exact small-sample stats (Fisher two-tailed + Wilson)

Stdlib-only Fisher's exact for the firing 2x2 and a Wilson score interval
for the inflation rate. Unit-tested against known values (0/5 vs 5/5 =>
p~=0.0079; Wilson bounds for 0/5 and 5/5).
EOF
)"
```

---

### Task 6: Two-arm ablation runner

**Files:**
- Create: `tests/ab/configs/per-agent/synthesiser-baseline.yaml`
- Create: `tests/ab/run-ablation.sh`

**Why:** The ablation swaps the three PR #52 files between their pre-PR text (arm A) and current text (arm B), runs N per-agent trials per arm per fixture, scores each, and restores the files on every exit path. It mirrors the existing harness's mutate-then-revert discipline (`tests/ab/lib/mutate.sh`: trap on `EXIT/INT/TERM/HUP`, `MANUAL_REVERT_REQUIRED` sentinel on failed restore).

- [ ] **Step 1: Author the synthesiser per-agent config**

Write `tests/ab/configs/per-agent/synthesiser-baseline.yaml` (2-space YAML, LF, final newline):

```yaml
name: synthesiser-baseline
description: Synthesiser per-agent arm for the agent-hazard ablation. Model/effort fixed; the ablation varies only the basis text via run-ablation.sh file swap.
mode: per-agent
agent: review-synthesiser
session:
  model: opus
  effort: default
```

(Opus is the production synthesiser model — `agents/review-synthesiser.md:4`. The ablation is about the basis text, not model tuning, so both arms hold model fixed.)

- [ ] **Step 2: Implement the ablation wrapper**

Write `tests/ab/run-ablation.sh` (4-space indent, LF, final newline, `chmod +x`). It does NOT itself call `claude` — it swaps files and delegates each arm to `tests/ab/run.sh --mode per-agent`. The pre-PR blobs come from `0c89cf6` (main tip before the feature branch; verify with `git log` that this is the parent of `a5bc62d`):

```bash
#!/usr/bin/env bash
# tests/ab/run-ablation.sh — two-arm ablation for the agent-hazard basis.
# Arm B = working-tree (basis present). Arm A = the three PR #52 files reverted
# to their pre-PR blob. Restores on every exit path.
#
# Usage:
#   tests/ab/run-ablation.sh --fixture <id> --trials <n> [--pre-pr-ref <sha>]
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
PRE_PR_REF="0c89cf6"
FIXTURE=""
TRIALS="5"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fixture) FIXTURE="$2"; shift 2 ;;
        --trials) TRIALS="$2"; shift 2 ;;
        --pre-pr-ref) PRE_PR_REF="$2"; shift 2 ;;
        *) echo "run-ablation.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$FIXTURE" ]]; then
    echo "run-ablation.sh: --fixture <id> is required" >&2
    exit 2
fi

FILES=(
    "plugins/code-review-suite/includes/severity-definitions.md"
    "plugins/code-review-suite/agents/review-synthesiser.md"
    "plugins/code-review-suite/agents/correctness-reviewer.md"
)

BACKUP_DIR=$(mktemp -d)
RESTORE_FAILED=0

restore_arm_b() {
    local f
    for f in "${FILES[@]}"; do
        if [[ -f "$BACKUP_DIR/$(basename "$f")" ]]; then
            cp "$BACKUP_DIR/$(basename "$f")" "$REPO_ROOT/$f" || RESTORE_FAILED=1
        fi
    done
    if [[ "$RESTORE_FAILED" == "1" ]]; then
        echo "MANUAL_REVERT_REQUIRED — restore the three PR #52 files from git" >&2
        touch "$REPO_ROOT/tests/ab/MANUAL_REVERT_REQUIRED"
    fi
}
trap restore_arm_b EXIT INT TERM HUP

# Snapshot arm-B (working tree) copies up front.
for f in "${FILES[@]}"; do
    cp "$REPO_ROOT/$f" "$BACKUP_DIR/$(basename "$f")"
done

run_one_arm() {
    local arm="$1"
    echo "=== ARM $arm — fixture $FIXTURE, $TRIALS trials ==="
    "$REPO_ROOT/tests/ab/run.sh" \
        --config "$REPO_ROOT/tests/ab/configs/per-agent/synthesiser-baseline.yaml" \
        --corpus "$FIXTURE" \
        --trials "$TRIALS" \
        --name "ablation-arm-${arm}-${FIXTURE}" \
        --stream-json
}

# Arm B first (files already in working-tree state).
run_one_arm B

# Swap the three files to their pre-PR blob for arm A.
for f in "${FILES[@]}"; do
    git -C "$REPO_ROOT" show "${PRE_PR_REF}:${f}" > "$REPO_ROOT/$f"
done

run_one_arm A

# trap restores arm B on exit.
echo "Ablation complete. Score each run dir with tests/ab/lib/synth_score.sh and"
echo "feed counts to tests/ab/lib/ab_stats.py (see docs/.../ab-trial-results.md)."
```

- [ ] **Step 3: Make it executable and verify it parses**

```bash
chmod +x tests/ab/run-ablation.sh
```
```bash
bash -n tests/ab/run-ablation.sh
```
Expected: no output (syntax OK). Do NOT run it for real here — it dispatches Opus and costs tokens; the real run is Task 7.

- [ ] **Step 4: Verify the pre-PR ref is correct**

```bash
git log --oneline -1 0c89cf6
```
Expected: this is the commit immediately before `a5bc62d` (the first PR #52 commit). If the branch base differs, pass the correct ref via `--pre-pr-ref` in Task 7 and note it. Confirm the three files differ between the refs:

```bash
git diff --stat 0c89cf6 HEAD -- plugins/code-review-suite/includes/severity-definitions.md plugins/code-review-suite/agents/review-synthesiser.md plugins/code-review-suite/agents/correctness-reviewer.md
```
Expected: three files changed (the PR #52 edits).

- [ ] **Step 5: Commit**

```bash
git add tests/ab/configs/per-agent/synthesiser-baseline.yaml tests/ab/run-ablation.sh
git commit -m "$(cat <<'EOF'
feat(ab-trial): two-arm ablation runner for the agent-hazard basis

run-ablation.sh snapshots the three PR #52 files, runs arm B (basis present)
then swaps them to their pre-PR blob for arm A, delegating each arm to the
per-agent harness. Restores on every exit path with a MANUAL_REVERT_REQUIRED
sentinel, mirroring mutate.sh discipline.
EOF
)"
```

---

### Task 7: Run the trial and record the outcome (manual)

**Files:**
- Create: `docs/superpowers/notes/2026-06-16-ab-trial-results.md`
- Create (captured): `tests/ab/corpus/synth-hazard-hit/expected/report.md`, `tests/ab/corpus/synth-hazard-nearmiss/expected/report.md`

**Why:** This is the actual experiment. It dispatches real Opus trials, so it is manual and gated on a valid Bedrock SSO token (`tests/ab/README.md` "Preconditions"). The apparatus from Tasks 2-6 makes it mechanical to run and score.

- [ ] **Step 1: Preconditions**

Confirm a clean working tree (commit/stash any pending edits first), a valid AWS SSO token for the Bedrock account, and tools on PATH (`yq`, `jq`, `gh`, `git`, `gtimeout`). The ablation runner restores files but starts from the working tree — it must be clean.

- [ ] **Step 2: Run the hit fixture, both arms, 5 trials each**

```bash
tests/ab/run-ablation.sh --fixture synth-hazard-hit --trials 5
```
This produces run dirs under `tests/ab/runs/` for arm B and arm A. If `0c89cf6` was not the branch base (Task 6 Step 4), add `--pre-pr-ref <correct-sha>`.

- [ ] **Step 3: Run the near-miss fixture, both arms, 5 trials each**

```bash
tests/ab/run-ablation.sh --fixture synth-hazard-nearmiss --trials 5
```

- [ ] **Step 4: Score every trial**

For each run dir's per-trial `stdout.log` (the synthesiser report), score the planted finding's tier. The planted `file:line` is `lib/cache.py:42` for both fixtures (from `source.yaml.planted`). For each trial:

```bash
tests/ab/lib/synth_score.sh
```
is sourced, not executed — instead, for each trial run dir, call the function. Practical recipe (one Bash call per trial, or a small scoring loop committed as a scratch script under `$CLAUDE_TEMP_DIR`): source `synth_score.sh`, then `synth_score_severity <trial>/stdout.log lib/cache.py 42`. Tally, per arm per fixture, how many trials scored `Important` (or `Critical`).

- [ ] **Step 5: Compute the statistics**

Build the hit-fixture 2×2 (arm A Important-count = `a`, arm A not = `b`, arm B Important-count = `c`, arm B not = `d`) and run:

```bash
python3 -c "import sys; sys.path.insert(0,'tests/ab/lib'); import ab_stats; print(ab_stats.fisher_exact_two_tailed(a=A, b=B, c=C, d=D))"
```
(substitute the real counts). For the near-miss arm-B inflation rate:

```bash
python3 -c "import sys; sys.path.insert(0,'tests/ab/lib'); import ab_stats; print(ab_stats.wilson_interval(successes=S, n=5))"
```
(`S` = near-miss arm-B trials that wrongly scored Important).

- [ ] **Step 6: Apply the decision rule and escalate if ambiguous**

- **Validated** iff: the hit 2×2 Fisher p < 0.05 with arm B skewed toward Important (clear A→B shift) AND the near-miss arm-B inflation Wilson upper bound is acceptably low (record the number; the design treats inflation as an actionable finding, not a hard threshold).
- **Ambiguous** (hit split borderline, p ≥ 0.05): top the hit cells up to 10 trials each (`--trials 10`) and recompute before concluding.
- **Failed firing** (arm A ≈ arm B): the basis is not changing synthesiser behaviour — record and escalate; do not claim validation.

- [ ] **Step 7: Capture the canonical reports and stamp provenance**

Pick one representative arm-B trial report per fixture, copy it to `expected/report.md`, and update each `source.yaml`'s `captured_under.suite_sha` to the current suite SHA (`git rev-parse HEAD`):

```bash
git rev-parse HEAD
```
Then write the two `report.md` files from the chosen trial stdout (Read the trial stdout, Write the report). Edit the two `source.yaml` `suite_sha:` values.

- [ ] **Step 8: Write the results note**

Create `docs/superpowers/notes/2026-06-16-ab-trial-results.md` recording: the run command(s), the per-arm per-fixture Important counts, the Fisher p-value, the Wilson interval, the decision-rule outcome, the verdict (VALIDATED / AMBIGUOUS / FAILED), and any follow-up the result triggers (e.g. guardrail wording if the near-miss inflated). Reference the spec and PR #52.

- [ ] **Step 9: Commit**

```bash
git add docs/superpowers/notes/2026-06-16-ab-trial-results.md tests/ab/corpus/synth-hazard-hit/expected/report.md tests/ab/corpus/synth-hazard-nearmiss/expected/report.md tests/ab/corpus/synth-hazard-hit/source.yaml tests/ab/corpus/synth-hazard-nearmiss/source.yaml
git commit -m "$(cat <<'EOF'
test(ab-trial): record agent-hazard basis ablation results

Captures the two-arm (basis absent vs present) outcome for the hit and
near-miss fixtures: per-arm Important counts, Fisher's exact p-value, the
near-miss Wilson inflation interval, and the decision-rule verdict. Stamps
the captured canonical reports and suite SHA into the fixtures.
EOF
)"
```

- [ ] **Step 10: STOP — report to the maintainer**

Surface the verdict (VALIDATED / AMBIGUOUS / FAILED) and the numbers. If VALIDATED, note that PR #52's "Validation status" caveat can now be discharged. Do not open or merge any PR autonomously — ask.

---

## Self-review

- **Spec coverage:** one objective bit → Task 4 scorer. Synthesiser altitude → Tasks 2/6 drive `review-synthesiser`. Matched hit/near-miss pair → Task 3. New `specialist_findings` plumbing (additive, guarded) → Task 2 + its structural test. Ablation via mutate-then-revert → Task 6. Faithfulness-capture-first de-risking → Task 1 (front-loaded) + Task 7 Step 7 canonical capture. Fisher (firing) + Wilson (inflation) + escalation → Task 5 + Task 7 Steps 5-6. No-model-as-judge → scoring is tier-string matching (Task 4), never an LLM grader. Per-specialist tuning explicitly OUT → Scope boundary. All spec items routed.
- **Placeholder scan:** every code/markdown step shows full literal content and exact commands with expected output. The two deliberately-deferred captures (`expected/report.md`, the `<HEAD_SHA>` token, `suite_sha`) are explicitly flagged as captured-at-runtime per the documented corpus-refresh workflow, not left as silent TBDs — and Task 1 fixes the `<HEAD_SHA>` value the Task 3 fixtures consume.
- **Type/literal consistency:** the scorer function is `synth_score_severity` in Task 4's implementation, its test, and Task 7's scoring step. The stats functions are `fisher_exact_two_tailed(a,b,c,d)` and `wilson_interval(successes,n)` identically in Task 5's module, its tests, and Task 7's invocation. The reconstruction keys `review_mode` / `specialist_findings` match between Task 2's code, its test, and Task 3's fixtures. The planted anchor `lib/cache.py:42` is identical across both fixtures, the sample reports, the scorer tests, and Task 7's scoring. The pre-PR ref `0c89cf6` is used in Task 6's runner default and verified in Task 6 Step 4 / Task 7 Step 2.
- **Risk handling:** the one genuine feasibility risk (driving the synthesiser synthetically given its own git-diff/SHA validation) is isolated in Task 1 with an explicit go/no-go and escalation path BEFORE any apparatus is built, so a dead end costs one spike rather than the whole build.
```
