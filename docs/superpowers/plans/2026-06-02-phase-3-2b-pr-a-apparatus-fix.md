# Phase 3.2b — PR A (apparatus fix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the apparatus confound from the per-agent A/B harness so eslint-reviewer trials are hermetic and order-independent — eliminating the shared-working-dir + missing-`node_modules` install race that produced Phase 3.2's spurious "eslint not available" skips.

**Architecture:** Three coupled changes, all confined to the harness and fixture metadata (no `*-reviewer.md` body edit, no config change). (A1) Commit a pinned `package-lock.json` to the eslint fixture and un-ignore it. (A2) Add an optional `setup` command to `source.yaml`, parsed by `fixture.sh` and run once after materialise into a *template* directory. (A3) Restructure `run.sh`'s per-agent flow to materialise+provision once into a template dir, then `cp -R` a fresh per-trial working dir from that template inside the trial loop, so each trial gets an isolated, already-provisioned tree.

**Tech Stack:** Bash (4-space indent), `yq` for YAML, the in-tree `tests/lib/harness.sh` assertion framework (`assert_equals`, `assert_dir_exists`, `pass`, `fail`), `npm ci` for deterministic provisioning, eslint 10.x.

**Spec:** [`../specs/2026-06-02-phase-3-2b-eslint-apparatus-and-reprobe-design.md`](../specs/2026-06-02-phase-3-2b-eslint-apparatus-and-reprobe-design.md) (§"PR A — apparatus fix")

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `tests/fixtures/static-analysis/eslint/package-lock.json` | Pin eslint 10.x for reproducible `npm ci` | Create |
| `.gitignore` | Stop ignoring the one committed lockfile | Modify (line 21) |
| `tests/ab/corpus/eslint-smoke-bad-js/source.yaml` | Declare the provisioning command | Modify (add `setup:`) |
| `tests/ab/lib/fixture.sh` | Parse `setup.command`; expose `fixture_run_setup` | Modify |
| `tests/ab/run.sh` | Template-once + per-trial `cp -R` isolation | Modify (`_ab_run_per_agent`) |
| `tests/lib/test_ab_per_agent_lib.sh` | Unit tests for setup-parsing + isolation | Modify (append tests) |

**Ordering rationale:** Task 1 (lockfile + gitignore) is a prerequisite for the `npm ci` in Task 3. Task 2 (`source.yaml`) declares the key the parser in Task 3 reads. Task 3 (`fixture.sh`) exposes the setup primitive. Task 4 (`run.sh`) wires template+isolation. Task 5 is the live end-to-end verification that proves the race is gone.

---

## Task 1: Commit a pinned lockfile and un-ignore it

**Files:**
- Create: `tests/fixtures/static-analysis/eslint/package-lock.json`
- Modify: `.gitignore:21`

- [ ] **Step 1: Generate the lockfile from the existing fixture package.json**

The fixture already declares `eslint: ^10.4.1` in `package.json`. Generate a lockfile without leaving an installed tree behind. Run each as a separate Bash call (no `&&`):

Run: `cd tests/fixtures/static-analysis/eslint`
Run: `npm install --package-lock-only`
Expected: `package-lock.json` created; no `node_modules/` directory (the `--package-lock-only` flag resolves and writes the lockfile only).

- [ ] **Step 2: Verify the lockfile pins eslint and no node_modules was created**

Run: `test -f tests/fixtures/static-analysis/eslint/package-lock.json && echo PRESENT`
Expected: `PRESENT`

Run: `test -d tests/fixtures/static-analysis/eslint/node_modules && echo LEAKED || echo CLEAN`
Expected: `CLEAN`

- [ ] **Step 3: Un-ignore the fixture lockfile in .gitignore**

The repo ignores all `package-lock.json` (`.gitignore:21`). Add a negation so only this fixture's lockfile is tracked. Edit `.gitignore`, replacing the `# Node` block:

```gitignore
# Node
node_modules/
package-lock.json
# Exception: the eslint A/B fixture commits its lockfile so `npm ci` is
# reproducible in the per-agent harness (Phase 3.2b apparatus fix).
!tests/fixtures/static-analysis/eslint/package-lock.json
```

- [ ] **Step 4: Verify git now tracks the fixture lockfile**

Run: `git check-ignore tests/fixtures/static-analysis/eslint/package-lock.json && echo IGNORED || echo TRACKED`
Expected: `TRACKED`

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/static-analysis/eslint/package-lock.json .gitignore
git commit -m "test(ab): commit pinned eslint lockfile for reproducible provisioning"
git push
```

Push immediately — autoUpdate has previously wiped unpushed branches on this clone.

---

## Task 2: Declare the provisioning command in source.yaml

**Files:**
- Modify: `tests/ab/corpus/eslint-smoke-bad-js/source.yaml`

- [ ] **Step 1: Add the setup key**

The `setup` key is optional (not in `_AB_FIXTURE_REQUIRED_KEYS`), so adding it does not affect schema validation for fixtures that omit it. Add this block after the `working_dir_strategy: copy` line in `tests/ab/corpus/eslint-smoke-bad-js/source.yaml`:

```yaml
working_dir_strategy: copy
setup:
  command: npm ci
