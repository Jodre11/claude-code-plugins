# Ephemeral Worktree Review Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Review a GitHub PR against an ephemeral git worktree cut from the exact PR head SHA, so concurrent reviews never collide and a review can never silently analyse stale/wrong code.

**Architecture:** A deterministic `bin/review-worktree` bash helper owns the fragile multi-step git sequence (prune → fetch → verify SHA → `worktree add --detach` → re-assert HEAD → print path). The `review-gh-pr` host skill calls it in a new Phase -0.5, reassigns `$REPO_DIR` to the worktree, pins `$HEAD_SHA`, gates the now-redundant Phase 0.55 staleness halt, and tears the worktree down on exit. A prerequisite fix threads `repoDir` into the Workflow `workflow()` call so the synthesiser reads the target tree, not cwd.

**Tech Stack:** Bash (helper, matching the `bin/housekeeper-freshness` deterministic-engine idiom), git worktrees, `gh` CLI, the existing shell test harness (`tests/run.sh` + `tests/lib/test_*.sh`).

## Global Constraints

- **Three-file verbatim sync.** The pipeline body — from the line `Follow these instructions exactly. Do not skip steps or reorder.` through `Present the synthesiser's formatted report to the user.` — MUST be byte-identical across `plugins/code-review-suite/includes/review-pipeline.md` (canonical), `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`, and `plugins/code-review-suite/commands/pre-review.md`. `tests/lib/test_sync_notes.sh` enforces this with a `diff`. Every prose edit in Task 1 and Task 4 lands in all three files identically.
- **No `version` field** in any `plugin.json` — versioning is by commit SHA.
- **2-space indentation** for `.md`/`.json`; **4-space** for shell scripts; **LF** line endings; **final newline** on every text file. Enforced by `tests/lib/test_conventions.sh`.
- **Executables** in `bin/` MUST have the `+x` bit (`tests/lib/test_conventions.sh::test_executables_have_x_bit`).
- **Correctness chain is non-negotiable and fails loud:** GitHub head SHA → fetched → worktree cut at that immutable SHA → `rev-parse HEAD` re-asserted equal. Any break is a hard, non-zero halt that creates nothing — never review an unverified tree.
- **`pre-review` (local mode) is unchanged in behaviour.** Phase -0.5 and teardown carry a "skip in local mode" clause, so the identical prose is inert in `pre-review.md`.
- **Spec:** `docs/superpowers/specs/2026-07-01-worktree-review-isolation-design.md`.

---

### Task 1: Thread `repoDir` into the Workflow call (prerequisite fix)

`review-core.mjs` reads `repoDir` (lines 126, 356) to tell the synthesiser which tree to read, but no consumer passes it — so the synthesiser silently reads cwd. This is a standalone correctness fix that the worktree work depends on (under a worktree, cwd would be the wrong tree). The edit lands in all three synced files.

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (the `workflow({scriptPath: ...})` args block, ~line 806-817)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (same block, ~line 912-923)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (same block, ~line 807)
- Test: `tests/lib/test_review_worktree.sh` (new file; first assertion added here)

**Interfaces:**
- Consumes: `$REPO_DIR` (already resolved in Phase -1 of every consumer).
- Produces: the string token `repoDir: $REPO_DIR` present inside the `workflow(...)` args object in all three files. `review-core.mjs` already destructures `repoDir` (line 126) — no `.mjs` change needed.

- [ ] **Step 1: Write the failing test**

Create `tests/lib/test_review_worktree.sh` with this content:

```bash
#!/usr/bin/env bash
# Tests for the ephemeral worktree review isolation feature:
# the repoDir Workflow arg, the bin/review-worktree helper, and the
# Phase -0.5 / Phase 0.55-gating / teardown prose.

_rw_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

test_review_worktree_repodir_threaded() {
    local cr
    cr=$(_rw_cr_dir)
    local missing=()
    local f
    for f in \
        "includes/review-pipeline.md" \
        "skills/review-gh-pr/SKILL.md" \
        "commands/pre-review.md"; do
        if ! grep -qF 'repoDir: $REPO_DIR' "$cr/$f" 2>/dev/null; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "repoDir threaded into workflow() args in all three consumers"
    else
        fail "repoDir threaded into workflow() args in all three consumers" \
            "missing 'repoDir: \$REPO_DIR' in: ${missing[*]}"
    fi
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 'repoDir threaded'`
Expected: FAIL — `missing 'repoDir: $REPO_DIR' in: includes/review-pipeline.md skills/review-gh-pr/SKILL.md commands/pre-review.md`

