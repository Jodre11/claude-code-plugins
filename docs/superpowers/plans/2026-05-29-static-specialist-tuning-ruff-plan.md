# Static-specialist tuning — ruff-reviewer Haiku/low directional probe (Phase 3.1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether `ruff-reviewer` running at Haiku/low produces a finding set byte-identical to the Phase 2b Sonnet/default baseline (3 trials, hash-match), and if so, adopt Haiku/low for the production `ruff-reviewer` agent. If not, document the failure and leave production unchanged.

**Architecture:** A single new per-agent config file (`tests/ab/configs/per-agent/ruff-haiku-low.yaml`) varies model+effort externally — the harness drives all variation; the production agent file is unaware it is being tested. The probe runs 3 trials of the new config against the existing `ruff-smoke-bad-py` corpus fixture under `--faithfulness-check`, comparing each trial's `findings.json` against the canonical baseline at hash `7b003236...`. The verdict gates one production edit: `plugins/code-review-suite/agents/ruff-reviewer.md` frontmatter `model: sonnet` → `model: haiku`. No new harness code is required — this plan is the first real *use* of the Phase 2 chassis.

**Tech Stack:** The Phase 2 per-agent harness (`tests/ab/run.sh --mode per-agent --faithfulness-check`), the existing `lib/config.sh` validator, the existing `lib/agent_capture.sh` parser, and the existing `lib/agent_dispatch.sh` reconstruction. No new Bash, Bedrock, or tooling dependencies.

**Spec:** [`docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`](../specs/2026-05-29-static-specialist-tuning-sweep.md). Phase 3.1 is the strict subset of the spec covering only `ruff-reviewer`. The methodology is locked: do not relitigate the directional-probe approach. Surface defects to the operator before changing the spec.

**Driving question:** Is `ruff-reviewer` on Haiku at low effort byte-identical to the captured Sonnet/default baseline on finding sets across 3 trials?

**Cost expectation:** ~30k Bedrock tokens for 3 trials, ~3 minutes wall-clock for the live-fire step. Total Phase 3.1 wall-clock ~1 hour including plan execution and PR.

---

## Pre-flight context

Read these before executing — they will not be in your fresh subagent's context:

1. **Spec:** `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md` — Step 4 (directional probe), Step 5 (one-page report), and Step 6 (richer-fixture follow-up, **out of Phase 3.1 scope**).
2. **Phase 2b stop-and-investigate rules:** `docs/superpowers/plans/2026-05-28-per-agent-harness-phase-2-plan.md` Task 9 Step 6 — same rules apply here (no blind retries on INCONCLUSIVE / empty stdout / unexpected non-zero / wall-clock > 60s).
3. **Per-agent harness usage:** `tests/ab/README.md` § "Per-agent mode (Phase 2)" — usage, output layout, and three load-bearing implementation notes (empirically ground parsers, CLI flag spellings, `effort: default` sentinel).
4. **Auto-memory:** `feedback_models_overlook_tuning_hooks` — variation must flow through the harness, never via a runtime hook on the production agent. The frontmatter `model:` edit is a permanent change, not a hook.

## Branching

Branch off `main` at `b214944` (the Phase 2 squash-merge SHA) as `feat/per-agent-tuning-ruff-haiku-low`. Phase 3.1 should not be branched off the current `chore/phase-3-handover` branch — that branch carries only the handover doc; the plan and the experiment work go on a fresh branch from `main`.

## Housekeeping no-op note

The producing session of the handover already audited GitHub Actions and runner pins on `main`:

- `actions/checkout` → `de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2` matches `gh api repos/actions/checkout/releases/latest`.
- `gitleaks/gitleaks-action` → `ff98106e4c7b2bc287b24eaf42907196329070c7 # v2.3.9` matches latest.
- `runs-on: ubuntu-24.04` is the current standard pin.

No housekeeping PR is required. If you want to re-verify, run the three `gh api` calls; otherwise treat this as a no-op and proceed.

## File Structure

**New files (Phase 3.1):**

| Path | Responsibility |
|---|---|
| `tests/ab/configs/per-agent/ruff-haiku-low.yaml` | Probe arm: same shape as `ruff-baseline.yaml` but `session.model: haiku`, `session.effort: low`. The single externally-driven configuration change that the entire Phase 3.1 verdict depends on. |
| `docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md` | One-page comparison report capturing the verdict (equivalent | better | worse | inconclusive), per-trial hashes, wall-clock per arm, and the production-adoption recommendation. New `notes/` directory; create as part of this task. |

**Modified files (Phase 3.1):**

| Path | Change | Conditional |
|---|---|---|
| `tests/lib/test_ab_per_agent_lib.sh` | Add a structural test asserting the new config parses via `config_load` and exposes `_AB_CONFIG_SESSION_MODEL=haiku`, `_AB_CONFIG_SESSION_EFFORT=low`. | Always. |
| `plugins/code-review-suite/agents/ruff-reviewer.md` | Frontmatter line 4: `model: sonnet` → `model: haiku`. | **Only if the probe passes 3/3.** This is the actual cost optimisation Phase 3.1 exists to enable. |

