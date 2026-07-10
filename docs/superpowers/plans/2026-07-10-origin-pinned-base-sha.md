# Origin-pinned base SHA for PR reviews — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/review-gh-pr` compute its diff against an origin-authoritative base SHA (the PR's `baseRefOid`) instead of a bare `main` ref that resolves to a stale local branch inside the review worktree.

**Architecture:** In PR mode the orchestrator pins `$BASE` to the PR's `baseRefOid` and fetches its objects — in Phase -0.5 on the plugin-owned-worktree path, or as a Step 1 fallback on the `--no-worktree`/external-worktree path. Every subagent then receives the pinned SHA via the existing `Base branch:` prompt line, so specialists and the synthesiser need no diff-command changes. A standalone specialist (invoked with no orchestrator) degrades read-only: it pins `baseRefOid` only if that SHA is already in the local object store, never fetching (the read-only reviewer guard forbids `git fetch`).

**Tech Stack:** Markdown pipeline prose (`code-review-suite` plugin), Bash structural tests (`tests/lib/test_*.sh` + `tests/run.sh`), `gh` CLI (`--json baseRefOid`/`baseRefName`), git.

## Global Constraints

- **Byte-sync invariant (load-bearing).** `includes/review-pipeline.md` is the CANONICAL pipeline body and is inlined **byte-for-byte** into `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md`. Any edit inside the pipeline body (everything between `Follow these instructions exactly` and `Present the synthesiser's formatted report to the user.`) MUST be applied identically to all three files, or `test_sync_pipeline_inline_matches_canonical` fails. Edit the canonical first, then paste the identical block into the two consumers.
- **Items 1–4 are frozen.** `test_sync_base_branch_steps_match` compares the numbered items `1.`–`4.` between `Try these in order:` and the `Store as` line, byte-for-byte, across `review-pipeline.md` and `specialist-context.md`. Never edit those four items. All new logic goes either BEFORE `Try these in order:` (the pinned-skip guard) or AFTER the `Store as $BASE` line (the fallback pins) — both outside that extraction window.
- **Reviewers are read-only.** `~/.claude/hooks/_lib.sh` `is_mutating_git()` classifies `fetch` as mutating; `allow-permissions.sh` denies mutating git for any `*-reviewer` / `code-analysis` / `review-synthesiser`. `git fetch` may appear ONLY in orchestrator (main-session) prose — never in `specialist-context.md`.
- **`$BASE_REF` vs `$BASE`:** the base branch *name* (`baseRefName`) is used ONLY as a `git fetch` refspec. It must NEVER reach a `git diff`. Only the validated 40-hex `baseRefOid` SHA is stored in `$BASE` and fed to diffs.
- **Three-dot diffs unchanged.** `git diff "$BASE"..."$HEAD_SHA"` when `$EMPTY_TREE_MODE = false`; two-arg when true. EMPTY_TREE and local (`pre-review`) modes are untouched.
- **`review-synthesiser.md` gets NO change** — it is a pure prompt consumer of the `Base branch:` line, not a resolver.
- **Repo conventions:** md 2-space indent, LF, final newline; `.sh` 4-space indent. Bash: one simple command per call, no `&&`/`;`/`|`/`$(...)`/redirection except `2>&1` (the `git commit -m "$(cat <<'EOF'…EOF)"` heredoc is the sole carve-out). No `version` field in any `plugin.json`.
- **No behavioural A/B.** This is a correctness fix to diff *inputs*, not a model-tuning change; the gated-sweep apparatus does not apply. Verification is `tests/run.sh` green.

---

### Task 1: Pin the base in Phase -0.5 (owned-worktree path) + regression-guard scaffold

**Files:**
- Create: `tests/lib/test_base_pin.sh`
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (Phase -0.5, item 3 "Default (plugin-owned worktree)")
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (same section, inlined copy)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (same section, inlined copy)
- Test: `tests/lib/test_base_pin.sh` (run via `tests/run.sh`)

