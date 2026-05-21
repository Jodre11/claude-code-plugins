# A/B Test Harness — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a minimum-viable shell A/B harness in `tests/ab/` that runs the code review suite end-to-end against one hard-coded corpus PR under one named config, captures mechanical metrics (wall-clock, exit code, report length, verdict), and reverts all in-tree mutations to tracked agent and dispatch-prompt files via an `EXIT` trap.

**Architecture:** A single Bash entry point (`tests/ab/run.sh`) orchestrates preflight → manifest → mutation install (with revert trap) → trial loop → summary CSV. Three sourced helpers (`lib/mutate.sh`, `lib/launch.sh`, `lib/capture.sh`) handle the failure-sensitive primitives. Configuration is one YAML file; the corpus PR is hard-coded as a Phase 1 shortcut. The harness drives all variation by editing tracked files in the working tree and reverting via `git checkout --` on every exit path — the suite stays unaware it is being tested.

**Tech Stack:** Bash 4+, `yq` (Mike Farah, Go), `jq`, `gh` CLI, `git`, GNU `timeout` (or `gtimeout` on macOS). The harness invokes `command claude -p` directly with `--permission-mode bypassPermissions`, `--model`, `--effort`, and a per-trial timeout. Source `~/.claudeenv` and run `~/.claude/scripts/aws-sso-preflight.sh` from inside the harness — the user's `claude()` shell function is bypassed.

**Spec:** [`docs/superpowers/specs/2026-05-21-ab-test-harness-design.md`](../specs/2026-05-21-ab-test-harness-design.md) (commit `bbd7d81`). Refer to the spec for design rationale and decision log; this plan implements the Phase 1 slice only.

**Driving experiment:** Does the literal `ultrathink` keyword at the start of the synthesiser dispatch prompt actually escalate thinking budget on the dispatched subagent, or is it ornamental? Phase 1's success criterion is: the harness answers this question on PR #29 (3 trials baseline + 3 trials with the keyword stripped) with mechanical metrics alone.

---

## File Structure

**New files (Phase 1):**

| Path | Responsibility |
|---|---|
| `tests/ab/run.sh` | Orchestrator: preflight → manifest → mutate → loop → revert → summary. Single entry point, single source of truth for the run lifecycle. |
| `tests/ab/lib/mutate.sh` | Owns the in-tree-edit-and-revert mechanism. Edits agent frontmatter `model:` lines and strips the `ultrathink` keyword from all three synthesiser dispatch sites. Installs the `EXIT`/`INT`/`TERM`/`HUP` revert trap. The most failure-sensitive component. |
| `tests/ab/lib/launch.sh` | Headless invocation: source `~/.claudeenv`, run SSO preflight once, exec `command claude -p` with `--permission-mode bypassPermissions`, `--model`, `--effort`, per-trial timeout. |
| `tests/ab/lib/capture.sh` | Parse trial output: extract synthesiser report block, capture verdict, write `timing.json` and `usage.json` (null-tolerant). |
| `tests/ab/lib/config.sh` | Minimal YAML config loader: validate schema, expose `model:` and `ultrathink:` fields per agent. |
| `tests/ab/configs/no-ultrathink.yaml` | The Phase 1 experiment config. Strips `ultrathink` keyword from synthesiser dispatch; leaves all model assignments at production defaults. |
| `tests/ab/configs/baseline.yaml` | Control config: no mutations. Documents the production defaults explicitly. |
| `tests/ab/README.md` | One page: how to run, what it does, what it does not do, where output lands. |
| `tests/lib/test_ab_harness.sh` | Structural tests for the harness scripts (shebangs, `set -euo pipefail`, fixture-based mutation tests, idempotent revert). Hooks into the existing `tests/run.sh` discovery loop. |
| `tests/ab/fixtures/synthesiser-dispatch-before.md` | Golden-input fixture for `lib/mutate.sh` tests: a copy of one synthesiser dispatch block before the `ultrathink` strip. |
| `tests/ab/fixtures/synthesiser-dispatch-after.md` | Golden-output fixture: the same block after the strip. Used to assert the mutation produces byte-identical output. |
| `tests/ab/fixtures/agent-before.md` | Golden-input fixture for the frontmatter `model:` rewrite test. |
| `tests/ab/fixtures/agent-after.md` | Golden-output fixture for the same. |

**Modified files (Phase 1):**

| Path | Change |
|---|---|
| `.gitignore` | Add `tests/ab/runs/` to ignore output directories. |
| `README.md` (top-level) | Add a one-line entry under an "Internal tooling" subsection pointing at `tests/ab/README.md`. |

**Modified files (housekeeping PR, lands first):**

| Path | Change |
|---|---|
| `.github/workflows/tests.yml` | Bump pinned action SHAs to the latest stable major; pin `runs-on:` to `ubuntu-24.04`. |
| `.github/workflows/gitleaks.yml` | Same audit as above. |

**Out of scope for Phase 1 (do not create):** `tests/ab/score.sh`, `tests/ab/corpus/*.yaml`, `tests/ab/lib/corpus.sh`, `--dry-run` flag, seeded-bug support, differential agreement scoring. The spec explicitly cuts these from Phase 1.

---

## Task 1: Housekeeping — bump GitHub Actions and runner pins (separate PR, lands first)

Per CLAUDE.md "Repo Housekeeping (always while we're here)": this lands as a separate PR ahead of the harness PR. Do not bundle into the harness PR.

**Files:**
- Modify: `.github/workflows/tests.yml`
- Modify: `.github/workflows/gitleaks.yml`

- [ ] **Step 1: Inspect current pins**

Run:

```bash
grep -nE 'uses:|runs-on:' .github/workflows/tests.yml .github/workflows/gitleaks.yml
```

Expected output (current state, baseline for comparison):

```
.github/workflows/tests.yml:10:    runs-on: ubuntu-latest
.github/workflows/tests.yml:12:      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
.github/workflows/gitleaks.yml:11:    runs-on: ubuntu-latest
.github/workflows/gitleaks.yml:13:      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
.github/workflows/gitleaks.yml:16:      - uses: gitleaks/gitleaks-action@ff98106e4c7b2bc287b24eaf42907196329070c7 # v2.3.9
```

- [ ] **Step 2: Resolve the latest stable SHA for each action**

Run for each pinned action:

```bash
gh api repos/actions/checkout/releases/latest --jq '.tag_name + " " + .target_commitish'
gh api repos/gitleaks/gitleaks-action/releases/latest --jq '.tag_name + " " + .target_commitish'
```

Then resolve the commit SHA for the published tag (GitHub may publish releases against branch tips; the immutable SHA is what we pin):

```bash
gh api repos/actions/checkout/git/refs/tags/<tag-name> --jq '.object.sha'
gh api repos/gitleaks/gitleaks-action/git/refs/tags/<tag-name> --jq '.object.sha'
```

If the SHA already matches what's in the workflow file, no bump is required for that action — note this in the commit message.

- [ ] **Step 3: Update each `uses:` line**

Replace the SHA and the trailing `# v…` comment in lockstep. The comment must always reflect the SHA on the same line.

Before:

```yaml
- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
```

After (illustrative — substitute the actual resolved SHA and tag from Step 2):

```yaml
- uses: actions/checkout@<resolved-sha> # <resolved-tag>
```

- [ ] **Step 4: Pin runner to a specific Ubuntu version**

`ubuntu-latest` is a moving target and CLAUDE.md asks for a specific runner pin. Replace both occurrences:

Before:

```yaml
runs-on: ubuntu-latest
```

After:

```yaml
runs-on: ubuntu-24.04
```

- [ ] **Step 5: Verify YAML still parses and the diff is the intended one**

Run:

```bash
yq '.' .github/workflows/tests.yml >/dev/null
yq '.' .github/workflows/gitleaks.yml >/dev/null
git diff --stat .github/workflows/
git diff .github/workflows/
```

Expected: zero stderr from `yq`, the diff touches only the four lines identified in Step 1.

- [ ] **Step 6: Run the structural tests**

Run:

```bash
tests/run.sh
```

Expected: PASS for the entire suite (workflows are not directly under structural-test inspection but a clean run confirms nothing else regressed).

- [ ] **Step 7: Commit and open the housekeeping PR**

Stage only the workflow files. Do not include any harness-related changes.

```bash
git checkout -b chore/ci-action-and-runner-pins
git add .github/workflows/tests.yml .github/workflows/gitleaks.yml
git commit -m "$(cat <<'EOF'
chore(ci): bump action SHAs to latest stable and pin runners to ubuntu-24.04

Routine housekeeping before the A/B harness PR (feat/ab-test-harness-spec)
lands. Bumps actions/checkout and gitleaks/gitleaks-action to the latest
stable releases, and replaces ubuntu-latest with ubuntu-24.04 so the runner
version is explicit rather than tracking GitHub's rolling alias.
EOF
)"
git push -u origin chore/ci-action-and-runner-pins
gh pr create --title "chore(ci): bump action SHAs and pin runners" --body-file "${CLAUDE_TEMP_DIR}/housekeeping-pr-body.md"
```

The PR body (write to `${CLAUDE_TEMP_DIR}/housekeeping-pr-body.md` first) should include:

```markdown
Routine CI housekeeping landing ahead of the upcoming A/B test harness PR
(`feat/ab-test-harness-spec`). The harness PR will modify the same workflow
files and we want the dependency-and-runner bumps to land cleanly first so
the harness diff stays focused on the harness itself.

## Changes

- Bump `actions/checkout` SHA pin to the latest stable release.
- Bump `gitleaks/gitleaks-action` SHA pin to the latest stable release.
- Replace `runs-on: ubuntu-latest` with `runs-on: ubuntu-24.04` in both
  workflows so the runner version is explicit rather than tracking
  GitHub's rolling alias.

## Test plan

- [ ] CI runs green on this branch
- [ ] No behavioural change in `tests/run.sh` output
```

- [ ] **Step 8: Wait for CI green and merge**

Run:

```bash
gh pr checks --watch
gh pr merge --squash --delete-branch
```

Then return to `feat/ab-test-harness-spec` for the harness work:

```bash
git checkout feat/ab-test-harness-spec
git pull --rebase origin main
```

---

## Task 2: Scaffold `tests/ab/` and wire structural tests

Set up the directory tree, gitignore the runs output directory, and add the harness's own structural test file to the existing `tests/run.sh` discovery loop. This is the first commit on the harness branch.

**Files:**
- Create: `tests/ab/run.sh` (skeleton — body filled in later tasks)
- Create: `tests/ab/lib/.gitkeep`
- Create: `tests/ab/configs/.gitkeep`
- Create: `tests/ab/fixtures/.gitkeep`
- Create: `tests/lib/test_ab_harness.sh`
- Modify: `.gitignore`
- Test: `tests/lib/test_ab_harness.sh` (this is the test file itself)

- [ ] **Step 1: Add the runs output directory to `.gitignore`**

Append to the end of `.gitignore`, in a new section to match the existing style:

```
# A/B test harness output
tests/ab/runs/
```

- [ ] **Step 2: Create the directory scaffold with `.gitkeep` placeholders**

Run:

```bash
mkdir -p tests/ab/lib tests/ab/configs tests/ab/fixtures
touch tests/ab/lib/.gitkeep tests/ab/configs/.gitkeep tests/ab/fixtures/.gitkeep
```

- [ ] **Step 3: Create `tests/ab/run.sh` skeleton**

Write to `tests/ab/run.sh`:

```bash
#!/usr/bin/env bash
# A/B test harness — entry point.
# Runs N trials of one corpus PR under one named config, captures mechanical
# metrics, reverts all in-tree mutations on exit. See tests/ab/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/config.sh
# shellcheck source=lib/mutate.sh
# shellcheck source=lib/launch.sh
# shellcheck source=lib/capture.sh

usage() {
    cat <<'EOF'
Usage: tests/ab/run.sh --config <path> --trials <n> [--name <experiment-name>] [--timeout-seconds <n>]

Required:
  --config <path>           Path to a YAML config under tests/ab/configs/
  --trials <n>              Number of trials to run (positive integer)

Optional:
  --name <name>             Human label for the run directory (default: derived from config name)
  --timeout-seconds <n>     Per-trial timeout in seconds (default: 1800)
  -h, --help                Show this help

Phase 1 limitation: the corpus PR is hard-coded. See tests/ab/README.md.
EOF
}

main() {
    # Filled in by later tasks. For now, fail loudly so the scaffold cannot be
    # accidentally invoked as if implemented.
    echo "tests/ab/run.sh: not yet implemented (scaffold only)" >&2
    exit 64  # EX_USAGE
}

main "$@"
```

Make it executable:

```bash
chmod +x tests/ab/run.sh
```

- [ ] **Step 4: Write the failing structural test**

Create `tests/lib/test_ab_harness.sh`:

```bash
#!/usr/bin/env bash
# Structural tests for the A/B test harness scaffold and lib scripts.

_ab_dir() {
    echo "$REPO_ROOT/tests/ab"
}

test_ab_scaffold_present() {
    local ab
    ab=$(_ab_dir)
    if [[ ! -d "$ab" ]]; then
        fail "A/B harness: tests/ab/ exists" "directory missing"
        return
    fi

    assert_file_exists "tests/ab/run.sh" "A/B harness: run.sh exists"
    assert_dir_exists "tests/ab/lib" "A/B harness: lib/ exists"
    assert_dir_exists "tests/ab/configs" "A/B harness: configs/ exists"
    assert_dir_exists "tests/ab/fixtures" "A/B harness: fixtures/ exists"

    if [[ -x "$ab/run.sh" ]]; then
        pass "A/B harness: run.sh is executable"
    else
        fail "A/B harness: run.sh is executable" "missing +x bit on tests/ab/run.sh"
    fi
}

test_ab_runs_dir_gitignored() {
    if grep -qE '^tests/ab/runs/?$' "$REPO_ROOT/.gitignore"; then
        pass "A/B harness: tests/ab/runs/ is gitignored"
    else
        fail "A/B harness: tests/ab/runs/ is gitignored" \
            "expected an exact line 'tests/ab/runs/' in .gitignore so trial output never accidentally lands in commits"
    fi
}

test_ab_shell_scripts_have_strict_mode() {
    local script
    for script in "$REPO_ROOT"/tests/ab/run.sh "$REPO_ROOT"/tests/ab/lib/*.sh; do
        if [[ ! -f "$script" ]]; then
            continue
        fi
        local rel="${script#"$REPO_ROOT/"}"
        if head -5 "$script" | grep -qE '^set -euo pipefail$'; then
            pass "A/B harness: $rel uses set -euo pipefail"
        else
            fail "A/B harness: $rel uses set -euo pipefail" \
                "every shell script in tests/ab/ must declare strict mode in its first 5 lines"
        fi
        if head -1 "$script" | grep -qE '^#!/usr/bin/env bash$'; then
            pass "A/B harness: $rel has /usr/bin/env bash shebang"
        else
            fail "A/B harness: $rel has /usr/bin/env bash shebang" \
                "first line must be '#!/usr/bin/env bash' for portability"
        fi
    done
}
```

- [ ] **Step 5: Run the test suite**

Run:

```bash
tests/run.sh
```

Expected: all existing tests still pass; the three new `test_ab_*` tests pass (the scaffold satisfies them as written).

- [ ] **Step 6: Commit**

```bash
git add tests/ab/ tests/lib/test_ab_harness.sh .gitignore
git commit -m "$(cat <<'EOF'
feat(tests/ab): scaffold A/B harness directory and structural tests

Adds tests/ab/{run.sh,lib/,configs/,fixtures/} with a non-functional run.sh
skeleton, gitignores tests/ab/runs/ for trial output, and adds
tests/lib/test_ab_harness.sh hooked into the existing structural test
discovery loop. Subsequent commits flesh out lib/mutate.sh, lib/launch.sh,
lib/capture.sh, lib/config.sh, and the run.sh body.
EOF
)"
```

---

## Task 3: `lib/mutate.sh` — mutation install + revert trap (TDD with fixtures)

This is the most failure-sensitive component. A leaked dirty working tree from a half-reverted mutation poisons every subsequent run. We TDD it against fixtures so the mutation logic is testable in isolation, before wiring it into the live tree.

**Files:**
- Create: `tests/ab/lib/mutate.sh`
- Create: `tests/ab/fixtures/synthesiser-dispatch-before.md`
- Create: `tests/ab/fixtures/synthesiser-dispatch-after.md`
- Create: `tests/ab/fixtures/agent-before.md`
- Create: `tests/ab/fixtures/agent-after.md`
- Modify: `tests/lib/test_ab_harness.sh` (add fixture-based tests)

- [ ] **Step 1: Capture the synthesiser-dispatch fixture (before state)**

The mutation strips the literal `ultrathink\n\n` prefix from a single line in three sync sites. Write a minimal fixture that mirrors the real shape of the dispatch block exactly enough to exercise the regex.

Create `tests/ab/fixtures/synthesiser-dispatch-before.md`:

```markdown
Some preamble text.

```
Agent({
    description: "Synthesise review findings",
    subagent_type: "code-review-suite:review-synthesiser",
    name: "review-synthesiser",
    mode: "auto",
    model: "opus",
    prompt: "ultrathink\n\nBase branch: $BASE\nHead SHA: $HEAD_SHA\nReview mode: $REVIEW_MODE\n\nRest of prompt elided for fixture brevity."
})
```

Trailing prose — must not be touched by the mutation.
```

- [ ] **Step 2: Capture the synthesiser-dispatch fixture (after state)**

Create `tests/ab/fixtures/synthesiser-dispatch-after.md` — identical to `-before.md` except the `ultrathink\n\n` prefix is stripped:

```markdown
Some preamble text.

```
Agent({
    description: "Synthesise review findings",
    subagent_type: "code-review-suite:review-synthesiser",
    name: "review-synthesiser",
    mode: "auto",
    model: "opus",
    prompt: "Base branch: $BASE\nHead SHA: $HEAD_SHA\nReview mode: $REVIEW_MODE\n\nRest of prompt elided for fixture brevity."
})
```

Trailing prose — must not be touched by the mutation.
```

- [ ] **Step 3: Capture the agent-frontmatter fixture pair**

Create `tests/ab/fixtures/agent-before.md`:

```markdown
---
name: review-synthesiser
description: Test fixture — do not deploy as a real agent.
model: opus
tools: Read, Grep, Glob, Bash
---

Body content. The mutation must not touch lines below the closing `---`.
```

Create `tests/ab/fixtures/agent-after.md` (model rewritten from `opus` to `sonnet`):

```markdown
---
name: review-synthesiser
description: Test fixture — do not deploy as a real agent.
model: sonnet
tools: Read, Grep, Glob, Bash
---

Body content. The mutation must not touch lines below the closing `---`.
```

- [ ] **Step 4: Write the failing mutation tests**

Append to `tests/lib/test_ab_harness.sh`:

```bash
test_ab_mutate_strips_ultrathink_keyword() {
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local before="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-before.md"
    local after="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-after.md"

    if [[ ! -f "$mutate" ]]; then
        fail "A/B mutate: lib/mutate.sh exists" "missing"
        return
    fi
    if [[ ! -f "$before" || ! -f "$after" ]]; then
        fail "A/B mutate: fixtures present" "missing fixture pair"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$before" "$tmp"

    # Source the helper and call its public mutator. The function is named
    # `mutate_strip_ultrathink_keyword <file>` and edits in place.
    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_strip_ultrathink_keyword "$tmp"
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: ultrathink keyword stripped to expected form"
    else
        local diff_output
        diff_output=$(diff -u --label expected --label actual "$after" "$tmp" | head -30 || true)
        fail "A/B mutate: ultrathink keyword stripped to expected form" "$diff_output"
    fi
    rm -f "$tmp"
}

test_ab_mutate_rewrites_agent_model() {
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local before="$REPO_ROOT/tests/ab/fixtures/agent-before.md"
    local after="$REPO_ROOT/tests/ab/fixtures/agent-after.md"

    if [[ ! -f "$mutate" ]]; then
        fail "A/B mutate: lib/mutate.sh exists" "missing"
        return
    fi
    if [[ ! -f "$before" || ! -f "$after" ]]; then
        fail "A/B mutate: agent fixtures present" "missing fixture pair"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$before" "$tmp"

    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_set_agent_model "$tmp" sonnet
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: agent model frontmatter rewritten"
    else
        local diff_output
        diff_output=$(diff -u --label expected --label actual "$after" "$tmp" | head -30 || true)
        fail "A/B mutate: agent model frontmatter rewritten" "$diff_output"
    fi
    rm -f "$tmp"
}

test_ab_mutate_strip_idempotent() {
    # Second strip must be a no-op — exit 0, no edit. Guards against accidental
    # double-strips eating non-ultrathink prompt content.
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local after="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-after.md"

    if [[ ! -f "$mutate" || ! -f "$after" ]]; then
        skip "A/B mutate: idempotent strip" "missing helper or fixture"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$after" "$tmp"

    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_strip_ultrathink_keyword "$tmp"
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: second strip is a no-op"
    else
        fail "A/B mutate: second strip is a no-op" \
            "applying the strip twice produced different output — strip is not idempotent"
    fi
    rm -f "$tmp"
}
```

- [ ] **Step 5: Run the tests to confirm they fail**

Run:

```bash
tests/run.sh
```

Expected: three new tests fail with "A/B mutate: lib/mutate.sh exists — missing" because we have not written the helper yet.

- [ ] **Step 6: Implement `tests/ab/lib/mutate.sh`**

Create `tests/ab/lib/mutate.sh`:

```bash
#!/usr/bin/env bash
# tests/ab/lib/mutate.sh — in-tree mutation primitives + revert trap.
#
# This file is sourced by tests/ab/run.sh. The two public mutator functions
# (mutate_strip_ultrathink_keyword, mutate_set_agent_model) are also exercised
# by tests/lib/test_ab_harness.sh against fixtures.
#
# The revert trap (mutate_install_revert_trap) is the most failure-sensitive
# part of the harness. A leaked dirty working tree from a half-reverted
# mutation poisons every subsequent run. The trap fires on EXIT, INT, TERM,
# and HUP; on a revert failure it writes a MANUAL_REVERT_REQUIRED marker
# rather than continuing silently.
set -euo pipefail

# The three sync sites that must be mutated in lockstep when stripping the
# ultrathink keyword. Test test_sync_synthesiser_dispatch_uses_ultrathink in
# tests/lib/test_sync_notes.sh enforces that all three start with the keyword
# in production. Strip from all three or none.
_AB_ULTRATHINK_SYNC_SITES=(
    "plugins/code-review-suite/includes/review-pipeline.md"
    "plugins/code-review-suite/skills/review-gh-pr/SKILL.md"
    "plugins/code-review-suite/commands/pre-review.md"
)

# Files mutated during the current run. Populated by the public mutators;
# consumed by the revert trap.
_AB_MUTATED_FILES=()

# Run-directory marker location. Set by run.sh before installing the trap.
_AB_RUN_DIR=""

# Strip the literal `ultrathink\n\n` prefix from the synthesiser dispatch
# prompt in a single file. Matches the substring `prompt: "ultrathink\n\n`
# (the `\n` here are the two literal characters, not real newlines — the
# dispatch template encodes newlines in the JSON-like Agent({...}) prompt
# field). Idempotent: applies a no-op edit if the keyword is already absent.
mutate_strip_ultrathink_keyword() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "mutate_strip_ultrathink_keyword: $file: not a regular file" >&2
        return 1
    fi

    # sed -i differs between BSD (macOS) and GNU. Use the portable two-arg form
    # by writing to a temp file and replacing atomically.
    local tmp
    tmp=$(mktemp)
    sed 's/prompt: "ultrathink\\n\\n/prompt: "/' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Rewrite the `model:` line in YAML frontmatter to a new value. Matches the
# first occurrence of `^model:` from the top of the file (frontmatter only —
# bails after the closing `---`). Used to retarget an agent at sonnet/haiku/etc.
mutate_set_agent_model() {
    local file="$1"
    local new_model="$2"

    if [[ ! -f "$file" ]]; then
        echo "mutate_set_agent_model: $file: not a regular file" >&2
        return 1
    fi
    if [[ -z "$new_model" ]]; then
        echo "mutate_set_agent_model: $file: empty model value" >&2
        return 1
    fi

    # awk-based rewrite: only touch lines before the second '---' (which closes
    # the YAML frontmatter). After that we are in body content and must not
    # rewrite anything that happens to start with 'model:'.
    local tmp
    tmp=$(mktemp)
    awk -v new_model="$new_model" '
        BEGIN { dash_count = 0 }
        /^---$/ { dash_count++ }
        dash_count <= 1 && /^model:[[:space:]]/ { print "model: " new_model; next }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Track a path so the revert trap will restore it on exit.
_ab_track_mutation() {
    local file="$1"
    _AB_MUTATED_FILES+=("$file")
}

# Install the revert trap. Must be called from run.sh after _AB_RUN_DIR is set
# but before any mutation is applied. Reverts every tracked file and verifies
# the working tree is clean. On failure it writes MANUAL_REVERT_REQUIRED into
# the run directory and exits non-zero — a louder signal than silent partial
# revert.
mutate_install_revert_trap() {
    if [[ -z "${_AB_RUN_DIR:-}" ]]; then
        echo "mutate_install_revert_trap: _AB_RUN_DIR not set" >&2
        return 1
    fi
    trap '_ab_revert_on_exit' EXIT
    trap '_ab_revert_on_exit; exit 130' INT
    trap '_ab_revert_on_exit; exit 143' TERM
    trap '_ab_revert_on_exit; exit 129' HUP
}

_ab_revert_on_exit() {
    if [[ ${#_AB_MUTATED_FILES[@]} -eq 0 ]]; then
        return 0
    fi

    # `git checkout --` is idempotent and safe even if a file was never edited.
    # We feed every tracked path so a partial-mutation failure is still cleaned.
    local file revert_failed=0
    for file in "${_AB_MUTATED_FILES[@]}"; do
        if ! git -C "$REPO_ROOT" checkout -- "$file" 2>/dev/null; then
            revert_failed=1
            echo "revert: failed to checkout $file" >&2
        fi
    done

    if [[ $revert_failed -eq 1 ]]; then
        _ab_write_manual_revert_marker
        return 0
    fi

    # Verify the working tree is clean across the mutated paths only — we do
    # not touch other files so cannot speak for them. A non-zero diff against
    # any tracked-and-mutated path means revert silently failed.
    if ! git -C "$REPO_ROOT" diff --quiet -- "${_AB_MUTATED_FILES[@]}"; then
        _ab_write_manual_revert_marker
        return 0
    fi

    if [[ -n "$_AB_RUN_DIR" && -d "$_AB_RUN_DIR" ]]; then
        : > "$_AB_RUN_DIR/REVERT_OK"
    fi
}

_ab_write_manual_revert_marker() {
    if [[ -z "$_AB_RUN_DIR" || ! -d "$_AB_RUN_DIR" ]]; then
        echo "MANUAL_REVERT_REQUIRED — run dir unavailable; resolve dirty tree by hand" >&2
        return 0
    fi
    {
        echo "Mutated files (some or all may still be dirty):"
        printf '  %s\n' "${_AB_MUTATED_FILES[@]}"
        echo
        echo "git status:"
        git -C "$REPO_ROOT" status --short
    } > "$_AB_RUN_DIR/MANUAL_REVERT_REQUIRED"
    echo "MANUAL_REVERT_REQUIRED — see $_AB_RUN_DIR/MANUAL_REVERT_REQUIRED" >&2
}

# Apply all mutations declared by the loaded config. Reads the parsed config
# (populated by lib/config.sh into _AB_CONFIG_*) and dispatches per-key.
# Tracks every mutated file via _ab_track_mutation so the trap can revert.
mutate_apply_config() {
    # Strip the ultrathink keyword from all three sync sites if the config
    # disables it on the synthesiser. Strip-from-all-three-or-none is enforced
    # by the structural test test_sync_synthesiser_dispatch_uses_ultrathink.
    if [[ "${_AB_CONFIG_STRIP_ULTRATHINK:-false}" == "true" ]]; then
        local site
        for site in "${_AB_ULTRATHINK_SYNC_SITES[@]}"; do
            local abs="$REPO_ROOT/$site"
            if [[ ! -f "$abs" ]]; then
                echo "mutate_apply_config: missing sync site $site" >&2
                return 1
            fi
            mutate_strip_ultrathink_keyword "$abs"
            _ab_track_mutation "$site"
        done
    fi

    # Per-agent model rewrites. _AB_CONFIG_AGENT_MODELS is a parallel-array
    # encoding: name then value, name then value. lib/config.sh populates it.
    local i agent new_model agent_path
    if [[ -n "${_AB_CONFIG_AGENT_MODELS:-}" ]]; then
        local -a kv
        # shellcheck disable=SC2206
        kv=( ${_AB_CONFIG_AGENT_MODELS} )
        for ((i = 0; i < ${#kv[@]}; i += 2)); do
            agent="${kv[i]}"
            new_model="${kv[i+1]}"
            agent_path="plugins/code-review-suite/agents/${agent}.md"
            if [[ ! -f "$REPO_ROOT/$agent_path" ]]; then
                echo "mutate_apply_config: agent file not found: $agent_path" >&2
                return 1
            fi
            mutate_set_agent_model "$REPO_ROOT/$agent_path" "$new_model"
            _ab_track_mutation "$agent_path"
        done
    fi
}
```

- [ ] **Step 7: Run the tests to confirm they pass**

Run:

```bash
tests/run.sh
```

Expected: all three `test_ab_mutate_*` tests pass; existing tests still pass; the structural sync-note tests still pass (we have not touched any of the real sync sites).

- [ ] **Step 8: Commit**

```bash
git add tests/ab/lib/mutate.sh tests/ab/fixtures/ tests/lib/test_ab_harness.sh
git commit -m "$(cat <<'EOF'
feat(tests/ab): add lib/mutate.sh with fixture-based tests

Implements the in-tree mutation primitives:
- mutate_strip_ultrathink_keyword: idempotent strip of the literal
  'ultrathink\n\n' prefix from a synthesiser dispatch prompt.
- mutate_set_agent_model: frontmatter-only rewrite of the model: line.
- mutate_install_revert_trap: EXIT/INT/TERM/HUP handler that reverts every
  tracked file via git checkout -- and writes MANUAL_REVERT_REQUIRED on
  any partial-revert failure.

Tested against four golden fixtures so the mutation logic is exercisable
without touching the real sync sites.
EOF
)"
```

---

## Task 4: `lib/config.sh` — minimal YAML config loader

The Phase 1 schema is intentionally narrow: a `name:`, an optional `description:`, an `agents:` map with per-agent `model:` and `ultrathink:` fields, and an optional `session:` block (`model:`, `effort:`). Unrecognised keys are an error, not a warning — the spec requires this so config typos cannot silently revert to baseline.

**Files:**
- Create: `tests/ab/lib/config.sh`
- Create: `tests/ab/configs/baseline.yaml`
- Create: `tests/ab/configs/no-ultrathink.yaml`
- Create: `tests/ab/fixtures/config-bad-key.yaml`
- Modify: `tests/lib/test_ab_harness.sh`

- [ ] **Step 1: Author the two real config files**

Create `tests/ab/configs/baseline.yaml`:

```yaml
name: baseline
description: Production defaults — no mutations applied. Used as the control arm.
session:
  model: opus
  effort: max
agents: {}
```

Create `tests/ab/configs/no-ultrathink.yaml`:

```yaml
name: no-ultrathink
description: Strip the ultrathink keyword from synthesiser dispatch; leave all model assignments at production defaults.
session:
  model: opus
  effort: max
agents:
  review-synthesiser:
    ultrathink: false
```

Create `tests/ab/fixtures/config-bad-key.yaml` (used to test that unknown keys fail validation):

```yaml
name: bogus
unknown_top_level_key: this should be rejected
agents: {}
```

- [ ] **Step 2: Write the failing config-loader tests**

Append to `tests/lib/test_ab_harness.sh`:

```bash
test_ab_config_loads_baseline() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local baseline="$REPO_ROOT/tests/ab/configs/baseline.yaml"

    if [[ ! -f "$config" || ! -f "$baseline" ]]; then
        fail "A/B config: lib/config.sh and baseline.yaml exist" "missing one or both"
        return
    fi

    local name strip
    name=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$baseline" >/dev/null
        echo "$_AB_CONFIG_NAME"
    )
    strip=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$baseline" >/dev/null
        echo "${_AB_CONFIG_STRIP_ULTRATHINK:-false}"
    )

    assert_equals "baseline" "$name" "A/B config: baseline.yaml exposes name=baseline"
    assert_equals "false" "$strip" "A/B config: baseline.yaml does not strip ultrathink"
}

test_ab_config_loads_no_ultrathink() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local cfg="$REPO_ROOT/tests/ab/configs/no-ultrathink.yaml"

    if [[ ! -f "$config" || ! -f "$cfg" ]]; then
        fail "A/B config: lib/config.sh and no-ultrathink.yaml exist" "missing one or both"
        return
    fi

    local strip
    strip=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$cfg" >/dev/null
        echo "${_AB_CONFIG_STRIP_ULTRATHINK:-false}"
    )

    assert_equals "true" "$strip" "A/B config: no-ultrathink.yaml strips ultrathink"
}

test_ab_config_rejects_unknown_top_level_key() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local bad="$REPO_ROOT/tests/ab/fixtures/config-bad-key.yaml"

    if [[ ! -f "$config" || ! -f "$bad" ]]; then
        fail "A/B config: bad-key fixture present" "missing"
        return
    fi

    local rc
    rc=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$bad" >/dev/null 2>&1
        echo $?
    )

    if [[ "$rc" != "0" ]]; then
        pass "A/B config: unknown top-level keys rejected"
    else
        fail "A/B config: unknown top-level keys rejected" \
            "config_load accepted a config with 'unknown_top_level_key' — schema validation must hard-fail on unrecognised keys per the spec"
    fi
}
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run:

```bash
tests/run.sh
```

Expected: the three new `test_ab_config_*` tests fail with "missing" because `lib/config.sh` does not exist yet.

- [ ] **Step 4: Implement `tests/ab/lib/config.sh`**

Create `tests/ab/lib/config.sh`:

```bash
#!/usr/bin/env bash
# tests/ab/lib/config.sh — minimal YAML config loader for the A/B harness.
#
# Sourced by tests/ab/run.sh. Exposes config_load <path>, which validates the
# schema and populates the following environment-style globals consumed by
# lib/mutate.sh and lib/launch.sh:
#
#   _AB_CONFIG_NAME              — the config's name: field (string)
#   _AB_CONFIG_DESCRIPTION       — optional description: field (string)
#   _AB_CONFIG_SESSION_MODEL     — session.model (string; passed as --model)
#   _AB_CONFIG_SESSION_EFFORT    — session.effort (string; passed as --effort)
#   _AB_CONFIG_STRIP_ULTRATHINK  — "true" if agents.review-synthesiser.ultrathink == false
#   _AB_CONFIG_AGENT_MODELS      — space-separated "name model" pairs (parallel array)
#
# Unrecognised top-level or per-agent keys are a hard error — a typo must not
# silently fall back to production defaults.
set -euo pipefail

_AB_VALID_TOP_KEYS="name description session agents"
_AB_VALID_SESSION_KEYS="model effort"
_AB_VALID_AGENT_KEYS="model ultrathink"

config_load() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "config_load: $path: not found" >&2
        return 1
    fi

    # 1. Validate top-level keys.
    local key
    for key in $(yq 'keys | .[]' "$path"); do
        if ! _ab_key_in_set "$key" "$_AB_VALID_TOP_KEYS"; then
            echo "config_load: $path: unknown top-level key '$key' (allowed: $_AB_VALID_TOP_KEYS)" >&2
            return 1
        fi
    done

    # 2. Validate session keys.
    if [[ "$(yq 'has("session")' "$path")" == "true" ]]; then
        for key in $(yq '.session | keys | .[]' "$path"); do
            if ! _ab_key_in_set "$key" "$_AB_VALID_SESSION_KEYS"; then
                echo "config_load: $path: unknown session key '$key' (allowed: $_AB_VALID_SESSION_KEYS)" >&2
                return 1
            fi
        done
    fi

    # 3. Validate per-agent keys.
    local agent
    for agent in $(yq '.agents // {} | keys | .[]' "$path"); do
        for key in $(yq ".agents.\"$agent\" | keys | .[]" "$path"); do
            if ! _ab_key_in_set "$key" "$_AB_VALID_AGENT_KEYS"; then
                echo "config_load: $path: unknown agent.$agent key '$key' (allowed: $_AB_VALID_AGENT_KEYS)" >&2
                return 1
            fi
        done
    done

    # 4. Populate globals. yq returns 'null' for missing keys; coerce to empty.
    _AB_CONFIG_NAME=$(yq -r '.name // ""' "$path")
    _AB_CONFIG_DESCRIPTION=$(yq -r '.description // ""' "$path")
    _AB_CONFIG_SESSION_MODEL=$(yq -r '.session.model // ""' "$path")
    _AB_CONFIG_SESSION_EFFORT=$(yq -r '.session.effort // ""' "$path")

    if [[ -z "$_AB_CONFIG_NAME" ]]; then
        echo "config_load: $path: name: is required" >&2
        return 1
    fi

    # 5. Derive the strip-ultrathink flag from the synthesiser entry.
    local synth_ultra
    synth_ultra=$(yq -r '.agents."review-synthesiser".ultrathink // "true"' "$path")
    if [[ "$synth_ultra" == "false" ]]; then
        _AB_CONFIG_STRIP_ULTRATHINK="true"
    else
        _AB_CONFIG_STRIP_ULTRATHINK="false"
    fi

    # 6. Build _AB_CONFIG_AGENT_MODELS as a space-separated parallel-array
    # encoding consumed by mutate_apply_config.
    _AB_CONFIG_AGENT_MODELS=""
    for agent in $(yq '.agents // {} | keys | .[]' "$path"); do
        local model_val
        model_val=$(yq -r ".agents.\"$agent\".model // \"\"" "$path")
        if [[ -n "$model_val" ]]; then
            _AB_CONFIG_AGENT_MODELS+=" $agent $model_val"
        fi
    done
    _AB_CONFIG_AGENT_MODELS="${_AB_CONFIG_AGENT_MODELS# }"
}

_ab_key_in_set() {
    local needle="$1"
    local haystack="$2"
    local k
    for k in $haystack; do
        if [[ "$k" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run:

```bash
tests/run.sh
```

Expected: all three new `test_ab_config_*` tests pass; existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add tests/ab/lib/config.sh tests/ab/configs/ tests/ab/fixtures/config-bad-key.yaml tests/lib/test_ab_harness.sh
git commit -m "$(cat <<'EOF'
feat(tests/ab): add lib/config.sh with strict YAML schema validation

Implements config_load <path>: validates that every top-level, session, and
per-agent key is in the allow-list and hard-fails on unrecognised keys.
Populates _AB_CONFIG_* globals consumed by lib/mutate.sh and lib/launch.sh.

Adds the two Phase 1 configs (baseline.yaml, no-ultrathink.yaml) and a
bad-key fixture that asserts schema validation rejects typos rather than
silently reverting to defaults.
EOF
)"
```

---

## Task 5: `lib/launch.sh` — headless `command claude -p` invocation

The user's `claude()` shell function does setup work (Bedrock env, SSO refresh, tmux wrap) but does *not* pass `-p` through. The harness must replicate the necessary setup itself and invoke `command claude -p` directly. The dotfiles function stays untouched.

**Files:**
- Create: `tests/ab/lib/launch.sh`
- Modify: `tests/lib/test_ab_harness.sh`

- [ ] **Step 1: Choose the timeout binary at script-load time**

GNU `timeout` is available as `timeout` on Linux and `gtimeout` on macOS via Homebrew `coreutils`. The harness must work in both environments. The macOS dev box does not currently have `coreutils` installed; we treat that as a preflight failure rather than silently dropping the timeout.

- [ ] **Step 2: Write the failing launch tests**

Append to `tests/lib/test_ab_harness.sh`:

```bash
test_ab_launch_resolves_timeout_binary() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    if [[ ! -f "$launch" ]]; then
        fail "A/B launch: lib/launch.sh exists" "missing"
        return
    fi

    local result
    result=$(
        # shellcheck disable=SC1090
        source "$launch"
        # PATH manipulation: prepend a sandbox where we have only `timeout`
        # available. The function must accept either timeout or gtimeout.
        if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
            launch_resolve_timeout_binary
        else
            echo "neither-available"
        fi
    )

    if [[ "$result" == "timeout" || "$result" == "gtimeout" ]]; then
        pass "A/B launch: resolves timeout or gtimeout from PATH"
    elif [[ "$result" == "neither-available" ]]; then
        skip "A/B launch: timeout binary present" "neither timeout nor gtimeout on PATH on this host"
    else
        fail "A/B launch: resolves timeout or gtimeout from PATH" \
            "expected 'timeout' or 'gtimeout' on PATH; got: '$result'"
    fi
}

test_ab_launch_builds_argv_for_claude_p() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    if [[ ! -f "$launch" ]]; then
        fail "A/B launch: lib/launch.sh exists" "missing"
        return
    fi

    # Source the helper, call launch_build_claude_argv with known inputs, and
    # assert the resulting argv array contains the expected flags. The
    # function writes one argv element per line to stdout for testability.
    local argv
    argv=$(
        # shellcheck disable=SC1090
        source "$launch"
        launch_build_claude_argv "opus" "max" "/review-gh-pr https://example/pr/29"
    )

    if echo "$argv" | grep -qF -- "-p"; then
        pass "A/B launch: argv includes -p flag"
    else
        fail "A/B launch: argv includes -p flag" "argv=$argv"
    fi
    if echo "$argv" | grep -qF -- "--permission-mode"; then
        pass "A/B launch: argv includes --permission-mode"
    else
        fail "A/B launch: argv includes --permission-mode" "argv=$argv"
    fi
    if echo "$argv" | grep -qF -- "bypassPermissions"; then
        pass "A/B launch: argv passes bypassPermissions"
    else
        fail "A/B launch: argv passes bypassPermissions" "argv=$argv"
    fi
    if echo "$argv" | grep -qF -- "--model"; then
        pass "A/B launch: argv includes --model"
    else
        fail "A/B launch: argv includes --model" "argv=$argv"
    fi
    if echo "$argv" | grep -qF -- "--effort"; then
        pass "A/B launch: argv includes --effort"
    else
        fail "A/B launch: argv includes --effort" "argv=$argv"
    fi
}
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run:

```bash
tests/run.sh
```

Expected: `test_ab_launch_*` tests fail with "missing" because `lib/launch.sh` does not exist.

- [ ] **Step 4: Implement `tests/ab/lib/launch.sh`**

Create `tests/ab/lib/launch.sh`:

```bash
#!/usr/bin/env bash
# tests/ab/lib/launch.sh — launch primitive for the A/B harness.
#
# Sourced by tests/ab/run.sh. Replicates the setup the user's claude() shell
# function performs (source ~/.claudeenv, run aws-sso-preflight.sh) without
# wrapping in tmux and without dropping the -p flag. Then exec's
# `command claude -p <prompt>` with --permission-mode bypassPermissions and
# the per-config --model and --effort.
set -euo pipefail

# Resolve the GNU timeout binary. Linux ships it as `timeout`; macOS exposes
# it as `gtimeout` via Homebrew coreutils. Returns the chosen name on stdout.
launch_resolve_timeout_binary() {
    if command -v timeout >/dev/null 2>&1; then
        echo "timeout"
        return 0
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
        return 0
    fi
    echo "launch_resolve_timeout_binary: neither timeout nor gtimeout on PATH" >&2
    echo "neither-available"
    return 1
}