**Out of scope for Phase 3.1 (do not create):**

- per-agent configs / fixtures / probe runs for `eslint-reviewer`, `trivy-reviewer`, `jbinspect-reviewer` — separate plans for Phase 3.2, 3.3, 3.4.
- a richer ruff fixture (Step 6 of the spec) — only triggered by a probe failure, only after operator approval.
- any modification to the `ruff-smoke-bad-py` corpus fixture, the canonical baseline, or any `lib/` file. Phase 3.1 reuses the harness chassis as-is.
- any change to `summary.csv` schema, manifest schema, or the comparison helper.

---

## Important context for implementers

Three details that are easy to miss:

1. **`effort: low` is a real CLI value, distinct from `effort: default`.** The harness logic at `tests/ab/lib/launch.sh:220-242` treats `default` as a sentinel that omits `--effort` entirely (the CLI does not accept `default` as a value). For Haiku/low, the config must specify `effort: low` literally — that string flows through to `--effort low`. Do not write `effort: default` in the haiku config; the probe would not actually run at low effort.

2. **The probe arm uses the EXISTING smoke fixture.** The Phase 2b baseline at `tests/ab/corpus/ruff-smoke-bad-py/expected/findings.json` (hash `7b003236...`) is the comparison target. The faithfulness-check helper at `tests/ab/lib/agent_capture.sh:agent_capture_compare_findings` compares each trial's `findings.json` to that baseline by `jq -S` + sha256 — order-insensitive within the array, byte-identical otherwise. No new fixture, no new corpus entry.

3. **The agent file edit is a permanent production change, not a runtime hook.** Per `feedback_models_overlook_tuning_hooks`, the harness drives variation externally. Editing `plugins/code-review-suite/agents/ruff-reviewer.md`'s `model:` field is the single permitted production edit, and it is gated on a positive verdict. Do not introduce extension points the suite must consult.

---

## Task 1: Branch off main and confirm clean preconditions

This is the first Phase 3.1 commit's prerequisite. No code change yet — just a fresh branch and a clean tree.

**Files:** none modified.

- [ ] **Step 1: Confirm the working tree is clean and you are on the expected branch**

Run:

```bash
git status --short
git rev-parse HEAD
git rev-parse --abbrev-ref HEAD
```

Expected: clean status; HEAD on `main` (or rebased onto it); current branch displayed.

If the current branch is `chore/phase-3-handover`, switch to `main` first:

```bash
git checkout main
git pull --rebase origin main
```

- [ ] **Step 2: Confirm `main` is at `b214944` (or an ancestor that includes Phase 2)**

Run:

```bash
git log --oneline -1 main
git merge-base --is-ancestor b214944 main && echo "Phase 2 ancestor: yes" || echo "Phase 2 ancestor: NO"
```

Expected: the merge-base check prints `Phase 2 ancestor: yes`. If not, stop and ask the operator — Phase 3.1 depends on Phase 2 being on `main`.

- [ ] **Step 3: Confirm the smoke fixture and its canonical baseline are in tree**

Run:

```bash
test -f tests/ab/corpus/ruff-smoke-bad-py/expected/findings.json && echo "baseline present"
shasum -a 256 tests/ab/corpus/ruff-smoke-bad-py/expected/findings.json
```

Expected: the baseline file is present and its hash is `7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`. If the hash differs, stop and surface to the operator — the comparison target is wrong.

- [ ] **Step 4: Confirm the structural tests are currently green**

Run:

```bash
tests/run.sh
```