**Interfaces:**
- Produces: `$BASE_PINNED` (boolean, `true` once the base is an origin-pinned SHA — consumed by Task 2's guard and Task 3's fallback), `$BASE_REF` (base branch name, fetch refspec only), `$EXPECTED_BASE_SHA` (validated `baseRefOid`). After this task `$BASE` on the owned path is a 40-hex SHA and `$EMPTY_TREE_MODE = false`.

- [ ] **Step 1: Write the failing test**

Create `tests/lib/test_base_pin.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# Origin-pinned base SHA regression guards (spec 2026-07-10-origin-pinned-base-sha).
# The pipeline body is byte-synced across three files; these guards assert the new
# base-pin prose landed in the CANONICAL (includes/review-pipeline.md) and, for the
# read-only path, in includes/specialist-context.md. The existing pipeline-inline sync
# test enforces propagation to SKILL.md and pre-review.md.

test_base_pin_phase_minus05_pins_baserefoid() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin Phase -0.5" "code-review-suite plugin not found"
        return
    fi
    local canonical="$cr/includes/review-pipeline.md"
    # Scope to the Phase -0.5 section so §2a's later baseRefOid addition cannot false-pass this.
    local phase
    phase=$(sed -n '/^## Phase -0.5: Ephemeral worktree$/,/^## Phase 0: Intent Ledger$/p' "$canonical")
    if grep -qF 'baseRefOid' <<<"$phase" && grep -qF 'BASE_PINNED = true' <<<"$phase"; then
        pass "base pin Phase -0.5: canonical resolves baseRefOid and sets \$BASE_PINNED"
    else
        fail "base pin Phase -0.5: canonical resolves baseRefOid and sets \$BASE_PINNED" \
            "review-pipeline.md Phase -0.5 (owned-worktree path) must resolve the PR baseRefOid and set \$BASE_PINNED = true so the base diff endpoint is an origin-pinned SHA"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 'base pin Phase'`
Expected: FAIL — `review-pipeline.md Phase -0.5 ... must resolve the PR baseRefOid` (the string `baseRefOid` / `BASE_PINNED = true` is not yet in Phase -0.5).

- [ ] **Step 3: Edit the canonical (`includes/review-pipeline.md`)**

In Phase -0.5, item 3 "Default (plugin-owned worktree)", insert a new sub-bullet immediately AFTER the `$EXPECTED_HEAD_SHA` bullet (the one ending `report Phase -0.5 halt: could not resolve PR head SHA and stop.`) and BEFORE the `$RESOLVED_TEMP_DIR` bullet:

```markdown
   - Resolve `$BASE_REF` (the base branch name) from
     `gh pr view "$ARGUMENTS" --repo "$OWNER_REPO" --json baseRefName -q .baseRefName`,
     and `$EXPECTED_BASE_SHA` from
     `gh pr view "$ARGUMENTS" --repo "$OWNER_REPO" --json baseRefOid -q .baseRefOid`.
     Validate `$EXPECTED_BASE_SHA` matches `^[0-9a-f]{40}$`; if not, report
     `Phase -0.5 halt: could not resolve PR base SHA` and stop.
   - Fetch the base objects into the shared object store, then pin the base as a SHA.
     A plain fetch writes only objects, `FETCH_HEAD`, and the remote-tracking ref — it
     never touches the working tree, `HEAD`, the local branch refs, or any worktree
     checkout, so it is side-effect-free for everything the review analyses:

     ```bash
     git -C "$REPO_DIR" fetch origin "$BASE_REF"
     ```

     Then set `$BASE = $EXPECTED_BASE_SHA`, `$EMPTY_TREE_MODE = false` (a live PR base is
     never the empty tree), and `$BASE_PINNED = true` for the rest of the pipeline.
     `$BASE_REF` is used ONLY as the fetch refspec — never fed to `git diff`.
```

Then update the Phase -0.5 announce paragraph. Replace:

```markdown
Announce `> Phase -0.5: reviewing in worktree $REPO_DIR at $HEAD_SHA` on the
owned path, or `> Phase -0.5: worktree skipped ($WORKTREE_OWNED reason)`
otherwise, and continue to Phase 0.
```