source_path: tests/fixtures/static-analysis/eslint/
```

(The `source_path` line already exists immediately below `working_dir_strategy`; insert the two `setup` lines between them.)

- [ ] **Step 2: Verify yq parses the new key**

Run: `yq -r '.setup.command' tests/ab/corpus/eslint-smoke-bad-js/source.yaml`
Expected: `npm ci`

- [ ] **Step 3: Verify the ruff fixture is unaffected (no setup key)**

Run: `yq -r '.setup.command // "ABSENT"' tests/ab/corpus/ruff-smoke-bad-py/source.yaml`
Expected: `ABSENT`

- [ ] **Step 4: Commit**

```bash
git add tests/ab/corpus/eslint-smoke-bad-js/source.yaml
git commit -m "test(ab): declare npm ci setup command for eslint fixture"
git push
```

---

## Task 3: Parse and run the setup command in fixture.sh

**Files:**
- Modify: `tests/ab/lib/fixture.sh`
- Test: `tests/lib/test_ab_per_agent_lib.sh`

- [ ] **Step 1: Write the failing test for setup-command parsing**

Append to `tests/lib/test_ab_per_agent_lib.sh`. This test confirms `fixture_load_from_path` populates a new `_AB_FIXTURE_SETUP_COMMAND` global from the `setup.command` key, and leaves it empty when the key is absent.

```bash
test_ab_fixture_parses_setup_command() {
    local lib="$REPO_ROOT/tests/ab/lib/fixture.sh"
    local with_setup="$REPO_ROOT/tests/ab/fixtures/source-yaml-with-setup.yaml"
    local good="$REPO_ROOT/tests/ab/fixtures/source-yaml-good.yaml"

    if [[ ! -f "$lib" || ! -f "$with_setup" || ! -f "$good" ]]; then
        fail "A/B fixture: setup-command fixtures present" "missing"
        return
    fi

    local cmd_present cmd_absent
    cmd_present=$(
        # shellcheck disable=SC1090
        source "$lib"
        fixture_load_from_path "$with_setup" >/dev/null
        echo "${_AB_FIXTURE_SETUP_COMMAND:-}"
    )
    cmd_absent=$(
        # shellcheck disable=SC1090
        source "$lib"
        fixture_load_from_path "$good" >/dev/null
        echo "${_AB_FIXTURE_SETUP_COMMAND:-EMPTY}"
    )

    assert_equals "npm ci" "$cmd_present" "A/B fixture: setup.command parsed when present"
    assert_equals "EMPTY" "$cmd_absent" "A/B fixture: setup.command empty when absent"
}
```

- [ ] **Step 2: Create the test fixture with a setup key**

Create `tests/ab/fixtures/source-yaml-with-setup.yaml`:

```yaml
id: smoke-with-setup
agent: eslint-reviewer
captured_at: 2026-06-02T00:00:00Z
captured_under:
  suite_sha: deadbeef
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
setup:
  command: npm ci
source_path: tests/fixtures/static-analysis/eslint/
intent_ledger: |
  - Test fixture for setup-command parsing.
depends_on: []
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 "setup.command parsed"`
Expected: FAIL — `_AB_FIXTURE_SETUP_COMMAND` is unset, so the present-case assertion reports `expected: npm ci, got: ` (empty).

- [ ] **Step 4: Add setup parsing to fixture_load_from_path**

In `tests/ab/lib/fixture.sh`, inside `fixture_load_from_path`, after the line
`_AB_FIXTURE_SOURCE_YAML="$path"` (currently line 64), add:

```bash
    _AB_FIXTURE_SETUP_COMMAND=$(yq -r '.setup.command // ""' "$path")
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A1 "setup.command parsed"`
Expected: PASS for both `setup.command parsed when present` and `setup.command empty when absent`.

- [ ] **Step 6: Write the failing test for fixture_run_setup**

This test confirms a new `fixture_run_setup <dir>` helper runs the parsed command with `<dir>` as cwd, and is a no-op (success, no error) when no command is set. Use a harmless command (`touch setup-ran`) instead of `npm ci` so the unit test stays offline and fast. Append to `tests/lib/test_ab_per_agent_lib.sh`:

```bash
test_ab_fixture_run_setup_executes_in_dir() {
    local lib="$REPO_ROOT/tests/ab/lib/fixture.sh"
    if [[ ! -f "$lib" ]]; then
        fail "A/B fixture: lib present for run_setup" "missing"
        return
    fi

    local d marker rc_noop
    d=$(mktemp -d)

    # With a command set, fixture_run_setup runs it with $d as cwd.
    (
        # shellcheck disable=SC1090
        source "$lib"
        _AB_FIXTURE_SETUP_COMMAND="touch setup-ran"
        fixture_run_setup "$d"
    )
    if [[ -f "$d/setup-ran" ]]; then
        marker=PRESENT
    else
        marker=ABSENT
    fi

    # With no command, fixture_run_setup is a no-op returning success.
    rc_noop=$(
        # shellcheck disable=SC1090
        source "$lib"
        _AB_FIXTURE_SETUP_COMMAND=""
        set +e
        fixture_run_setup "$d"
        echo $?
    )

    assert_equals "PRESENT" "$marker" "A/B fixture: run_setup executes command in target dir"
    assert_equals "0" "$rc_noop" "A/B fixture: run_setup is a no-op when no command set"

    rm -rf "$d"
}
```

- [ ] **Step 7: Run the test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 "run_setup executes"`
Expected: FAIL — `fixture_run_setup: command not found` (function does not exist yet).