Expected: all tests pass (the operator's last known state was 294 tests, 293 passed, 1 skipped, 0 failed). Any failure here is a baseline regression unrelated to Phase 3.1 — surface to the operator before proceeding.

- [ ] **Step 5: Branch off main**

Run:

```bash
git checkout -b feat/per-agent-tuning-ruff-haiku-low
```

No commit yet — the next task lands the first one.

---

## Task 2: Author `ruff-haiku-low.yaml` with a failing structural test first

TDD: a structural test first asserts the new config parses correctly, fails, then the YAML file makes it pass. Mirrors the Phase 2 Task 3 pattern (config-loader extension) at the smaller scope of one new config file.

**Files:**
- Modify: `tests/lib/test_ab_per_agent_lib.sh` (append one test case)
- Create: `tests/ab/configs/per-agent/ruff-haiku-low.yaml`

- [ ] **Step 1: Write the failing structural test**

Append to `tests/lib/test_ab_per_agent_lib.sh`:

```bash
test_ab_config_per_agent_ruff_haiku_low_parses() {
    # Phase 3.1: the haiku-low probe arm config must parse and expose
    # session.model=haiku, session.effort=low. The harness drives all
    # variation; the agent file is never touched at runtime.
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local probe="$REPO_ROOT/tests/ab/configs/per-agent/ruff-haiku-low.yaml"

    if [[ ! -f "$config" ]]; then
        fail "A/B config: per-agent ruff-haiku-low parses" "config.sh missing"
        return
    fi
    if [[ ! -f "$probe" ]]; then
        fail "A/B config: per-agent ruff-haiku-low parses" "ruff-haiku-low.yaml not yet authored"
        return
    fi

    local mode agent model effort
    mode=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_MODE:-}"
    )
    agent=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_AGENT:-}"
    )
    model=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_MODEL:-}"
    )
    effort=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_EFFORT:-}"
    )

    assert_equals "per-agent" "$mode" "A/B config: ruff-haiku-low.mode = per-agent"
    assert_equals "ruff-reviewer" "$agent" "A/B config: ruff-haiku-low.agent = ruff-reviewer"
    assert_equals "haiku" "$model" "A/B config: ruff-haiku-low.session.model = haiku"
    assert_equals "low" "$effort" "A/B config: ruff-haiku-low.session.effort = low"
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run:

```bash
tests/run.sh
```

Expected: the new `test_ab_config_per_agent_ruff_haiku_low_parses` fails because `ruff-haiku-low.yaml` does not yet exist (the test's early-return reports "ruff-haiku-low.yaml not yet authored"). All other tests still pass.

- [ ] **Step 3: Author `tests/ab/configs/per-agent/ruff-haiku-low.yaml`**

Create the file with this exact content:

```yaml
name: ruff-haiku-low
description: Phase 3.1 directional probe — ruff-reviewer at Haiku/low. Compared against ruff-baseline (sonnet/default) on per-trial findings hash. Three-trial faithfulness check; positive verdict adopts Haiku/low for the production agent file.
mode: per-agent
agent: ruff-reviewer
session:
  model: haiku
  effort: low
```

The single difference from `ruff-baseline.yaml` is `session.model` and `session.effort`. The `effort: low` value is literal — it flows through to the `--effort low` CLI flag (the `default` sentinel handling at `lib/launch.sh:220-242` only applies when the value is `default` or empty).

- [ ] **Step 4: Run the test to confirm it passes**

Run:

```bash
tests/run.sh
```

Expected: the new structural test passes; all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/configs/per-agent/ruff-haiku-low.yaml tests/lib/test_ab_per_agent_lib.sh
git commit -m "$(cat <<'EOF'
feat(tests/ab): add ruff-haiku-low.yaml — Phase 3.1 probe arm

Adds the directional probe configuration:
- session.model: haiku, session.effort: low (literal, not the 'default'
  sentinel)
- mode: per-agent, agent: ruff-reviewer

The probe runs against the existing ruff-smoke-bad-py corpus fixture under
--faithfulness-check; verdict gates the production agent file edit at
plugins/code-review-suite/agents/ruff-reviewer.md (frontmatter model:).

Structural test added in tests/lib/test_ab_per_agent_lib.sh asserts the
config parses and exposes the expected (model, effort) pair.
EOF
)"
```

---

## Task 3: Live-fire 3 trials at Haiku/low with `--faithfulness-check`

The first Bedrock-touching task in Phase 3.1. Cost ~30k tokens, ~3 minutes wall-clock. Same cost-aware stop-and-investigate rules as Phase 2b's Task 9 Step 6: any INCONCLUSIVE / empty stdout / unexpected non-zero / wall-clock > 60s halts the run for inspection rather than blind retry.

**Files:** none modified (the run directory is gitignored under `tests/ab/runs/`).

- [ ] **Step 1: Confirm Bedrock auth is current**

Run:

```bash
~/.claude/scripts/aws-sso-preflight.sh
```

Expected: zero stderr, zero exit code. If the SSO token has expired, the operator runs `aws sso login --profile <profile>` themselves; the harness will re-run preflight on `tests/ab/run.sh` invocation.

- [ ] **Step 2: Run the 3-trial probe**

Run:

```bash
tests/ab/run.sh --config tests/ab/configs/per-agent/ruff-haiku-low.yaml --corpus ruff-smoke-bad-py --trials 3 --timeout-seconds 600 --faithfulness-check
```

Expected on success:

- Three trials complete within ~3 minutes total wall-clock.
- stderr ends with `run.sh: faithfulness check PASSED (3/3 trials matched)`.
- Exit code 0.
- Run directory under `tests/ab/runs/<timestamp>-ruff-haiku-low/` containing `manifest.yaml`, `summary.csv`, three `trial-NNN/` directories each with `agent-output.md`, `findings.json`, `findings_hash.txt`, `timing.json`, `system-prompt.md`, `user-message.txt`. No `faithfulness.diff` files (those are only written on divergence).
- `summary.csv` rows show `inconclusive=false`, `timed_out=false`, `findings_count >= 1`, identical `findings_hash` across all three rows.

- [ ] **Step 3: Stop-and-investigate triggers — DO NOT BLIND-RETRY**

If any of the following occurs, halt the task at this step and surface to the operator before doing anything else:

- A trial returns INCONCLUSIVE — capture the marker file and the trial's `stdout.log` / `stderr.log`. Common cause: `Skipped — ruff not available on PATH.` (PATH issue inside the trial subshell, not a Haiku/low signal).
- A trial returns empty stdout. Per `project_orchestrator_empty_stdout_anomaly` (auto-memory) this anomaly was observed once in Phase 1 with cause unknown. Capture stderr and ask the operator before re-running.
- A trial exits with a non-zero rc that is not from the comparison helper (i.e. the underlying `claude` invocation itself failed). Inspect `stderr.log`; do not retry.
- Per-trial wall-clock > 60s on a 3-line file is a smell — capture timing.json and inspect.
- The faithfulness check FAILED (any divergence). This is a real signal — proceed to Task 4 to compute the verdict; do NOT retry.

- [ ] **Step 4: Capture per-trial outcome metadata for the report**

Read off the run directory:

```bash
RUN_DIR=$(ls -t tests/ab/runs | head -1)
echo "RUN_DIR=$RUN_DIR"
cat "tests/ab/runs/$RUN_DIR/summary.csv"
ls "tests/ab/runs/$RUN_DIR/trial-001"
```

Note for Task 4 (write into `${CLAUDE_TEMP_DIR}/probe-outcome.txt` for handoff to the report task):

- The three `findings_hash` values from `summary.csv` (column 5).
- The three `wall_clock_seconds` values (column 3).
- The three `findings_count` values (column 4).
- The `inconclusive` column for any non-`false` value.
- The exact run-directory name.

```bash
mkdir -p "${CLAUDE_TEMP_DIR}"
{
    echo "run_dir=$RUN_DIR"
    echo "summary_csv:"
    cat "tests/ab/runs/$RUN_DIR/summary.csv"
    echo
    echo "first-trial agent-output.md (first 50 lines):"
    head -50 "tests/ab/runs/$RUN_DIR/trial-001/agent-output.md"
} > "${CLAUDE_TEMP_DIR}/probe-outcome.txt"
```

The probe-outcome file is a temp artefact — never commit it.

---

## ⏸ Operator review gate (the load-bearing pause)

**Operator review at this point.** The 3-trial probe has run; the verdict is one of:

- **PASS:** 3/3 hash-match. Adoption candidate.
- **FAIL:** 0/3 hash-match. Decisive no.
- **NON-DETERMINISTIC:** 1/3 or 2/3 hash-match. Treated as a no by default — non-determinism in a transmission task is itself a defect (per spec Step 4).

Surface the trial outcomes to the operator BEFORE any production agent file edit:

```
Run directory: <RUN_DIR>
summary.csv:
<paste contents>

Per-trial findings_hash values:
- trial-001: <hash>
- trial-002: <hash>
- trial-003: <hash>

Faithfulness verdict: <PASSED 3/3 | FAILED N/3>
Wall-clock per trial: <list>

Proposed verdict: <equivalent | worse | inconclusive>
Proposed action: <adopt Haiku/low for ruff-reviewer | reject; stay at Sonnet/default | reject; document non-determinism>
```

Do not edit `plugins/code-review-suite/agents/ruff-reviewer.md` until the operator says "proceed". Phase 1 + 2 spent ~5 months and ~5M+ Bedrock tokens building the apparatus that lets this edit happen responsibly. Bypassing the gate to save 30 seconds is not the trade.

If the operator wants to repeat the probe with adjusted parameters (more trials, different timeout) before finalising the verdict, do that and re-surface before proceeding.

---

## Task 4: Write the one-page comparison report

Write the report regardless of probe outcome. A failed probe is publishable too — the spec § "Cost expectations" calls out that either result is publishable; the produced artefact is the documented "no" or "yes".

**Files:**
- Create: `docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md`

The `docs/superpowers/notes/` directory does not yet exist; the create-step lands the first file there.

- [ ] **Step 1: Create the directory and the report file**

Use the actual values from `${CLAUDE_TEMP_DIR}/probe-outcome.txt` and the run directory. The skeleton below is the complete required layout — fill the `<placeholders>` with real numbers and prose, and pick one of the verdict / recommendation alternatives. Do not commit any literal `<placeholder>` strings.

```bash
mkdir -p docs/superpowers/notes
```

Write `docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md` with this skeleton (replacing all bracketed placeholders with real values from the trial run):

```markdown
# ruff-reviewer Haiku/low directional probe — Phase 3.1 result

**Date:** 2026-05-29
**Status:** <Adopted | Rejected | Inconclusive>
**Probe scope:** Single specialist (`ruff-reviewer`), single fixture
(`ruff-smoke-bad-py`), 3 trials, faithfulness-check against the captured
Sonnet/default baseline.
**Suite SHA at probe time:** <git rev-parse HEAD before the probe ran>
**Run directory:** `tests/ab/runs/<RUN_DIR>` (gitignored; see commit body for
the SHAs of the captured manifest/summary if needed for reproduction).

## Probe configuration

- Baseline arm (already captured in Phase 2b at suite SHA `f3f73270...`):
  - Config: `tests/ab/configs/per-agent/ruff-baseline.yaml`
  - Model / effort: `sonnet` / `default`
  - Canonical findings hash:
    `7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`
- Probe arm (this report):
  - Config: `tests/ab/configs/per-agent/ruff-haiku-low.yaml`
  - Model / effort: `haiku` / `low`

## Results

| Metric | Baseline (Phase 2b) | Probe (this run) |
|---|---|---|
| Trials | 3 | 3 |
| Distinct `findings_hash` values across trials | 1 | <count> |
| Wall-clock per trial (s) | <Phase 2b numbers — see Phase 2b run> | <list> |
| Mean wall-clock (s) | <baseline mean> | <probe mean> |
| Findings count per trial | <list> | <list> |
| Hash-match against baseline | n/a (self) | <N>/3 |
| Faithfulness check verdict | PASSED 3/3 (Phase 2b) | <PASSED 3/3 \| FAILED N/3> |

## Per-trial detail

- trial-001: hash=`<sha>`, count=<n>, wall=<s>s, hash-match=<yes|no>
- trial-002: hash=`<sha>`, count=<n>, wall=<s>s, hash-match=<yes|no>
- trial-003: hash=`<sha>`, count=<n>, wall=<s>s, hash-match=<yes|no>

## Verdict

Per the spec's Step 4 outcome table:

- **3/3 hash-match → equivalent** (adopt Haiku/low).
- **0/3 hash-match → worse** (reject; stay at Sonnet/default).
- **1-2/3 hash-match → inconclusive / non-deterministic** (reject by default;
  non-determinism in a transmission task is itself a defect).

**Verdict for this probe:** <equivalent | worse | inconclusive>.

## Recommendation

<one paragraph: do we adopt Haiku/low for ruff-reviewer in production? If
adopting, what (if any) follow-up work is queued? If rejecting, what is the
nature of the failure — recall loss, fabrications, format drift, non-
determinism? If inconclusive, what additional probe (e.g. richer fixture per
spec Step 6) would tighten the answer?>

## Cost delta

Approximate per-trial token usage on this fixture (3-line Python file):

- Baseline: <tokens> per trial — captured in Phase 2b's run directory at
  suite SHA `f3f73270...`.
- Probe: <tokens> per trial — captured in this run's manifest.

Cost saving per trial if adopted: ~<X>% (Haiku is ~1/<n>th the per-token cost
of Sonnet on Bedrock as of 2026-05-29; effort: low further reduces per-trial
token spend).

## Cross-specialist transfer signal (informational)

Per the spec § "Sequencing within Phase 3", the directional answer for
`ruff-reviewer` is *very likely* to transfer to the other three static
specialists (`eslint-reviewer`, `trivy-reviewer`, `jbinspect-reviewer`).
A <PASS|FAIL> here biases the Phase 3.2-3.4 prior towards the same verdict.
Phase 3.2 (eslint) is the next step in the sweep regardless.

## Reproduction

```bash
git checkout main
git log --oneline -1
# Confirm tip is at or after b214944 (Phase 2 squash-merge SHA).
tests/ab/run.sh --config tests/ab/configs/per-agent/ruff-haiku-low.yaml \
    --corpus ruff-smoke-bad-py --trials 3 --timeout-seconds 600 \
    --faithfulness-check
```

Expected stderr tail: `run.sh: faithfulness check <PASSED 3/3 | FAILED N/3>`.
```

- [ ] **Step 2: Sanity-check the report**

Read the file back. Verify:

- All `<placeholder>` strings have been replaced with real values.
- The verdict cell, the recommendation paragraph, and the per-trial detail are internally consistent (the verdict matches the hash-match counts; the recommendation matches the verdict).
- The Suite SHA matches `git rev-parse HEAD` *as of when the probe ran* — not as of when the report is written, if those have drifted.

- [ ] **Step 3: Run the structural tests**

Run:

```bash
tests/run.sh
```

Expected: all tests still pass — the report is documentation-only and structural tests do not assert on its content.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md
git commit -m "$(cat <<'EOF'
docs(superpowers): record Phase 3.1 ruff-reviewer Haiku/low probe result

Captures the verdict of the 3-trial faithfulness check against the
Phase 2b Sonnet/default baseline (canonical hash 7b003236...). Records
per-trial hashes, wall-clock per arm, the spec-conformant verdict, and
the production-adoption recommendation.

This is the first artefact in docs/superpowers/notes/ — the Phase 3
sweep is the first phase in the suite-tuning programme that produces
per-specialist directional results worth recording outside of plan and
spec documents.
EOF
)"
```

---

## Task 5: IF probe passed — adopt Haiku/low for the production `ruff-reviewer` agent

**Conditional task.** Skip entirely if the probe verdict is `worse` or `inconclusive`. If skipped, proceed directly to Task 6 (PR opening) — the Haiku/low config and the report still ship even when the verdict is negative, so the result is reproducible and publishable.

Single one-line frontmatter edit. The dispatched agent file change is the actual cost optimisation Phase 3.1 exists to enable; everything before this task is measurement apparatus.

**Files:**
- Modify: `plugins/code-review-suite/agents/ruff-reviewer.md` (frontmatter line 4 only)

- [ ] **Step 1: Re-confirm the operator approved the adoption**

The operator review gate at the end of Task 3 surfaced the trial outcomes. Re-confirm before editing — if the operator's "proceed" was conditional on something (e.g. "proceed if 3/3 AND mean wall-clock < 30s"), check the condition holds.

If anything is unclear, surface to the operator and pause. Do not interpret a soft signal as approval.

- [ ] **Step 2: Edit the frontmatter**

Open `plugins/code-review-suite/agents/ruff-reviewer.md`. The frontmatter block is the first 7 lines:

```markdown
---
name: ruff-reviewer
description: Runs Ruff on Python files in the diff (including notebooks via Ruff ≥ 0.6.0 or nbqa fallback) and reports findings. Standalone or dispatched by the review include.
model: sonnet
tools: Read, Grep, Glob, Bash
background: true
---
```

Change line 4 from:

```yaml
model: sonnet
```

to:

```yaml
model: haiku
```

Nothing else changes — name, description, tools, background remain.

- [ ] **Step 3: Run `tests/run.sh` to confirm structural tests still pass**

The handover calls this out explicitly: structural tests check sync-note consistency and may surface drift if the agent file is edited in ways that interact with other rules. Run:

```bash
tests/run.sh
```

Expected: all tests pass. Specifically watch for:

- `test_sync_notes` — sync-note validation regexes match the file's structure. The `model:` field is not in any sync-note regex, so a model change should not surface here, but verify.
- `test_ab_corpus_smoke_depends_on_paths_resolve` — `ruff-reviewer.md` is a `depends_on` of the smoke fixture; the path still exists, so this stays green.
- `test_static_analysis_behavioural` — the agent file's procedural shape is asserted; the model field is metadata and out of scope.

If any test fails, the failure is real and unrelated to "the model changed" — investigate.

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review-suite/agents/ruff-reviewer.md
git commit -m "$(cat <<'EOF'
feat(code-review-suite): adopt Haiku/low for ruff-reviewer (Phase 3.1)

Frontmatter model: sonnet -> haiku based on the Phase 3.1 directional
probe. Three Haiku/low trials produced a findings hash byte-identical to
the Phase 2b Sonnet/default baseline at hash 7b003236...; the static-
analysis transmission contract is preserved on the smoke fixture.

Verdict and methodology recorded in
docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md.

Effort field is intentionally not added to the agent frontmatter — the
ruff-reviewer agent is dispatched by the orchestrator at default effort
in production, and the probe was specifically of haiku/low. Effort tuning
is a separate concern; this commit changes only the model.
EOF
)"
```