with:

```markdown
Announce `> Phase -0.5: reviewing in worktree $REPO_DIR at $HEAD_SHA (base pinned to $BASE)`
on the owned path, or `> Phase -0.5: worktree skipped ($WORKTREE_OWNED reason)`
otherwise, and continue to Phase 0.
```

- [ ] **Step 4: Propagate byte-identically to the two consumers**

Apply the *exact same two edits* from Step 3 to:
- `skills/review-gh-pr/SKILL.md` — same "Default (plugin-owned worktree)" bullet and same Phase -0.5 announce paragraph (locate by the heading `## Phase -0.5: Ephemeral worktree` and the `$EXPECTED_HEAD_SHA` bullet, not by line number).
- `commands/pre-review.md` — same section, same anchors.

The inserted block and the announce replacement must be byte-for-byte identical in all three files.

- [ ] **Step 5: Run tests to verify pass + byte-sync intact**

Run: `bash tests/run.sh`
Expected: PASS overall. Specifically:
- `base pin Phase -0.5: canonical resolves baseRefOid and sets $BASE_PINNED` → ✓
- `pipeline inline sync: review-gh-pr/SKILL.md matches canonical` → ✓
- `pipeline inline sync: commands/pre-review.md matches canonical` → ✓
- `base-branch resolution steps 1-4 match between pipeline and specialist` → ✓

If a `pipeline inline sync` line fails, the three files diverged — diff the reported block and make the consumer byte-identical to the canonical.

- [ ] **Step 6: Commit**

```bash
git add tests/lib/test_base_pin.sh plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md
git commit -m "$(cat <<'EOF'
fix(code-review): pin PR base to origin baseRefOid in Phase -0.5

Owned-worktree PR reviews now diff against the PR's baseRefOid (fetched
from origin) instead of a bare `main` ref that resolves to a stale local
branch inside the worktree. Adds the Phase -0.5 base pin + regression guard.
EOF
)"
```

---

### Task 2: Guard Step 1 against clobbering the Phase -0.5 pin

**Why this task exists:** After Phase -0.5 pins `$BASE` to a SHA, Step 1 runs next and its item 2 (`gh pr view --json baseRefName`) would overwrite the SHA with the bare branch name. The guard makes Step 1 skip re-resolution when `$BASE_PINNED = true`. Without it Task 1's pin is silently undone.

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (Step 1, before `Try these in order:`)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (same, inlined)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (same, inlined)
- Test: `tests/lib/test_base_pin.sh` (append one function)

**Interfaces:**
- Consumes: `$BASE_PINNED` (from Task 1).
- Produces: no new variables; guarantees `$BASE` survives Step 1 unchanged when already pinned.

- [ ] **Step 1: Append the failing test**

Append this function to `tests/lib/test_base_pin.sh`:

```bash
test_base_pin_step1_skips_when_pinned() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin Step 1 guard" "code-review-suite plugin not found"
        return
    fi
    local canonical="$cr/includes/review-pipeline.md"
    # The guard must sit BEFORE "Try these in order:" so it never enters the byte-synced
    # items 1-4. Extract Step 1's head (heading -> "Try these in order:") and assert it.
    local head
    head=$(sed -n '/^### Step 1: Determine base branch$/,/^Try these in order:$/p' "$canonical")
    if grep -qF 'BASE_PINNED' <<<"$head" && grep -qiF 'skip items 1' <<<"$head"; then
        pass "base pin Step 1 guard: canonical skips re-resolution when \$BASE_PINNED is true"
    else
        fail "base pin Step 1 guard: canonical skips re-resolution when \$BASE_PINNED is true" \
            "Step 1 must guard on \$BASE_PINNED BEFORE 'Try these in order:' — otherwise item 2 (gh pr view --json baseRefName) overwrites the Phase -0.5 SHA pin with a bare branch name"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 'base pin Step 1 guard'`
Expected: FAIL — `Step 1 must guard on $BASE_PINNED BEFORE 'Try these in order:'`.

- [ ] **Step 3: Edit the canonical (`includes/review-pipeline.md`)**

