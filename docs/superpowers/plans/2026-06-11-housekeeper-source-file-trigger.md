# Housekeeper Source-File Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen `$HOUSEKEEPING_DETECTED` so the housekeeper specialist also dispatches when a PR edits a .NET or npm *source* file (not only a dependency manifest), matching the engine's already-correct per-ecosystem scope resolution.

**Architecture:** Docs/test-only change. The detection prose in Step 2.6 lives byte-identically in three synced files (`includes/review-pipeline.md` canonical, `commands/pre-review.md`, `skills/review-gh-pr/SKILL.md`). We append source-file extensions that mirror the engine's `_NUGET_SCOPE_SUFFIXES`/`_NPM_SCOPE_SUFFIXES` constants, then add a sync-note test that pins the prose list against those engine constants so they cannot drift.

**Tech Stack:** Markdown prose (pipeline includes), Bash test harness (`tests/lib/test_sync_notes.sh`, auto-discovered by `test_` prefix), Python stdlib engine (read-only here — `bin/housekeeper-freshness`).

---

## File Structure

- `plugins/code-review-suite/includes/review-pipeline.md` — canonical Step 2.6 detection bullet (line 693). Edit first.
- `plugins/code-review-suite/commands/pre-review.md` — mirror (line 694).
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — mirror (line 799).
- `tests/lib/test_sync_notes.sh` — append new test `test_housekeeping_trigger_mirrors_engine_scope`.
- `plugins/code-review-suite/bin/housekeeper-freshness` — READ ONLY (source of truth for the extension list; not modified).

The three prose edits are identical text. The test locks the relationship. No engine or agent code changes.

---

## Task 1: Add the sync-note test (TDD — written first, must fail against current prose)

**Files:**
- Modify: `tests/lib/test_sync_notes.sh` (append a new function at end of file)
- Reference (read-only): `plugins/code-review-suite/bin/housekeeper-freshness` lines 416, 615

**Context the engineer needs:**
- The harness (`tests/lib/harness.sh`) provides `REPO_ROOT`, and the helpers `pass "<label>"`, `fail "<label>" "<reason>"`, `skip "<label>" "<reason>"`. Tests are auto-discovered by their `test_` prefix — no registration.
- `_cr_dir()` (already defined in this file) echoes `$REPO_ROOT/plugins/code-review-suite`.
- The engine declares two tuples of scope suffixes. The test greps the literal extension tokens out of the detection prose and asserts each one is present somewhere in the engine file. This catches drift in the direction that matters: a trigger naming an extension the engine does not scope (dead dispatch), and indirectly documents the reverse.

- [ ] **Step 1: Write the failing test**

Append to the end of `tests/lib/test_sync_notes.sh`:

```bash
test_housekeeping_trigger_mirrors_engine_scope() {
    # The Step 2.6 "Housekeeping detection" prose names source-file extensions
    # that MUST mirror the engine's _NUGET_SCOPE_SUFFIXES / _NPM_SCOPE_SUFFIXES
    # constants. If the trigger names an extension the engine does not scope, the
    # housekeeper dispatches and finds nothing (dead dispatch). This test pins the
    # prose list against the engine so the two cannot drift silently — the exact
    # failure mode the 2026-06-11 source-file-trigger change fixed.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "housekeeping trigger mirrors engine scope" "code-review-suite plugin not found"
        return
    fi

    local pipeline engine
    pipeline="$cr/includes/review-pipeline.md"
    engine="$cr/bin/housekeeper-freshness"

    if [[ ! -f "$pipeline" || ! -f "$engine" ]]; then
        fail "housekeeping trigger mirrors engine scope: inputs present" \
            "missing pipeline ($pipeline) or engine ($engine)"
        return
    fi

    # Extract the "Housekeeping detection" bullet line from the canonical.
    local bullet
    bullet=$(grep -F 'Housekeeping detection:' "$pipeline" | head -1)
    if [[ -z "$bullet" ]]; then
        fail "housekeeping trigger mirrors engine scope: bullet found" \
            "no 'Housekeeping detection:' bullet in review-pipeline.md"
        return
    fi

    # Every source-file extension the trigger must name (mirror of the engine
    # scope sets, source files only — manifest extensions like .csproj are tested
    # by the existing prose-parity test, not here).
    local ext missing
    missing=""
    for ext in .cs .fs .vb .razor .cshtml .ts .tsx .js .jsx .mjs .cjs .mts .cts .vue .svelte; do
        # Present in the trigger prose?
        if ! grep -qF "\`$ext\`" <<<"$bullet"; then
            missing="$missing prose:$ext"
            continue
        fi
        # Present in an engine scope constant?
        if ! grep -qF "\"$ext\"" "$engine"; then
            missing="$missing engine:$ext"
        fi
    done

    if [[ -z "$missing" ]]; then
        pass "housekeeping trigger mirrors engine scope: all source extensions present in prose and engine"
    else
        fail "housekeeping trigger mirrors engine scope: all source extensions present in prose and engine" \
            "extensions missing (prose:X = absent from trigger bullet, engine:X = absent from engine scope constants):$missing"
    fi
}
```