---

## Task 6: Open the Phase 3.1 PR

The PR title encodes the verdict. Two title shapes:

- **Positive verdict (Task 5 ran):** `feat(code-review-suite): adopt Haiku/low for ruff-reviewer (Phase 3.1)`
- **Negative verdict (Task 5 skipped):** `chore(tests/ab): record ruff-reviewer Haiku/low probe — verdict: <reject | inconclusive>`

The body links to the report and states the verdict in the first paragraph.

**Files:** none modified.

- [ ] **Step 1: Confirm the branch is clean and rebased**

Run:

```bash
git status --short
git fetch origin main
git rebase origin/main
```

Expected: clean status; rebase completes without conflicts. The only main-branch movement since branching should be unrelated commits (none expected; the producing-session branch lives at the same SHA).

- [ ] **Step 2: Push and write the PR body**

Run:

```bash
git push -u origin feat/per-agent-tuning-ruff-haiku-low
```

Write the PR body to `${CLAUDE_TEMP_DIR}/phase31-pr-body.md`. The body must begin with the contextual summary CLAUDE.md requires (1-3 sentences orienting a non-technical reader), then the technical details. Use the appropriate variant below depending on verdict.

**Variant A — Positive verdict (Task 5 ran):**

```markdown
This PR is the first functional change to the code-review-suite plugin
from the multi-phase suite-tuning programme that began in 2026-05. It
adopts Haiku at low effort for the `ruff-reviewer` static-analysis agent
on the back of a 3-trial directional probe that produced findings
byte-identical to the Sonnet/default baseline. Phase 3.1 in the static-
specialist tuning sweep (spec at
`docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`);
Phases 3.2-3.4 cover `eslint-reviewer`, `trivy-reviewer`, and
`jbinspect-reviewer` respectively in subsequent PRs. Builds on Phase 2's
per-agent A/B harness (PR #33, merged 2026-05-29).

## Verdict

3/3 hash-match against the captured baseline at
`7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`.
Haiku/low transmits faithfully on the `ruff-smoke-bad-py` fixture.

Full result:
[`docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md`](docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md).

## Changes

- `tests/ab/configs/per-agent/ruff-haiku-low.yaml` — new probe-arm
  configuration. `mode: per-agent`, `agent: ruff-reviewer`,
  `session.model: haiku`, `session.effort: low`.
- `tests/lib/test_ab_per_agent_lib.sh` — new structural test asserts the
  config parses and exposes the expected (model, effort) pair.
- `docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md` —
  one-page comparison report. First entry in the new `notes/` directory.
- `plugins/code-review-suite/agents/ruff-reviewer.md` — frontmatter
  `model: sonnet` → `model: haiku`. The actual cost optimisation enabled
  by Phases 1 + 2 + 3.1.

## Test plan

- [x] `tests/run.sh` passes locally (covers the new structural test for
      `ruff-haiku-low.yaml`).
- [x] One 3-trial faithfulness check at Haiku/low passed 3/3 against the
      Phase 2b baseline.
- [x] `tests/run.sh` passes after the agent file edit (sync-note
      consistency holds; behavioural tests still green).
- [ ] CI green.
```

