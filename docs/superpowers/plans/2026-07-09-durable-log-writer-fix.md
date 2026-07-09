# Durable full-log writer reliability fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the code-review-suite durable full log write reliably by replacing buried
post-completion prose with a reordered, deterministic `bin/` script call plus a Stop-hook
forcing function that blocks turn-end if a review ran but no durable log landed.

**Architecture:** Three coordinated moves against the three failure layers identified in the
spec — (1) **reorder** the write from Step 7a (after report presentation) to a new Step 3.6
(immediately after the Workflow bundle returns, high attention); (2) **replace** the fragile
multi-step JSONL-hand-assembly prose with one deterministic, unit-tested `bin/durable-log-write`
that assembles JSONL via `jq -c` (fixing silent corruption on finding text with newlines/quotes);
(3) **add** a `Stop` hook that arms off a session-scoped breadcrumb marker and blocks turn-end
when the expected log file is absent.

**Tech Stack:** Bash (`#!/usr/bin/env bash`, `set -euo pipefail`), `jq`, Claude Code plugin
hooks (`hooks/hooks.json` `Stop` event), the repo's shell test harness (`tests/lib/harness.sh`,
auto-discovered `test_*` functions in `tests/lib/test_*.sh`).

**Spec:** `docs/superpowers/specs/2026-07-09-durable-log-writer-fix-design.md` (read it first).

## Global Constraints

Every task's requirements implicitly include this section.

- **Durable log path convention (shared by writer + hook):**
  `$HOME/.claude/code-review-suite/logs/<repo-slug>/<ident>-<sha>.{md,jsonl}` where `<repo-slug>`
  is the reviewed repo `owner/name` with `/`→`-`, `<ident>` is `pr-<N>` (PR mode) or the slugified
  branch (local mode), `<sha>` is the **12-char** head sha. Overwrite on same sha is intentional
  (idempotent, latest-wins).