In Step 1, insert this paragraph AFTER the "This duplicates the logic in `includes/specialist-context.md` …" sync-note paragraph and IMMEDIATELY BEFORE the line `Try these in order:`:

```markdown
**If `$BASE_PINNED` is already `true`** (Phase -0.5 pinned the origin base SHA on the
plugin-owned-worktree path), `$BASE` is a validated 40-hex SHA and `$EMPTY_TREE_MODE` is
already `false`. Do NOT re-resolve the base: skip items 1–4 and the `Store as $BASE` block
below — re-running item 2 (`gh pr view --json baseRefName`) would overwrite the pinned SHA
with a bare branch name — and continue at item 5 (`Path scope:` extraction). Otherwise
resolve the base now:

```

(Keep the blank line so `Try these in order:` remains its own line.)

- [ ] **Step 4: Propagate byte-identically to the two consumers**

Paste the identical paragraph into `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md` at the same position (after the Step 1 sync-note paragraph, before `Try these in order:`). Byte-for-byte identical.

- [ ] **Step 5: Run tests to verify pass + byte-sync intact**

Run: `bash tests/run.sh`
Expected: PASS overall. Specifically:
- `base pin Step 1 guard: canonical skips re-resolution when $BASE_PINNED is true` → ✓
- `pipeline inline sync: …` (both consumers) → ✓
- `base-branch resolution steps 1-4 match between pipeline and specialist` → ✓ (guard is outside the items 1-4 window, so this stays green)

- [ ] **Step 6: Commit**

```bash
git add tests/lib/test_base_pin.sh plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md
git commit -m "$(cat <<'EOF'
fix(code-review): skip Step 1 base re-resolution when base is pinned

Guards the Phase -0.5 SHA pin from being clobbered by Step 1 item 2's bare
baseRefName resolution. Placed before "Try these in order:" so the byte-synced
items 1-4 are untouched.
EOF
)"
```

---

### Task 3: Step 1 fallback pin for the `--no-worktree` / external-worktree PR path

**Why this task exists:** On the `--no-worktree` and external-worktree paths, Phase -0.5's pin is skipped, so `$BASE_PINNED` is unset and `$BASE` was resolved to a bare name by items 1–4. This orchestrator-only fallback pins it to `baseRefOid` (fetch permitted — main session, no `agent_type`).

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (Step 1, after the `Store as $BASE` / validate / Diff-syntax block, before item 5)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (same, inlined)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (same, inlined)
- Test: `tests/lib/test_base_pin.sh` (append one function)

**Interfaces:**
- Consumes: `$BASE_PINNED`, `$REVIEW_MODE`, `$EMPTY_TREE_MODE`, `$BASE` (bare name from items 1–4), `$OWNER_REPO`.
- Produces: on this path, `$BASE` becomes a 40-hex SHA and `$BASE_PINNED = true`.

- [ ] **Step 1: Append the failing test**

Append this function to `tests/lib/test_base_pin.sh`:

```bash
test_base_pin_step1_noworktree_fallback() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin Step 1 fallback" "code-review-suite plugin not found"
        return
    fi
    local canonical="$cr/includes/review-pipeline.md"
    # The --no-worktree fallback lives AFTER "Store as" (outside byte-synced items 1-4) and
    # before Step 2. It must pin baseRefOid and fetch (orchestrator-only, main session).
    local tail
    tail=$(sed -n '/^Store as /,/^### Step 2: Measure the diff/p' "$canonical")
    if grep -qF 'baseRefOid' <<<"$tail" && grep -qF 'fetch origin' <<<"$tail"; then
        pass "base pin Step 1 fallback: canonical pins baseRefOid + fetches on the --no-worktree path"
    else
        fail "base pin Step 1 fallback: canonical pins baseRefOid + fetches on the --no-worktree path" \
            "Step 1 must, after 'Store as \$BASE', pin baseRefOid and 'git fetch origin' for the --no-worktree PR path (orchestrator-only, guarded by \$BASE_PINNED not true and \$REVIEW_MODE = pr)"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 'base pin Step 1 fallback'`