# Source ~/.claudeenv if present, then run aws-sso-preflight.sh once. Both are
# idempotent. Failure of the preflight is a hard halt — Bedrock will hang on
# expired tokens otherwise.
launch_preflight_environment() {
    if [[ -f "$HOME/.claudeenv" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.claudeenv"
    fi
    if [[ -x "$HOME/.claude/scripts/aws-sso-preflight.sh" ]]; then
        if ! "$HOME/.claude/scripts/aws-sso-preflight.sh"; then
            echo "launch_preflight_environment: aws-sso-preflight.sh failed" >&2
            return 1
        fi
    fi
}

# Build the argv to pass to `command claude`. The prompt is written to a temp
# file by the caller and fed via stdin to keep argv short and shell-safe;
# this function only emits flags. One element per line on stdout for testing.
launch_build_claude_argv() {
    local model="$1"
    local effort="$2"
    local prompt="$3"  # printed last as the positional prompt argument

    printf '%s\n' \
        "-p" \
        "--permission-mode" "bypassPermissions" \
        "--model" "$model" \
        "--effort" "$effort" \
        "--exclude-dynamic-system-prompt-sections" \
        "$prompt"
}

# Run one trial. Wraps the `command claude` invocation in `timeout`, captures
# stdout/stderr to per-trial files, and writes timing.json. Caller passes the
# trial directory and the resolved per-trial args.
#
# Returns 0 on a clean run, 124 on timeout (per GNU timeout convention), or
# the underlying exit code.
launch_run_trial() {
    local trial_dir="$1"
    local timeout_seconds="$2"
    local model="$3"
    local effort="$4"
    local prompt="$5"
    local timeout_bin="$6"

    local stdout="$trial_dir/stdout.log"
    local stderr="$trial_dir/stderr.log"
    local timing="$trial_dir/timing.json"

    local start_iso
    start_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local start_epoch=$SECONDS

    local rc=0
    "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
        command claude \
            -p \
            --permission-mode bypassPermissions \
            --model "$model" \
            --effort "$effort" \
            --exclude-dynamic-system-prompt-sections \
            "$prompt" \
        > "$stdout" 2> "$stderr" || rc=$?

    local end_epoch=$SECONDS
    local end_iso
    end_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local elapsed=$((end_epoch - start_epoch))

    local timed_out="false"
    if [[ "$rc" == "124" ]]; then
        timed_out="true"
    fi

    jq -n \
        --arg start "$start_iso" \
        --arg end "$end_iso" \
        --argjson elapsed "$elapsed" \
        --argjson rc "$rc" \
        --arg timed_out "$timed_out" \
        '{start: $start, end: $end, wall_clock_seconds: $elapsed, exit_code: $rc, timed_out: ($timed_out == "true")}' \
        > "$timing"

    return "$rc"
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run:

```bash
tests/run.sh
```

Expected: `test_ab_launch_*` tests pass; existing tests still pass. The timeout-resolution test may report `skip` rather than `pass` on a host without `timeout` or `gtimeout` — that is the correct behaviour, not a failure.

- [ ] **Step 6: Commit**

```bash
git add tests/ab/lib/launch.sh tests/lib/test_ab_harness.sh
git commit -m "$(cat <<'EOF'
feat(tests/ab): add lib/launch.sh — headless command claude -p invocation

Implements the launch primitives:
- launch_resolve_timeout_binary: picks timeout (Linux) or gtimeout (macOS).
- launch_preflight_environment: sources ~/.claudeenv and runs the AWS SSO
  preflight; hard-fails on auth failure.
- launch_build_claude_argv: deterministic argv builder (used by tests).
- launch_run_trial: runs one trial under GNU timeout, captures
  stdout/stderr, writes timing.json with wall-clock and exit code.

The harness invokes 'command claude -p' directly, bypassing the dotfiles
claude() shell function (which does not pass -p through).
EOF
)"
```

---

## Task 6: `lib/capture.sh` — extract synthesiser report and verdict from trial stdout

The trial stdout contains the synthesiser's full report, terminated by a `Verdict: APPROVE` or `Verdict: REQUEST_CHANGES` line per the synthesiser's output contract (enforced by `test_synthesiser_verdict_output_restricted_to_two_values` in the existing test suite). We extract from the first occurrence of the report header through the verdict line and write three files: the raw report, the verdict alone, and a coarse finding count.

**Files:**
- Create: `tests/ab/lib/capture.sh`
- Create: `tests/ab/fixtures/trial-stdout-approve.log`
- Create: `tests/ab/fixtures/trial-stdout-request-changes.log`
- Create: `tests/ab/fixtures/trial-stdout-truncated.log`
- Modify: `tests/lib/test_ab_harness.sh`

- [ ] **Step 1: Create the trial-stdout fixtures**

Each fixture mimics the shape of a real trial stdout — preamble noise from Claude Code session output, then the synthesiser report block, then the verdict line, then any trailing prose. Real reports are far longer; the fixtures are pared down to what `capture.sh` actually parses.

Create `tests/ab/fixtures/trial-stdout-approve.log`:

```
Some session preamble that capture must skip.

# Code Review Report

## Important
- None

## Suggestions
- One stylistic nit at file.go:14
- Another at file.go:42

## Verdict Output Format

Verdict: APPROVE
Rubric row applied: 1

Trailing prose that capture must not include in the report.
```

Create `tests/ab/fixtures/trial-stdout-request-changes.log`:

```
Preamble.

# Code Review Report

## Important
- Real bug at auth.go:42 — unparameterised query.

## Suggestions
- Style nit.

## Verdict Output Format

Verdict: REQUEST_CHANGES
Rubric row applied: 2

Trailing.
```

Create `tests/ab/fixtures/trial-stdout-truncated.log` (timeout case — no verdict line):

```
Preamble.

# Code Review Report

## Important
- Mid-sentence cut here, the synthesiser was killed by timeout
```

- [ ] **Step 2: Write the failing capture tests**

Append to `tests/lib/test_ab_harness.sh`:

```bash
test_ab_capture_extracts_verdict_approve() {
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-approve.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: helper and fixture exist" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$capture"
        capture_parse_trial "$trial_dir"
    )

    local verdict
    verdict=$(cat "$trial_dir/verdict.txt" 2>/dev/null)
    assert_equals "APPROVE" "$verdict" "A/B capture: APPROVE verdict extracted"

    if [[ -s "$trial_dir/synthesiser-report.md" ]]; then
        pass "A/B capture: synthesiser-report.md is non-empty"
    else
        fail "A/B capture: synthesiser-report.md is non-empty" "report file missing or empty"
    fi

    rm -rf "$trial_dir"
}

test_ab_capture_extracts_verdict_request_changes() {
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-request-changes.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: REQUEST_CHANGES fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$capture"
        capture_parse_trial "$trial_dir"
    )

    local verdict
    verdict=$(cat "$trial_dir/verdict.txt" 2>/dev/null)
    assert_equals "REQUEST_CHANGES" "$verdict" "A/B capture: REQUEST_CHANGES verdict extracted"

    rm -rf "$trial_dir"
}

test_ab_capture_handles_truncated_output() {
    # When the trial timed out before the synthesiser emitted a verdict, the
    # capture must write 'INCONCLUSIVE' rather than silently producing an
    # empty verdict.txt — silent empty would corrupt the summary CSV.
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-truncated.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: truncated fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$capture"
        capture_parse_trial "$trial_dir"
    )

    local verdict
    verdict=$(cat "$trial_dir/verdict.txt" 2>/dev/null)
    assert_equals "INCONCLUSIVE" "$verdict" "A/B capture: truncated stdout yields INCONCLUSIVE"

    rm -rf "$trial_dir"
}
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run:

```bash
tests/run.sh
```

Expected: the three new `test_ab_capture_*` tests fail with "missing" because `lib/capture.sh` does not exist.

- [ ] **Step 4: Implement `tests/ab/lib/capture.sh`**

Create `tests/ab/lib/capture.sh`:

```bash
#!/usr/bin/env bash
# tests/ab/lib/capture.sh — parse trial stdout into structured artefacts.
#
# Sourced by tests/ab/run.sh. After lib/launch.sh runs a trial and writes
# stdout.log, capture_parse_trial extracts:
#   - synthesiser-report.md  : the report block (from "# Code Review Report"
#                              through the line after Verdict:)
#   - verdict.txt            : APPROVE | REQUEST_CHANGES | INCONCLUSIVE
#   - report-stats.json      : char count, line count, finding count proxy
set -euo pipefail

# Phase 1 deliberately skips usage.json — the spec marks token-usage capture
# as best-effort and Phase 1 leans on wall-clock as the primary thinking-
# budget proxy.

capture_parse_trial() {
    local trial_dir="$1"
    local stdout="$trial_dir/stdout.log"

    if [[ ! -f "$stdout" ]]; then
        echo "capture_parse_trial: $stdout: not found" >&2
        return 1
    fi

    # 1. Extract the report block. From the first '# Code Review Report' line
    # through the next 'Verdict: ' line (inclusive). If no Verdict: line is
    # found we treat the trial as truncated — do not emit a malformed report.
    local report
    report=$(awk '
        /^# Code Review Report$/ { in_block = 1 }
        in_block { print }
        in_block && /^Verdict: / { exit }
    ' "$stdout")

    if [[ -n "$report" ]]; then
        printf '%s\n' "$report" > "$trial_dir/synthesiser-report.md"
    else
        : > "$trial_dir/synthesiser-report.md"
    fi

    # 2. Extract the verdict line. The synthesiser contract restricts it to
    # APPROVE | REQUEST_CHANGES (enforced by an existing structural test).
    # Anything else — including an absent line — is INCONCLUSIVE.
    local verdict_line
    verdict_line=$(grep -m1 -E '^Verdict: (APPROVE|REQUEST_CHANGES)$' "$stdout" || true)

    local verdict="INCONCLUSIVE"
    if [[ "$verdict_line" =~ ^Verdict:[[:space:]](APPROVE|REQUEST_CHANGES)$ ]]; then
        verdict="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$verdict" > "$trial_dir/verdict.txt"

    # 3. Coarse stats: char count, line count, and a finding count proxy
    # (number of bullet lines in the report). A real report has tier headings
    # (## Important / ## Suggestions / ## Nits / etc.); the count is a
    # directional metric, not absolute — see the spec's scoring section.
    local chars lines findings
    chars=$(wc -c < "$trial_dir/synthesiser-report.md" | tr -d '[:space:]')
    lines=$(wc -l < "$trial_dir/synthesiser-report.md" | tr -d '[:space:]')
    findings=$(grep -cE '^- ' "$trial_dir/synthesiser-report.md" || true)

    jq -n \
        --argjson chars "$chars" \
        --argjson lines "$lines" \
        --argjson findings "$findings" \
        '{report_chars: $chars, report_lines: $lines, finding_count: $findings}' \
        > "$trial_dir/report-stats.json"
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run:

```bash
tests/run.sh
```

Expected: all three new `test_ab_capture_*` tests pass; existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add tests/ab/lib/capture.sh tests/ab/fixtures/trial-stdout-*.log tests/lib/test_ab_harness.sh
git commit -m "$(cat <<'EOF'
feat(tests/ab): add lib/capture.sh — parse trial stdout into artefacts

Implements capture_parse_trial: extracts the synthesiser report block,
the verdict (APPROVE | REQUEST_CHANGES | INCONCLUSIVE for truncated runs),
and coarse report stats (char/line/finding counts).

Tested against three fixtures: APPROVE happy path, REQUEST_CHANGES happy
path, and a truncated stdout (timeout) case. INCONCLUSIVE is the
load-bearing third value — silent empty verdict would corrupt summary.csv.
EOF
)"
```

---

## Task 7: `run.sh` — orchestrator wiring (preflight → manifest → mutate → loop → revert → summary)

This task replaces the scaffold body of `tests/ab/run.sh` (created in Task 2) with the full orchestrator. Everything it needs already exists: `lib/config.sh`, `lib/mutate.sh`, `lib/launch.sh`, `lib/capture.sh`. The orchestrator is responsible for the lifecycle decisions and the run-directory layout — it never re-implements the primitives.

**Phase 1 hard-coded corpus PR:** `https://github.com/Jodre11/claude-code-plugins/pull/29` (the deletion-detection feature PR; merged at SHA `0d9f460`, base `eb560a9`). Picked because it produced non-trivial findings on a real review and is small enough to review in under 15 minutes per trial. The hard-code is a pragmatic shortcut: corpus YAML schema is explicitly Phase 2.

**Files:**
- Modify: `tests/ab/run.sh` (replace the scaffold body with the full orchestrator)
- Modify: `tests/lib/test_ab_harness.sh` (add a smoke test that exercises `--help` and bad-config rejection)

- [ ] **Step 1: Write a failing smoke test for `--help` and bad-config rejection**

Append to `tests/lib/test_ab_harness.sh`:

```bash
test_ab_run_sh_help_succeeds() {
    local run="$REPO_ROOT/tests/ab/run.sh"
    if [[ ! -x "$run" ]]; then
        fail "A/B run.sh: executable" "missing or not +x"
        return
    fi

    local out rc
    out=$("$run" --help 2>&1)
    rc=$?

    if [[ "$rc" == "0" ]] && echo "$out" | grep -qF "Usage: tests/ab/run.sh"; then
        pass "A/B run.sh: --help exits 0 and prints usage"
    else
        fail "A/B run.sh: --help exits 0 and prints usage" \
            "rc=$rc out=$out"
    fi
}

test_ab_run_sh_rejects_unknown_config_key() {
    local run="$REPO_ROOT/tests/ab/run.sh"
    local bad="$REPO_ROOT/tests/ab/fixtures/config-bad-key.yaml"
    if [[ ! -x "$run" || ! -f "$bad" ]]; then
        fail "A/B run.sh: bad-config rejection" "missing run.sh or fixture"
        return
    fi

    # We pass --trials 1 but expect run.sh to exit non-zero during preflight
    # because config_load fails on the unknown key. The harness must NOT begin
    # mutating the tree in this state.
    local rc
    "$run" --config "$bad" --trials 1 >/dev/null 2>&1 || rc=$?

    if [[ "${rc:-0}" != "0" ]]; then
        pass "A/B run.sh: rejects unknown config key with non-zero exit"
    else
        fail "A/B run.sh: rejects unknown config key with non-zero exit" \
            "run.sh exited 0 on a config with an unknown top-level key — this is the precondition that must hard-halt before any mutation"
    fi

    # Belt-and-braces: the working tree must still be clean. If it isn't,
    # mutations leaked despite the preflight failure.
    if git -C "$REPO_ROOT" diff --quiet; then
        pass "A/B run.sh: bad-config rejection leaves working tree clean"
    else
        fail "A/B run.sh: bad-config rejection leaves working tree clean" \
            "working tree is dirty after run.sh rejected a bad config — the preflight check fired AFTER mutations were applied, which is the wrong order"
    fi
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run:

```bash
tests/run.sh
```

Expected: both tests fail because `run.sh` is still the scaffold that exits 64.

- [ ] **Step 3: Replace the body of `tests/ab/run.sh`**

Overwrite `tests/ab/run.sh` with the full orchestrator. The previous scaffold's `usage()` is preserved verbatim; only `main()` is fleshed out and helper functions are added.

```bash
#!/usr/bin/env bash
# A/B test harness — entry point.
# Runs N trials of one corpus PR under one named config, captures mechanical
# metrics, reverts all in-tree mutations on exit. See tests/ab/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/mutate.sh
source "$SCRIPT_DIR/lib/mutate.sh"
# shellcheck source=lib/launch.sh
source "$SCRIPT_DIR/lib/launch.sh"
# shellcheck source=lib/capture.sh
source "$SCRIPT_DIR/lib/capture.sh"

# Phase 1 hard-coded corpus PR. Phase 2 replaces this with corpus/<id>.yaml
# loading.
_AB_CORPUS_PR_URL="https://github.com/Jodre11/claude-code-plugins/pull/29"
_AB_CORPUS_REVIEW_MODE="pr"

# The harness preamble. Auto-confirms operational halts but is narrow enough
# not to influence verdict decisions. Identical text to the spec § Step 4.
_AB_PREAMBLE="This is a non-interactive harness run. Auto-confirm any 'Proceed?' gates as if the user replied 'yes'. Skip Class A confirmation flows and treat them as approved. Do not pause for user input. Do not let this preamble influence your verdict decisions."

usage() {
    cat <<'EOF'
Usage: tests/ab/run.sh --config <path> --trials <n> [--name <experiment-name>] [--timeout-seconds <n>]

Required:
  --config <path>           Path to a YAML config under tests/ab/configs/
  --trials <n>              Number of trials to run (positive integer)

Optional:
  --name <name>             Human label for the run directory (default: derived from config name)
  --timeout-seconds <n>     Per-trial timeout in seconds (default: 1800)
  -h, --help                Show this help

Phase 1 limitation: the corpus PR is hard-coded. See tests/ab/README.md.
EOF
}

main() {
    local config_path=""
    local trials=""
    local experiment_name=""
    local timeout_seconds=1800

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_path="$2"; shift 2 ;;
            --trials) trials="$2"; shift 2 ;;
            --name) experiment_name="$2"; shift 2 ;;
            --timeout-seconds) timeout_seconds="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown arg: $1" >&2; usage >&2; exit 64 ;;
        esac
    done

    if [[ -z "$config_path" || -z "$trials" ]]; then
        usage >&2
        exit 64
    fi
    if ! [[ "$trials" =~ ^[1-9][0-9]*$ ]]; then
        echo "--trials must be a positive integer (got: $trials)" >&2
        exit 64
    fi

    # 1. Preflight (in order — each step halts on failure).
    _ab_preflight_marketplace_root
    _ab_preflight_clean_tree
    _ab_preflight_required_tools
    config_load "$config_path"
    _ab_preflight_corpus_reachable
    launch_preflight_environment

    # 2. Set up run directory and write manifest.
    if [[ -z "$experiment_name" ]]; then
        experiment_name="$_AB_CONFIG_NAME"
    fi
    local timestamp
    timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
    _AB_RUN_DIR="$SCRIPT_DIR/runs/${timestamp}-${experiment_name}"
    mkdir -p "$_AB_RUN_DIR"
    _ab_write_manifest "$config_path" "$timestamp" "$experiment_name" "$trials" "$timeout_seconds"

    # 3. Install mutations + revert trap. Trap MUST be installed before
    # mutations are applied so a SIGINT during mutate_apply_config still
    # reverts whatever was already touched.
    mutate_install_revert_trap
    mutate_apply_config

    # Append a record of the active mutations to the manifest.
    git -C "$REPO_ROOT" diff --stat >> "$_AB_RUN_DIR/manifest.yaml"

    # 4. Trial loop.
    local timeout_bin
    timeout_bin=$(launch_resolve_timeout_binary)

    local prompt
    prompt="$_AB_PREAMBLE"$'\n\n'"/review-gh-pr $_AB_CORPUS_PR_URL"

    local summary="$_AB_RUN_DIR/summary.csv"
    echo "trial,exit_code,wall_clock_seconds,verdict,finding_count,report_chars,timed_out" > "$summary"

    local i
    for ((i = 1; i <= trials; i++)); do
        local trial_num
        trial_num=$(printf 'trial-%03d' "$i")
        local trial_dir="$_AB_RUN_DIR/$trial_num"
        mkdir -p "$trial_dir"
        echo "[$(date -u +'%H:%M:%SZ')] $trial_num: launching..." >&2

        local rc=0
        launch_run_trial \
            "$trial_dir" \
            "$timeout_seconds" \
            "$_AB_CONFIG_SESSION_MODEL" \
            "$_AB_CONFIG_SESSION_EFFORT" \
            "$prompt" \
            "$timeout_bin" \
            || rc=$?

        capture_parse_trial "$trial_dir"
        _ab_append_summary_row "$trial_dir" "$i" "$rc"

        # Inter-trial pause — gives Bedrock breathing room.
        if [[ "$i" -lt "$trials" ]]; then
            sleep 5
        fi
    done

    _ab_emit_completion_summary "$trials"
    # Trap fires on EXIT and reverts mutations.
}

_ab_preflight_marketplace_root() {
    if [[ ! -f "$REPO_ROOT/.claude-plugin/marketplace.json" ]]; then
        echo "preflight: not at marketplace root (expected $REPO_ROOT/.claude-plugin/marketplace.json)" >&2
        exit 1
    fi
}

_ab_preflight_clean_tree() {
    if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
        echo "preflight: working tree is dirty — refusing to start (mutations + dirty tree = unsafe revert)" >&2
        exit 1
    fi
}

_ab_preflight_required_tools() {
    local tool missing=()
    for tool in yq jq gh git; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
        missing+=("timeout (or gtimeout via Homebrew coreutils on macOS)")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "preflight: missing required tools: ${missing[*]}" >&2
        exit 1
    fi
}

_ab_preflight_corpus_reachable() {
    if ! gh pr view "$_AB_CORPUS_PR_URL" --json state >/dev/null 2>&1; then
        echo "preflight: corpus PR not reachable: $_AB_CORPUS_PR_URL" >&2
        exit 1
    fi
}

_ab_write_manifest() {
    local config_path="$1"
    local timestamp="$2"
    local experiment_name="$3"
    local trials="$4"
    local timeout_seconds="$5"

    local config_sha
    config_sha=$(shasum -a 256 "$config_path" | awk '{print $1}')

    local suite_sha
    suite_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)

    local hostname
    hostname=$(hostname)

    cat > "$_AB_RUN_DIR/manifest.yaml" <<EOF
experiment_name: $experiment_name
timestamp: $timestamp
trials: $trials
timeout_seconds: $timeout_seconds
config:
  path: ${config_path#"$REPO_ROOT/"}
  sha256: $config_sha
  name: $_AB_CONFIG_NAME
  description: $_AB_CONFIG_DESCRIPTION
corpus:
  pr_url: $_AB_CORPUS_PR_URL
  review_mode: $_AB_CORPUS_REVIEW_MODE
suite_git_sha: $suite_sha
host: $hostname
session:
  model: $_AB_CONFIG_SESSION_MODEL
  effort: $_AB_CONFIG_SESSION_EFFORT
mutations:
  strip_ultrathink: $_AB_CONFIG_STRIP_ULTRATHINK
  agent_models: "$_AB_CONFIG_AGENT_MODELS"

# git diff --stat after mutations applied:
EOF
}

_ab_append_summary_row() {
    local trial_dir="$1"
    local trial_num="$2"
    local rc="$3"

    local wall verdict findings chars timed_out
    wall=$(jq -r '.wall_clock_seconds' "$trial_dir/timing.json")
    timed_out=$(jq -r '.timed_out' "$trial_dir/timing.json")
    verdict=$(cat "$trial_dir/verdict.txt")
    findings=$(jq -r '.finding_count' "$trial_dir/report-stats.json")
    chars=$(jq -r '.report_chars' "$trial_dir/report-stats.json")

    printf '%d,%d,%d,%s,%d,%d,%s\n' \
        "$trial_num" "$rc" "$wall" "$verdict" "$findings" "$chars" "$timed_out" \
        >> "$_AB_RUN_DIR/summary.csv"
}

_ab_emit_completion_summary() {
    local trials="$1"
    local summary="$_AB_RUN_DIR/summary.csv"

    local succeeded timeouts
    succeeded=$(awk -F, 'NR>1 && $2==0 {n++} END {print n+0}' "$summary")
    timeouts=$(awk -F, 'NR>1 && $7=="true" {n++} END {print n+0}' "$summary")

    local mean_wall
    mean_wall=$(awk -F, 'NR>1 {s+=$3; n++} END {if (n>0) printf "%d", s/n; else print 0}' "$summary")

    echo "Run complete: ${succeeded}/${trials} trials, ${timeouts} timeouts, mean ${mean_wall}s. Output: $_AB_RUN_DIR" >&2
}

main "$@"
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run:

```bash
tests/run.sh
```

Expected: all `test_ab_*` tests pass — including the bad-config rejection, which exercises the preflight chain end-to-end without ever touching the live working tree.

- [ ] **Step 5: Manual smoke — `--help` only**

Run:

```bash
tests/ab/run.sh --help
```

Expected: usage block prints, exits 0. No mutations, no run directory created.

Run:

```bash
git status --short
```

Expected: empty output. No working-tree changes from the smoke test.

- [ ] **Step 6: Commit**

```bash
git add tests/ab/run.sh tests/lib/test_ab_harness.sh
git commit -m "$(cat <<'EOF'
feat(tests/ab): wire run.sh orchestrator end-to-end

Replaces the run.sh scaffold with the full Phase 1 lifecycle:
preflight (marketplace root, clean tree, required tools, config schema,
corpus reachable, AWS SSO) → manifest → mutate (with EXIT trap installed
BEFORE mutations) → trial loop → capture → summary.csv → revert.

Phase 1 hard-codes the corpus PR (Jodre11/claude-code-plugins#29) — corpus
YAML schema is Phase 2. Preflight failures hard-halt before any mutation
is applied; the bad-config rejection test asserts the working tree stays
clean on a rejected config.
EOF
)"
```

---

## Task 8: Live smoke — one trial of `baseline` against PR #29

This is the first run of the harness against a real PR with real Bedrock cost. We deliberately use the `baseline` config (no mutations, no `ultrathink` strip) and 1 trial — a sanity check that the lifecycle wires up correctly, the preflight passes, the synthesiser report parses, and the revert trap leaves the tree clean. This is *not* the experiment yet.

**Files:** none modified. The artefact of this task is a run directory under `tests/ab/runs/` and operator-confirmed clean state.

- [ ] **Step 1: Confirm the working tree is clean and we are on the right branch**

Run:

```bash
git status --short
git rev-parse --abbrev-ref HEAD
```

Expected: empty status, branch `feat/ab-test-harness-spec`.

- [ ] **Step 2: Run a one-trial baseline**

Run:

```bash
tests/ab/run.sh --config tests/ab/configs/baseline.yaml --trials 1 --timeout-seconds 1800
```

Expected (on stderr):

```
[HH:MM:SSZ] trial-001: launching...
Run complete: 1/1 trials, 0 timeouts, mean <wall>s. Output: tests/ab/runs/<timestamp>-baseline
```

If the run aborts in preflight, fix the underlying issue (missing tool, dirty tree, expired SSO) and retry. Do *not* edit the harness to bypass the check.

- [ ] **Step 3: Verify the run directory layout and revert succeeded**

Run:

```bash
ls tests/ab/runs/
ls tests/ab/runs/$(ls -t tests/ab/runs/ | head -1)
ls tests/ab/runs/$(ls -t tests/ab/runs/ | head -1)/trial-001/
```

Expected: one directory, containing `manifest.yaml`, `summary.csv`, `REVERT_OK`, and `trial-001/`. Trial directory contains `stdout.log`, `stderr.log`, `synthesiser-report.md`, `verdict.txt`, `timing.json`, `report-stats.json`.

- [ ] **Step 4: Verify the working tree is clean**

Run:

```bash
git status --short
git diff --stat
```

Expected: both empty. If any `plugins/code-review-suite/...` file shows as modified, the revert trap failed silently — STOP and investigate before running anything else against this tree.

- [ ] **Step 5: Eyeball the captured artefacts**

Run:

```bash
cat tests/ab/runs/$(ls -t tests/ab/runs/ | head -1)/summary.csv
cat tests/ab/runs/$(ls -t tests/ab/runs/ | head -1)/manifest.yaml
head -20 tests/ab/runs/$(ls -t tests/ab/runs/ | head -1)/trial-001/synthesiser-report.md
```

Expected:
- `summary.csv` has a header row plus exactly one data row with verdict either `APPROVE` or `REQUEST_CHANGES` (not `INCONCLUSIVE` — if the trial timed out, raise `--timeout-seconds`).
- `manifest.yaml` records the exact config sha256, the suite git SHA, and the corpus PR URL.
- `synthesiser-report.md` starts with `# Code Review Report` or similar — non-empty.

If the verdict is `INCONCLUSIVE` despite a non-zero `report_chars`, the verdict-line regex needs adjusting. Note this as a real bug to fix before running the experiment.

- [ ] **Step 6: No commit needed**

Run directories are gitignored. If anything in the harness needed a fix during this task, commit *that* (the harness fix), not the run output.

---

## Task 9: `tests/ab/README.md` and top-level README pointer

A short operator-facing README explaining how to use the harness, what it does, and what it deliberately does not do. The Phase 1 README is one page — Phase 2 will expand it as corpus YAML and `score.sh` arrive.

**Files:**
- Create: `tests/ab/README.md`
- Modify: `README.md` (top-level — add a one-line pointer)

- [ ] **Step 1: Write `tests/ab/README.md`**

Create `tests/ab/README.md`:

```markdown
# A/B test harness for the code review suite

Phase 1 — minimum viable runner. See
[`docs/superpowers/specs/2026-05-21-ab-test-harness-design.md`](../../docs/superpowers/specs/2026-05-21-ab-test-harness-design.md)
for the full design.

## What it does

Runs N trials of one hard-coded corpus PR (currently
`Jodre11/claude-code-plugins#29`) through the code review suite under one
named config. Captures wall-clock, exit code, the synthesiser report, the
verdict, and a coarse finding count per trial. Writes everything to
`tests/ab/runs/<timestamp>-<config-name>/`.

All variation is achieved by editing tracked agent and dispatch-prompt
files in the working tree. An `EXIT`/`INT`/`TERM`/`HUP` trap reverts every
mutation on every exit path. A failed revert writes `MANUAL_REVERT_REQUIRED`
into the run directory rather than continuing silently.

## What it does not do (Phase 1)

- No corpus YAML — the PR URL is hard-coded.
- No `score.sh` — comparison between two run directories is by hand.
- No seeded-bug recall.
- No `--dry-run`.
- No model-as-judge scoring (this is a permanent design constraint, not a
  Phase 1 cut — see the spec).

## Usage

```
tests/ab/run.sh --config <path> --trials <n> [--name <experiment-name>] [--timeout-seconds <n>]
```

Example — control arm of the `ultrathink` experiment:

```
tests/ab/run.sh --config tests/ab/configs/baseline.yaml --trials 3
```

Example — experiment arm:

```
tests/ab/run.sh --config tests/ab/configs/no-ultrathink.yaml --trials 3
```

## Preconditions

- Working tree clean (`git status --short` empty). The harness refuses to
  start otherwise — mutating an already-dirty tree makes revert unsafe.
- Tools on PATH: `yq`, `jq`, `gh`, `git`, and either `timeout` (Linux) or
  `gtimeout` (macOS via Homebrew `coreutils`).
- AWS SSO token valid for the Bedrock account. The harness sources
  `~/.claudeenv` and runs `~/.claude/scripts/aws-sso-preflight.sh` itself —
  the dotfiles `claude()` shell function is bypassed.

## Output layout

```
tests/ab/runs/<timestamp>-<config-name>/
  manifest.yaml          # config + corpus + suite SHA + mutation summary
  summary.csv            # one row per trial
  REVERT_OK              # marker file written when revert succeeded
  trial-001/
    stdout.log
    stderr.log
    synthesiser-report.md
    verdict.txt
    timing.json
    report-stats.json
  trial-002/
  ...
```

## Configs

A config is a YAML file under `tests/ab/configs/`. Schema:

```yaml
name: <required>
description: <optional>
session:
  model: <opus|sonnet|haiku|...>     # passed as --model
  effort: <low|medium|high|xhigh|max> # passed as --effort
agents:
  <agent-name>:
    model: <opus|sonnet|haiku>       # rewrites frontmatter model:
    ultrathink: <true|false>         # only meaningful on review-synthesiser;
                                     # false strips the keyword from all 3 sync sites
```

Unrecognised top-level, session, or per-agent keys are a hard error — typos
must not silently fall back to production defaults.
```

- [ ] **Step 2: Add a top-level pointer**

Open `README.md`. Find an appropriate section to add the pointer (look for an existing "Internal" / "Development" / "Tests" subsection, or add one).

If no such section exists yet, append after the existing content:

```markdown
## Internal tooling

- [`tests/ab/`](tests/ab/README.md) — A/B test harness for the code review suite.
  Operator-driven; runs identical inputs through the suite under different
  agent parameter configurations and captures mechanical metrics.
```

- [ ] **Step 3: Run the structural tests one more time**

Run:

```bash
tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add tests/ab/README.md README.md
git commit -m "$(cat <<'EOF'
docs(tests/ab): add operator README and top-level pointer

One-page README documenting Phase 1 usage, preconditions, output layout,
and config schema. Top-level README points at it from a new "Internal
tooling" subsection.
EOF
)"
```

---

## Task 10: Run the actual experiment — answer the `ultrathink` question

This is the reason the harness exists. Run baseline (3 trials) and `no-ultrathink` (3 trials) against the same corpus PR, then read the mean wall-clock. If `no-ultrathink` is materially faster (>25%) than baseline, the keyword does something. If they are statistically indistinguishable, it is ornamental.

**Files:** none modified. The artefact is two run directories and a short conclusion written into a temporary file in `${CLAUDE_TEMP_DIR}` for the operator to act on.

- [ ] **Step 1: Confirm preconditions**

Run:

```bash
git status --short
git rev-parse --abbrev-ref HEAD
```

Expected: clean tree, branch `feat/ab-test-harness-spec`.

- [ ] **Step 2: Run the baseline arm**

Run:

```bash
tests/ab/run.sh --config tests/ab/configs/baseline.yaml --trials 3 --timeout-seconds 1800 --name baseline
```

Expected (on stderr):

```
[HH:MM:SSZ] trial-001: launching...
[HH:MM:SSZ] trial-002: launching...
[HH:MM:SSZ] trial-003: launching...
Run complete: 3/3 trials, 0 timeouts, mean <wall>s. Output: tests/ab/runs/<timestamp>-baseline
```

Capture the mean wall-clock from the completion line. Verify:

```bash
git status --short
cat tests/ab/runs/$(ls -t tests/ab/runs/ | head -1)/REVERT_OK >/dev/null
```

Expected: clean status, REVERT_OK marker present.

- [ ] **Step 3: Run the experiment arm**

Run:

```bash
tests/ab/run.sh --config tests/ab/configs/no-ultrathink.yaml --trials 3 --timeout-seconds 1800 --name no-ultrathink
```

Expected: same shape as Step 2. Capture the mean wall-clock.

Verify the working tree reverted cleanly:

```bash
git status --short
git diff --stat -- plugins/code-review-suite/
```

Expected: both empty. If any synthesiser dispatch site shows as modified, the strip-and-revert cycle is broken — STOP and investigate.

- [ ] **Step 4: Compute the deltas by hand and write a conclusion**

Read both `summary.csv` files:

```bash
cat tests/ab/runs/<baseline-dir>/summary.csv
cat tests/ab/runs/<no-ultrathink-dir>/summary.csv
```

Compute:

- `mean_baseline_wall` — average of the `wall_clock_seconds` column in the baseline summary.
- `mean_experiment_wall` — same for the experiment summary.
- `delta_pct = (mean_baseline_wall - mean_experiment_wall) / mean_baseline_wall * 100`

Write a short conclusion to `${CLAUDE_TEMP_DIR}/ultrathink-experiment-conclusion.md`:

```markdown
# ultrathink keyword experiment — Phase 1 result

