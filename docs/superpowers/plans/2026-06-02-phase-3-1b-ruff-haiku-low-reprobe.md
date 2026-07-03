# Phase 3.1b — ruff-reviewer Haiku/low re-probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-probe `ruff-reviewer` at Haiku/low on the post-3.1c harness (n=20), classify the trials, and decide whether it is equivalent to the Sonnet/default baseline on finding sets.

**Architecture:** One operator-gated Bedrock sweep (~50 k tokens) produces 20 trial artefacts under a gitignored run dir. An offline, `$CLAUDE_TEMP_DIR`-resident classification script reads the harness's native `summary.csv` plus per-trial `stderr.log`, classifies each trial NORMAL/DRIFT/EMPTY/OTHER, and computes Wilson 95 % CIs. A one-page report records the before/after-vs-3.1a comparison and the equivalence verdict. No production config is changed.

**Tech Stack:** Bash harness (`tests/ab/run.sh`), `jq`/`yq`/`awk`, `python3` (stdlib only) for the classifier + Wilson-CI calculator, Claude Code CLI on Bedrock.

---

## Critical operational constraints (read before any task)

- **Push after every commit.** This clone is an autoUpdate-managed marketplace clone; a prior reclone wiped an unpushed branch. The branch `feat/phase-3-1b-ruff-reprobe` already exists and is pushed. Re-push immediately after every commit.
- **Bash hook rules.** No compound commands (`&&`, `||`, `;`), no `$(...)`/backticks (except the commit/PR HEREDOC carve-out), no loops/subshells in a single Bash call. Any multi-step shell recipe goes in a script file run with one `bash <path>` call. Temp files under `$CLAUDE_TEMP_DIR`.
- **No `*-reviewer.md` edits.** Model/effort variation flows from the config YAML only. This probe informs a later adoption decision; it does not flip production config.
- **Classifier is a per-run overlay, NOT committed to the harness** (matches the 3.1c precedent and the spec's Step 0). It lives in `$CLAUDE_TEMP_DIR`. Do not `git add` it.

## Key constants

- **Canonical tuple hash:** `7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`
- **Canonical finding:** `findings_count == 1`, rule `F401`.
- **Probe config:** `tests/ab/configs/per-agent/ruff-haiku-low.yaml` (`model: haiku`, `effort: low`).
- **Baseline (cited, not re-run):** 3.1c validation sweep, 20/20 NORMAL, Wilson 95 % CI [83.89 %, 100.00 %].
- **Test-oracle run dir (committed, present locally):** `tests/ab/runs/20260602T073653Z-ruff-baseline-validation/` — 20/20 NORMAL; used to verify the classifier before the live sweep.

## File structure

- **Create (temp, not committed):** `$CLAUDE_TEMP_DIR/classify_trials.py` — the classification + Wilson-CI script.
- **Create (committed):** `docs/superpowers/notes/2026-06-02-ruff-haiku-low-result.md` — the one-page report.
- **Read-only:** `tests/ab/run.sh`, `tests/ab/lib/launch.sh`, the run dirs under `tests/ab/runs/`.
- **No harness source files are modified.**

---

### Task 1: Pre-flight verification (offline, no Bedrock spend)

**Files:**
- Read: `tests/ab/configs/per-agent/ruff-haiku-low.yaml`
- Read: `tests/ab/corpus/ruff-smoke-bad-py/expected/findings.json`, `.../findings_hash.txt`

- [ ] **Step 1: Confirm the branch is pushed**

Run: `git status -sb`
Expected: `## feat/phase-3-1b-ruff-reprobe...origin/feat/phase-3-1b-ruff-reprobe` with no `[ahead N]`. If ahead, run `git push`.

- [ ] **Step 2: Confirm the probe config is the Haiku/low arm**

Run: `git show HEAD:tests/ab/configs/per-agent/ruff-haiku-low.yaml`
Expected: contains `model: haiku` and `effort: low` under `session:`, `mode: per-agent`, `agent: ruff-reviewer`.

- [ ] **Step 3: Confirm the canonical baseline hash is unchanged**

Run: `cat tests/ab/corpus/ruff-smoke-bad-py/expected/findings_hash.txt`
Expected: `7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`

- [ ] **Step 4: Confirm the test-oracle run dir is present**

Run: `head -1 tests/ab/runs/20260602T073653Z-ruff-baseline-validation/summary.csv`
Expected: the CSV header `trial,exit_code,wall_clock_seconds,findings_count,findings_hash,first_finding_rule,inconclusive,timed_out`. (If absent, the classifier in Task 2 cannot be verified — stop and resolve before proceeding.)

No commit for this task (verification only).

---

### Task 2: Write and verify the classification + Wilson-CI script

The classifier is the one piece of logic that must be correct before the live sweep. We verify it against the committed 3.1c validation run dir, whose answer is known (20 NORMAL, Wilson 95 % CI [83.89 %, 100.00 %]) — a deterministic offline test oracle requiring zero Bedrock spend.

**Files:**
- Create: `$CLAUDE_TEMP_DIR/classify_trials.py`

- [ ] **Step 1: Write the classifier script**

Write the following to `$CLAUDE_TEMP_DIR/classify_trials.py` verbatim:

```python
#!/usr/bin/env python3
"""Classify per-agent A/B trial outcomes and compute Wilson 95% CIs.

Per-run analysis overlay for the Phase 3.1b ruff Haiku/low re-probe. Reads the
harness-native summary.csv plus each trial's stderr.log, classifies every trial
NORMAL/DRIFT/EMPTY/OTHER, writes classification.csv into the run dir, and prints
a class breakdown with Wilson 95% confidence intervals.

NOT committed to the harness (per the Phase 3.1b spec, Step 0): this is a
reconstructable per-run overlay matching the 3.1c precedent.

Usage: python3 classify_trials.py <run_dir>
"""

import csv
import json
import math
import sys
from pathlib import Path

CANONICAL_HASH = "7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3"
ASSERT_STAGE = "launch_assert_trial_recoverable"


def classify_trial(row, run_dir):
    """Return (class, reason) for one summary.csv row.

    Classification order (first match wins):
      1. timed out / rc==124            -> OTHER  (timeout)
      2. validate-or-die fired           -> EMPTY  (unrecoverable; upstream)
      3. other non-zero exit             -> OTHER  (cli-error)
      4. count==1 and hash==canonical    -> NORMAL
      5. exit 0, present but non-canonical -> DRIFT
    """
    exit_code = int(row["exit_code"])
    timed_out = row["timed_out"].strip().lower() == "true"
    count = int(row["findings_count"])
    findings_hash = row["findings_hash"].strip()

    if timed_out or exit_code == 124:
        return "OTHER", "timeout"

    # Detect a validate-or-die fire: the assertion appends a JSON object with
    # stage=launch_assert_trial_recoverable to the trial's stderr.log and returns
    # non-zero only when the trial is genuinely unrecoverable (empty stdout AND
    # no recovery signal). A fallback-recovered trial leaves no such line.
    stderr_path = run_dir / row_trial_dir(row) / "stderr.log"
    assert_reason = read_assert_reason(stderr_path)
    if exit_code != 0 and assert_reason is not None:
        return "EMPTY", assert_reason
    if exit_code != 0:
        return "OTHER", "cli-error"

    if count == 1 and findings_hash == CANONICAL_HASH:
        return "NORMAL", ""
    return "DRIFT", "non-canonical"


def row_trial_dir(row):
    """summary.csv stores the trial index (1..N); the dir is trial-NNN."""
    return "trial-%03d" % int(row["trial"])


def read_assert_reason(stderr_path):
    """Return the validate-or-die reason string if the assertion fired, else None."""
    if not stderr_path.is_file():
        return None
    reason = None
    for line in stderr_path.read_text().splitlines():
        line = line.strip()
        if ASSERT_STAGE not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("stage") == ASSERT_STAGE:
            reason = obj.get("reason", "unknown")
    return reason


def wilson_ci(k, n, z=1.96):
    """Wilson score 95% CI for k successes in n trials, clamped to [0, 1]."""
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    margin = (z / denom) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, centre - margin), min(1.0, centre + margin))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python3 classify_trials.py <run_dir>")
    run_dir = Path(sys.argv[1])
    summary = run_dir / "summary.csv"
    if not summary.is_file():
        sys.exit("no summary.csv in %s" % run_dir)

    rows = list(csv.DictReader(summary.open()))
    results = []
    for row in rows:
        cls, reason = classify_trial(row, run_dir)
        results.append({
            "trial": row_trial_dir(row),
            "class": cls,
            "findings_count": row["findings_count"],
            "wall_clock_seconds": row["wall_clock_seconds"],
            "reason": reason,
        })

    out_csv = run_dir / "classification.csv"
    with out_csv.open("w", newline="") as fh:
        writer = csv.DictWriter(
            fh, fieldnames=["trial", "class", "findings_count", "wall_clock_seconds", "reason"])
        writer.writeheader()
        writer.writerows(results)

    n = len(results)
    classes = ["NORMAL", "DRIFT", "EMPTY", "OTHER"]
    counts = {c: sum(1 for r in results if r["class"] == c) for c in classes}
    walls = [int(r["wall_clock_seconds"]) for r in results]

    print("run_dir: %s" % run_dir)
    print("n = %d" % n)
    print("%-7s %5s %8s   %s" % ("class", "count", "pct", "Wilson 95% CI"))
    for c in classes:
        k = counts[c]
        lo, hi = wilson_ci(k, n)
        print("%-7s %5d %7.2f%%   [%6.2f%%, %6.2f%%]" % (c, k, 100 * k / n, 100 * lo, 100 * hi))
    if walls:
        print("wall-clock: mean %.1fs, range %d-%ds" % (sum(walls) / len(walls), min(walls), max(walls)))
    fired = [r for r in results if r["class"] == "EMPTY"]
    if fired:
        print("validate-or-die fires: %d" % len(fired))
        for r in fired:
            print("  %s: %s" % (r["trial"], r["reason"]))
    print("wrote %s" % out_csv)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the classifier against the test oracle (this IS the test)**

Run: `python3 "$CLAUDE_TEMP_DIR/classify_trials.py" tests/ab/runs/20260602T073653Z-ruff-baseline-validation`

Expected output:
```
n = 20
NORMAL     20  100.00%   [ 83.89%, 100.00%]
DRIFT       0    0.00%   [  0.00%,  16.11%]
EMPTY       0    0.00%   [  0.00%,  16.11%]
OTHER       0    0.00%   [  0.00%,  16.11%]
```
The NORMAL CI `[83.89%, 100.00%]` must match 3.1c's published interval exactly. If it does, the Wilson maths and the NORMAL/DRIFT logic are both correct. No `validate-or-die fires` line should appear.

- [ ] **Step 3: If the oracle output diverges, fix the script and re-run Step 2**

Do not proceed to the live sweep until the oracle reproduces `[83.89%, 100.00%]` and 20 NORMAL. A divergence here means the classifier is wrong; catching it now costs zero Bedrock tokens.

No commit (the classifier is a temp-dir overlay, not committed).

---

### Task 3: Operator gate, then the live Haiku/low sweep (~50 k tokens)

**Files:** none created; produces a gitignored run dir under `tests/ab/runs/`.

- [ ] **Step 1: Surface the cost at an operator gate**

State to the operator: "About to spend ~50 k Bedrock tokens / ~9–10 min on the 20-trial Haiku/low sweep. Proceed?" Wait for explicit go-ahead. (The operator has pre-authorised token spend for this programme, but the gate is the spec's contract — honour it.)

- [ ] **Step 2: Run the sweep**

Run (single command, no shell operators):
```bash
tests/ab/run.sh --config tests/ab/configs/per-agent/ruff-haiku-low.yaml --corpus ruff-smoke-bad-py --trials 20 --timeout-seconds 600 --stream-json --name ruff-haiku-low-reprobe
```
Expected: 20 trials execute (heartbeat lines on stderr), the run completes rc=0, and a new dir `tests/ab/runs/<timestamp>-ruff-haiku-low-reprobe/` is created containing `summary.csv`, `manifest.yaml`, and `trial-001`..`trial-020`. Note the exact run-dir path for Task 4. (Some individual trials may exit non-zero if validate-or-die fires — that is expected signal, not a harness failure.)

- [ ] **Step 3: Capture the run-dir path**

Run: `ls -d tests/ab/runs/*ruff-haiku-low-reprobe`
Record the path; pass it to Task 4.

No commit (run dirs are gitignored).

---

### Task 4: Classify the sweep and compute CIs

**Files:** writes `classification.csv` into the run dir (gitignored).

- [ ] **Step 1: Run the classifier against the live run dir**

Run: `python3 "$CLAUDE_TEMP_DIR/classify_trials.py" tests/ab/runs/<timestamp>-ruff-haiku-low-reprobe`
(substitute the path from Task 3 Step 3)

Expected: a class breakdown over n=20 with Wilson CIs, a wall-clock summary, and — if any trial was unrecoverable — a `validate-or-die fires` list with reasons. `classification.csv` is written into the run dir.

- [ ] **Step 2: Corroborate against the native summary.csv**

Run: `cat tests/ab/runs/<timestamp>-ruff-haiku-low-reprobe/summary.csv`
Cross-check: every trial the classifier called NORMAL must have `findings_count 1`, the canonical `findings_hash`, and `first_finding_rule F401`; every EMPTY must have a non-zero `exit_code` and a `launch_assert_trial_recoverable` line in its `trial-NNN/stderr.log`.

- [ ] **Step 3: Operator gate — surface classification + verdict**

Present to the operator, before writing the report:
- The class breakdown with Wilson CIs.
- The before/after-vs-3.1a delta: EMPTY 30 %→?, DRIFT 65 %→?, NORMAL 5 %→?.
- The equivalence verdict (`equivalent` | `better` | `worse` | `inconclusive`) against the Sonnet baseline's 100 % NORMAL, applying the >25 % movement guard. Within-arm non-determinism (mixed hashes) ⇒ `inconclusive`/"no".
- Any residual unrecoverable-EMPTY count, footnoted as the upstream CLI envelope bug (does not block the verdict; if non-zero, state the adjusted denominator).

Wait for confirmation before Task 5.

No commit.

---

### Task 5: Write the one-page result report

**Files:**
- Create: `docs/superpowers/notes/2026-06-02-ruff-haiku-low-result.md`

- [ ] **Step 1: Write the report**

Populate `docs/superpowers/notes/2026-06-02-ruff-haiku-low-result.md` with the actual sweep numbers (no placeholders), following the structure below. Fill every bracketed field from the Task 4 classification output:

```markdown
# Phase 3.1b — ruff-reviewer Haiku/low re-probe result

**Date:** 2026-06-02
**Status:** [verdict-one-word]
**Spec:** ../specs/2026-06-02-phase-3-1b-ruff-haiku-low-design.md
**Plan:** ../plans/2026-06-02-phase-3-1b-ruff-haiku-low-reprobe.md
**Precedent (pre-fix sweep):** ./2026-05-29-empty-stdout-investigation-result.md
**Baseline (cited):** ./2026-06-02-phase-3-1c-validation-sweep.md
**Run dir:** `tests/ab/runs/<timestamp>-ruff-haiku-low-reprobe/` (gitignored)
**Sweep SHA:** [git rev-parse --short HEAD at sweep time]

## Sweep configuration

- Codepath: per-agent harness, `--stream-json`.
- Specialist: `ruff-reviewer`. Fixture: `ruff-smoke-bad-py` (single canonical F401).
- Model / effort: Haiku / `low`. Trials: n=20. Timeout: 600 s.

## Baseline (cited, not re-run)

Sonnet/default, 3.1c validation sweep: 20/20 NORMAL, canonical hash `7b003236…91c3`,
Wilson 95 % CI [83.89 %, 100.00 %]. Provenance: 3.1c swept `ed437cb`; `main` is the
squash-merge `a01c876`; the functional harness (`tests/ab/lib/`, `run.sh`, expected
baseline, configs) is byte-identical across the two SHAs — the only `tests/ab/` delta
is the `suite_sha` provenance string in `source.yaml`.

## Class breakdown (n=20)

| Class  | Count | Percentage | Wilson 95% CI |
|--------|-------|------------|---------------|
| NORMAL | [..]  | [..] %     | [..]          |
| DRIFT  | [..]  | [..] %     | [..]          |
| EMPTY  | [..]  | [..] %     | [..]          |
| OTHER  | [..]  | [..] %     | [..]          |

[Per-trial table from classification.csv if useful.]

## Before / after vs Phase 3.1a (same arm, same fixture, n=20)

| Class  | 3.1a (pre-fix) | 3.1b (post-3.1c) | Movement |
|--------|----------------|-------------------|----------|
| NORMAL | 5.00 %         | [..] %            | [..]     |
| DRIFT  | 65.00 %        | [..] %            | [..]     |
| EMPTY  | 30.00 %        | [..] %            | [..]     |

## Wall-clock

Mean [..]s, range [..]-[..]s (cost delta vs 3.1a mean 22 s).

## Verdict

[equivalent | better | worse | inconclusive], with reasoning against the >25 %
movement guard and the recall direction (misses vs fabrications) on any divergence.
This probe informs a later adoption decision; it does NOT flip `ruff-reviewer.md`.

## Residual unrecoverable EMPTY (if any)

[Count + reasons; attributed to the upstream CLI envelope-finalisation gap; footnoted,
does not block the verdict. State adjusted denominator if non-zero. If zero, say so.]

## Cross-references

- Parent spec: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Phase 3.1a result: ./2026-05-29-empty-stdout-investigation-result.md
- Phase 3.1c validation: ./2026-06-02-phase-3-1c-validation-sweep.md
```

- [ ] **Step 2: Capture the sweep SHA for the report header**

Run: `git rev-parse --short HEAD`
Substitute into the report's **Sweep SHA** field.

- [ ] **Step 3: Commit the report**

```bash
git add docs/superpowers/notes/2026-06-02-ruff-haiku-low-result.md
git commit -m "docs(ab): Phase 3.1b result — ruff Haiku/low re-probe"
```

- [ ] **Step 4: Push immediately**

Run: `git push`
Expected: branch updated on origin (autoUpdate-wipe guard).

---

### Task 6: Open the PR

**Files:** none.

- [ ] **Step 1: Confirm the offline test suite still passes**

Run: `tests/run.sh`
Expected: all checks pass (we added only docs; no harness source changed). If anything fails, investigate before opening the PR.

- [ ] **Step 2: Write the PR body to a temp file**

Write a PR body to `$CLAUDE_TEMP_DIR/pr-body.md`. Begin with a 1–3 sentence non-technical contextual summary (where 3.1b sits in the Phase 3 cost-tuning programme and why), then the technical detail: the verdict, the before/after-vs-3.1a numbers, the cited baseline + provenance, and a link to PR #39 (3.1c). State explicitly that no production config changed.

- [ ] **Step 3: Create the PR**

```bash
gh pr create --base main --head feat/phase-3-1b-ruff-reprobe --title "docs(ab): Phase 3.1b — ruff Haiku/low re-probe result" --body-file "$CLAUDE_TEMP_DIR/pr-body.md"
```
Expected: a PR URL. Return it to the operator.

---

## Self-review (completed by plan author)

- **Spec coverage:** Step 0 pre-flight → Task 1; classification + Wilson CIs (Step 2) → Task 2; operator-gated sweep (Step 1) → Task 3; classification + verdict gate (Steps 2–3) → Task 4; one-page report (Step 4) → Task 5; land + PR (Step 5) → Task 6. All four design decisions (n=20, cited baseline, Step 5 verdict + recovery rule, residual-EMPTY footnote) are encoded in Tasks 3–5.
- **Placeholder scan:** the only bracketed fields are in the report template (Task 5), which are intentionally filled from live sweep output — not plan placeholders. The classifier code is complete and verbatim.
- **Type consistency:** the classifier reads `summary.csv` columns (`trial`, `exit_code`, `findings_count`, `findings_hash`, `timed_out`, `wall_clock_seconds`) confirmed against the real artefact; `trial-%03d` dir naming and the `launch_assert_trial_recoverable` stderr marker confirmed against `tests/ab/lib/launch.sh`. The canonical hash matches the committed `findings_hash.txt`. The Wilson formula was hand-verified to reproduce 3.1c's published `[83.89%, 100.00%]`.
```