- [ ] **Step 2: Run the test to verify it FAILS**

Run: `cd /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins && bash tests/run.sh 2>&1 | grep -A2 'housekeeping trigger mirrors'`

Expected: FAIL, listing `prose:.cs prose:.fs ...` — the current trigger bullet names no source extensions, so every one is absent from the prose. (The engine side already has them, so only `prose:` entries appear.)

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/lib/test_sync_notes.sh
git commit -m "test(housekeeper): pin trigger source-extension list to engine scope constants"
```

(Committing red is intentional in this TDD flow — Task 2 turns it green. If you prefer not to commit red, defer this commit and fold it into Task 2's commit.)

---

## Task 2: Widen the detection prose in the canonical (`review-pipeline.md`)

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md:693`

**Context:** This is the canonical copy. The exact current line is below — replace it verbatim. Note the change also folds `.targets` into the manifest list (engine scopes it; prose currently omits it) so prose and engine align.

- [ ] **Step 1: Replace the detection bullet**

Find this exact line (line 693):

```
   - **Housekeeping detection:** if any changed file is under `.github/workflows/` and ends `.yml`/`.yaml`, is a `package.json` (npm manifest), ends `.csproj`/`.fsproj`/`.vbproj`/`.props`, or is a `packages.lock.json` (NuGet manifests), set `$HOUSEKEEPING_DETECTED = true`. (This slice covers GitHub Actions, workflow runners, npm, and NuGet; follow-on plans extend the trigger to PyPI/crates/Go/RubyGems/Docker/SDK manifests.)
```

Replace with:

```
   - **Housekeeping detection:** if any changed file is under `.github/workflows/` and ends `.yml`/`.yaml`; is a `package.json` (npm manifest); ends `.csproj`/`.fsproj`/`.vbproj`/`.props`/`.targets`; is a `packages.lock.json` (NuGet manifest); is a .NET source file ending `.cs`/`.fs`/`.vb`/`.razor`/`.cshtml`; or is an npm source file ending `.ts`/`.tsx`/`.js`/`.jsx`/`.mjs`/`.cjs`/`.mts`/`.cts`/`.vue`/`.svelte`, set `$HOUSEKEEPING_DETECTED = true`. The source-file extensions mirror the engine's `_NUGET_SCOPE_SUFFIXES`/`_NPM_SCOPE_SUFFIXES` scope sets: a changed source file pulls in its nearest-ancestor project and the engine audits all that project's dependencies (not only changed manifest lines). (This slice covers GitHub Actions, workflow runners, npm, and NuGet; follow-on plans extend both the engine scope sets and this trigger in lockstep for PyPI/crates/Go/RubyGems/Docker/SDK.)
```

- [ ] **Step 2: Verify the test now passes**

Run: `cd /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins && bash tests/run.sh 2>&1 | grep 'housekeeping trigger mirrors'`

Expected: PASS — `all source extensions present in prose and engine`.

- [ ] **Step 3: Do NOT commit yet**