- [ ] **Step 3: Add the `repoDir` arg to the canonical file**

In `plugins/code-review-suite/includes/review-pipeline.md`, in the `workflow(...)` args object, add the `repoDir` key. Change:

```
    base: $BASE, headSha: $HEAD_SHA, emptyTreeMode: $EMPTY_TREE_MODE,
    pathScope: $PATH_SCOPE, tempDir: $RESOLVED_TEMP_DIR,
    intentLedger: $INTENT_LEDGER
})
```

to:

```
    base: $BASE, headSha: $HEAD_SHA, emptyTreeMode: $EMPTY_TREE_MODE,
    pathScope: $PATH_SCOPE, tempDir: $RESOLVED_TEMP_DIR,
    intentLedger: $INTENT_LEDGER, repoDir: $REPO_DIR
})
```

- [ ] **Step 4: Mirror the identical edit into the other two files**

Apply the exact same change to the `workflow(...)` args block in:
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
- `plugins/code-review-suite/commands/pre-review.md`

The three blocks must remain byte-identical (Global Constraint: three-file verbatim sync).

- [ ] **Step 5: Run the new test and the sync test to verify they pass**

Run: `bash tests/run.sh 2>&1 | grep -E 'repoDir threaded|pipeline inline sync'`
Expected: `✓ repoDir threaded into workflow() args in all three consumers`, and both `✓ pipeline inline sync: skills/review-gh-pr/SKILL.md matches canonical` and `✓ pipeline inline sync: commands/pre-review.md matches canonical`.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all tests pass (0 failed).

- [ ] **Step 7: Commit**

```bash
git add tests/lib/test_review_worktree.sh \
  plugins/code-review-suite/includes/review-pipeline.md \
  plugins/code-review-suite/skills/review-gh-pr/SKILL.md \
  plugins/code-review-suite/commands/pre-review.md
git commit -m "fix(code-review): thread repoDir into the review-core workflow() call

The synthesiser read cwd instead of the target repo because no consumer
passed repoDir, which review-core.mjs already destructures. Prerequisite
for ephemeral worktree isolation."
```

---

### Task 2: `bin/review-worktree` helper — add (happy path) + remove

Create the deterministic lifecycle helper. It is a single cohesive script (a deterministic shell tool, per the repo lesson: drive multi-step git determinism from a real script, never LLM prose). This task writes the complete script and pins the happy `add` path and the executable bit; Task 3 pins the adversarial guarantees (SHA mismatch, stale-prune, remove idempotency) against the same script.

**Files:**
- Create: `plugins/code-review-suite/bin/review-worktree` (executable)
- Test: `tests/lib/test_review_worktree.sh` (extend)