**Variant B — Negative verdict (Task 5 skipped):**

```markdown
This PR records a directional probe result for the multi-phase suite-
tuning programme that began in 2026-05. It captures the configuration and
verdict for a 3-trial probe of `ruff-reviewer` at Haiku/low against the
Phase 2b Sonnet/default baseline. The verdict is **<reject | inconclusive>**;
the production agent file is unchanged. Phase 3.1 in the static-specialist
tuning sweep (spec at
`docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`);
the negative result biases the prior for Phases 3.2-3.4 (`eslint-reviewer`,
`trivy-reviewer`, `jbinspect-reviewer`) towards the same verdict and may
trigger a richer-fixture follow-up per spec Step 6.

## Verdict

<N>/3 hash-match against the captured baseline at
`7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`.
<one sentence summarising the failure mode — recall loss, fabrications,
format drift, non-determinism>.

Full result:
[`docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md`](docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md).

## Changes

- `tests/ab/configs/per-agent/ruff-haiku-low.yaml` — new probe-arm
  configuration. Kept on `main` so the result is reproducible.
- `tests/lib/test_ab_per_agent_lib.sh` — structural test for the new
  config.
- `docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md` —
  one-page comparison report.
- **No production agent file change.** `plugins/code-review-suite/agents/
  ruff-reviewer.md` stays at `model: sonnet`.

## Test plan

- [x] `tests/run.sh` passes locally.
- [x] 3-trial faithfulness check at Haiku/low produced the recorded
      verdict (<N>/3 hash-match).
- [ ] CI green.
```