- [ ] **Step 8: Implement fixture_run_setup**

In `tests/ab/lib/fixture.sh`, add this function after `fixture_materialise` (after its closing `}`, currently line 108). It runs the command in a subshell with the working dir as cwd, so a relative install lands in the right tree:

```bash
# Run the fixture's optional setup command (e.g. `npm ci`) once into <dir>,
# with <dir> as cwd. No-op (success) when no setup.command is declared.
fixture_run_setup() {
    local dir="$1"
    if [[ -z "${_AB_FIXTURE_SETUP_COMMAND:-}" ]]; then
        return 0
    fi
    ( cd "$dir" && eval "$_AB_FIXTURE_SETUP_COMMAND" )
}
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A1 "run_setup executes"`
Expected: PASS for both `run_setup executes command in target dir` and `run_setup is a no-op when no command set`.

- [ ] **Step 10: Run the full suite to confirm no regressions**

Run: `bash tests/run.sh 2>&1 | tail -5`
Expected: all tests pass (the suite previously reported 334 passed / 1 skipped; expect that plus the 4 new assertions).

- [ ] **Step 11: Commit**

```bash
git add tests/ab/lib/fixture.sh tests/ab/fixtures/source-yaml-with-setup.yaml tests/lib/test_ab_per_agent_lib.sh
git commit -m "feat(ab): add fixture setup-command primitive (parse + run)"
git push
```

---

## Task 4: Template-once + per-trial isolation in run.sh

**Files:**
- Modify: `tests/ab/run.sh:248-286` (the materialise block + trial loop in `_ab_run_per_agent`)

- [ ] **Step 1: Replace the single-shared-dir materialise with template + provision**

In `tests/ab/run.sh`, the current block (lines 248-251) is:

```bash
    # Materialise the working dir once and reuse across trials.
    local working_dir="${CLAUDE_TEMP_DIR:-/tmp}/per-agent-${timestamp}"
    fixture_materialise "$working_dir"
    trap "fixture_cleanup '$working_dir'" EXIT
```

Replace it with a template dir that is materialised AND provisioned once:

```bash
    # Materialise + provision a TEMPLATE once, then give each trial a fresh
    # per-trial copy of the template (Phase 3.2b: hermetic, order-independent
    # trials — no shared mutable working dir, no install race).
    local template_dir="${CLAUDE_TEMP_DIR:-/tmp}/per-agent-${timestamp}-template"
    fixture_materialise "$template_dir"
    fixture_run_setup "$template_dir"
    local trials_root="${CLAUDE_TEMP_DIR:-/tmp}/per-agent-${timestamp}-trials"
    mkdir -p "$trials_root"
    trap "fixture_cleanup '$template_dir'; rm -rf '$trials_root'" EXIT
```

- [ ] **Step 2: Give each trial its own working dir copied from the template**

In the same function, the trial loop (lines 260-286) currently passes the shared `$working_dir` to `agent_dispatch_run_trial`. Inside the loop, after `mkdir -p "$trial_dir"` (line 264) and before the `echo "[...] launching"` line, add a per-trial working dir provisioned by copying the template:

```bash
        local trial_work="$trials_root/$trial_num"
        mkdir -p "$trial_work"
        cp -R "$template_dir/." "$trial_work/"
```

Then change the `agent_dispatch_run_trial` argument on the line currently reading `"$working_dir" \` (line 276) to:

```bash
            "$trial_work" \