Expected: FAIL — `Step 1 must, after 'Store as $BASE', pin baseRefOid and 'git fetch origin'`.

- [ ] **Step 3: Edit the canonical (`includes/review-pipeline.md`)**

In Step 1, insert this block AFTER the `**Diff syntax:** …` paragraph (the one ending `continue using three-dot syntax as normal.`) and IMMEDIATELY BEFORE item `5.` (the `Path scope:` bullet):

```markdown
**Origin-pin the base (PR mode, orchestrator only).** If `$BASE_PINNED` is not `true`,
`$REVIEW_MODE` is `pr`, and `$EMPTY_TREE_MODE` is `false`, then Phase -0.5's pin was skipped
(the `--no-worktree` or external-worktree path) but a live PR base exists and `$BASE` is
currently a bare branch name. Pin it to the origin SHA:

- Resolve `$BASE_REF` from
  `gh pr view "$ARGUMENTS" --repo "$OWNER_REPO" --json baseRefName -q .baseRefName`, and
  `$EXPECTED_BASE_SHA` from
  `gh pr view "$ARGUMENTS" --repo "$OWNER_REPO" --json baseRefOid -q .baseRefOid`. Validate
  `$EXPECTED_BASE_SHA` matches `^[0-9a-f]{40}$`; if not, report
  `Step 1 halt: could not resolve PR base SHA` and stop.
- Fetch base objects only — never touches the working tree, `HEAD`, or local branch refs:

  ```bash
  git -C "$REPO_DIR" fetch origin "$BASE_REF"
  ```

  Then set `$BASE = $EXPECTED_BASE_SHA` and `$BASE_PINNED = true`. `$BASE_REF` is the fetch
  refspec only — never fed to `git diff`.

This step runs in the main session (the orchestrator carries no `agent_type`), so the fetch
is permitted. Announce `> Step 1: base pinned to $BASE (origin baseRefOid)`.

```

- [ ] **Step 4: Propagate byte-identically to the two consumers**

Paste the identical block into `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md` at the same position (after `**Diff syntax:** …`, before item `5.`). Byte-for-byte identical.

- [ ] **Step 5: Run tests to verify pass + byte-sync intact**

Run: `bash tests/run.sh`
Expected: PASS overall. Specifically:
- `base pin Step 1 fallback: canonical pins baseRefOid + fetches on the --no-worktree path` → ✓
- `pipeline inline sync: …` (both consumers) → ✓
- `base-branch resolution steps 1-4 match between pipeline and specialist` → ✓ (block is after `Store as`, outside the items 1-4 window)

- [ ] **Step 6: Commit**

```bash
git add tests/lib/test_base_pin.sh plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md
git commit -m "$(cat <<'EOF'
fix(code-review): pin base to baseRefOid on the --no-worktree PR path

Step 1 fallback: when Phase -0.5's pin was skipped (--no-worktree/external
worktree) but a live PR base exists, resolve and fetch baseRefOid so the diff
base is an origin SHA. Orchestrator-only (main session), placed after the
byte-synced items 1-4.
EOF
)"
```

---

### Task 4: Standalone-specialist read-only degraded pin

**Why this task exists:** A specialist invoked directly (no orchestrator, no `Base branch:` SHA in its prompt) resolves the base itself and, today, lands on a bare name. It cannot fetch (read-only mandate). This task lets it pin `baseRefOid` *only if the SHA is already local*, else keep the bare name and warn. `specialist-context.md` is NOT byte-synced with the pipeline after the `Store as` line, so this edit is standalone.

**Files:**
- Modify: `plugins/code-review-suite/includes/specialist-context.md` (after its `Store as $BASE` / Diff-syntax block, before item 5)
- Test: `tests/lib/test_base_pin.sh` (append one function)

**Interfaces:**
- Consumes: `$BASE` (bare name from items 1–4), `$EMPTY_TREE_MODE`.
- Produces: `$BASE` becomes a SHA only when `git cat-file -e` confirms it is already present locally; otherwise unchanged. Never fetches.