Open the PR with the variant matching the actual verdict:

```bash
# Variant A:
gh pr create --title "feat(code-review-suite): adopt Haiku/low for ruff-reviewer (Phase 3.1)" --body-file "${CLAUDE_TEMP_DIR}/phase31-pr-body.md"

# OR Variant B (substitute the verdict word):
gh pr create --title "chore(tests/ab): record ruff-reviewer Haiku/low probe — verdict: <reject|inconclusive>" --body-file "${CLAUDE_TEMP_DIR}/phase31-pr-body.md"
```

- [ ] **Step 3: Watch CI green**

Run:

```bash
gh pr checks --watch
```

Expected: all checks green. If a check fails, fix locally, push the fixup, and let CI re-run.

- [ ] **Step 4: Merge**

Once green and the operator says "merge":

```bash
gh pr merge --squash --delete-branch
```

After merge, return to main:

```bash
git checkout main
git pull --rebase origin main
```

---

## Task 7: Auto-memory entry capturing the verdict

Per the auto-memory protocol: the Phase 3.1 verdict is concrete, dated, and load-bearing for the four-specialist sweep. Capture it as a project memory so Phase 3.2-3.4 sessions inherit the prior.

**Files:**
- Create: `~/.claude/projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/project_phase_3_1_ruff_haiku_low_probe.md`
- Modify: `~/.claude/projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/MEMORY.md` (one line index entry)