- **Breadcrumb marker contract (plan-level resolution of the spec's deferred path decision):**
  the host Writes `$CLAUDE_TEMP_DIR/durable-log-expected.json` =
  `{"repo_slug":…,"ident":…,"sha":…,"ts":…}` (all host-context literals; `sha` is the **12-char**
  filename form) BEFORE calling the writer. The Stop hook reconstructs the session temp dir from
  its stdin `session_id` (`/tmp/claude-<session_id>/durable-log-expected.json`) — `CLAUDE_TEMP_DIR`
  is NOT exported into hook subprocesses, and keying off `session_id` makes a foreign session's
  breadcrumb structurally invisible (dissolves the cross-session false-block landmine). The marker
  stores the 12-char sha so no 40→12 normalisation is needed anywhere.
- **Breadcrumb self-expiry:** the hook ignores a marker older than a TTL
  (`DURABLE_LOG_GATE_TTL_MINUTES`, default 360 — matches `REVIEW_WORKTREE_STALE_MINUTES`) so a
  crashed session cannot wedge a live one.
- **Bash hook rules (CLAUDE.md, hook-enforced):** in *this repo's tooling and any command you run*,
  one simple command per Bash call — no `&&`/`;`/`|`/`$(…)`/redirection except `2>&1`; the only
  carve-out is the `git commit -m "$(cat <<'EOF'…EOF)"` HEREDOC. (This constrains how YOU run
  commands; the *shipped scripts* themselves are ordinary multi-line bash and are exempt.)
- **Shell conventions:** `#!/usr/bin/env bash`, `set -euo pipefail`, **4-space** indent, `chmod +x`
  on anything in `bin/`/`hooks/`, LF line endings, final newline. `jq` is an assumed prerequisite
  (already used across the suite).
- **Plugin conventions:** no `version` field in `plugin.json`; md/json 2-space, `.sh` 4-space.
  Tests are `tests/lib/test_*.sh` sourced by `tests/run.sh`; any `test_*` function is auto-run.
- **Scanner safety:** never commit a full Bedrock inference-profile ARN literal; use plain model
  names. (Not expected to arise here, but the pre-commit secret scan is active.)
- **CI:** `tests/run.sh` + gitleaks must pass. `main` is branch-protected → this ships as a PR.

---

### Task 1: `bin/durable-log-write` deterministic writer

**Files:**
- Create: `plugins/code-review-suite/bin/durable-log-write`
- Test: `tests/lib/test_durable_log_write.sh`

**Interfaces:**
- Consumes: nothing from other tasks. A `--payload` JSON file (the `bundle.log` object — shape
  from `workflows/review-core.mjs:700 buildLogPayload`: always `{bodyText, findings[]}`, optionally
  `{meta, cogs[]}`). The `{meta, cogs}` keys are present on the normal PR/local path and absent on
  the finalize/stall-recovery route (`:136` passes `phaseLog=null`); the true lightweight route
  emits no `log` at all, so it never reaches this writer. Host-context literals arrive via flags.
- Produces (relied on by Task 3's prose and Task 2's hook via the shared path convention):
  the CLI contract
  `durable-log-write --repo-slug <s> --ident <i> --sha <12hex> --plugin-sha <s|unknown>
   --payload <path> [--tokens <path>] [--ts <iso8601>] [--out-dir <dir>]`, writing
  `<out-dir>/<repo-slug>/<ident>-<sha>.{md,jsonl}`; `--out-dir` defaults to
  `$HOME/.claude/code-review-suite/logs`.

- [ ] **Step 1: Write the failing test file**

Create `tests/lib/test_durable_log_write.sh`. It follows the harness pattern (functions named
`test_*`, using `pass`/`fail`/`assert_equals`; `$REPO_ROOT` is provided by the harness). A shared
fixture-builder writes a `bundle.log` payload whose finding text deliberately contains a double
quote and a newline — the corruption case that is the highest-value assertion.

```bash
#!/usr/bin/env bash
# Unit tests for bin/durable-log-write — the deterministic durable-log writer.

_dlw_bin() { echo "$REPO_ROOT/plugins/code-review-suite/bin/durable-log-write"; }

# Build a payload fixture: "full" = meta + cogs + findings (normal PR/local path);
# "nocogs" = bodyText + findings only, no meta/cogs. The nocogs shape is what the
# FINALIZE / stall-recovery route emits (review-core.mjs:136 passes phaseLog=null →
# buildLogPayload returns {bodyText, findings}). NOTE: the true "lightweight" route
# (buildLightweightBundle) returns NO `log` key at all, so Step 3.6 skips it entirely;
# this fixture is the recovered-envelope case, not the lightweight case.
# $1 = "full" | "nocogs"; echoes the payload file path (caller rm -rf's the dir).
_dlw_payload() {
    local mode="$1" dir
    dir=$(mktemp -d)
    if [[ "$mode" == "full" ]]; then
        cat > "$dir/payload.json" <<'JSON'
{
  "bodyText": "## Review\nLine two.",
  "meta": {"base":"abc","head_sha":"0123456789abcdef0123456789abcdef01234567","empty_tree_mode":false,"path_scope":""},
  "cogs": [{"phase":"round1","domain":"correctness","output":{"findings":[]}}],
  "findings": [{"tier":"consensus","file":"a.py","line":3,"description":"has \"quotes\" and\na newline"}]
}
JSON
    else
        cat > "$dir/payload.json" <<'JSON'
{
  "bodyText": "No findings.",
  "findings": [{"tier":"consensus","file":"a.py","line":1,"description":"plain"}]
}
JSON
    fi
    echo "$dir/payload.json"
}

test_dlw_md_header_and_body_verbatim() {
    local bin payload out md
    bin=$(_dlw_bin); payload=$(_dlw_payload full); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha deadbee \
        --payload "$payload" --ts 2026-07-09T00:00:00Z --out-dir "$out"
    md="$out/o-r/pr-1-0123456789ab.md"
    assert_equals "<!-- plugin_sha: deadbee | ts: 2026-07-09T00:00:00Z -->" \
        "$(head -1 "$md")" "durable-log-write: .md line 1 is the provenance comment"
    # bodyText verbatim: second line onward equals the payload bodyText.
    assert_equals "## Review" "$(sed -n '2p' "$md")" "durable-log-write: .md body is bodyText verbatim (line 1)"
    assert_equals "Line two." "$(sed -n '3p' "$md")" "durable-log-write: .md body is bodyText verbatim (line 2)"
    rm -rf "$out" "$(dirname "$payload")"
}

test_dlw_jsonl_every_line_valid_json() {
    local bin payload out jsonl badlines
    bin=$(_dlw_bin); payload=$(_dlw_payload full); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out"
    jsonl="$out/o-r/pr-1-0123456789ab.jsonl"
    badlines=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
            badlines=$((badlines + 1))
        fi
    done < "$jsonl"
    assert_equals "0" "$badlines" "durable-log-write: every .jsonl line is valid JSON (finding with quote+newline survives)"
    rm -rf "$out" "$(dirname "$payload")"
}

test_dlw_jsonl_line_order() {
    local bin payload out jsonl types
    bin=$(_dlw_bin); payload=$(_dlw_payload full); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out"
    jsonl="$out/o-r/pr-1-0123456789ab.jsonl"
    types=$(jq -r '.type' "$jsonl" | tr '\n' ' ')
    assert_equals "meta cog finding " "$types" "durable-log-write: .jsonl order is meta -> cog -> finding"
    rm -rf "$out" "$(dirname "$payload")"
}

test_dlw_nocogs_emits_meta_and_finding_only() {
    local bin payload out jsonl types
    bin=$(_dlw_bin); payload=$(_dlw_payload nocogs); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident my-branch --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out"
    jsonl="$out/o-r/my-branch-0123456789ab.jsonl"
    types=$(jq -r '.type' "$jsonl" | tr '\n' ' ')
    assert_equals "meta finding " "$types" "durable-log-write: no-cogs payload (recovered envelope) emits meta + finding only"
    rm -rf "$out" "$(dirname "$payload")"
}

test_dlw_tokens_appended_and_malformed_skipped() {
    local bin payload out jsonl toks n
    bin=$(_dlw_bin); payload=$(_dlw_payload full); out=$(mktemp -d); toks=$(mktemp)
    printf '%s\n' '{"phase":"round1","tokens":10}' 'THIS IS NOT JSON' '{"phase":"synth","tokens":5}' > "$toks"
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --tokens "$toks" --out-dir "$out"
    jsonl="$out/o-r/pr-1-0123456789ab.jsonl"
    # 1 meta + 1 cog + 1 finding + 2 valid token rows (malformed skipped) = 5 lines.
    n=$(wc -l < "$jsonl" | tr -d ' ')
    assert_equals "5" "$n" "durable-log-write: valid token rows appended, malformed row skipped, still exits 0"
    rm -rf "$out" "$(dirname "$payload")" "$toks"
}

test_dlw_missing_payload_exits_1_writes_nothing() {
    local bin out rc
    bin=$(_dlw_bin); out=$(mktemp -d)
    set +e
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$out/does-not-exist.json" --out-dir "$out" >/dev/null 2>&1
    rc=$?
    set -e
    assert_equals "1" "$rc" "durable-log-write: missing --payload exits 1"
    if [[ -z "$(find "$out" -name '*.md' -o -name '*.jsonl' 2>/dev/null)" ]]; then
        pass "durable-log-write: missing --payload writes nothing"
    else
        fail "durable-log-write: missing --payload writes nothing" "files were written"
    fi
    rm -rf "$out"
}

test_dlw_malformed_payload_exits_1() {
    local bin out payload rc
    bin=$(_dlw_bin); out=$(mktemp -d); payload=$(mktemp)
    printf '%s' 'not json {' > "$payload"
    set +e
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out" >/dev/null 2>&1
    rc=$?
    set -e
    assert_equals "1" "$rc" "durable-log-write: non-JSON --payload exits 1"
    rm -rf "$out" "$payload"
}

test_dlw_ident_controls_filename() {
    local bin payload out
    bin=$(_dlw_bin); payload=$(_dlw_payload nocogs); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident pr-86 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out"
    if [[ -f "$out/o-r/pr-86-0123456789ab.md" ]]; then
        pass "durable-log-write: --ident pr-86 yields pr-86-<sha>.md"
    else
        fail "durable-log-write: --ident pr-86 yields pr-86-<sha>.md" "file missing"
    fi
    rm -rf "$out" "$(dirname "$payload")"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run.sh` (this repo's Bash hook forbids `|`/`&&`/redirection except `2>&1`, so
run the whole suite and read its output — do NOT pipe to `grep`). In the output, locate the
`durable-log-write:` assertion lines (hyphenated, matching the test messages).
Expected: FAIL — the `durable-log-write` binary does not exist yet (each test's first line
resolves `_dlw_bin` to a missing file; assertions fail).

- [ ] **Step 3: Write the `bin/durable-log-write` implementation**

Create `plugins/code-review-suite/bin/durable-log-write`:

```bash
#!/usr/bin/env bash
# durable-log-write — deterministic writer for the code-review-suite durable
# full log. The host (SKILL.md / pre-review.md Step 3.6) resolves every value
# and hands them over as flags; this script only validates and writes. Fragile
# JSONL assembly is jq -c, never LLM-improvised prose — the same principle as
# bin/review-worktree ("deterministic, unit-tested shell, not improvised prose").
#
# Usage:
#   durable-log-write --repo-slug <owner-name> --ident <pr-N|branch-slug> \
#       --sha <12-hex> --plugin-sha <sha|unknown> --payload <path> \
#       [--tokens <path>] [--ts <iso8601>] [--out-dir <dir>]
#
# Writes (idempotent, latest-wins per sha):
#   <out-dir>/<repo-slug>/<ident>-<sha>.md    provenance header + bodyText verbatim
#   <out-dir>/<repo-slug>/<ident>-<sha>.jsonl meta, cog(s), finding(s), token rows
# <out-dir> defaults to $HOME/.claude/code-review-suite/logs. --payload is
# validated (must exist, be valid JSON, carry bodyText) — a bad payload is a hard
# error, never a silent empty write. --tokens rows are best-effort: a malformed
# line is skipped, never fatal.
set -euo pipefail

_die() {
    echo "durable-log-write: $*" >&2
    exit 1
}

repo_slug=""
ident=""
sha=""
plugin_sha=""
payload=""
tokens=""
ts=""
out_dir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-slug)  repo_slug="${2:-}"; shift 2 ;;
        --ident)      ident="${2:-}"; shift 2 ;;
        --sha)        sha="${2:-}"; shift 2 ;;
        --plugin-sha) plugin_sha="${2:-}"; shift 2 ;;
        --payload)    payload="${2:-}"; shift 2 ;;
        --tokens)     tokens="${2:-}"; shift 2 ;;
        --ts)         ts="${2:-}"; shift 2 ;;
        --out-dir)    out_dir="${2:-}"; shift 2 ;;
        *)            _die "unknown arg: $1" ;;
    esac
done

[[ -n "$repo_slug" && -n "$ident" && -n "$sha" && -n "$payload" ]] \
    || _die "requires --repo-slug --ident --sha --payload"
[[ -n "$plugin_sha" ]] || plugin_sha="unknown"
[[ -n "$out_dir" ]] || out_dir="$HOME/.claude/code-review-suite/logs"
[[ -n "$ts" ]] || ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Validate-or-die: payload must exist, parse as JSON, and carry bodyText.
[[ -f "$payload" ]] || _die "payload not found: $payload"
jq empty "$payload" 2>/dev/null || _die "payload is not valid JSON: $payload"
jq -e 'has("bodyText")' "$payload" >/dev/null 2>&1 || _die "payload missing bodyText: $payload"

dir="$out_dir/$repo_slug"
mkdir -p "$dir"
md="$dir/$ident-$sha.md"
jsonl="$dir/$ident-$sha.jsonl"

# Markdown: provenance header, then bodyText verbatim.
printf '<!-- plugin_sha: %s | ts: %s -->\n' "$plugin_sha" "$ts" > "$md"
jq -r '.bodyText' "$payload" >> "$md"

# JSONL: meta -> cog(s) -> finding(s) -> token row(s). Every structured line is
# emitted via jq -c so it is valid JSON regardless of quotes/newlines in text.
: > "$jsonl"
jq -c --arg ps "$plugin_sha" --arg t "$ts" \
    '(.meta // {}) + {plugin_sha:$ps, ts:$t, type:"meta"}' "$payload" >> "$jsonl"
jq -c '.cogs[]? | . + {type:"cog"}' "$payload" >> "$jsonl"
jq -c '.findings[]? | . + {type:"finding"}' "$payload" >> "$jsonl"

# Tokens: best-effort. Validate each line; skip (warn) a malformed row, never
# abort. Guarded so set -euo pipefail cannot kill the script on a bad line.
# NOTE: no producer of $CLAUDE_TEMP_DIR/tokens.jsonl was found in review-core.mjs
# (the --tokens reference is inherited from the old Step 7a). Absent/empty is the
# expected common case and handled below; if a producer is never wired, token
# rows simply never land — out of scope for this reliability fix.
if [[ -n "$tokens" && -s "$tokens" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
            printf '%s\n' "$line" >> "$jsonl"
        else
            echo "durable-log-write: skipping malformed token row" >&2
        fi
    done < "$tokens"
fi

exit 0
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x plugins/code-review-suite/bin/durable-log-write`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run.sh` (no pipe — read the output directly). Locate the `durable-log-write:`
assertion lines.
Expected: PASS — all `durable-log-write` assertions green. If `test_dlw_jsonl_line_order`
prints an unexpected trailing/leading type, check the `jq -c` filters emit nothing (not `null`)
for absent `cogs`/`findings`.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/bin/durable-log-write tests/lib/test_durable_log_write.sh
git commit -m "feat(code-review): deterministic durable-log-write bin + unit tests"
```

---

### Task 2: `hooks/durable-log-gate.sh` Stop-hook forcing function

**Files:**
- Create: `plugins/code-review-suite/hooks/durable-log-gate.sh`
- Modify: `plugins/code-review-suite/hooks/hooks.json` (add a `Stop` entry)
- Test: `tests/lib/test_durable_log_gate.sh`

**Interfaces:**
- Consumes: the shared path convention and marker contract from Global Constraints. Reads Claude
  Code's Stop-hook stdin JSON (`{session_id, …}`). Test seams (env overrides): `DURABLE_LOG_TMP_BASE`
  (session-dir base, default `/tmp`), `DURABLE_LOG_DIR` (logs base, default
  `$HOME/.claude/code-review-suite/logs`), `DURABLE_LOG_GATE_TTL_MINUTES` (default 360).
- Produces (relied on by Task 3): the marker filename `durable-log-expected.json` with fields
  `{repo_slug, ident, sha}` — Task 3's prose MUST Write a marker with exactly these keys and the
  12-char sha. Block output is the Stop-hook JSON form `{"decision":"block","reason":…}` on stdout,
  exit 0.

**Disarm mechanism — CONSCIOUS DIVERGENCE from the spec's literal wording.** Spec Component 3
requirement 2 says a successful write "removes/neutralises the breadcrumb". This hook does NOT
delete the marker; it disarms by **log-existence** — if the expected `.md` file is present, the
hook exits 0 (see hook Step 3, the `[[ -f "$expected_md" ]]` gate). Because the hook is stateless
and the marker is a single per-session file, this satisfies the spec's actual *behavioural*
invariant ("the gate never fires twice for one write") without a delete: once the log exists, every
subsequent turn-end is a clean no-op. Deletion was rejected as strictly worse — it would re-arm a
false block if the log were later removed, and it couples the hook to write-side cleanup. The
spec's separately-listed "disarm: second consecutive turn-end is a clean no-op" case is therefore
covered by `test_dlg_breadcrumb_with_log_passes` (log present → inert) rather than a dedicated
second-run test, which would be redundant given statelessness. **This divergence is user-blessed
(plan review, 2026-07-09).**

- [ ] **Step 1: Write the failing test file**

Create `tests/lib/test_durable_log_gate.sh`. Each test builds a hermetic session-temp base and a
logs base via `mktemp -d`, writes a marker under `<tmp_base>/claude-<sid>/`, and feeds the hook a
stdin JSON carrying `session_id`. This exercises the real session-scoped reconstruction (no `/tmp`
litter, no `DURABLE_LOG_MARKER` bypass).

```bash
#!/usr/bin/env bash
# Unit tests for hooks/durable-log-gate.sh — the durable-log Stop-hook gate.

_dlg_hook() { echo "$REPO_ROOT/plugins/code-review-suite/hooks/durable-log-gate.sh"; }

# Build a session temp base with a marker for session $sid. Args:
#   $1 tmp_base  $2 sid  $3 repo_slug  $4 ident  $5 sha
_dlg_write_marker() {
    local tmp_base="$1" sid="$2" repo_slug="$3" ident="$4" sha="$5" mdir
    mdir="$tmp_base/claude-$sid"
    mkdir -p "$mdir"
    jq -cn --arg r "$repo_slug" --arg i "$ident" --arg s "$sha" \
        '{repo_slug:$r, ident:$i, sha:$s, ts:"2026-07-09T00:00:00Z"}' \
        > "$mdir/durable-log-expected.json"
    echo "$mdir/durable-log-expected.json"
}

# Run the hook with a given session_id on stdin; echoes stdout, sets $DLG_RC.
_dlg_run() {
    local sid="$1" tmp_base="$2" logs_dir="$3" ttl="${4:-360}" out
    set +e
    out=$(printf '{"session_id":"%s","hook_event_name":"Stop"}' "$sid" \
        | DURABLE_LOG_TMP_BASE="$tmp_base" DURABLE_LOG_DIR="$logs_dir" \
          DURABLE_LOG_GATE_TTL_MINUTES="$ttl" bash "$(_dlg_hook)")
    DLG_RC=$?
    set -e
    printf '%s' "$out"
}

test_dlg_no_breadcrumb_inert() {
    local tmp_base logs out
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    out=$(_dlg_run "sid-none" "$tmp_base" "$logs")
    assert_equals "0" "$DLG_RC" "durable-log-gate: no breadcrumb -> exit 0"
    assert_equals "" "$out" "durable-log-gate: no breadcrumb -> no block output"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_breadcrumb_no_log_blocks() {
    local tmp_base logs out
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    _dlg_write_marker "$tmp_base" "sid-a" "o-r" "pr-1" "0123456789ab" >/dev/null
    out=$(_dlg_run "sid-a" "$tmp_base" "$logs")
    assert_equals "0" "$DLG_RC" "durable-log-gate: block path still exits 0 (block via stdout JSON)"
    assert_equals "block" "$(printf '%s' "$out" | jq -r '.decision')" \
        "durable-log-gate: breadcrumb present + log absent -> decision block"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_breadcrumb_with_log_passes() {
    local tmp_base logs out
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    _dlg_write_marker "$tmp_base" "sid-a" "o-r" "pr-1" "0123456789ab" >/dev/null
    mkdir -p "$logs/o-r"
    printf 'x\n' > "$logs/o-r/pr-1-0123456789ab.md"
    out=$(_dlg_run "sid-a" "$tmp_base" "$logs")
    assert_equals "0" "$DLG_RC" "durable-log-gate: log present -> exit 0"
    assert_equals "" "$out" "durable-log-gate: log present -> no block (disarmed by log existence)"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_foreign_session_invisible() {
    # Marker exists for sid-a; hook runs as sid-b -> reconstructs sid-b's dir,
    # finds no marker -> inert. Proves session-scoping kills the cross-session
    # false-block landmine.
    local tmp_base logs out
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    _dlg_write_marker "$tmp_base" "sid-a" "o-r" "pr-1" "0123456789ab" >/dev/null
    out=$(_dlg_run "sid-b" "$tmp_base" "$logs")
    assert_equals "0" "$DLG_RC" "durable-log-gate: foreign session's breadcrumb is invisible -> exit 0"
    assert_equals "" "$out" "durable-log-gate: foreign session -> no block"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_stale_breadcrumb_expires() {
    local tmp_base logs marker out
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    marker=$(_dlg_write_marker "$tmp_base" "sid-a" "o-r" "pr-1" "0123456789ab")
    # Age the marker 10 minutes; run with a 1-minute TTL -> treated as absent.
    touch -t "$(date -v-600S +%Y%m%d%H%M.%S 2>/dev/null || date -d '-600 seconds' +%Y%m%d%H%M.%S)" "$marker"
    out=$(_dlg_run "sid-a" "$tmp_base" "$logs" 1)
    assert_equals "0" "$DLG_RC" "durable-log-gate: stale breadcrumb (past TTL) -> exit 0"
    assert_equals "" "$out" "durable-log-gate: stale breadcrumb -> no block (self-expiry)"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_no_session_id_inert() {
    local out
    set +e
    out=$(printf '{"hook_event_name":"Stop"}' | bash "$(_dlg_hook)")
    DLG_RC=$?
    set -e
    assert_equals "0" "$DLG_RC" "durable-log-gate: missing session_id -> exit 0 (cannot scope)"
    assert_equals "" "$out" "durable-log-gate: missing session_id -> no block"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run.sh` (no pipe — read the output directly). Locate the `durable-log-gate:`
assertion lines.
Expected: FAIL — `durable-log-gate.sh` does not exist.

- [ ] **Step 3: Write the `hooks/durable-log-gate.sh` implementation**

Create `plugins/code-review-suite/hooks/durable-log-gate.sh`:

```bash
#!/usr/bin/env bash
# durable-log-gate.sh — Stop-hook forcing function for the durable full log.
# Arms off a session-scoped breadcrumb the host writes in Step 3.6; if a review
# in THIS session intended a durable log but the expected file is absent, block
# turn-end with an executable corrective instruction. Inert on every non-review
# turn. Session-scoped via the stdin session_id (reconstructs /tmp/claude-<sid>/),
# so a foreign or stranded breadcrumb from another session is structurally
# invisible. Self-expiring via a breadcrumb-mtime TTL so a dead session cannot
# wedge a live one. CLAUDE_TEMP_DIR is NOT exported into hook subprocesses — the
# session id from stdin is the only session anchor available (same lesson as
# reviewer-dispatch-observe.sh falling back to $TMPDIR).
set -euo pipefail

TTL_MINUTES="${DURABLE_LOG_GATE_TTL_MINUTES:-360}"
LOGS_DIR="${DURABLE_LOG_DIR:-$HOME/.claude/code-review-suite/logs}"
TMP_BASE="${DURABLE_LOG_TMP_BASE:-/tmp}"

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""')"
[[ -n "$session_id" ]] || exit 0        # no session id -> cannot scope -> inert

marker="$TMP_BASE/claude-$session_id/durable-log-expected.json"
[[ -f "$marker" ]] || exit 0            # no breadcrumb -> inert (the common case)

# Self-expiry: a marker older than the TTL is a crashed/abandoned session.
if find "$marker" -mmin "+$TTL_MINUTES" 2>/dev/null | grep -q .; then
    exit 0
fi

repo_slug="$(jq -r '.repo_slug // ""' "$marker" 2>/dev/null || true)"
ident="$(jq -r '.ident // ""' "$marker" 2>/dev/null || true)"
sha="$(jq -r '.sha // ""' "$marker" 2>/dev/null || true)"
if [[ -z "$repo_slug" || -z "$ident" || -z "$sha" ]]; then
    exit 0                              # malformed/foreign marker -> treat as absent
fi

expected_md="$LOGS_DIR/$repo_slug/$ident-$sha.md"
if [[ -f "$expected_md" ]]; then
    exit 0                              # the write happened -> disarmed
fi

reason="Durable full log NOT written for ${repo_slug}/${ident}-${sha}. A review ran this session with orchestration.full_log enabled, but ${expected_md} is missing. Complete Step 3.6: run bin/durable-log-write with the resolved --repo-slug/--ident/--sha and --payload \$CLAUDE_TEMP_DIR/bundle-log.json. If the write keeps failing, fix the cause or remove the breadcrumb at ${marker} to abandon this log."
jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x plugins/code-review-suite/hooks/durable-log-gate.sh`

- [ ] **Step 5: Add the `Stop` entry to `hooks/hooks.json`**

**Edit** (do NOT wholesale-replace — the file may drift) `plugins/code-review-suite/hooks/hooks.json`
to add a `Stop` array as a sibling of the existing `PreToolUse` array. First `Read` the file; the
`PreToolUse` array is the only key today. Insert `Stop` immediately after the `PreToolUse` array's
closing `]` (adding the trailing comma to that `]`). The resulting file must be:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Agent",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/reviewer-dispatch-observe.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/durable-log-gate.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

(If the current `PreToolUse` block differs from the snippet above, preserve it verbatim and only
splice in the `Stop` sibling — Step 7's `jq empty` validates the merged result.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/run.sh` (no pipe — read the output directly). Locate the `durable-log-gate:`
assertion lines.
Expected: PASS — all `durable-log-gate` assertions green. If the block test fails with empty
output, confirm the hook writes the JSON to stdout (not stderr) and exits 0.

- [ ] **Step 7: Verify hooks.json is valid JSON**

Run: `jq empty plugins/code-review-suite/hooks/hooks.json`
Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git add plugins/code-review-suite/hooks/durable-log-gate.sh plugins/code-review-suite/hooks/hooks.json tests/lib/test_durable_log_gate.sh
git commit -m "feat(code-review): Stop-hook durable-log gate (session-scoped, self-expiring) + tests"
```

---

### Task 3: Relocate Step 7a → Step 3.6 prose in both call sites

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (remove Step 7a at 1064–1122;
  insert Step 3.6 after the Step 3.5 stall-recovery block ending ~1038)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (remove Step 7a at 959–1018; insert
  Step 3.6 after the Step 3.5 bundle-return block ending ~1039)
- Test: `tests/lib/test_durable_log_gate.sh` (add cross-reference prose assertions — same file as
  Task 2, so it is already discovered)

**Interfaces:**
- Consumes: Task 1's CLI contract (`bin/durable-log-write …`) and Task 2's marker contract
  (`durable-log-expected.json` with `{repo_slug, ident, sha}`, 12-char sha).
- Produces: the host wiring — writes the breadcrumb marker + payload, then calls the writer. No
  downstream task depends on this.
- Note: the `--tokens $CLAUDE_TEMP_DIR/tokens.jsonl` arg is carried verbatim from the old Step 7a,
  but no producer of that file was found in `review-core.mjs`. The writer treats it as best-effort
  (absent/empty → no token rows, still exits 0), so keeping the arg is harmless; it is NOT a
  guaranteed input.

- [ ] **Step 1: Write the failing cross-reference test**

Append to `tests/lib/test_durable_log_gate.sh` (these guard the prose relocation and wiring):

```bash
_dlg_cr_dir() { echo "$REPO_ROOT/plugins/code-review-suite"; }

test_dlg_step36_present_both_sites() {
    local cr missing f
    cr=$(_dlg_cr_dir); missing=()
    for f in "skills/review-gh-pr/SKILL.md" "commands/pre-review.md"; do
        if ! grep -qF 'Step 3.6: Durable full log' "$cr/$f" 2>/dev/null; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "durable-log Step 3.6 heading present in both call sites"
    else
        fail "durable-log Step 3.6 heading present in both call sites" "missing in: ${missing[*]}"
    fi
}

test_dlg_writer_invoked_both_sites() {
    local cr missing f
    cr=$(_dlg_cr_dir); missing=()
    for f in "skills/review-gh-pr/SKILL.md" "commands/pre-review.md"; do
        if ! grep -qF 'bin/durable-log-write' "$cr/$f" 2>/dev/null; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "durable-log-write invoked in both call sites"
    else
        fail "durable-log-write invoked in both call sites" "missing in: ${missing[*]}"
    fi
}

test_dlg_breadcrumb_written_both_sites() {
    local cr missing f
    cr=$(_dlg_cr_dir); missing=()
    for f in "skills/review-gh-pr/SKILL.md" "commands/pre-review.md"; do
        if ! grep -qF 'durable-log-expected.json' "$cr/$f" 2>/dev/null; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "durable-log breadcrumb marker written in both call sites"
    else
        fail "durable-log breadcrumb marker written in both call sites" "missing in: ${missing[*]}"
    fi
}

test_dlg_old_step7a_removed_both_sites() {
    local cr present f
    cr=$(_dlg_cr_dir); present=()
    for f in "skills/review-gh-pr/SKILL.md" "commands/pre-review.md"; do
        if grep -qF 'Step 7a: Durable full log' "$cr/$f" 2>/dev/null; then
            present+=("$f")
        fi
    done
    if [[ ${#present[@]} -eq 0 ]]; then
        pass "old Step 7a heading removed from both call sites"
    else
        fail "old Step 7a heading removed from both call sites" "still present in: ${present[*]}"
    fi
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run.sh` (no pipe — read the output directly). Locate the four cross-reference
assertion lines (`Step 3.6 heading present`, `durable-log-write invoked`, `breadcrumb marker
written`, `old Step 7a heading removed`).
Expected: FAIL — Step 3.6 heading absent, `bin/durable-log-write`/`durable-log-expected.json`
absent, and the old `Step 7a` heading still present.

- [ ] **Step 3: Remove Step 7a and insert Step 3.6 in `SKILL.md`**

In `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`, DELETE the entire `#### Step 7a:
Durable full log …` block (from the `#### Step 7a:` heading at ~1064 through the closing paragraph
ending "…finding text from private repos." at ~1122, i.e. up to but not including the `---`
separator that precedes "After the review pipeline completes…").

Then INSERT this block immediately after the Step 3.5 stall-recovery block (after the paragraph
ending "…use it exactly as the normal bundle below…" ~1038, before `## Phase 9: Worktree teardown`):

```markdown
#### Step 3.6: Durable full log (opt-in, default OFF)

The full unfiltered analytical record is a fine-tuning instrument with a finite useful life.
Resolve `orchestration.full_log` from two config layers, first match wins: (1) the reviewed
repo's `.claude/code-review.toml`, then (2) the user-level `~/.claude/code-review.toml`. Read
each file the same way as `intent.doc_paths`; treat a missing/malformed file as not setting the
key, and fall through. If neither layer sets the key, the value is `false`. An explicit `false`
in the repo-level file wins over a `true` in the user-level file. If the resolved value is
`false`, skip this entire step — write nothing (no breadcrumb, so the Stop-hook gate stays inert).

When `true` **and** the bundle carries a `log` payload (`bundle.log`):

1. Resolve identity (all host-context): `<repo-slug>` = reviewed repo `owner/name` with `/`→`-`;
   `<ident>` = `pr-$ARGUMENTS`; `<sha>` = the first 12 characters of `$HEAD_SHA` (`$HEAD_SHA` is
   the validated 40-char sha — truncate it here, e.g. `${HEAD_SHA:0:12}`). The same 12-char value
   MUST be used for both the `--sha` flag and the breadcrumb marker so the gate self-matches.
   Resolve `$PLUGIN_SHA` =
   `git -C "{plugin-marketplace-dir}" rev-parse --short HEAD` (use `unknown` if it fails). Stamp
   `$LOG_TS` = `date -u +%Y-%m-%dT%H:%M:%SZ`.
2. `Write` the `bundle.log` object to `$CLAUDE_TEMP_DIR/bundle-log.json`.
3. `Write` the breadcrumb marker `$CLAUDE_TEMP_DIR/durable-log-expected.json` — this arms the
   Stop-hook gate, so it MUST be written before the writer call and MUST carry exactly these keys
   (the 12-char `<sha>`):

   ```json
   {"repo_slug":"<repo-slug>","ident":"pr-$ARGUMENTS","sha":"<sha>","ts":"$LOG_TS"}
   ```

4. Run **one** command (the deterministic writer — never hand-assemble the JSONL in prose):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}"/bin/durable-log-write --repo-slug <repo-slug> --ident pr-$ARGUMENTS --sha <sha> --plugin-sha $PLUGIN_SHA --payload $CLAUDE_TEMP_DIR/bundle-log.json --tokens $CLAUDE_TEMP_DIR/tokens.jsonl --ts $LOG_TS
   ```

The writer creates `$HOME/.claude/code-review-suite/logs/<repo-slug>/pr-$ARGUMENTS-<sha>.{md,jsonl}`.
The durable log is NEVER posted to GitHub and NEVER committed — it is analysis exhaust that may
contain finding text from private repos. Writing the log here (before report presentation) is what
makes it reliable; the `durable-log-gate` Stop hook blocks turn-end if the breadcrumb is armed but
the log file is missing.
```

- [ ] **Step 4: Remove Step 7a and insert Step 3.6 in `pre-review.md`**

In `plugins/code-review-suite/commands/pre-review.md`, DELETE the entire `#### Step 7a: Durable
full log …` block (heading ~959 through "…the only persisted artefact." ~1018).

Then INSERT the same block immediately after the Step 3.5 bundle-return paragraph (after "…use it
exactly as the normal bundle below." ~1039, before the "After the review pipeline completes…" line
~1126), with the **only** per-site difference being `<ident>` — local mode uses the slugified
branch, not `pr-$ARGUMENTS`:

```markdown
#### Step 3.6: Durable full log (opt-in, default OFF)

The full unfiltered analytical record is a fine-tuning instrument with a finite useful life.
Resolve `orchestration.full_log` from two config layers, first match wins: (1) the reviewed
repo's `.claude/code-review.toml`, then (2) the user-level `~/.claude/code-review.toml`. Read
each file the same way as `intent.doc_paths`; treat a missing/malformed file as not setting the
key, and fall through. If neither layer sets the key, the value is `false`. An explicit `false`
in the repo-level file wins over a `true` in the user-level file. If the resolved value is
`false`, skip this entire step — write nothing (no breadcrumb, so the Stop-hook gate stays inert).

When `true` **and** the bundle carries a `log` payload (`bundle.log`):

1. Resolve identity (all host-context): `<repo-slug>` = reviewed repo `owner/name` with `/`→`-`;
   `<ident>` = the slugified current branch (`git rev-parse --abbrev-ref HEAD`, `/`→`-`); `<sha>`
   = the first 12 characters of `$HEAD_SHA` (`$HEAD_SHA` is the validated 40-char sha — truncate
   it here, e.g. `${HEAD_SHA:0:12}`). The same 12-char value MUST be used for both the `--sha`
   flag and the breadcrumb marker so the gate self-matches. Resolve `$PLUGIN_SHA` =
   `git -C "{plugin-marketplace-dir}" rev-parse --short HEAD` (use `unknown` if it fails). Stamp
   `$LOG_TS` = `date -u +%Y-%m-%dT%H:%M:%SZ`.
2. `Write` the `bundle.log` object to `$CLAUDE_TEMP_DIR/bundle-log.json`.
3. `Write` the breadcrumb marker `$CLAUDE_TEMP_DIR/durable-log-expected.json` — this arms the
   Stop-hook gate, so it MUST be written before the writer call and MUST carry exactly these keys
   (the 12-char `<sha>`):

   ```json
   {"repo_slug":"<repo-slug>","ident":"<branch-slug>","sha":"<sha>","ts":"$LOG_TS"}
   ```

4. Run **one** command (the deterministic writer — never hand-assemble the JSONL in prose):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}"/bin/durable-log-write --repo-slug <repo-slug> --ident <branch-slug> --sha <sha> --plugin-sha $PLUGIN_SHA --payload $CLAUDE_TEMP_DIR/bundle-log.json --tokens $CLAUDE_TEMP_DIR/tokens.jsonl --ts $LOG_TS
   ```

The writer creates `$HOME/.claude/code-review-suite/logs/<repo-slug>/<branch-slug>-<sha>.{md,jsonl}`.
The durable log is NEVER posted to GitHub and NEVER committed — it is analysis exhaust that may
contain finding text from private repos. Writing the log here (before report presentation) is what
makes it reliable; the `durable-log-gate` Stop hook blocks turn-end if the breadcrumb is armed but
the log file is missing.
```

- [ ] **Step 5: Run the cross-reference tests to verify they pass**

Run: `bash tests/run.sh` (no pipe — read the output directly). Locate the four cross-reference
assertion lines.
Expected: PASS — Step 3.6 present in both, writer + breadcrumb referenced in both, old Step 7a gone.

- [ ] **Step 6: Run the whole suite + sync-note check**

Run: `bash tests/run.sh`
Expected: full suite PASS. In particular `test_sync_notes.sh` must still pass — Step 7a was never
under byte-parity sync (the two blocks differ by the `--ident` line, and `includes/review-pipeline.md`
never carried it), so relocating it breaks no sync assertion.

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md tests/lib/test_durable_log_gate.sh
git commit -m "feat(code-review): relocate durable-log write to Step 3.6, wire deterministic writer + breadcrumb"
```

---

## Self-Review

**1. Spec coverage** (checked against `2026-07-09-durable-log-writer-fix-design.md`):

- Component 1 `bin/durable-log-write` (validate-or-die, `.md` header+bodyText, `jq -c` JSONL in
  meta→cogs→findings→tokens order, best-effort tokens, `--out-dir`, overwrite semantics) →
  **Task 1**.
- Component 2 prose relocation Step 7a→3.6 in both call sites, only `--ident` differs, no sync
  break → **Task 3**.
- Component 3 Stop hook (session-scoped, disarm-by-log-existence, self-expiry, sha-form match,
  block with executable reason) → **Task 2**. The spec's three hard requirements
  (session-scoping / disarm / self-expiry) map to `test_dlg_foreign_session_invisible`,
  `test_dlg_breadcrumb_with_log_passes`, `test_dlg_stale_breadcrumb_expires`.
- Testing section: script unit tests (Task 1 Step 1) and Stop-hook tests (Task 2 Step 1) cover
  every listed case, incl. the newline+quote finding (`test_dlw_jsonl_every_line_valid_json`), the
  no-cogs recovered-envelope shape (`test_dlw_nocogs_emits_meta_and_finding_only` — the spec calls
  this the "lightweight path", but that label is imprecise: see the fixture note, the real
  lightweight route emits no `log`),
  malformed tokens (`test_dlw_tokens_appended_and_malformed_skipped`), and sha reconciliation
  (resolved structurally — the marker stores the 12-char sha, so no 40→12 mismatch; noted in
  Global Constraints).
- Non-goals respected: no change to `bundle.log` shape or the `full_log` default; no approach A′;
  no replay tooling; the end-to-end live confirm remains the organic (not-automated) step.

**2. Placeholder scan:** no "TBD"/"add appropriate handling"/"similar to Task N" — every code and
test step carries complete content.

**3. Type consistency:** the CLI contract (`--repo-slug/--ident/--sha/--plugin-sha/--payload/
--tokens/--ts/--out-dir`) is identical in Task 1's implementation, Task 1's tests, and Task 3's
prose. The marker keys (`repo_slug/ident/sha/ts`) are identical in Task 2's hook, Task 2's tests,
and Task 3's two prose blocks. The path convention
`<out-dir|LOGS_DIR>/<repo-slug>/<ident>-<sha>.{md,jsonl}` matches across writer, hook, and tests.

**Deferred to execution (flagged, not blocking):** the spec's residual-risk honesty holds — if the
model skips *all* of Step 3.6 (including the marker Write), the gate never arms. The reorder to
high-attention Step 3.6 is the mitigation; full model-independence is approach A′ (out of scope).
One accepted trade-off: the block is unconditional (not gated on `stop_hook_active`) to honour the
"impossible to ignore" intent; the escape valves are (a) running the writer creates the log and
disarms, and (b) the TTL expiry / explicit "remove the breadcrumb" instruction in the block reason.

**4. Plan-review fixes (user-blessed, 2026-07-09):** six findings from the pre-execution review
were folded in — (1) all six verification `Run:` lines de-piped (this repo's Bash hook forbids
`|`; the old `| grep "durable log write"` also mis-matched the hyphenated assertion text); (2) the
disarm-by-log-existence divergence from the spec's literal "remove the breadcrumb" wording is now
documented and blessed in Task 2's Interfaces; (3) `<sha>` prose in both Task 3 blocks now
truncates the validated 40-char `$HEAD_SHA` to 12 (`${HEAD_SHA:0:12}`) instead of asserting it is
"already 12-char", and pins the same value to flag + marker; (4) the misleading "lightweight"
fixture/test renamed to `nocogs` (the real lightweight route emits no `log`; the no-cogs shape is
the finalize/recovery route); (5) `--tokens` documented as having no known producer and being
best-effort, not a guaranteed input; (6) Task 2 Step 5 changed from a wholesale `hooks.json`
replace to an Edit-insert of the `Stop` sibling.