Baseline (`ultrathink` keyword present on synthesiser dispatch):
- Trials: 3
- Mean wall-clock: <fill in>s
- Verdicts: <APPROVE×n, REQUEST_CHANGES×n>
- Mean finding count: <fill in>

Experiment (`ultrathink` stripped):
- Trials: 3
- Mean wall-clock: <fill in>s
- Verdicts: <fill in>
- Mean finding count: <fill in>

Delta: <fill in>% wall-clock change.

Conclusion (apply the verdict guard rails from the spec):
- If |delta| > 25% AND no metric moved >25% in the opposite direction:
  the keyword has a measurable effect — keep it, and investigate whether
  there is also an explicit thinking-budget mechanism (subagent-level
  --effort propagation) we can use as a primary lever.
- If |delta| <= 25%:
  the keyword appears ornamental on this corpus PR. Do NOT strip it from
  production yet — Phase 1 is one PR, three trials. Schedule a Phase 2
  follow-up across a wider corpus before acting.
```

- [ ] **Step 5: Surface the conclusion to the user**

Print the conclusion file to stdout for the operator to read and act on. Do *not* automatically modify production configs based on a 3-trial result — the spec is explicit that the verdict logic is conservative and three trials cannot give statistical significance.

```bash
cat ${CLAUDE_TEMP_DIR}/ultrathink-experiment-conclusion.md
```

- [ ] **Step 6: No commit**

The experiment artefacts are gitignored. Any tweaks to the harness needed during the run should already be committed at the point they were made; this step produces no new commit.

---

## Task 11: Open the harness PR

The housekeeping PR (Task 1) has already merged to `main`. This task opens the PR for the harness itself.

**Files:** none modified.

- [ ] **Step 1: Confirm the branch is clean and rebased**

Run:

```bash
git status --short
git fetch origin main
git rebase origin/main
```

Expected: clean status, rebase completes without conflicts (the only main-branch change should be the merged housekeeping PR, which does not touch `tests/ab/`).

- [ ] **Step 2: Push and open the PR**

Run:

```bash
git push -u origin feat/ab-test-harness-spec
```

Write the PR body to `${CLAUDE_TEMP_DIR}/harness-pr-body.md`:

```markdown
This PR adds the Phase 1 slice of the A/B test harness designed in
`docs/superpowers/specs/2026-05-21-ab-test-harness-design.md` (commit
`bbd7d81`). The harness exists to answer specific tuning questions about
the code review suite without depending on a single "gold standard"
reference — its first job is the empirical question of whether the
literal `ultrathink` keyword on the synthesiser dispatch actually
escalates thinking budget on the dispatched subagent, or is ornamental.