These are in the user's home directory, not the marketplace repo. Do not include them in the Phase 3.1 PR.

- [ ] **Step 1: Write the memory file**

Create the memory file with content matching the actual verdict:

```markdown
---
name: phase-3-1-ruff-haiku-low-probe
description: Phase 3.1 directional probe — ruff-reviewer at Haiku/low <equivalent|worse|inconclusive> vs Sonnet/default; verdict, PR, follow-ups
metadata:
  type: project
---

Phase 3.1 ruff-reviewer Haiku/low directional probe result (recorded
2026-05-29). 3 trials of `tests/ab/configs/per-agent/ruff-haiku-low.yaml`
against `ruff-smoke-bad-py` fixture under `--faithfulness-check`. Result:
<N>/3 hash-match against the Phase 2b baseline at hash `7b003236...`.

**Verdict:** <equivalent | worse | inconclusive>.

**Production action:** <Haiku/low adopted for ruff-reviewer at PR #<n>,
merged YYYY-MM-DD | rejected; ruff-reviewer stays at Sonnet/default; no
production change shipped>.

**Why:** Static-analysis specialists are mechanical transmission tasks —
the directional answer for ruff is the prior for [[per-agent-harness-phase2-planning]]'s
deferred Phase 2c question and biases Phases 3.2 (eslint), 3.3 (trivy),
3.4 (jbinspect).

**How to apply:** When starting Phase 3.2/3.3/3.4, use this verdict as the
default expectation. If positive, expect the other static specialists to
likely pass too — run cheap probes first. If negative or inconclusive,
expect the same failure mode in the others and consider whether the
spec's Step 6 richer-fixture follow-up should land before the next
specialist's probe.

**Related:** [[per-agent-harness-phase2-planning]] (chassis),
[[differential-analysis-followup]] (parallel cost-tuning track),
[[models-overlook-tuning-hooks]] (variation must flow externally — agent
file model: edit was a one-time permanent change, not a runtime hook).
```