**Interfaces:**
- Produces (CLI contract consumed by Task 4's prose):
  - `review-worktree add <repoDir> <branch> <expectedHeadSha>` → on success prints the absolute worktree path to stdout and exits 0; on any failure exits non-zero and creates nothing.
  - `review-worktree remove <worktreePath>` → idempotent; exits 0 whether or not the path exists.
- Worktree root: `${CLAUDE_TEMP_DIR:-${TMPDIR:-/tmp}}/review-worktrees` (session-scoped). Stale threshold: `${REVIEW_WORKTREE_STALE_MINUTES:-360}` minutes.

- [ ] **Step 1: Write the failing happy-path test**

Append to `tests/lib/test_review_worktree.sh`:

```bash
# Build a fixture repo with an 'origin' remote and one commit on 'main'.
# Echoes: "<repoDir> <bareOrigin> <headSha>". Caller rm -rf's both dirs.
_rw_make_fixture() {
    local origin work
    origin=$(mktemp -d)
    work=$(mktemp -d)
    git init -q --bare "$origin"
    git init -q -b main "$work"
    git -C "$work" config user.email "t@example.com"
    git -C "$work" config user.name "T"
    echo "hello" > "$work/file.txt"
    git -C "$work" add file.txt
    git -C "$work" commit -qm "v1"
    git -C "$work" remote add origin "$origin"
    git -C "$work" push -q -u origin main
    printf '%s %s %s\n' "$work" "$origin" "$(git -C "$work" rev-parse HEAD)"
}

test_review_worktree_add_happy_path() {
    local helper
    helper="$(_rw_cr_dir)/bin/review-worktree"
    if [[ ! -x "$helper" ]]; then
        fail "review-worktree add: happy path" "helper missing or not executable"
        return
    fi
    local root fixture work origin sha wt_path actual
    root=$(mktemp -d)
    read -r work origin sha < <(_rw_make_fixture)

    wt_path=$(CLAUDE_TEMP_DIR="$root" "$helper" add "$work" main "$sha")
    if [[ -d "$wt_path" ]]; then
        pass "review-worktree add: prints an existing worktree path"
    else
        fail "review-worktree add: prints an existing worktree path" "path: $wt_path"
    fi

    actual=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)
    assert_equals "$sha" "$actual" "review-worktree add: worktree HEAD is the expected SHA"

    # Detached HEAD -> symbolic-ref fails.
    if git -C "$wt_path" symbolic-ref -q HEAD >/dev/null 2>&1; then
        fail "review-worktree add: worktree is detached" "HEAD is on a branch"
    else
        pass "review-worktree add: worktree is detached"
    fi

    git -C "$work" worktree remove --force "$wt_path" 2>/dev/null || true
    rm -rf "$root" "$work" "$origin"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 'review-worktree add: happy'`
Expected: FAIL — `helper missing or not executable`.

- [ ] **Step 3: Write the complete helper script**

Create `plugins/code-review-suite/bin/review-worktree` with this content (4-space indentation, LF, final newline):

```bash
#!/usr/bin/env bash
# review-worktree — deterministic ephemeral git-worktree lifecycle for
# code-review-suite. The fragile multi-step git sequence is deterministic,
# unit-tested shell — never LLM-improvised prose.
#
# Subcommands:
#   add <repoDir> <branch> <expectedHeadSha>
#       Prune stale plugin-owned worktrees, fetch <branch>, assert the fetched
#       head equals <expectedHeadSha>, create a detached worktree at that
#       immutable SHA under the session temp root, re-assert HEAD, print the
#       absolute path. Exits non-zero and creates nothing on any failure.
#   remove <worktreePath>
#       Idempotent teardown. Exit 0 whether or not the path exists.
#
# Worktree root: ${CLAUDE_TEMP_DIR:-${TMPDIR:-/tmp}}/review-worktrees
# Stale age threshold (minutes): ${REVIEW_WORKTREE_STALE_MINUTES:-360}
set -euo pipefail

STALE_MINUTES="${REVIEW_WORKTREE_STALE_MINUTES:-360}"

_root() {
    printf '%s/review-worktrees' "${CLAUDE_TEMP_DIR:-${TMPDIR:-/tmp}}"
}

_die() {
    echo "review-worktree: $*" >&2
    exit 1
}

# Reclaim leaked plugin-owned worktrees older than the threshold (self-heal for
# a worktree left behind by a crashed run), then prune git's admin records.
# Age-based so a concurrent review's fresh worktree is never reclaimed.
_prune_stale() {
    local repo_dir="$1"
    local root dir
    root="$(_root)"
    if [[ -d "$root" ]]; then
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            git -C "$repo_dir" worktree remove --force "$dir" 2>/dev/null || rm -rf "$dir"
        done < <(find "$root" -maxdepth 1 -type d -name 'wt-*' -mmin "+$STALE_MINUTES" 2>/dev/null)
    fi
    git -C "$repo_dir" worktree prune 2>/dev/null || true
}

cmd_add() {
    local repo_dir="${1:-}" branch="${2:-}" expected_sha="${3:-}"
    [[ -n "$repo_dir" && -n "$branch" && -n "$expected_sha" ]] \
        || _die "add requires <repoDir> <branch> <expectedHeadSha>"
    [[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] \
        || _die "expected head SHA is not a 40-hex string: $expected_sha"
    git -C "$repo_dir" rev-parse --show-toplevel >/dev/null 2>&1 \
        || _die "not a git repo: $repo_dir"

    _prune_stale "$repo_dir"

    # Fetch the exact head by branch.
    git -C "$repo_dir" fetch --quiet origin "$branch" \
        || _die "fetch failed for origin/$branch"

    # Verify the fetched ref matches the expected SHA.
    local fetched_sha
    fetched_sha="$(git -C "$repo_dir" rev-parse FETCH_HEAD)"
    [[ "$fetched_sha" == "$expected_sha" ]] \
        || _die "fetched head $fetched_sha != expected $expected_sha (branch $branch)"

    # Create the worktree detached at the immutable SHA.
    local root worktree_path
    root="$(_root)"
    mkdir -p "$root"
    worktree_path="${root}/wt-${expected_sha:0:12}-$$"
    git -C "$repo_dir" worktree add --quiet --detach "$worktree_path" "$expected_sha" \
        || _die "worktree add failed at $expected_sha"

    # Post-condition: the new worktree is at the expected SHA.
    local actual_sha
    actual_sha="$(git -C "$worktree_path" rev-parse HEAD)"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        git -C "$repo_dir" worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
        git -C "$repo_dir" worktree prune 2>/dev/null || true
        _die "post-condition failed: worktree HEAD $actual_sha != $expected_sha"
    fi

    printf '%s\n' "$worktree_path"
}

cmd_remove() {
    local worktree_path="${1:-}"
    [[ -n "$worktree_path" ]] || _die "remove requires <worktreePath>"
    if [[ -d "$worktree_path" ]]; then
        # Resolve the owning repo from the worktree's common gitdir.
        local common_dir repo_dir
        common_dir="$(git -C "$worktree_path" rev-parse --git-common-dir 2>/dev/null || true)"
        if [[ -n "$common_dir" ]]; then
            case "$common_dir" in
                /*) : ;;
                *) common_dir="$worktree_path/$common_dir" ;;
            esac
            repo_dir="$(dirname "$common_dir")"
            git -C "$repo_dir" worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
            git -C "$repo_dir" worktree prune 2>/dev/null || true
        else
            rm -rf "$worktree_path"
        fi
    fi
    exit 0
}

main() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        add) cmd_add "$@" ;;
        remove) cmd_remove "$@" ;;
        *) _die "unknown subcommand: ${sub:-<none>} (expected add|remove)" ;;
    esac
}

main "$@"
```

- [ ] **Step 4: Set the executable bit**

Run: `chmod +x plugins/code-review-suite/bin/review-worktree`

- [ ] **Step 5: Run the happy-path test and the conventions x-bit check**

Run: `bash tests/run.sh 2>&1 | grep -E 'review-worktree add: (happy|prints|worktree)|executable: plugins/code-review-suite/bin/review-worktree'`
Expected: `✓ review-worktree add: prints an existing worktree path`, `✓ review-worktree add: worktree HEAD is the expected SHA`, `✓ review-worktree add: worktree is detached`, and `✓ executable: plugins/code-review-suite/bin/review-worktree`.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all tests pass (0 failed).

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review-suite/bin/review-worktree tests/lib/test_review_worktree.sh
git commit -m "feat(code-review): add bin/review-worktree lifecycle helper

Deterministic add/remove of an ephemeral git worktree cut from a verified
PR head SHA (fetch -> assert SHA -> worktree add --detach -> re-assert HEAD)."
```

---

### Task 3: `review-worktree` adversarial guarantees (mismatch, stale-prune, remove idempotency)

Pin the correctness-chain guards and self-heal behaviour of the helper written in Task 2. Each test proves a distinct guarantee the design calls non-negotiable.

**Files:**
- Test: `tests/lib/test_review_worktree.sh` (extend)

**Interfaces:**
- Consumes: `review-worktree add`/`remove` CLI contract and the `_rw_make_fixture` / `_rw_cr_dir` helpers from Task 2.

- [ ] **Step 1: Write the SHA-mismatch failing test**

Append to `tests/lib/test_review_worktree.sh`:

```bash
test_review_worktree_add_sha_mismatch_halts() {
    local helper
    helper="$(_rw_cr_dir)/bin/review-worktree"
    if [[ ! -x "$helper" ]]; then
        fail "review-worktree add: SHA mismatch halts" "helper missing"
        return
    fi
    local root work origin sha wrong out rc before after
    root=$(mktemp -d)
    read -r work origin sha < <(_rw_make_fixture)
    wrong="0000000000000000000000000000000000000000"

    before=$(find "$root" -maxdepth 1 -type d -name 'wt-*' 2>/dev/null | wc -l | tr -d ' ')
    set +e
    out=$(CLAUDE_TEMP_DIR="$root" "$helper" add "$work" main "$wrong" 2>&1)
    rc=$?
    set -e
    after=$(find "$root" -maxdepth 1 -type d -name 'wt-*' 2>/dev/null | wc -l | tr -d ' ')

    if [[ $rc -ne 0 ]]; then
        pass "review-worktree add: SHA mismatch exits non-zero"
    else
        fail "review-worktree add: SHA mismatch exits non-zero" "exit 0, stdout: $out"
    fi
    assert_equals "$before" "$after" "review-worktree add: SHA mismatch creates no worktree"

    rm -rf "$root" "$work" "$origin"
}
```

- [ ] **Step 2: Run it to verify it passes (guard already present)**

Run: `bash tests/run.sh 2>&1 | grep 'SHA mismatch'`
Expected: `✓ review-worktree add: SHA mismatch exits non-zero` and `✓ review-worktree add: SHA mismatch creates no worktree`. (The Task-2 verify guard already enforces this; this test pins it against regression.)

- [ ] **Step 3: Write the stale-prune test**

Append:

```bash
test_review_worktree_add_prunes_stale() {
    local helper
    helper="$(_rw_cr_dir)/bin/review-worktree"
    if [[ ! -x "$helper" ]]; then
        fail "review-worktree add: prunes stale worktrees" "helper missing"
        return
    fi
    local root work origin sha stale wt_path
    root=$(mktemp -d)
    read -r work origin sha < <(_rw_make_fixture)

    # Seed a stale plugin-owned dir aged past a 1-minute threshold.
    mkdir -p "$root/review-worktrees"
    stale="$root/review-worktrees/wt-staleseed000-1"
    mkdir -p "$stale"
    touch -d "10 minutes ago" "$stale"

    wt_path=$(CLAUDE_TEMP_DIR="$root" REVIEW_WORKTREE_STALE_MINUTES=1 "$helper" add "$work" main "$sha")

    if [[ -d "$stale" ]]; then
        fail "review-worktree add: prunes stale worktrees" "stale dir survived"
    else
        pass "review-worktree add: prunes stale worktrees"
    fi

    git -C "$work" worktree remove --force "$wt_path" 2>/dev/null || true
    rm -rf "$root" "$work" "$origin"
}
```

- [ ] **Step 4: Write the remove-idempotency test**

Append:

```bash
test_review_worktree_remove_idempotent() {
    local helper
    helper="$(_rw_cr_dir)/bin/review-worktree"
    if [[ ! -x "$helper" ]]; then
        fail "review-worktree remove: idempotent" "helper missing"
        return
    fi
    local root work origin sha wt_path rc1 rc2
    root=$(mktemp -d)
    read -r work origin sha < <(_rw_make_fixture)
    wt_path=$(CLAUDE_TEMP_DIR="$root" "$helper" add "$work" main "$sha")

    set +e
    CLAUDE_TEMP_DIR="$root" "$helper" remove "$wt_path"; rc1=$?
    CLAUDE_TEMP_DIR="$root" "$helper" remove "$wt_path"; rc2=$?
    set -e

    if [[ ! -d "$wt_path" ]]; then
        pass "review-worktree remove: worktree gone after remove"
    else
        fail "review-worktree remove: worktree gone after remove" "still present"
    fi
    assert_equals "0" "$rc1" "review-worktree remove: first remove exits 0"
    assert_equals "0" "$rc2" "review-worktree remove: second remove (already gone) exits 0"

    rm -rf "$root" "$work" "$origin"
}
```

- [ ] **Step 5: Run the three new tests**

Run: `bash tests/run.sh 2>&1 | grep -E 'prunes stale|remove:'`
Expected: `✓ review-worktree add: prunes stale worktrees`, `✓ review-worktree remove: worktree gone after remove`, `✓ review-worktree remove: first remove exits 0`, `✓ review-worktree remove: second remove (already gone) exits 0`.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all tests pass (0 failed).

- [ ] **Step 7: Commit**

```bash
git add tests/lib/test_review_worktree.sh
git commit -m "test(code-review): pin review-worktree correctness-chain guards

Cover SHA-mismatch hard-halt (creates nothing), stale-worktree self-heal
on add, and remove idempotency."
```

---

### Task 4: Host-skill wiring — Phase -0.5, Phase 0.55 gating, teardown (three-file sync)

Add the worktree lifecycle to the pipeline prose. Because `review-core.mjs` runs in a sandbox with no shell/filesystem access, lifecycle lives in the host skill. All three synced files receive byte-identical edits; the Phase -0.5 and teardown blocks are inert in `pre-review.md` via their "skip in local mode" clauses.

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (canonical)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
- Modify: `plugins/code-review-suite/commands/pre-review.md`
- Test: `tests/lib/test_review_worktree.sh` (extend)

**Interfaces:**
- Consumes: `review-worktree add|remove` CLI (Task 2); `$REPO_DIR`, `$OWNER_REPO` (Phase -1); `$REVIEW_MODE` (Phase 0.1); `$HEAD_SHA` (Step 2.1); the PR head branch `headRefName` (Step 1 PR data).
- Produces: `$WORKTREE_OWNED` (`true`/`false`) consumed by the Phase 0.55 gate and by teardown; `$REPO_DIR` reassigned to the worktree path on the owned path.

- [ ] **Step 1: Write the failing structure test**

Append to `tests/lib/test_review_worktree.sh`:

```bash
test_review_worktree_phase_prose_present_and_synced() {
    local cr
    cr=$(_rw_cr_dir)
    local tokens=(
        '## Phase -0.5: Ephemeral worktree'
        'WORKTREE_OWNED'
        '--no-worktree'
        'Worktree:'
        'review-worktree add'
        'review-worktree remove'
    )
    local files=(
        "includes/review-pipeline.md"
        "skills/review-gh-pr/SKILL.md"
        "commands/pre-review.md"
    )
    local missing=()
    local f t
    for f in "${files[@]}"; do
        for t in "${tokens[@]}"; do
            if ! grep -qF "$t" "$cr/$f" 2>/dev/null; then
                missing+=("$f::$t")
            fi
        done
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "worktree phase prose present in all three consumers"
    else
        fail "worktree phase prose present in all three consumers" "missing: ${missing[*]}"
    fi

    # Gate: Phase 0.55 must run only when the worktree is NOT owned.
    if grep -qF 'WORKTREE_OWNED = false' "$cr/includes/review-pipeline.md" 2>/dev/null; then
        pass "Phase 0.55 gated on \$WORKTREE_OWNED = false"
    else
        fail "Phase 0.55 gated on \$WORKTREE_OWNED = false" "gating clause not found"
    fi
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 'worktree phase prose'`
Expected: FAIL — `missing:` lists the Phase -0.5 tokens across all three files.

- [ ] **Step 3: Add Phase -0.5 to the canonical file**

In `plugins/code-review-suite/includes/review-pipeline.md`, insert a new section **between the end of Phase -1 (after the paragraph ending `target a PR in a repository other than the current directory.`) and `## Phase 0: Intent Ledger`**:

````markdown
## Phase -0.5: Ephemeral worktree

Run Phase -0.5 AFTER Phase -1 and BEFORE Phase 0. It runs only when
`$REVIEW_MODE` is `pr`. If `$REVIEW_MODE` is `local`, skip this entire section
(leave `$WORKTREE_OWNED = false`) and continue to Phase 0 — pre-review measures
the working tree in place and must not relocate it.

The review must analyse the exact commit the PR head points to, in a worktree
that neither disturbs nor is disturbed by the target repo's live checkout.
Resolve the mode below, first match wins:

1. **External worktree supplied.** If `$ARGUMENTS` contains a
   `Worktree: <abs-path>` line, set `$REPO_DIR` to that path, set
   `$WORKTREE_OWNED = false`, and skip both creation and teardown. The supplier
   (e.g. shakedown) owns that worktree's lifecycle. Validate the path is
   absolute and `git -C "$REPO_DIR" rev-parse --show-toplevel` succeeds; if not,
   report `Invalid worktree: $REPO_DIR` and stop.

2. **Opt-out.** If `$ARGUMENTS` contains a `--no-worktree` token, skip creation;
   keep today's in-place behaviour against the Phase -1 `$REPO_DIR`. Set
   `$WORKTREE_OWNED = false`.

3. **Default (plugin-owned worktree).**
   - Resolve the PR head branch `$HEAD_BRANCH` from the `headRefName` field of
     the Step 1 PR data.
   - Resolve `$EXPECTED_HEAD_SHA` from
     `gh pr view "$ARGUMENTS" --repo "$OWNER_REPO" --json headRefOid -q .headRefOid`.
     Validate it matches `^[0-9a-f]{40}$`; if not, report
     `Phase -0.5 halt: could not resolve PR head SHA` and stop.
   - Call the helper (from this plugin's `bin/` directory, already on `PATH`):

     ```bash
     review-worktree add "$REPO_DIR" "$HEAD_BRANCH" "$EXPECTED_HEAD_SHA"
     ```

     On a **non-zero exit**, hard-halt with the helper's stderr message and run
     no review — never analyse an unverified tree.
   - On success, capture the printed absolute path. Reassign `$REPO_DIR` to it,
     set `$WORKTREE_OWNED = true`, and pin `$HEAD_SHA = $EXPECTED_HEAD_SHA` for
     the rest of the pipeline.

Announce `> Phase -0.5: reviewing in worktree $REPO_DIR at $HEAD_SHA` on the
owned path, or `> Phase -0.5: worktree skipped ($WORKTREE_OWNED reason)`
otherwise, and continue to Phase 0.
````

- [ ] **Step 4: Gate Phase 0.55 in the canonical file**

In `plugins/code-review-suite/includes/review-pipeline.md`, in `## Phase 0.55: Local branch freshness check`, add a new gating subsection immediately after the section heading and its opening paragraph, before `### 0.55.1 Skip in local mode`:

```markdown
### 0.55.0 Skip when the worktree is plugin-owned

If `$WORKTREE_OWNED = true`, skip this entire section and continue to Phase 0.6.
The owned worktree was cut from the freshly fetched-and-verified PR head in
Phase -0.5, so the "local HEAD behind remote" staleness halt is redundant. The
`--no-worktree` and external-worktree paths keep `$WORKTREE_OWNED = false` and
still run the checks below.
```

- [ ] **Step 5: Add teardown to the canonical file**

In `plugins/code-review-suite/includes/review-pipeline.md`, add a teardown subsection at the very end of the synced pipeline body, immediately **before** the final line `Present the synthesiser's formatted report to the user.` (keep that exact line as the last line of the synced range):

````markdown
## Phase 9: Worktree teardown

If `$WORKTREE_OWNED = true`, tear the plugin-owned worktree down on **every**
exit path from this pipeline — successful completion, clean halt, or error —
by running:

```bash
review-worktree remove "$REPO_DIR"
```

`remove` is idempotent (safe to call when already gone, safe to double-call).
Combined with the prune-on-next-`add` self-heal in the helper, a worktree
leaked by a hard crash between `add` and `remove` is reclaimed on the next
review. When `$WORKTREE_OWNED = false` (external or `--no-worktree`), do
nothing — the worktree is not ours to remove.

````

Confirm the section that follows still begins with `Present the synthesiser's formatted report to the user.` so the sync-range end marker is preserved.

- [ ] **Step 6: Mirror all three edits into the other two files**

Apply the Step 3, Step 4, and Step 5 insertions **verbatim** into:
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
- `plugins/code-review-suite/commands/pre-review.md`

The synced range (from `Follow these instructions exactly...` to `Present the synthesiser's formatted report to the user.`) must be byte-identical across all three.

- [ ] **Step 7: Run the structure test and the sync test**

Run: `bash tests/run.sh 2>&1 | grep -E 'worktree phase prose|Phase 0.55 gated|pipeline inline sync'`
Expected: `✓ worktree phase prose present in all three consumers`, `✓ Phase 0.55 gated on $WORKTREE_OWNED = false`, and both `✓ pipeline inline sync: ... matches canonical` lines.

- [ ] **Step 8: Run the full suite**

Run: `bash tests/run.sh`
Expected: all tests pass (0 failed). If `pipeline inline sync` fails, the three copies diverged — diff the reported file against the canonical and re-align byte-for-byte.

- [ ] **Step 9: Commit**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md \
  plugins/code-review-suite/skills/review-gh-pr/SKILL.md \
  plugins/code-review-suite/commands/pre-review.md \
  tests/lib/test_review_worktree.sh
git commit -m "feat(code-review): review PRs in an ephemeral verified worktree

Phase -0.5 cuts a plugin-owned worktree from the fetched-and-verified PR
head via bin/review-worktree, gating the now-redundant Phase 0.55 staleness
halt on the owned path and tearing the worktree down on every exit.
Supports Worktree:<path> (external) and --no-worktree opt-outs."
```

---

### Task 5: README note

Document the new `bin/` tool and the `--no-worktree` / `Worktree:` flags so consumers discover the behaviour.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing. Documentation only.

- [ ] **Step 1: Add the note under Internal tooling**

In `README.md`, under the `## Internal tooling` section, add a bullet after the `tests/ab/` bullet:

```markdown
- [`plugins/code-review-suite/bin/review-worktree`](plugins/code-review-suite/bin/review-worktree)
  — deterministic add/remove of the ephemeral, verified worktree PR reviews run
  against. By default `review-gh-pr` cuts a worktree from the exact PR head SHA
  so concurrent reviews never collide and never analyse stale code. Pass
  `--no-worktree` in the review arguments to review in place, or a
  `Worktree: <abs-path>` line to supply an externally-owned worktree (the plugin
  then neither creates nor tears it down).
```

- [ ] **Step 2: Verify LF endings and final newline**

Run: `bash tests/run.sh 2>&1 | grep -E 'LF line endings|final newline'`
Expected: both `✓` (no regressions from the README edit).

- [ ] **Step 3: Run the full suite**

Run: `bash tests/run.sh`
Expected: all tests pass (0 failed).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(code-review): document review-worktree and its opt-out flags"
```

---

## Known limitations (implement per spec; surface, do not silently deviate)

- **Fork PRs.** `review-worktree add` fetches `origin <branch>` (the PR `headRefName`). For a PR opened from a fork, that branch may not exist on `origin`; the fetch fails and the helper hard-halts (creates nothing, informs the user) — which is the correct fail-loud behaviour, not a silent wrong-tree review. Broadening the fetch to `refs/pull/<n>/head` is out of scope for this spec; note it as a follow-up if fork reviews become common.
- **Mid-review head drift** is deliberately not chased. The worktree pins to the head at review start; the existing Step 4 / Class B.2 pre-post `headRefOid` re-check already warns before submitting if the head advanced.

## Follow-on (separate repo, NOT this PR)

- **shakedown wiring** lives in the private `~/.claude` repo (`commands/shakedown.md` + `scripts/shakedown-core.mjs`) — a separate git remote and push target. This plugin PR only establishes the `Worktree: <abs-path>` contract that the private shakedown will later target by passing that line in its `agentPrompt`/args. Do not add shakedown changes to this PR.

## Self-Review

**Spec coverage:**
- Prerequisite `repoDir` fix → Task 1. ✓
- Component 1 `bin/review-worktree` add (prune→fetch→verify→create→post-assert→print) → Task 2 Step 3; adversarial guards → Task 3. ✓
- Component 1 `remove` idempotency → Task 2 (code) + Task 3 (test). ✓
- Correctness chain (fetch→assert→pin) → Task 2 code + Task 3 mismatch test + Task 4 Phase -0.5 pin of `$HEAD_SHA`. ✓
- Component 2(a) repoDir arg → Task 1. (b) Phase -0.5 opt-out modes → Task 4 Step 3. (c) Phase 0.55 gating → Task 4 Step 4. (d) teardown every exit → Task 4 Step 5. ✓
- Component 3 shakedown → flagged as follow-on in the private repo (out of this PR), per spec §"Detailed shakedown wiring is a follow-on". ✓
- Mid-review drift → Known limitations. ✓
- Error handling (add fails / remove idempotent / leaked→prune / owned=false preserves guards) → Tasks 2–4. ✓
- Testing (add fixture, SHA-mismatch, remove idempotency, prune-on-add, x-bit) → Tasks 2–3 + conventions harness. ✓
- Files touched: bin (Task 2), SKILL.md (Task 4), tests (Tasks 1–4 — note the canonical include + pre-review.md also change, which the spec's "Files touched" understated; captured as a Global Constraint), README (Task 5). ✓

**Placeholder scan:** No TBD/TODO/"add appropriate error handling"/"write tests for the above" — every code and test step carries complete content. ✓

**Type/name consistency:** `$WORKTREE_OWNED`, `$REPO_DIR`, `$HEAD_SHA`, `$EXPECTED_HEAD_SHA`, `$HEAD_BRANCH`, `$OWNER_REPO`, `$REVIEW_MODE` used consistently. Helper CLI `review-worktree add <repoDir> <branch> <expectedHeadSha>` / `remove <worktreePath>` matches between Task 2 interface, Task 3 tests, and Task 4 prose. Env vars `CLAUDE_TEMP_DIR` / `REVIEW_WORKTREE_STALE_MINUTES` consistent between helper and tests. ✓