This is Phase 1 of a four-phase design. It deliberately ships only the
slice needed for the `ultrathink` experiment: a runner, mechanical
metrics, one config, one hard-coded corpus PR, and the EXIT-trap revert
mechanism. Phase 2 (corpus YAML + differential agreement scoring), Phase
3 (seeded-bug recall), and Phase 4 (sweep mode) are explicitly out of
scope.

## Changes

- Adds `tests/ab/run.sh` — orchestrator (preflight → manifest → mutate →
  trial loop → revert → summary).
- Adds `tests/ab/lib/{config,mutate,launch,capture}.sh` — sourced helpers,
  one responsibility each, exercised by fixture-based tests.
- Adds `tests/ab/configs/{baseline,no-ultrathink}.yaml` — the two configs
  needed for the first experiment.
- Adds `tests/lib/test_ab_harness.sh` — structural tests hooked into the
  existing `tests/run.sh` discovery loop.
- Gitignores `tests/ab/runs/`.
- Adds `tests/ab/README.md` and a top-level pointer.

The CI-housekeeping bumps (`actions/checkout` and `gitleaks-action` SHA
pins, `runs-on: ubuntu-24.04`) landed in #PREVIOUS-PR-NUMBER ahead of
this PR per CLAUDE.md "Repo Housekeeping" guidance.