- [ ] **Step 2: Add the index entry to `MEMORY.md`**

Append one line under the existing entries:

```markdown
- [Phase 3.1 ruff probe](project_phase_3_1_ruff_haiku_low_probe.md) — Haiku/low <equivalent|worse|inconclusive> vs Sonnet/default; <adopted|rejected|inconclusive> for production
```

Match the slug to the file name and the description hook to the actual verdict.

- [ ] **Step 3: No commit (memory dir is in `~/.claude/`, not this repo)**

The memory directory is committed in the user's `~/.claude` repo separately. Mention to the operator that they should commit and push the memory entry in `~/.claude` after this PR merges; do not run those commits as part of Phase 3.1 unless the operator asks.

---

## Self-review

**Spec coverage check:**

| Spec section | Implementing task |
|---|---|
| Step 1 — Smoke fixture (ruff) | Reused; `tests/ab/corpus/ruff-smoke-bad-py/` already in tree from Phase 2 |
| Step 2 — Sonnet baseline capture | Reused; `expected/findings.json` at hash `7b003236...` already in tree from Phase 2b |
| Step 3 — 3-trial faithfulness check at Sonnet/default | Reused; already validated in Phase 2b |
| Step 4 — 3-trial directional probe at Haiku/low | Tasks 2 (config) + 3 (live-fire) |
| Step 4 outcome table — verdict computation | Task 3 (operator review gate) + Task 4 (report verdict cell) |
| Step 5 — One-page comparison report | Task 4 |
| Step 6 — Optional richer-fixture follow-up | **Out of Phase 3.1 scope** per the handover. Triggered only on probe failure, only after operator approval. Not implemented here. |
| Per-specialist parser additions | n/a — ruff parser exists from Phase 2 |
| Verifications during implementation: empirically ground parsers | n/a — the parser is unchanged from Phase 2; the probe is a measurement of an already-grounded contract |
| Verifications during implementation: CLI flag spellings | Confirmed for sonnet+haiku in Phase 2; reused as-is per spec § "Verifications during implementation" |
| Sequencing: ruff first | Implemented (this is Phase 3.1, ruff-only) |

**Out-of-scope items honoured (not in any task):**

- No richer ruff fixture authored.
- No probe / config / fixture work for `eslint-reviewer`, `trivy-reviewer`, or `jbinspect-reviewer`.
- No modification to `lib/agent_capture.sh`, `lib/agent_dispatch.sh`, `lib/fixture.sh`, `lib/launch.sh`, `lib/config.sh`, or `tests/ab/run.sh`.
- No re-litigation of the directional-probe methodology.
- No address of the rubric-row-2 anomaly (`project_rubric_row2_stability`) or the empty-stdout anomaly (`project_orchestrator_empty_stdout_anomaly`).
- No new extension points or runtime tuning hooks on production agents.

**Placeholder scan:** the report skeleton in Task 4 contains `<placeholder>` strings by design — they are the values the implementer fills in after the live-fire run. Task 4 Step 2 explicitly checks no `<placeholder>` strings make it into the committed file. The PR body and memory file both have variants A/B and require the implementer to pick one and substitute the verdict-shaped values; no literal placeholders are committed.

**Type/identifier consistency check:**

- `_AB_CONFIG_MODE`, `_AB_CONFIG_AGENT`, `_AB_CONFIG_SESSION_MODEL`, `_AB_CONFIG_SESSION_EFFORT` — defined in `lib/config.sh` (Phase 2 Task 3); consumed in Task 2 Step 1's structural test by sourcing `config.sh` and reading the same names.
- `agent_capture_compare_findings` — defined in `lib/agent_capture.sh` (Phase 2 Task 9); consumed transparently by `tests/ab/run.sh --faithfulness-check` in Task 3 Step 2.
- `tests/ab/corpus/ruff-smoke-bad-py/expected/findings.json` — created in Phase 2b at hash `7b003236...`; read in Task 1 Step 3 (precondition check) and consumed in Task 3 Step 2 (`--faithfulness-check` comparison target). Hash spelled the same in plan title, Architecture summary, Important context point 2, Task 1 Step 3, Task 4 Step 1 report skeleton, and Task 7 Step 1 memory file.
- `feat/per-agent-tuning-ruff-haiku-low` — branch name spelled identically in Task 1 Step 5 (creation), Task 6 Step 2 (push), and Task 6 Step 4 (delete on merge).

All consistent.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-static-specialist-tuning-ruff-plan.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration. Phase 3.1 has one explicit ⏸ operator review gate (between Task 3 and Task 5) which subagent-driven naturally accommodates.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