```

- [ ] **Step 3: Verify the edited function is syntactically valid**

Run: `bash -n tests/ab/run.sh && echo OK`
Expected: `OK` (no syntax errors).

- [ ] **Step 4: Verify no remaining reference to the old `working_dir` variable**

Run: `grep -n 'working_dir' tests/ab/run.sh`
Expected: no matches inside `_ab_run_per_agent` (the variable is gone; `template_dir`/`trial_work`/`trials_root` replace it). Any matches must be in comments or other functions — confirm none are live code paths in the per-agent loop.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/run.sh
git commit -m "feat(ab): per-trial working-dir isolation from a provisioned template"
git push
```

---

## Task 5: Live verification — the race is gone

This is the spec's mechanical success criterion for PR A. It costs ~20 Haiku/low trials (≈ the 3.2 probe spend) and must run against real Bedrock, so it is a manual gated step, not an offline unit test.

**Files:** none modified (verification only). Produces a gitignored run dir under `tests/ab/runs/`.

- [ ] **Step 1: Run the existing eslint Haiku/low config on the fixed harness**

Run: `bash tests/ab/run.sh --mode per-agent --config tests/ab/configs/per-agent/eslint-haiku-low.yaml --corpus eslint-smoke-bad-js --trials 20 --stream-json`

(Confirm the exact flag spellings against `tests/ab/run.sh`'s argument parser before running; the config/corpus/trials/stream-json flags are the ones 3.2 used.)

Expected: 20 trials complete; the completion summary reports no missing-binary skips.

- [ ] **Step 2: Confirm zero binary-missing skips in the trial outputs**

Run: `grep -rl "not available on PATH or in node_modules" tests/ab/runs/<new-run-dir>/trial-*/ | wc -l`
Expected: `0` (contrast Phase 3.2, where trials 016 and 019 emitted this sentinel).

- [ ] **Step 3: Confirm the agent resolved the tool on tier 1 with no self-provisioning**

This is the load-bearing proof (spec §Verifications): the agent must find `node_modules/.bin/eslint` already present and NOT run `npm install` or `npx`. Pick any trial and inspect its command trace.

Run: `grep -o '"command":"[^"]*"' tests/ab/runs/<new-run-dir>/trial-001/stream.jsonl | grep -E 'npm install|npx'`
Expected: no output (no `npm install`, no `npx` — the template already carries `node_modules`).

Run: `grep -c 'node_modules/.bin/eslint' tests/ab/runs/<new-run-dir>/trial-001/stream.jsonl`
Expected: ≥1 (the agent invoked the pre-provisioned project-local binary).

- [ ] **Step 4: Record the verification outcome**

If Steps 2-3 pass, PR A's success criterion is met: the confound is removed. Note the run-dir timestamp; PR B's clean re-probe builds on this verified harness. If any step fails, the isolation/provisioning wiring is wrong — do NOT proceed to PR B; debug Task 3/Task 4 first.

- [ ] **Step 5 (optional): open the PR**

If the work was done on a branch, open PR A. The body must lead with a brief non-technical contextual summary (per repo PR conventions): this is the first of the Phase 3.2b sequence, fixing the test-harness confound that made the earlier eslint cost-tuning result inconclusive.

---

## Self-review

**Spec coverage (PR A scope only):**
- §A1 deterministic provisioning → Task 1 (lockfile + un-ignore) ✓
- §A2 per-trial isolation → Task 4 (template + `cp -R` per trial) ✓
- §A3 generalised `setup` key → Task 2 (declare) + Task 3 (parse + run) ✓
- §"ruff byte-unchanged" regression guard → Task 2 Step 3 + Task 3 noop test + Task 3 Step 10 full-suite run ✓
- §"PR A success criterion: zero binary-missing skips" → Task 5 Step 2 ✓
- §Verifications "ground against a live trace; tier-1 resolution, no install turns" → Task 5 Step 3 ✓
- §Verifications "result-envelope field names confirmed" → deferred to PR B (cost-column capture is a PR B deliverable, not PR A) ✓

**Placeholder scan:** No TBD/TODO. Every code step shows the exact code; every run step shows the command and expected output. The only `<placeholder>` is `<new-run-dir>` in Task 5, which is an unavoidable runtime-generated timestamp the operator substitutes.

**Type/name consistency:** The new global `_AB_FIXTURE_SETUP_COMMAND` is defined in Task 3 Step 4 and consumed by `fixture_run_setup` (Task 3 Step 8) and the test (Task 3 Step 1/6). The helper `fixture_run_setup` is defined in Task 3 Step 8 and called in `run.sh` Task 4 Step 1. The dir variables `template_dir` / `trials_root` / `trial_work` are introduced together in Task 4 and used consistently. No drift.

**Scope guard:** No task touches any `*-reviewer.md` body, any `*.yaml` config `model`/`effort` field, or the parser dispatch table. PR A is purely apparatus.