## Test plan

- [ ] `tests/run.sh` passes locally (covers harness fixture tests +
      sync-note tests that detect any drift introduced by the strip-
      ultrathink mutation logic).
- [ ] `tests/ab/run.sh --help` exits 0 and prints usage.
- [ ] `tests/ab/run.sh --config tests/ab/fixtures/config-bad-key.yaml --trials 1`
      exits non-zero AND leaves the working tree clean (preflight
      ordering correctness).
- [ ] One-trial baseline smoke (Task 8) succeeded against PR #29 with
      `REVERT_OK` written and clean working tree afterwards.
- [ ] CI green.
```

Open the PR:

```bash
gh pr create --title "feat(tests/ab): A/B test harness — Phase 1 minimum viable runner" --body-file "${CLAUDE_TEMP_DIR}/harness-pr-body.md"
```

- [ ] **Step 3: Wait for CI green**

Run:

```bash
gh pr checks --watch
```

If a check fails, fix locally, push the fixup, and let CI re-run. Do not merge with red checks.

---

## Self-review

**Spec coverage check:**

| Spec section | Implementing task |
|---|---|
| Architecture: `run.sh` orchestrator | Task 7 |
| Architecture: `lib/mutate.sh` (mutate + trap) | Task 3 |
| Architecture: `lib/launch.sh` | Task 5 |
| Architecture: `lib/capture.sh` | Task 6 |
| Architecture: `lib/config.sh` | Task 4 |
| Architecture: `configs/baseline.yaml`, `configs/no-ultrathink.yaml` | Task 4 |
| Architecture: `runs/<timestamp>-<exp-name>/` layout | Task 7 (write_manifest, append_summary_row, capture_parse_trial) |
| Schemas: config schema with strict unknown-key rejection | Task 4 |
| Run lifecycle: preflight (cwd, clean tree, tools, corpus reachable, SSO) | Task 7 (Step 3 `_ab_preflight_*`) |
| Run lifecycle: manifest with config sha256 + suite SHA | Task 7 (`_ab_write_manifest`) |
| Run lifecycle: install mutations + EXIT/INT/TERM/HUP trap | Task 3 (`mutate_install_revert_trap`) + Task 7 (called BEFORE mutate_apply_config) |
| Run lifecycle: per-trial dir, timing.json, capture, summary.csv row | Task 6 + Task 7 (`_ab_append_summary_row`) |
| Run lifecycle: revert + REVERT_OK / MANUAL_REVERT_REQUIRED | Task 3 (`_ab_revert_on_exit`) |
| Failure handling: halt-and-fix on infrastructure | Task 7 (`_ab_preflight_*` exit 1) |
| Failure handling: mark-and-continue on per-trial failures | Task 7 (loop catches non-zero rc, INCONCLUSIVE verdict) + Task 6 |
| Failure handling: hard halt + alarm on revert failures | Task 3 (`_ab_write_manual_revert_marker`) |
| Cost-aware: trial counts operator-controlled | Task 7 (`--trials` argv) |
| Bedrock-resident: source ~/.claudeenv + SSO preflight | Task 5 (`launch_preflight_environment`) |
| Alias-aware: invoke `command claude` directly | Task 5 (`launch_run_trial`) |
| Drive params from outside the suite | Tasks 3 + 4 (mutate via tracked-file edits + revert) |
| Phase 1 cuts: no corpus YAML, no score.sh, no diff agreement, no seeded bugs, no --dry-run | All — none of these are in any task |
| Open question: `--output-format stream-json` for usage.json | Deferred (Phase 1 scope explicitly leans on wall-clock; capture writes no usage.json) |
| Open question: `--effort` propagation to subagents | Deferred (will surface as a side-effect of the experiment in Task 10) |
| Open question: `ultrathink` strip respects three sync sites | Task 3 (`_AB_ULTRATHINK_SYNC_SITES` array) |
| Housekeeping: GitHub Actions and runner pins as a separate PR | Task 1 |

No spec gaps identified.

**Placeholder scan:** None. Every code step contains complete code; every command step contains an exact command and an expected outcome.

**Type/identifier consistency check:**
- `mutate_strip_ultrathink_keyword`, `mutate_set_agent_model`, `mutate_install_revert_trap`, `mutate_apply_config` — defined in Task 3, called from Task 7 with matching signatures.
- `config_load`, `_AB_CONFIG_NAME`, `_AB_CONFIG_DESCRIPTION`, `_AB_CONFIG_SESSION_MODEL`, `_AB_CONFIG_SESSION_EFFORT`, `_AB_CONFIG_STRIP_ULTRATHINK`, `_AB_CONFIG_AGENT_MODELS` — defined in Task 4, consumed in Tasks 3 and 7 under the same names.
- `launch_resolve_timeout_binary`, `launch_preflight_environment`, `launch_build_claude_argv`, `launch_run_trial` — defined in Task 5, called from Task 7 with matching signatures.
- `capture_parse_trial` — defined in Task 6, called from Task 7 once per trial.
- `_AB_RUN_DIR` — set in Task 7 (`main`) before the trap is installed, read by Task 3 (`_ab_revert_on_exit`, `_ab_write_manual_revert_marker`).
- `_AB_MUTATED_FILES` — populated by `_ab_track_mutation` (Task 3), consumed by `_ab_revert_on_exit` (Task 3).
- `_AB_ULTRATHINK_SYNC_SITES` — defined and consumed entirely within Task 3.

All consistent.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-21-ab-test-harness-phase-1-plan.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?