- [ ] **Step 1: Append the failing test**

Append these two functions to `tests/lib/test_base_pin.sh`:

```bash
test_base_pin_specialist_readonly() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin specialist read-only" "code-review-suite plugin not found"
        return
    fi
    local spec="$cr/includes/specialist-context.md"
    # Standalone specialists may pin baseRefOid ONLY if the SHA is already local (git cat-file
    # -e). They must NEVER fetch (read-only mandate; the guard blocks it).
    if grep -qF 'baseRefOid' "$spec" && grep -qF 'git cat-file -e' "$spec"; then
        pass "base pin specialist read-only: specialist-context pins baseRefOid guarded by cat-file"
    else
        fail "base pin specialist read-only: specialist-context pins baseRefOid guarded by cat-file" \
            "specialist-context.md must read baseRefOid and gate the pin on 'git cat-file -e' (SHA already in the local object store)"
    fi
}

test_base_pin_specialist_never_fetches() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin specialist never fetches" "code-review-suite plugin not found"
        return
    fi
    local spec="$cr/includes/specialist-context.md"
    if grep -qF 'git fetch' "$spec"; then
        fail "base pin specialist never fetches: specialist-context contains no 'git fetch'" \
            "specialist-context.md must contain no 'git fetch' — reviewers are read-only and the reviewer guard (allow-permissions.sh) blocks a fetch"
    else
        pass "base pin specialist never fetches: specialist-context contains no 'git fetch'"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 'base pin specialist read-only'`
Expected: FAIL — `specialist-context.md must read baseRefOid and gate the pin on 'git cat-file -e'`. (The `never fetches` guard passes already — `specialist-context.md` has no `git fetch` today — and must stay passing.)

- [ ] **Step 3: Edit `includes/specialist-context.md`**

Insert this block AFTER the `**Diff syntax:** …` paragraph (ending `use three-dot syntax as normal.`) and IMMEDIATELY BEFORE item `5.` (the `Path scope:` bullet):

```markdown
**Origin-pin the base when standalone (PR, read-only).** The orchestrator normally passes a
pinned 40-hex SHA in the `Base branch:` line — when it does, items 1–4 already stored it and
this step is a no-op. But when you are invoked directly against a live PR (no orchestrator),
`$BASE` above is a bare branch name. Try to pin it to the origin SHA **without fetching** —
you are a reviewer; `git fetch` is a read-only-mandate violation and is blocked by the
reviewer guard. Only when `$EMPTY_TREE_MODE` is `false`:

- Read the base SHA: `gh pr view --json baseRefOid -q .baseRefOid 2>/dev/null` (a read —
  permitted). Store as `$EXPECTED_BASE_SHA`.
- If `$EXPECTED_BASE_SHA` matches `^[0-9a-f]{40}$` AND `git cat-file -e "$EXPECTED_BASE_SHA"
  2>/dev/null` succeeds (the base commit is already in the local object store — normally
  true; it is an ancestor of the head you were given), set `$BASE = $EXPECTED_BASE_SHA`.
- Otherwise keep the bare `$BASE` and log a warning: `Base could not be origin-pinned (SHA
  absent locally; fetching would violate the read-only mandate) — diffing against bare
  "$BASE".`

Never run `git fetch` here.

```

- [ ] **Step 4: Run tests to verify pass**

Run: `bash tests/run.sh`
Expected: PASS overall. Specifically:
- `base pin specialist read-only: specialist-context pins baseRefOid guarded by cat-file` → ✓
- `base pin specialist never fetches: specialist-context contains no 'git fetch'` → ✓
- `base-branch resolution steps 1-4 match between pipeline and specialist` → ✓ (block is after `Store as`, outside the items 1-4 window)

- [ ] **Step 5: Commit**

```bash
git add tests/lib/test_base_pin.sh plugins/code-review-suite/includes/specialist-context.md
git commit -m "$(cat <<'EOF'
fix(code-review): read-only base pin for standalone specialists

A directly-invoked specialist pins baseRefOid only when that SHA is already in
the local object store (git cat-file -e); otherwise it keeps the bare name and
warns. Never fetches — reviewers are read-only.
EOF
)"
```