The prose-parity test (`test_*` that compares the three files' detection bullets) will now FAIL because `pre-review.md` and `SKILL.md` still hold the old line. Tasks 3 and 4 fix those before the next commit. (If you committed the red test separately in Task 1, hold this commit until Task 4.)

---

## Task 3: Mirror the edit into `commands/pre-review.md`

**Files:**
- Modify: `plugins/code-review-suite/commands/pre-review.md:694`

- [ ] **Step 1: Apply the identical replacement**

Find the same old bullet text shown in Task 2 Step 1 (it is byte-identical at `pre-review.md:694`) and replace it with the same new bullet text from Task 2 Step 1.

- [ ] **Step 2: No standalone verification**

Parity is verified once all three files match — see Task 4 Step 2.

---

## Task 4: Mirror the edit into `skills/review-gh-pr/SKILL.md` and verify the full suite

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md:799`

- [ ] **Step 1: Apply the identical replacement**

Find the same old bullet text shown in Task 2 Step 1 (byte-identical at `SKILL.md:799`) and replace it with the same new bullet text from Task 2 Step 1.

- [ ] **Step 2: Run the full test suite**

Run: `cd /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins && bash tests/run.sh`

Expected: all tests pass. Specifically confirm:
- `test_housekeeping_trigger_mirrors_engine_scope` — PASS.
- The existing detection-prose parity test across the three synced files — PASS (all three now hold identical new text).
- No other test regressed.

If the `bad-config rejection` test false-fails on a dirty tree, that is a known artifact — commit first (Step 4) then re-run.

- [ ] **Step 3: Engine regression check (proves only the trigger needed fixing)**

Confirm the engine already honours a source-only changeset. Use the existing NuGet fixture under `tests/fixtures/static-analysis/housekeeper/` (or any fixture project containing a `.csproj` with a stale dep). Write a changed-files list naming only a `.cs` path inside that project and an empty changed-lines file:

```bash
cd /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins
printf 'tests/fixtures/static-analysis/housekeeper/SomeProject/Program.cs\n' > "${CLAUDE_TEMP_DIR}/cf.txt"
: > "${CLAUDE_TEMP_DIR}/cl.txt"
HOUSEKEEPER_REGISTRY_FIXTURES=<fixtures-dir> plugins/code-review-suite/bin/housekeeper-freshness --root . --changed-files-from "${CLAUDE_TEMP_DIR}/cf.txt" --changed-lines-from "${CLAUDE_TEMP_DIR}/cl.txt"
```

Expected: a non-empty JSON tuple array for that project's stale deps — demonstrating the engine resolves `.cs` → nearest `.csproj` → all deps with no manifest in the changed-files list. (Adjust the `.cs` path and fixtures dir to the actual fixture layout; if no suitable fixture exists, this step is documentation-only — note it and proceed. The engine's own 31 unittests already cover `nuget_scope_roots`.)

- [ ] **Step 4: Commit all prose + test changes together**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md tests/lib/test_sync_notes.sh
git commit -m "feat(housekeeper): dispatch on edited source files, not just manifests"
```

- [ ] **Step 5: Push (house rule: push immediately)**

```bash
git push
```

Then refresh the plugin cache so the new trigger is live in-session: run `/plugins update` then `/reload-plugins` (per the marketplace cache-staleness rule).

---

## Self-Review notes

- **Spec coverage:** prose widening (Tasks 2–4), explicit-extensions decision (the literal lists in Task 2), mirror contract + sync test (Task 1), "engine/agent NOT changed" (no task touches them), verification incl. engine regression (Task 4 Step 3). All spec sections map to a task.
- **`.targets` fold-in:** included in Task 2's manifest list per the spec's note; the new test only pins *source* extensions, so `.targets` does not need to appear in the test loop.
- **Commit ordering:** Task 1 may commit red; Tasks 2–4 land green. The single combined commit in Task 4 keeps prose + test in one logical change if Task 1's separate commit is skipped.
- **No placeholders:** every edit shows exact before/after text; every command is runnable.