---

### Task 5: Full-suite verification

**Files:** none modified (verification only).

- [ ] **Step 1: Run the complete structural suite**

Run: `bash tests/run.sh`
Expected: final summary line shows `0 failed`. Confirm these are all green:
- `base pin Phase -0.5 …`, `base pin Step 1 guard …`, `base pin Step 1 fallback …`, `base pin specialist read-only …`, `base pin specialist never fetches …`
- `pipeline inline sync: review-gh-pr/SKILL.md matches canonical`
- `pipeline inline sync: commands/pre-review.md matches canonical`
- `base-branch resolution steps 1-4 match between pipeline and specialist`
- `BASE regex: …`, `HEAD_SHA regex: …`, `PATH_SCOPE regex: …` (unchanged — no regex touched)

- [ ] **Step 2: Confirm the synthesiser was not touched**

Run: `git diff --name-only main...HEAD`
Expected: the list contains `includes/review-pipeline.md`, `skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`, `includes/specialist-context.md`, `tests/lib/test_base_pin.sh` — and does NOT contain `agents/review-synthesiser.md` (it is a pure prompt consumer; spec §2d).

- [ ] **Step 3: Housekeeping note (standing rule)**

This change touches only markdown pipeline prose and one bash test — no dependency manifests, GitHub Actions, runners, or IaC. A freshness/dependency-bump pass has no surface here; skip it for this PR. (If the implementer opportunistically runs `code-review-suite:housekeeper` and it surfaces unrelated staleness, land that as a separate small PR per the repo's housekeeping rule — do not fold it in.)

---

## Self-Review

**1. Spec coverage:**
- §1 (Phase -0.5 core pin) → Task 1. ✓
- §2a (`--no-worktree` fallback, orchestrator-only, after `Store as`) → Task 3. ✓
- §2b (local mode untouched) → no task needed; local mode never sets `$BASE_PINNED` and the guards/fallbacks are gated on `$REVIEW_MODE = pr`. Verified by Task 5 Step 1 (local-path tests stay green). ✓
- §2c (EMPTY_TREE untouched) → every new block is gated on `$EMPTY_TREE_MODE = false`. ✓
- §2d two-resolvers-plus-consumer: pipeline resolver → Tasks 1–3; specialist resolver read-only → Task 4; synthesiser NOT a resolver → Task 5 Step 2 asserts it is untouched. ✓
- §2d clobber hazard (not explicit in spec, discovered in review) → Task 2 guard. ✓
- §3 (diff syntax unchanged) → no diff-command edits in any task; three-dot preserved. ✓
- Testing/byte-sync-stays-green → Global Constraints + every task's Step 5/4 asserts `pipeline inline sync` and `base-branch resolution steps 1-4` green. ✓
- Testing/regression-guard → Tasks 1–4 each add a structural guard. ✓
- Non-goals (Phase 0.55 head rule, EMPTY_TREE, local diff, resolver refactor) → none touched. ✓

**2. Placeholder scan:** No `TBD`/`handle edge cases`/`similar to`/bare "write tests" — every step carries literal prose blocks, exact `sed`/`grep` test bodies, and exact `git`/`bash` commands with expected output. ✓

**3. Type/name consistency:** `$BASE_PINNED`, `$BASE_REF`, `$EXPECTED_BASE_SHA`, `$BASE`, `$EMPTY_TREE_MODE`, `$REVIEW_MODE`, `$OWNER_REPO`, `$REPO_DIR` used identically across Tasks 1–4. Test function names unique: `test_base_pin_phase_minus05_pins_baserefoid`, `test_base_pin_step1_skips_when_pinned`, `test_base_pin_step1_noworktree_fallback`, `test_base_pin_specialist_readonly`, `test_base_pin_specialist_never_fetches`. All live in one file `tests/lib/test_base_pin.sh`, auto-discovered by `run.sh`'s `declare -F | grep '^test_'`. ✓
