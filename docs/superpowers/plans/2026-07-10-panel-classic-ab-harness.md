# Panel-vs-classic orchestration A/B harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `tests/ab/` with a `--mode orchestration` A/B that runs classic and panel review on the same real merged PRs, produces a mechanical differential (verdict agreement, finding-set delta, cost, wall-clock) and blinded side-by-side ranking packets, and applies a pre-registered decision rule to recommend flip / don't-flip.

**Architecture:** A third dispatcher arm in `tests/ab/run.sh` plus two new shell/Python libs and two ranking tools. The arm toggle writes a temporary user-level `~/.claude/code-review.toml` (backed up + restored via trap) instead of mutating tracked files. The primary data source is the durable JSONL log harvested from `$HOME/.claude/code-review-suite/logs/`, not the lossy stdout verdict regex. Blinding renders `bodyText` only, normalises arm tells against real captured samples, and seals a per-PR A/B randomisation. Model-as-judge is a permanent ban: the only quality adjudicator is the maintainer's blind ranking.

**Tech Stack:** Bash (harness, arm toggle, harvest) + Python 3 stdlib only (differential, ranking) — no third-party packages. `jq`, `yq` (Mike Farah Go variant), `gh`, `git`, `timeout`/`gtimeout`. Reuses `tests/ab/lib/launch.sh`, `tests/ab/lib/cost_model.py`, `tests/ab/lib/ab_stats.py`.

## Global Constraints

- **Python is stdlib-only.** No pip installs. Tests are `unittest.TestCase` classes under `tests/python/`, discovered by `python3 -m unittest discover -s tests/python` (the gate is `tests/lib/test_housekeeper_engine.sh`). Bare pytest-style functions are NOT run by CI — do not use them for new coverage.
- **Bash indent = 4 spaces; Markdown/JSON indent = 2 spaces; max line 120; LF line endings.** (`.editorconfig` / `.gitattributes`.)
- **No model-as-judge anywhere.** The ranking tooling must never call an LLM to score reports. Quality sign comes only from the human ranking.
- **No pipeline/behaviour change.** Zero edits to `plugins/code-review-suite/workflows/review-core.mjs` or any agent/skill. This plan only *measures*.
- **Arm toggle is user-level config, never tracked-file mutation.** The `mutate.sh` revert-trap discipline is the model, but the mechanism is a temp `~/.claude/code-review.toml` with backup/restore. A failed restore writes a `MANUAL_REVERT_REQUIRED` marker.
- **Corpus is merged PRs only** — this rides the SKILL §B.1 no-post safety (see below); no `--dry-run` flag is added.
- **Pre-registration criteria file is timestamped before any unblinding** and copied to a durable location outside the run dir so scratch-tree pruning cannot destroy the honesty anchor.
- **Findings are matched across arms by `(file, line-proximity, domain)` — NEVER by description text** (model-authored, unstable).
- New shell libs must `set -euo pipefail` and match the existing header-comment style in `tests/ab/lib/*.sh`.

## Ground-truth facts (verified against source at plan time)

These are load-bearing and were confirmed by reading the code, not the spec. Do not re-guess them.

- **Durable-log writer:** `plugins/code-review-suite/bin/durable-log-write`. Writes
  `<out-dir>/<repo-slug>/<ident>-<sha>.jsonl` and `.md`, where `<out-dir>` defaults to
  `$HOME/.claude/code-review-suite/logs`, `<repo-slug>` = reviewed repo `owner/name` with `/`→`-`,
  `<ident>` = `pr-<N>`, `<sha>` = **first 12 chars of `$HEAD_SHA`** (SKILL.md:1144-1167).
- **JSONL record order:** `meta` → `cog`(s) → `finding`(s) → optional `token` rows. Every line is valid JSON
  (`durable-log-write` lines 73-76; confirmed by `tests/lib/test_durable_log_write.sh`).
- **`meta` record fields** (`review-core.mjs:185-193` + writer line 74):
  `{type:"meta", base, head_sha, empty_tree_mode, path_scope, orchestration_mode, panel_size, plugin_sha, ts}`.
  `orchestration_mode` is `"classic"` or `"panel"`; `panel_size` is an int for panel, `null` for classic.
  NOTE: `orchestration_mode`/`panel_size` are stamped by `review-core.mjs` but are NOT yet listed in the
  `includes/finding-schema.json` `log.meta` definition (schema lags the code). This is a harmless doc gap for our
  read-only consumer — read them from the meta record regardless; do not "fix" the schema as part of this work.
- **`finding` record fields** (`review-core.mjs:937-947` + writer line 76):
  `{type:"finding", tier, domain, severity, confidence, file, line, description, suggested_fix, verdict_relevant}`.
  `tier` ∈ {`consensus`, `synthesiser`, `contested`, `dismissed`}. `confidence` is 0-100 (0 when absent).
- **`.md` sidecar:** line 1 is `<!-- plugin_sha: <sha> | ts: <iso> -->`, then `bodyText` verbatim
  (writer lines 67-68). This `.md` `bodyText` is the ONLY thing the ranking packet shows the maintainer.
- **Verdict is NOT in the durable log.** Take the per-trial verdict from `verdict.txt` produced by
  `capture.sh` (the stdout cross-check), exactly as end-to-end mode does.
- **Config resolution:** `[orchestration]` section, keys `review_mode` / `panel_size` / `full_log`, resolved
  repo `.claude/code-review.toml` first then user `~/.claude/code-review.toml`, first match wins
  (SKILL.md:1035-1040, 1132-1140).
- **SKILL §B.1 (SKILL.md:1449-1462):** at Stage 6 start, `gh pr view "$ARGUMENTS" --json state,mergedAt`; if
  `state` is `CLOSED` or `MERGED`, refuse to submit, print the two `>` lines, halt cleanly, do NOT present the
  Class A prompt. This is the free no-post path the corpus relies on.
- **Harness launch primitive:** `launch_run_trial` (`launch.sh:68`) runs `command claude -p ... "$prompt"` under
  `timeout`, sets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0`, writes `stdout.log`/`stderr.log`/`timing.json`. The
  orchestration prompt is `"$_AB_PREAMBLE"$'\n\n'"/review-gh-pr <pr-url>"`, identical shape to end-to-end.
- **`--stream-json` capture** for cost is wired only in `launch_run_per_agent_trial`. End-to-end `launch_run_trial`
  does NOT capture `stream.jsonl`. Task 3 must capture the stream so `cost_model.py` can price the run
  (see Task 3, Step "stream capture").

---

## File structure

```
tests/ab/
  run.sh                       # MODIFY: add --mode orchestration dispatcher + args
  lib/orchestration.sh         # CREATE: arm toggle (temp user TOML + trap) + durable-log harvest
  lib/differential.py          # CREATE: verdict agreement, finding-set delta, honesty flags
  lib/ranking_packet.py        # CREATE: blinded side-by-side packets + pre-registration
  lib/ranking_unblind.py       # CREATE: join rankings→arms + differential; apply decision rule
  lib/arm_tells.json           # CREATE (Task 6, data-derived): normalisation rules from live capture
  README.md                    # MODIFY: document --mode orchestration
tests/python/
  test_differential.py         # CREATE: unittest.TestCase suite for differential.py
  test_ranking_packet.py       # CREATE: unittest.TestCase suite for ranking_packet.py
  test_ranking_unblind.py      # CREATE: unittest.TestCase suite for ranking_unblind.py
tests/lib/
  test_ab_orchestration.sh     # CREATE: TOML round-trip + harvest-locate gates (bash harness)
tests/ab/fixtures/durable-log/ # CREATE: synthetic classic/panel JSONL + .md pairs for Python tests
```

Run-dir layout produced at runtime (all under `tests/ab/runs/`, gitignored):

```
<ts>-orchestration-<phase>/
  manifest.yaml
  corpus.yaml                  # pinned SHA list, recorded before any dispatch
  criteria.md                  # pre-registration; ALSO copied to durable location
  <pr-slug>/                   # one dir per corpus PR (e.g. jodre11-plugins-pr-88)
    classic/trial-001/{stdout.log,stderr.log,stream.jsonl,timing.json,verdict.txt,durable-log.jsonl,durable-log.md}
    classic/trial-002/ ...
    panel/trial-001/ ...
  differential.json            # differential.py output
  packets/<pr-slug>/{A.md,B.md}  # ranking_packet.py output, blinded
  packets/seed.json            # sealed arm→label map (never shown before unblind)
  rankings.json                # maintainer input (A-better/B-better/tie + reason per PR)
  unblinded.json               # ranking_unblind.py output + decision-rule verdict
```

---

### Task 1: Arm toggle — temp user-level `code-review.toml` with backup/restore

**Files:**
- Create: `tests/ab/lib/orchestration.sh`
- Test: `tests/lib/test_ab_orchestration.sh`

**Interfaces:**
- Produces:
  - `orchestration_apply_arm <arm> <panel_size> <toml_path>` — writes `[orchestration]` with
    `review_mode=<arm>`, `panel_size=<n>`, `full_log=true` to `<toml_path>`, backing up any existing file to
    `<toml_path>.ab-backup`. Tracks state in `_AB_ORCH_TOML` / `_AB_ORCH_BACKUP` / `_AB_ORCH_HAD_PRIOR`.
  - `orchestration_restore_arm` — restores the backup (or removes the temp file if none existed); on failure
    writes `MANUAL_REVERT_REQUIRED` into `$_AB_RUN_DIR`. Idempotent.
  - `orchestration_install_restore_trap` — installs EXIT/INT/TERM/HUP trap calling `orchestration_restore_arm`.
- Consumes: `_AB_RUN_DIR` (set by run.sh), `REPO_ROOT`.

- [ ] **Step 1: Write the failing test** — `tests/lib/test_ab_orchestration.sh`

```bash
#!/usr/bin/env bash
# tests/lib/test_ab_orchestration.sh — arm-toggle round-trip + harvest-locate gates.

_orch_lib() { echo "$REPO_ROOT/tests/ab/lib/orchestration.sh"; }

test_orch_apply_writes_expected_toml() {
    local tmp toml
    tmp=$(mktemp -d); toml="$tmp/code-review.toml"
    ( set -euo pipefail
      _AB_RUN_DIR="$tmp"; source "$(_orch_lib)"
      orchestration_apply_arm panel 5 "$toml" )
    assert_equals 'true' "$(grep -c 'review_mode = "panel"' "$toml" | tr -d ' ')" \
        "orch: review_mode written" 2>/dev/null || true
    if grep -q 'review_mode = "panel"' "$toml" && grep -q 'panel_size = 5' "$toml" \
        && grep -q 'full_log = true' "$toml"; then
        pass "orch: apply writes review_mode/panel_size/full_log"
    else
        fail "orch: apply writes review_mode/panel_size/full_log" "$(cat "$toml")"
    fi
    rm -rf "$tmp"
}

test_orch_restore_removes_temp_when_no_prior() {
    local tmp toml
    tmp=$(mktemp -d); toml="$tmp/code-review.toml"
    ( set -euo pipefail
      _AB_RUN_DIR="$tmp"; source "$(_orch_lib)"
      orchestration_apply_arm classic 3 "$toml"
      orchestration_restore_arm )
    if [[ ! -f "$toml" ]]; then
        pass "orch: restore removes temp file when no prior existed"
    else
        fail "orch: restore removes temp file when no prior existed" "file still present"
    fi
    rm -rf "$tmp"
}

test_orch_restore_reinstates_prior_file_byte_for_byte() {
    local tmp toml
    tmp=$(mktemp -d); toml="$tmp/code-review.toml"
    printf '[intent]\ndoc_paths = ["X.md"]\n' > "$toml"
    local before; before=$(shasum -a 256 "$toml" | awk '{print $1}')
    ( set -euo pipefail
      _AB_RUN_DIR="$tmp"; source "$(_orch_lib)"
      orchestration_apply_arm panel 3 "$toml"
      orchestration_restore_arm )
    local after; after=$(shasum -a 256 "$toml" | awk '{print $1}')
    assert_equals "$before" "$after" "orch: restore reinstates prior file byte-for-byte"
    rm -rf "$tmp"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 'orch:'`
Expected: FAIL — `orchestration.sh` not found / functions undefined.

- [ ] **Step 3: Write minimal implementation** — `tests/ab/lib/orchestration.sh` (toggle half only)

```bash
#!/usr/bin/env bash
# tests/ab/lib/orchestration.sh — orchestration A/B: arm toggle (temp user-level
# code-review.toml) + durable-log harvest. Sourced by tests/ab/run.sh; toggle
# functions exercised against temp fixtures by tests/lib/test_ab_orchestration.sh.
#
# Arm toggle rationale (see spec § "Arm toggle"): panel is selected by
# orchestration.review_mode in ~/.claude/code-review.toml, NOT by editing tracked
# files. We write a temp user-level TOML, back up any pre-existing one, and restore
# on every exit path. A failed restore writes MANUAL_REVERT_REQUIRED rather than
# leaving a stray toggle that would silently taint the operator's real reviews.
set -euo pipefail

_AB_ORCH_TOML=""
_AB_ORCH_BACKUP=""
_AB_ORCH_HAD_PRIOR="false"

# Write the [orchestration] arm config to <toml_path>, backing up any prior file.
orchestration_apply_arm() {
    local arm="$1"
    local panel_size="$2"
    local toml_path="${3:-$HOME/.claude/code-review.toml}"

    case "$arm" in
        classic|panel) ;;
        *) echo "orchestration_apply_arm: unknown arm '$arm'" >&2; return 1 ;;
    esac

    _AB_ORCH_TOML="$toml_path"
    _AB_ORCH_BACKUP="${toml_path}.ab-backup"
    mkdir -p "$(dirname "$toml_path")"

    if [[ -f "$toml_path" ]]; then
        _AB_ORCH_HAD_PRIOR="true"
        cp "$toml_path" "$_AB_ORCH_BACKUP"
    else
        _AB_ORCH_HAD_PRIOR="false"
    fi

    # full_log=true is forced on for the whole experiment — the durable log is the
    # data source. panel_size is written even for classic (the workflow ignores it).
    cat > "$toml_path" <<EOF
[orchestration]
review_mode = "$arm"
panel_size = $panel_size
full_log = true
EOF
}

# Restore the pre-run state. Idempotent; safe to call from a trap more than once.
orchestration_restore_arm() {
    [[ -n "$_AB_ORCH_TOML" ]] || return 0
    local ok=0
    if [[ "$_AB_ORCH_HAD_PRIOR" == "true" ]]; then
        if [[ -f "$_AB_ORCH_BACKUP" ]]; then
            mv -f "$_AB_ORCH_BACKUP" "$_AB_ORCH_TOML" || ok=1
        else
            ok=1
        fi
    else
        rm -f "$_AB_ORCH_TOML" || ok=1
    fi
    if [[ "$ok" -ne 0 ]]; then
        _ab_orch_manual_revert_marker
    fi
    _AB_ORCH_TOML=""  # disarm so a second trap invocation is a no-op
}

_ab_orch_manual_revert_marker() {
    local dir="${_AB_RUN_DIR:-}"
    if [[ -n "$dir" && -d "$dir" ]]; then
        {
            echo "MANUAL_REVERT_REQUIRED — code-review.toml restore failed"
            echo "toml:   $_AB_ORCH_TOML"
            echo "backup: $_AB_ORCH_BACKUP (had_prior=$_AB_ORCH_HAD_PRIOR)"
        } > "$dir/MANUAL_REVERT_REQUIRED"
    fi
    echo "orchestration: MANUAL_REVERT_REQUIRED — restore code-review.toml by hand" >&2
}

orchestration_install_restore_trap() {
    trap 'orchestration_restore_arm' EXIT
    trap 'orchestration_restore_arm; exit 130' INT
    trap 'orchestration_restore_arm; exit 143' TERM
    trap 'orchestration_restore_arm; exit 129' HUP
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep 'orch:'`
Expected: the three `orch:` toggle tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/orchestration.sh tests/lib/test_ab_orchestration.sh
git commit -m "feat(ab): orchestration arm toggle via temp user-level code-review.toml"
```

---

### Task 2: Durable-log harvest — locate and copy `<ident>-<sha>.{jsonl,md}`

**Files:**
- Modify: `tests/ab/lib/orchestration.sh`
- Test: `tests/lib/test_ab_orchestration.sh`

**Interfaces:**
- Consumes: the writer's on-disk layout `<logs-root>/<repo-slug>/<ident>-<sha12>.{jsonl,md}`.
- Produces:
  - `orchestration_slug_from_url <pr-url>` — echoes `owner-name` (github.com/owner/name/pull/N → `owner-name`).
  - `orchestration_ident_from_url <pr-url>` — echoes `pr-<N>`.
  - `orchestration_harvest <trial_dir> <logs_root> <repo_slug> <ident> <head_sha>` — locates
    `<logs_root>/<repo_slug>/<ident>-${head_sha:0:12}.{jsonl,md}` and copies them into `<trial_dir>` as
    `durable-log.jsonl` / `durable-log.md`. Returns non-zero (and writes nothing) if the jsonl is missing —
    the caller records a harvest-miss sentinel but does not abort the loop.

- [ ] **Step 1: Write the failing test** — append to `tests/lib/test_ab_orchestration.sh`

```bash
test_orch_slug_and_ident_from_url() {
    local url="https://github.com/Jodre11/claude-code-plugins/pull/88"
    source "$(_orch_lib)"
    assert_equals "Jodre11-claude-code-plugins" "$(orchestration_slug_from_url "$url")" \
        "orch: slug is owner-name"
    assert_equals "pr-88" "$(orchestration_ident_from_url "$url")" "orch: ident is pr-N"
}

test_orch_harvest_locates_by_slug_ident_sha12() {
    local tmp logs trial
    tmp=$(mktemp -d); logs="$tmp/logs"; trial="$tmp/trial"
    mkdir -p "$logs/o-r" "$trial"
    printf '{"type":"meta","orchestration_mode":"panel"}\n{"type":"finding","tier":"consensus"}\n' \
        > "$logs/o-r/pr-88-0123456789ab.jsonl"
    printf '<!-- x -->\n## Review\n' > "$logs/o-r/pr-88-0123456789ab.md"
    source "$(_orch_lib)"
    orchestration_harvest "$trial" "$logs" "o-r" "pr-88" "0123456789abcdef0123456789abcdef01234567"
    if [[ -f "$trial/durable-log.jsonl" && -f "$trial/durable-log.md" ]]; then
        pass "orch: harvest copies jsonl+md by slug/ident/sha12"
    else
        fail "orch: harvest copies jsonl+md by slug/ident/sha12" "$(ls "$trial")"
    fi
    rm -rf "$tmp"
}

test_orch_harvest_missing_jsonl_returns_nonzero() {
    local tmp logs trial rc
    tmp=$(mktemp -d); logs="$tmp/logs"; trial="$tmp/trial"
    mkdir -p "$logs/o-r" "$trial"
    source "$(_orch_lib)"
    set +e; orchestration_harvest "$trial" "$logs" "o-r" "pr-99" "abcabcabcabc000000000000000000000000abcd"; rc=$?; set -e
    assert_equals "1" "$rc" "orch: harvest returns 1 when jsonl missing"
    rm -rf "$tmp"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep 'orch: harvest\|orch: slug'`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Write minimal implementation** — append to `tests/ab/lib/orchestration.sh`

```bash
# owner/name from a github PR URL, with '/'→'-' (matches the writer's <repo-slug>).
orchestration_slug_from_url() {
    local url="$1"
    # .../<owner>/<name>/pull/<N>  → owner-name
    local path="${url#*github.com/}"
    local owner="${path%%/*}"; path="${path#*/}"
    local name="${path%%/*}"
    echo "${owner}-${name}"
}

orchestration_ident_from_url() {
    local url="$1"
    echo "pr-${url##*/}"
}

# Copy the durable log for one run into the trial dir. Returns 1 (writing nothing)
# when the jsonl is absent, so the caller records a harvest-miss and presses on.
orchestration_harvest() {
    local trial_dir="$1"
    local logs_root="$2"
    local repo_slug="$3"
    local ident="$4"
    local head_sha="$5"

    local sha12="${head_sha:0:12}"
    local src_jsonl="$logs_root/$repo_slug/${ident}-${sha12}.jsonl"
    local src_md="$logs_root/$repo_slug/${ident}-${sha12}.md"

    if [[ ! -f "$src_jsonl" ]]; then
        echo "orchestration_harvest: no durable log at $src_jsonl" >&2
        return 1
    fi
    cp "$src_jsonl" "$trial_dir/durable-log.jsonl"
    [[ -f "$src_md" ]] && cp "$src_md" "$trial_dir/durable-log.md"
    return 0
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep 'orch:'`
Expected: all Task-1 + Task-2 `orch:` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/orchestration.sh tests/lib/test_ab_orchestration.sh
git commit -m "feat(ab): durable-log harvest by slug/ident/sha12"
```

---

### Task 3: `run.sh --mode orchestration` dispatcher

**Files:**
- Modify: `tests/ab/run.sh`
- Modify: `tests/ab/README.md`

**Interfaces:**
- New CLI: `tests/ab/run.sh --mode orchestration --corpus <corpus.yaml> --arms "classic panel:5" --trials <n> --phase <pilot|full> [--panel-size <n>] [--timeout-seconds <n>]`.
- Consumes: `orchestration_apply_arm` / `orchestration_restore_arm` / `orchestration_install_restore_trap` /
  `orchestration_harvest` / `orchestration_slug_from_url` / `orchestration_ident_from_url` (Tasks 1-2),
  `launch_run_trial` + `launch_preflight_environment` (`launch.sh`), `capture_parse_trial` (`capture.sh`).
- Produces: the run-dir layout in "File structure" above; one `<pr-slug>/<arm>/trial-NNN/` per PR×arm×trial with
  `stdout.log`, `stderr.log`, `stream.jsonl`, `timing.json`, `verdict.txt`, `durable-log.jsonl`, `durable-log.md`.

**corpus.yaml schema** (recorded at phase start, per spec §"Corpus selection procedure" step 4):

```yaml
phase: pilot          # pilot | full
prs:
  - url: https://github.com/Jodre11/claude-code-plugins/pull/88
    head_sha: a757f69000000000000000000000000000000000  # 40-hex, pinned
    stratum: "large-diff/request-changes/hard"
```

- [ ] **Step 1: Write the failing test** — append to `tests/lib/test_ab_orchestration.sh`

This gate asserts the dispatcher parses args, refuses a repo-level `orchestration.*` override in a corpus repo
(spec §"Corpus selection procedure" step 2), and stops before Bedrock. It runs `run.sh` with a stub corpus and a
sentinel that makes `launch_preflight_environment` the last reachable call, asserting the run-dir + corpus.yaml
copy exist. Because a real trial hits Bedrock, this test sets `_AB_ORCH_DRYRUN=1` (a test-only env hook added in
Step 3) that skips the trial loop after writing the run scaffold.

```bash
test_orch_dispatcher_scaffolds_run_dir_and_records_corpus() {
    local tmp corpus
    tmp=$(mktemp -d); corpus="$tmp/corpus.yaml"
    cat > "$corpus" <<'YAML'
phase: pilot
prs:
  - url: https://github.com/Jodre11/claude-code-plugins/pull/88
    head_sha: a757f69000000000000000000000000000000000
    stratum: large/rc/hard
YAML
    local out
    out=$(_AB_ORCH_DRYRUN=1 CLAUDE_TEMP_DIR="$tmp" \
        bash "$REPO_ROOT/tests/ab/run.sh" --mode orchestration --corpus "$corpus" \
        --arms "classic panel:5" --trials 2 --phase pilot 2>&1 || true)
    # Dry-run prints the resolved run dir on the last "Run dir:" line.
    local run_dir; run_dir=$(printf '%s\n' "$out" | sed -n 's/.*Run dir:[[:space:]]*//p' | tail -1)
    if [[ -n "$run_dir" && -f "$run_dir/corpus.yaml" ]]; then
        pass "orch: dispatcher scaffolds run dir + copies corpus.yaml"
    else
        fail "orch: dispatcher scaffolds run dir + copies corpus.yaml" "$out"
    fi
    rm -rf "$tmp"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep 'orch: dispatcher'`
Expected: FAIL — `--mode orchestration` is an unknown mode (run.sh exits 64).

- [ ] **Step 3: Write minimal implementation**

In `tests/ab/run.sh`:

1. Source the new lib near the other sources (after `agent_capture.sh`):

```bash
# shellcheck source=lib/orchestration.sh
source "$SCRIPT_DIR/lib/orchestration.sh"
```

2. Add CLI flags to the `while`/`case` arg parser in `main()`:

```bash
            --mode) _cli_mode="$2"; shift 2 ;;
            --arms) arms="$2"; shift 2 ;;
            --phase) phase="$2"; shift 2 ;;
            --panel-size) panel_size="$2"; shift 2 ;;
```

with locals `_cli_mode=""`, `arms=""`, `phase=""`, `panel_size="3"` declared at the top of `main()`.
Corpus already has a `--corpus` flag; reuse it (it currently carries a fixture-id in per-agent mode — in
orchestration mode it carries a path to `corpus.yaml`).

3. Extend the dispatch `case` so an explicit `--mode orchestration` (CLI) overrides the config-derived mode:

```bash
    local mode="${_cli_mode:-${_AB_CONFIG_MODE:-end-to-end}}"
    case "$mode" in
        end-to-end) _ab_run_end_to_end ... ;;   # unchanged
        per-agent)  _ab_run_per_agent  ... ;;    # unchanged
        orchestration)
            if [[ -z "$corpus_id" || -z "$arms" || -z "$phase" ]]; then
                echo "run.sh: --corpus <corpus.yaml> --arms <spec> --phase <pilot|full> required for orchestration" >&2
                exit 64
            fi
            _ab_run_orchestration "$corpus_id" "$arms" "$trials" "$phase" "$panel_size" "$timeout_seconds"
            ;;
    esac
```

Note: orchestration mode does not require `--config` (it varies arm via TOML, not agent frontmatter). Relax the
early `if [[ -z "$config_path" ... ]]` guard so it only fires for non-orchestration modes, and skip
`config_load` when `_cli_mode == orchestration`.

4. Add the runner function. `--arms "classic panel:5"` is space-separated arm specs; each is `classic` or
   `panel:<size>`.

```bash
_ab_run_orchestration() {
    local corpus_yaml="$1" arms_spec="$2" trials="$3" phase="$4" default_panel="$5" timeout_seconds="$6"

    _ab_preflight_marketplace_root
    _ab_preflight_required_tools
    [[ -f "$corpus_yaml" ]] || { echo "run.sh: corpus.yaml not found: $corpus_yaml" >&2; exit 1; }

    local timestamp; timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
    _AB_RUN_DIR="$SCRIPT_DIR/runs/${timestamp}-orchestration-${phase}"
    mkdir -p "$_AB_RUN_DIR"
    cp "$corpus_yaml" "$_AB_RUN_DIR/corpus.yaml"

    # Pre-registration criteria: prompt is manual; the tool copies the file if the
    # operator placed it at $_AB_RUN_DIR/criteria.md OR $CLAUDE_TEMP_DIR/criteria.md,
    # then mirrors it to the durable honesty-anchor location (survives run-dir prune).
    _ab_orch_capture_criteria "$phase" "$timestamp"

    echo "==> orchestration A/B: phase=$phase arms='$arms_spec' trials=$trials" >&2
    echo "    Run dir: $_AB_RUN_DIR" >&2

    if [[ "${_AB_ORCH_DRYRUN:-0}" == "1" ]]; then
        return 0    # test hook: scaffold only, no Bedrock
    fi

    launch_preflight_environment
    local timeout_bin; timeout_bin=$(launch_resolve_timeout_binary)
    local logs_root="$HOME/.claude/code-review-suite/logs"

    # Iterate PRs from corpus.yaml.
    local n_prs; n_prs=$(yq '.prs | length' "$_AB_RUN_DIR/corpus.yaml")
    local pi
    for ((pi = 0; pi < n_prs; pi++)); do
        local url head_sha
        url=$(yq -r ".prs[$pi].url" "$_AB_RUN_DIR/corpus.yaml")
        head_sha=$(yq -r ".prs[$pi].head_sha" "$_AB_RUN_DIR/corpus.yaml")
        local slug ident pr_slug
        slug=$(orchestration_slug_from_url "$url")
        ident=$(orchestration_ident_from_url "$url")
        pr_slug="${slug}-${ident}"

        _ab_orch_preflight_no_repo_override "$url"   # disqualify repo-level orchestration.* (spec step 2)
        _ab_orch_preflight_merged "$url"             # confirm MERGED so §B.1 no-post holds

        local arm_spec
        for arm_spec in $arms_spec; do
            local arm psize
            arm="${arm_spec%%:*}"
            psize="$default_panel"
            [[ "$arm_spec" == *:* ]] && psize="${arm_spec#*:}"

            orchestration_install_restore_trap
            orchestration_apply_arm "$arm" "$psize" "$HOME/.claude/code-review.toml"

            local prompt; prompt="$_AB_PREAMBLE"$'\n\n'"/review-gh-pr $url"
            local i
            for ((i = 1; i <= trials; i++)); do
                local trial_dir; trial_dir=$(printf '%s/%s/%s/trial-%03d' "$_AB_RUN_DIR" "$pr_slug" "$arm" "$i")
                mkdir -p "$trial_dir"
                local rc=0
                _ab_orch_launch_trial "$trial_dir" "$timeout_seconds" "$prompt" "$timeout_bin" || rc=$?
                capture_parse_trial "$trial_dir" || true
                orchestration_harvest "$trial_dir" "$logs_root" "$slug" "$ident" "$head_sha" \
                    || : > "$trial_dir/HARVEST_MISS"
                [[ "$i" -lt "$trials" ]] && sleep 5
            done

            orchestration_restore_arm
            trap - EXIT INT TERM HUP
        done
    done

    echo "Run complete: $_AB_RUN_DIR" >&2
}
```

5. **Stream capture.** `launch_run_trial` does not write `stream.jsonl`; the cost model needs it. Add a thin
   orchestration launcher that mirrors `launch_run_trial` but in `--output-format stream-json --verbose` mode
   (the same mechanism `launch_run_per_agent_trial` already uses at `launch.sh:361-384`), capturing
   `stream.jsonl` and reconstructing `stdout.log` via `launch_jq_reduce_stream_jsonl`:

```bash
_ab_orch_launch_trial() {
    local trial_dir="$1" timeout_seconds="$2" prompt="$3" timeout_bin="$4"
    local stream_jsonl="$trial_dir/stream.jsonl" stdout="$trial_dir/stdout.log"
    local stderr="$trial_dir/stderr.log" timing="$trial_dir/timing.json"
    local start_iso; start_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ'); local start=$SECONDS
    local rc=0
    CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
    "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
        command claude -p --permission-mode bypassPermissions \
            --output-format stream-json --verbose \
            --exclude-dynamic-system-prompt-sections "$prompt" \
        > "$stream_jsonl" 2> "$stderr" || rc=$?
    launch_jq_reduce_stream_jsonl "$stream_jsonl" "$stdout"
    local elapsed=$((SECONDS - start)); local timed_out=false
    [[ "$rc" == "124" ]] && timed_out=true
    jq -n --arg s "$start_iso" --arg e "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --argjson el "$elapsed" --argjson rc "$rc" --arg to "$timed_out" \
        '{start:$s,end:$e,wall_clock_seconds:$el,exit_code:$rc,timed_out:($to=="true")}' > "$timing"
    return "$rc"
}
```

Model/effort are intentionally NOT passed — orchestration uses the production session defaults so both arms run
exactly as a real `/review-gh-pr` would; the arm difference is entirely in the TOML toggle.

6. Add helper stubs `_ab_orch_capture_criteria`, `_ab_orch_preflight_no_repo_override`, `_ab_orch_preflight_merged`
   (see Task 8 for `_ab_orch_capture_criteria`'s durable-copy body; the two preflights are:):

```bash
_ab_orch_preflight_merged() {
    local url="$1" state
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null || echo UNKNOWN)
    if [[ "$state" != "MERGED" ]]; then
        echo "orchestration: corpus PR not MERGED ($state) — §B.1 no-post safety not guaranteed: $url" >&2
        exit 1
    fi
}

_ab_orch_preflight_no_repo_override() {
    local url="$1"
    # A repo-level .claude/code-review.toml [orchestration] key would win over our
    # user-level temp toggle (SKILL.md:1035-1040). We cannot cheaply inspect the
    # remote repo's working tree here, so this is a RECORDED WARNING the operator
    # must clear when selecting the SHA (spec step 2). Log it; do not hard-fail.
    echo "orchestration: confirm $url's repo sets no [orchestration] key at repo layer (spec corpus step 2)" >&2
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep 'orch: dispatcher'`
Expected: `orch: dispatcher scaffolds run dir + copies corpus.yaml` PASS.

- [ ] **Step 5: Update README** — add a `## Orchestration mode` section to `tests/ab/README.md` documenting the
  CLI, corpus.yaml schema, arm-spec syntax, the TOML toggle, and the run-dir layout.

- [ ] **Step 6: Commit**

```bash
git add tests/ab/run.sh tests/ab/lib/orchestration.sh tests/lib/test_ab_orchestration.sh tests/ab/README.md
git commit -m "feat(ab): --mode orchestration dispatcher (PR x arm x trial loop)"
```

---

### Task 4: `differential.py` — verdict agreement (within-arm + cross-arm)

**Files:**
- Create: `tests/ab/lib/differential.py`
- Create: `tests/ab/fixtures/durable-log/` (synthetic classic/panel JSONL pairs)
- Create: `tests/python/test_differential.py`

**Interfaces:**
- Produces:
  - `load_arm(arm_dir) -> list[dict]` — one entry per `trial-*/` under `arm_dir`, each
    `{"verdict": <str>, "findings": [<finding dict>], "meta": <meta dict>}`. `verdict` from `trial-*/verdict.txt`;
    `findings`/`meta` from `trial-*/durable-log.jsonl` (records with `type=="finding"` / `type=="meta"`). A trial
    with a `HARVEST_MISS` marker or missing jsonl contributes `findings=[]`, `meta={}` but keeps its verdict.
  - `verdict_distribution(runs) -> dict[str,int]` — count of each verdict across the arm's runs.
  - `modal_verdict(runs) -> str` — the most common verdict (ties broken by first-seen order APPROVE,
    REQUEST_CHANGES, INCONCLUSIVE).
  - `within_arm_stability(runs) -> float` — fraction of runs whose verdict equals the modal verdict (1.0 = perfectly
    stable; the per-PR noise floor).
  - `cross_arm_agreement(runs_a, runs_b) -> dict` — `{"modal_match": bool, "pairwise_rate": float}` where
    `pairwise_rate` is the N×M fraction of (a,b) run pairs with equal verdicts.

- [ ] **Step 1: Write the failing test** — `tests/python/test_differential.py`

```python
import json
import pathlib
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "ab" / "lib"))

import differential  # noqa: E402


def _write_trial(arm_dir, n, verdict, findings, meta=None):
    td = arm_dir / f"trial-{n:03d}"
    td.mkdir(parents=True)
    (td / "verdict.txt").write_text(verdict + "\n", encoding="utf-8")
    lines = [json.dumps({**(meta or {}), "type": "meta"})]
    lines += [json.dumps({**f, "type": "finding"}) for f in findings]
    (td / "durable-log.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return td


class VerdictAgreementTest(unittest.TestCase):
    def test_within_arm_stability_all_agree(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            for i in range(1, 4):
                _write_trial(arm, i, "REQUEST_CHANGES", [])
            runs = differential.load_arm(arm)
            self.assertEqual(differential.modal_verdict(runs), "REQUEST_CHANGES")
            self.assertEqual(differential.within_arm_stability(runs), 1.0)

    def test_within_arm_stability_split(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            _write_trial(arm, 1, "APPROVE", [])
            _write_trial(arm, 2, "REQUEST_CHANGES", [])
            _write_trial(arm, 3, "REQUEST_CHANGES", [])
            runs = differential.load_arm(arm)
            self.assertEqual(differential.modal_verdict(runs), "REQUEST_CHANGES")
            self.assertAlmostEqual(differential.within_arm_stability(runs), 2 / 3)

    def test_cross_arm_pairwise_rate(self):
        with tempfile.TemporaryDirectory() as d:
            a = pathlib.Path(d) / "classic"
            b = pathlib.Path(d) / "panel"
            for i in range(1, 3):
                _write_trial(a, i, "REQUEST_CHANGES", [])
            _write_trial(b, 1, "REQUEST_CHANGES", [])
            _write_trial(b, 2, "APPROVE", [])
            ra, rb = differential.load_arm(a), differential.load_arm(b)
            agg = differential.cross_arm_agreement(ra, rb)
            self.assertFalse(agg["modal_match"])  # classic RC vs panel modal APPROVE/RC tie→first
            self.assertAlmostEqual(agg["pairwise_rate"], 0.5)  # 2 of 4 pairs agree
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tests/python && python3 -m unittest test_differential -v`
Expected: FAIL — `No module named 'differential'`.

- [ ] **Step 3: Write minimal implementation** — `tests/ab/lib/differential.py` (verdict half)

```python
#!/usr/bin/env python3
"""differential — mechanical differential for the panel-vs-classic orchestration A/B.

Pure-stdlib. Reads the harvested durable-log JSONL + per-trial verdict.txt under a
run dir and computes verdict agreement (within-arm noise floor + cross-arm) and the
finding-set delta (matched by file/line-proximity/domain, NEVER description). Emits
the honesty flags the decision rule needs (contradiction, noise-dominated). Never
calls an LLM — the quality sign is the human ranking, not this tool.
"""
import argparse
import glob
import json
import os

_VERDICT_ORDER = ("APPROVE", "REQUEST_CHANGES", "INCONCLUSIVE")


def _read_jsonl(path):
    out = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln:
                out.append(json.loads(ln))
    return out


def load_arm(arm_dir):
    """One entry per trial-*/ under arm_dir: {verdict, findings, meta}."""
    runs = []
    for trial in sorted(glob.glob(os.path.join(arm_dir, "trial-*"))):
        verdict = "INCONCLUSIVE"
        vpath = os.path.join(trial, "verdict.txt")
        if os.path.isfile(vpath):
            with open(vpath, encoding="utf-8") as fh:
                verdict = fh.read().strip() or "INCONCLUSIVE"
        findings, meta = [], {}
        jpath = os.path.join(trial, "durable-log.jsonl")
        if os.path.isfile(jpath):
            for rec in _read_jsonl(jpath):
                if rec.get("type") == "finding":
                    findings.append(rec)
                elif rec.get("type") == "meta":
                    meta = rec
        runs.append({"verdict": verdict, "findings": findings, "meta": meta})
    return runs


def verdict_distribution(runs):
    dist = {}
    for r in runs:
        dist[r["verdict"]] = dist.get(r["verdict"], 0) + 1
    return dist


def modal_verdict(runs):
    dist = verdict_distribution(runs)
    if not dist:
        return "INCONCLUSIVE"
    best = max(dist.values())
    for v in _VERDICT_ORDER:            # deterministic tie-break by canonical order
        if dist.get(v, 0) == best:
            return v
    return max(dist, key=dist.get)      # non-canonical verdicts fall through


def within_arm_stability(runs):
    if not runs:
        return 0.0
    modal = modal_verdict(runs)
    return sum(1 for r in runs if r["verdict"] == modal) / len(runs)


def cross_arm_agreement(runs_a, runs_b):
    modal_match = modal_verdict(runs_a) == modal_verdict(runs_b)
    if not runs_a or not runs_b:
        return {"modal_match": modal_match, "pairwise_rate": 0.0}
    agree = sum(1 for a in runs_a for b in runs_b if a["verdict"] == b["verdict"])
    return {"modal_match": modal_match, "pairwise_rate": agree / (len(runs_a) * len(runs_b))}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tests/python && python3 -m unittest test_differential -v`
Expected: the three `VerdictAgreementTest` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/differential.py tests/python/test_differential.py
git commit -m "feat(ab): differential verdict agreement (within/cross-arm)"
```

---

### Task 5: `differential.py` — finding-set delta + honesty flags

**Files:**
- Modify: `tests/ab/lib/differential.py`
- Modify: `tests/python/test_differential.py`

**Interfaces:**
- Consumes: `load_arm`, `within_arm_stability`, `cross_arm_agreement`, `modal_verdict` (Task 4).
- Produces:
  - `findings_match(f1, f2, line_proximity=5) -> bool` — True iff same `file`, same `domain`, and
    `abs(f1["line"] - f2["line"]) <= line_proximity`. Never inspects `description`.
  - `modal_presence(runs, finding) -> bool` — True iff a matching finding appears in ≥ half the arm's runs
    (the arm "holds" this finding).
  - `high_value(finding) -> bool` — True iff `tier == "consensus"` OR `confidence >= 80` (the regression-signal set,
    spec rule 2 / §"finding-set delta").
  - `finding_delta(runs_a, runs_b) -> dict` — from A(classic)→B(panel):
    `{"retained": [...], "dropped": [...], "added": [...], "tier_moved": [...]}`. `dropped` = high-value findings
    modally-present in A but not in B (the regression signal). `added` = findings modally-present in B with no A
    match. `tier_moved` = matched pairs whose `(tier, confidence-band)` differ.
  - `per_pr_differential(pr_dir) -> dict` — loads `classic/` and `panel/`, returns verdict agreement + finding delta
    + the two flags:
    - `"contradiction"`: placeholder here (needs ranking) — emitted as `None`; `ranking_unblind` fills it.
    - `"noise_dominated"`: True iff `(min_within - pairwise_rate) < 0.1` — the gap between the within-arm
      noise floor and cross-arm agreement is too small to discriminate the arms (they agree cross-arm about
      as much as each agrees with itself). Uses module constant `_NOISE_GAP_EPSILON = 0.1`. (Corrected from
      the original dead-code predicate `stab < pairwise_rate`, which was always False by proof.)
  - `build_differential(run_dir) -> dict` — walks every `<pr-slug>/` under run_dir, returns
    `{"prs": {<pr-slug>: per_pr_differential}, ...}`. CLI: `differential.py --run-dir <dir> [--out <path>]`.

- [ ] **Step 1: Write the failing test** — append to `tests/python/test_differential.py`

```python
class FindingMatchTest(unittest.TestCase):
    def _f(self, file="a.py", line=10, domain="correctness", tier="consensus", conf=90):
        return {"file": file, "line": line, "domain": domain, "tier": tier,
                "confidence": conf, "severity": "Important", "description": "whatever"}

    def test_match_within_line_proximity(self):
        self.assertTrue(differential.findings_match(self._f(line=10), self._f(line=13)))
        self.assertFalse(differential.findings_match(self._f(line=10), self._f(line=20)))

    def test_match_requires_same_domain_and_file(self):
        self.assertFalse(differential.findings_match(self._f(domain="security"), self._f(domain="style")))
        self.assertFalse(differential.findings_match(self._f(file="a.py"), self._f(file="b.py")))

    def test_match_never_uses_description(self):
        a = self._f(); b = self._f()
        b["description"] = "totally different words"
        self.assertTrue(differential.findings_match(a, b))  # identical position/domain → match

    def test_high_value_is_consensus_or_conf_ge_80(self):
        self.assertTrue(differential.high_value(self._f(tier="dismissed", conf=85)))
        self.assertTrue(differential.high_value(self._f(tier="consensus", conf=10)))
        self.assertFalse(differential.high_value(self._f(tier="contested", conf=50)))


class FindingDeltaTest(unittest.TestCase):
    def _run(self, findings):
        return {"verdict": "REQUEST_CHANGES", "findings": findings, "meta": {}}

    def _f(self, **kw):
        base = {"file": "a.py", "line": 10, "domain": "correctness",
                "tier": "consensus", "confidence": 90, "severity": "Important"}
        base.update(kw)
        return base

    def test_dropped_high_value_finding_flagged(self):
        classic = [self._run([self._f()]), self._run([self._f()]), self._run([self._f()])]
        panel = [self._run([]), self._run([]), self._run([])]
        delta = differential.finding_delta(classic, panel)
        self.assertEqual(len(delta["dropped"]), 1)
        self.assertEqual(len(delta["retained"]), 0)

    def test_retained_finding_not_dropped(self):
        classic = [self._run([self._f()])] * 3
        panel = [self._run([self._f(line=12)])] * 3   # within proximity → retained
        delta = differential.finding_delta(classic, panel)
        self.assertEqual(len(delta["retained"]), 1)
        self.assertEqual(len(delta["dropped"]), 0)

    def test_added_finding_surfaced(self):
        classic = [self._run([])] * 3
        panel = [self._run([self._f(domain="security", file="x.py")])] * 3
        delta = differential.finding_delta(classic, panel)
        self.assertEqual(len(delta["added"]), 1)


class NoiseDominatedTest(unittest.TestCase):
    def test_noise_dominated_true_when_arms_indistinguishable(self):
        # classic and panel both always APPROVE → gap = 0.0 < 0.1 → True
        with tempfile.TemporaryDirectory() as d:
            pr = pathlib.Path(d) / "pr-x"
            for arm in ("classic", "panel"):
                _write_trial(pr / arm, 1, "APPROVE", [])
                _write_trial(pr / arm, 2, "APPROVE", [])
            out = differential.per_pr_differential(str(pr))
            self.assertIs(out["noise_dominated"], True)

    def test_noise_dominated_false_when_arms_clearly_differ(self):
        # classic all-APPROVE, panel all-REQUEST_CHANGES → gap = 1.0 ≥ 0.1 → False
        with tempfile.TemporaryDirectory() as d:
            pr = pathlib.Path(d) / "pr-y"
            for trial in (1, 2):
                _write_trial(pr / "classic", trial, "APPROVE", [])
                _write_trial(pr / "panel", trial, "REQUEST_CHANGES", [])
            out = differential.per_pr_differential(str(pr))
            self.assertIs(out["noise_dominated"], False)
```

> **Design note:** the original predicate `stab < agreement["pairwise_rate"]` was dead code —
> `pairwise_rate <= min_within` always by proof, so the condition was never True. The corrected
> predicate uses the gap `(min_within - pairwise_rate) < _NOISE_GAP_EPSILON` (threshold 0.1).
> Tests strengthened from key-presence (`assertIn`) to value-asserting (`assertIs True/False`).

- [ ] **Step 2: Run to verify it fails**

Run: `cd tests/python && python3 -m unittest test_differential -v`
Expected: FAIL — `findings_match` / `finding_delta` / `per_pr_differential` undefined.

- [ ] **Step 3: Write minimal implementation** — append to `tests/ab/lib/differential.py`

```python
def findings_match(f1, f2, line_proximity=5):
    """Match by (file, domain, line-proximity). NEVER by description text."""
    if f1.get("file", "") != f2.get("file", ""):
        return False
    if f1.get("domain", "") != f2.get("domain", ""):
        return False
    return abs((f1.get("line") or 0) - (f2.get("line") or 0)) <= line_proximity


def high_value(finding):
    return finding.get("tier") == "consensus" or (finding.get("confidence") or 0) >= 80


def _dedupe_arm_findings(runs):
    """Collapse each arm's per-run findings into unique positional findings."""
    uniq = []
    for r in runs:
        for f in r["findings"]:
            if not any(findings_match(f, u) for u in uniq):
                uniq.append(f)
    return uniq


def modal_presence(runs, finding):
    if not runs:
        return False
    hits = sum(1 for r in runs if any(findings_match(finding, f) for f in r["findings"]))
    return hits * 2 >= len(runs)          # >= half the runs


def _conf_band(f):
    c = f.get("confidence") or 0
    return "high" if c >= 80 else ("mid" if c >= 50 else "low")


def finding_delta(runs_a, runs_b):
    """Classic(A) → panel(B) delta. dropped = high-value modally-present in A, not B."""
    a_uniq = _dedupe_arm_findings(runs_a)
    b_uniq = _dedupe_arm_findings(runs_b)
    retained, dropped, tier_moved = [], [], []
    for fa in a_uniq:
        if not modal_presence(runs_a, fa):
            continue
        match = next((fb for fb in b_uniq if findings_match(fa, fb) and modal_presence(runs_b, fb)), None)
        if match is None:
            if high_value(fa):
                dropped.append(fa)
        else:
            retained.append(fa)
            if (fa.get("tier"), _conf_band(fa)) != (match.get("tier"), _conf_band(match)):
                tier_moved.append({"classic": fa, "panel": match})
    added = []
    for fb in b_uniq:
        if not modal_presence(runs_b, fb):
            continue
        if not any(findings_match(fb, fa) and modal_presence(runs_a, fa) for fa in a_uniq):
            added.append(fb)
    return {"retained": retained, "dropped": dropped, "added": added, "tier_moved": tier_moved}


def per_pr_differential(pr_dir):
    classic = load_arm(os.path.join(pr_dir, "classic"))
    panel = load_arm(os.path.join(pr_dir, "panel"))
    agreement = cross_arm_agreement(classic, panel)
    stab = min(within_arm_stability(classic), within_arm_stability(panel))
    delta = finding_delta(classic, panel)
    return {
        "classic_modal_verdict": modal_verdict(classic),
        "panel_modal_verdict": modal_verdict(panel),
        "within_arm_stability": stab,
        "cross_arm_agreement": agreement,
        "finding_delta": delta,
        "noise_dominated": (stab - agreement["pairwise_rate"]) < _NOISE_GAP_EPSILON,
        "contradiction": None,          # filled by ranking_unblind once rankings exist
    }


def build_differential(run_dir):
    prs = {}
    for entry in sorted(os.listdir(run_dir)):
        pr_dir = os.path.join(run_dir, entry)
        if os.path.isdir(os.path.join(pr_dir, "classic")) and os.path.isdir(os.path.join(pr_dir, "panel")):
            prs[entry] = per_pr_differential(pr_dir)
    return {"prs": prs}


def main(argv=None):
    p = argparse.ArgumentParser(prog="differential")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--out", default=None)
    args = p.parse_args(argv)
    rep = build_differential(args.run_dir)
    text = json.dumps(rep, indent=2)
    print(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tests/python && python3 -m unittest test_differential -v`
Expected: all `differential` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/differential.py tests/python/test_differential.py
git commit -m "feat(ab): differential finding-set delta + noise-dominated flag"
```

---

### Task 6: Live-report capture + `ranking_packet.py` — blinded side-by-side packets

> **DATA-BLOCKED PREREQUISITE.** The exact arm-tell normalisation rules cannot be
> guessed — they must be derived from real `bodyText` (spec §"Open questions", and the
> per-agent-parser lesson). Step 1 of this task IS that capture. Do not skip it and do
> not invent rules; the normaliser reads rules from `tests/ab/lib/arm_tells.json`, which
> Step 1 produces from observed output.

**Files:**
- Create: `tests/ab/lib/arm_tells.json` (produced by Step 1 from live capture)
- Create: `tests/ab/lib/ranking_packet.py`
- Create: `tests/python/test_ranking_packet.py`

**Interfaces:**
- Produces:
  - `normalise_arm_tells(body_text, rules) -> str` — applies the rules list (each `{"pattern": <regex>,
    "replace": <str>}`) via `re.sub`, returning neutralised prose. Pure; deterministic.
  - `modal_run_body(arm_dir) -> str` — picks the modal-verdict representative run (the run whose verdict equals the
    arm's modal verdict; first if several) and returns its `durable-log.md` bodyText (the `.md` minus line-1
    provenance comment).
  - `seal_assignment(pr_slugs, seed) -> dict` — deterministic-given-seed arm→label(A/B) map per PR, using
    `random.Random(seed)`; the map is written to `packets/seed.json` and NOT shown before unblinding.
  - `build_packets(run_dir, seed, rules_path, criteria_present) -> None` — for each PR writes
    `packets/<pr-slug>/A.md` and `B.md` (normalised bodyText only, no `orchestration_mode`, no JSONL), plus
    `packets/seed.json`. Refuses to run (raises) if the pre-registration `criteria.md` is absent — blinding without
    a timestamped criteria file is worthless.

- [ ] **Step 1 (DATA CAPTURE — manual, gated): capture one classic + one panel report and derive the rules.**

  Run the orchestration harness once per arm against a single merged PR (1 trial each):

  ```bash
  cat > /tmp/claude-<id>/capture-corpus.yaml <<'YAML'
  phase: pilot
  prs:
    - url: <a merged PR url>
      head_sha: <40-hex>
      stratum: capture
  YAML
  tests/ab/run.sh --mode orchestration --corpus /tmp/claude-<id>/capture-corpus.yaml \
      --arms "classic panel:3" --trials 1 --phase pilot
  ```

  Then diff the two `durable-log.md` bodies:

  ```bash
  diff <run-dir>/<pr-slug>/classic/trial-001/durable-log.md \
       <run-dir>/<pr-slug>/panel/trial-001/durable-log.md
  ```

  Inspect for structural arm tells (candidates to verify against real output, NOT to assume):
  panel-writer section headings vs synth headings, any literal "panel"/"consensus vote"/"panelist" wording, a
  verdict-advisory phrasing that differs by arm, trailing provenance. Write each confirmed tell as a rule into
  `tests/ab/lib/arm_tells.json`:

  ```json
  [
    {"pattern": "(?i)\\bpanel(ists?)?\\b", "replace": "reviewers"},
    {"pattern": "(?i)\\bconsensus vote\\b", "replace": "consensus"}
  ]
  ```

  **The rules above are illustrative of the FORMAT only.** Replace them wholesale with the tells you actually
  observe. If the diff shows a structural tell that a regex cannot neutralise, record it in the task notes and
  raise it at the Task-6 review checkpoint — do not ship a half-blinding.

- [ ] **Step 2: Write the failing test** — `tests/python/test_ranking_packet.py`

```python
import json
import pathlib
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "ab" / "lib"))

import ranking_packet  # noqa: E402


class NormaliseTest(unittest.TestCase):
    def test_rules_applied(self):
        rules = [{"pattern": r"(?i)\bpanelists?\b", "replace": "reviewers"}]
        out = ranking_packet.normalise_arm_tells("The panelists agreed.", rules)
        self.assertNotIn("panelist", out.lower())
        self.assertIn("reviewers", out)

    def test_empty_rules_is_identity(self):
        self.assertEqual(ranking_packet.normalise_arm_tells("x", []), "x")


class SealAssignmentTest(unittest.TestCase):
    def test_deterministic_given_seed(self):
        a = ranking_packet.seal_assignment(["pr-1", "pr-2"], seed=42)
        b = ranking_packet.seal_assignment(["pr-1", "pr-2"], seed=42)
        self.assertEqual(a, b)

    def test_each_pr_maps_both_arms_to_distinct_labels(self):
        m = ranking_packet.seal_assignment(["pr-1"], seed=7)
        self.assertEqual(sorted(m["pr-1"].values()), ["A", "B"])
        self.assertEqual(sorted(m["pr-1"].keys()), ["classic", "panel"])


class BlindingInvariantTest(unittest.TestCase):
    def _scaffold(self, root):
        for arm in ("classic", "panel"):
            td = root / "pr-1" / arm / "trial-001"
            td.mkdir(parents=True)
            (td / "verdict.txt").write_text("REQUEST_CHANGES\n", encoding="utf-8")
            body = "## Review\nThe panelists reached consensus.\n"
            (td / "durable-log.md").write_text("<!-- plugin_sha: x | ts: y -->\n" + body, encoding="utf-8")
            (td / "durable-log.jsonl").write_text(
                json.dumps({"type": "meta", "orchestration_mode": arm}) + "\n", encoding="utf-8")
        (root / "criteria.md").write_text("catches real bugs > low FP\n", encoding="utf-8")

    def test_packet_has_no_orchestration_mode_leak(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            self._scaffold(root)
            rules = [{"pattern": r"(?i)\bpanelists?\b", "replace": "reviewers"}]
            rules_path = root / "arm_tells.json"
            rules_path.write_text(json.dumps(rules), encoding="utf-8")
            ranking_packet.build_packets(str(root), seed=1, rules_path=str(rules_path),
                                         criteria_present=True)
            for label in ("A", "B"):
                txt = (root / "packets" / "pr-1" / f"{label}.md").read_text(encoding="utf-8")
                self.assertNotIn("orchestration_mode", txt)
                self.assertNotIn("classic", txt.lower())
                self.assertNotIn("panelist", txt.lower())

    def test_build_refuses_without_criteria(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            self._scaffold(root)
            (root / "criteria.md").unlink()
            rules_path = root / "arm_tells.json"
            rules_path.write_text("[]", encoding="utf-8")
            with self.assertRaises(Exception):
                ranking_packet.build_packets(str(root), seed=1, rules_path=str(rules_path),
                                             criteria_present=False)
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd tests/python && python3 -m unittest test_ranking_packet -v`
Expected: FAIL — `No module named 'ranking_packet'`.

- [ ] **Step 4: Write minimal implementation** — `tests/ab/lib/ranking_packet.py`

```python
#!/usr/bin/env python3
"""ranking_packet — blinded side-by-side ranking packets for the orchestration A/B.

Pure-stdlib. Presents bodyText ONLY (never the JSONL meta), normalises arm tells
against rules derived from real output (tests/ab/lib/arm_tells.json), and seals a
per-PR arm→label(A/B) randomisation from a recorded seed. Refuses to build without a
pre-registration criteria file present — blinding without a timestamped honesty
anchor is worthless. NEVER calls an LLM.
"""
import argparse
import glob
import json
import os
import random
import re


def normalise_arm_tells(body_text, rules):
    out = body_text
    for rule in rules:
        out = re.sub(rule["pattern"], rule["replace"], out)
    return out


def _strip_provenance(md_text):
    lines = md_text.split("\n")
    if lines and lines[0].startswith("<!-- plugin_sha:"):
        lines = lines[1:]
    return "\n".join(lines).strip()


def _arm_runs(arm_dir):
    runs = []
    for trial in sorted(glob.glob(os.path.join(arm_dir, "trial-*"))):
        v = "INCONCLUSIVE"
        vp = os.path.join(trial, "verdict.txt")
        if os.path.isfile(vp):
            with open(vp, encoding="utf-8") as fh:
                v = fh.read().strip() or "INCONCLUSIVE"
        body = ""
        mp = os.path.join(trial, "durable-log.md")
        if os.path.isfile(mp):
            with open(mp, encoding="utf-8") as fh:
                body = _strip_provenance(fh.read())
        runs.append({"verdict": v, "body": body})
    return runs


_ORDER = ("APPROVE", "REQUEST_CHANGES", "INCONCLUSIVE")


def _modal(runs):
    dist = {}
    for r in runs:
        dist[r["verdict"]] = dist.get(r["verdict"], 0) + 1
    if not dist:
        return "INCONCLUSIVE"
    best = max(dist.values())
    for v in _ORDER:
        if dist.get(v, 0) == best:
            return v
    return max(dist, key=dist.get)


def modal_run_body(arm_dir):
    runs = _arm_runs(arm_dir)
    if not runs:
        return ""
    modal = _modal(runs)
    for r in runs:                    # first run matching the modal verdict
        if r["verdict"] == modal:
            return r["body"]
    return runs[0]["body"]


def seal_assignment(pr_slugs, seed):
    rng = random.Random(seed)
    out = {}
    for slug in pr_slugs:
        if rng.random() < 0.5:
            out[slug] = {"classic": "A", "panel": "B"}
        else:
            out[slug] = {"classic": "B", "panel": "A"}
    return out


def build_packets(run_dir, seed, rules_path, criteria_present):
    if not criteria_present and not os.path.isfile(os.path.join(run_dir, "criteria.md")):
        raise RuntimeError("refusing to build packets: pre-registration criteria.md absent")
    with open(rules_path, encoding="utf-8") as fh:
        rules = json.loads(fh.read())

    pr_slugs = sorted(
        e for e in os.listdir(run_dir)
        if os.path.isdir(os.path.join(run_dir, e, "classic"))
        and os.path.isdir(os.path.join(run_dir, e, "panel"))
    )
    assignment = seal_assignment(pr_slugs, seed)
    packets_dir = os.path.join(run_dir, "packets")
    os.makedirs(packets_dir, exist_ok=True)
    with open(os.path.join(packets_dir, "seed.json"), "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"seed": seed, "assignment": assignment}, indent=2) + "\n")

    for slug in pr_slugs:
        pr_out = os.path.join(packets_dir, slug)
        os.makedirs(pr_out, exist_ok=True)
        for arm, label in assignment[slug].items():
            body = modal_run_body(os.path.join(run_dir, slug, arm))
            with open(os.path.join(pr_out, f"{label}.md"), "w", encoding="utf-8") as fh:
                fh.write(normalise_arm_tells(body, rules) + "\n")


def main(argv=None):
    p = argparse.ArgumentParser(prog="ranking_packet")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--seed", type=int, required=True)
    p.add_argument("--rules", default=os.path.join(os.path.dirname(__file__), "arm_tells.json"))
    args = p.parse_args(argv)
    build_packets(args.run_dir, args.seed, args.rules, criteria_present=False)
    print(f"packets written under {os.path.join(args.run_dir, 'packets')}")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd tests/python && python3 -m unittest test_ranking_packet -v`
Expected: all `ranking_packet` tests PASS.

- [ ] **Step 6: Commit**

```bash
git add tests/ab/lib/ranking_packet.py tests/ab/lib/arm_tells.json tests/python/test_ranking_packet.py
git commit -m "feat(ab): blinded ranking packets + arm-tell normalisation (rules from live capture)"
```

---

### Task 7: `ranking_unblind.py` — join rankings → arms, apply the decision rule

**Files:**
- Create: `tests/ab/lib/ranking_unblind.py`
- Create: `tests/python/test_ranking_unblind.py`

**Interfaces:**
- Consumes: `packets/seed.json` (the sealed assignment), `differential.json` (Task 5 output), a `rankings.json`
  the maintainer fills in, and `criteria.md`.
- `rankings.json` schema (maintainer-authored): `{"pr-slug": {"winner": "A"|"B"|"tie", "reason": "<one line>"}}`.
- Produces:
  - `unblind(rankings, assignment) -> dict` — maps each PR's `A/B` winner back to `classic/panel/tie`.
  - `material_prs(differential) -> list[str]` — PRs whose two reports materially differ (NOT near-identical): a PR
    is material iff its finding_delta has any `dropped`/`added`/`tier_moved` OR the modal verdicts differ. Ties on
    near-identical PRs are excluded from the ranking denominator (spec rule 1).
  - `apply_decision_rule(unblinded, differential) -> dict` — evaluates the three pre-registered conditions and
    returns `{"rule1_ranking": bool, "rule2_no_regression": bool, "rule3_cost": <"pending"|bool>, "flip": bool,
    "contradictions": [...], "detail": {...}}`:
    - **Rule 1:** panel wins-or-ties ≥ ⅔ of *material* PRs.
    - **Rule 2:** zero PRs where panel dropped a classic high-value finding AND the blind ranking did not prefer
      panel on that PR (fills each PR's `contradiction` flag).
    - **Rule 3:** cost — left `"pending"` here (cost_model comparison is wired in Task 8's report step); the
      function accepts an optional `cost_non_worse: bool|None` and threads it through.
    - `flip` = rule1 AND rule2 AND (rule3 is True).
  - CLI: `ranking_unblind.py --run-dir <dir> [--cost-non-worse true|false]` — reads
    `packets/seed.json`, `differential.json`, `rankings.json`; writes `unblinded.json`.

- [ ] **Step 1: Write the failing test** — `tests/python/test_ranking_unblind.py`

```python
import pathlib
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "ab" / "lib"))

import ranking_unblind  # noqa: E402


def _diff(dropped=0, added=0, verdict_differ=False):
    return {
        "classic_modal_verdict": "REQUEST_CHANGES",
        "panel_modal_verdict": "APPROVE" if verdict_differ else "REQUEST_CHANGES",
        "finding_delta": {"dropped": [{"x": 1}] * dropped, "added": [{"y": 1}] * added,
                          "retained": [], "tier_moved": []},
        "noise_dominated": False, "contradiction": None,
    }


class UnblindTest(unittest.TestCase):
    def test_unblind_maps_labels_back_to_arms(self):
        assignment = {"pr-1": {"classic": "A", "panel": "B"}}
        rankings = {"pr-1": {"winner": "B", "reason": "clearer"}}
        out = ranking_unblind.unblind(rankings, assignment)
        self.assertEqual(out["pr-1"]["winner_arm"], "panel")


class MaterialTest(unittest.TestCase):
    def test_near_identical_pr_is_immaterial(self):
        diff = {"prs": {"pr-1": _diff(), "pr-2": _diff(dropped=1)}}
        self.assertEqual(ranking_unblind.material_prs(diff), ["pr-2"])


class DecisionRuleTest(unittest.TestCase):
    def test_flip_when_panel_wins_material_and_no_regression(self):
        diff = {"prs": {"pr-1": _diff(added=1), "pr-2": _diff(added=1), "pr-3": _diff(added=1)}}
        assignment = {p: {"classic": "A", "panel": "B"} for p in ("pr-1", "pr-2", "pr-3")}
        rankings = {p: {"winner": "B", "reason": "r"} for p in ("pr-1", "pr-2", "pr-3")}
        unbl = ranking_unblind.unblind(rankings, assignment)
        res = ranking_unblind.apply_decision_rule(unbl, diff, cost_non_worse=True)
        self.assertTrue(res["rule1_ranking"])
        self.assertTrue(res["rule2_no_regression"])
        self.assertTrue(res["flip"])

    def test_no_flip_when_panel_drops_finding_and_ranking_did_not_prefer_it(self):
        diff = {"prs": {"pr-1": _diff(dropped=1)}}
        assignment = {"pr-1": {"classic": "A", "panel": "B"}}
        rankings = {"pr-1": {"winner": "A", "reason": "classic caught more"}}  # preferred classic
        unbl = ranking_unblind.unblind(rankings, assignment)
        res = ranking_unblind.apply_decision_rule(unbl, diff, cost_non_worse=True)
        self.assertFalse(res["rule2_no_regression"])
        self.assertFalse(res["flip"])
        self.assertEqual(len(res["contradictions"]), 1)

    def test_cost_pending_blocks_flip(self):
        diff = {"prs": {"pr-1": _diff(added=1)}}
        assignment = {"pr-1": {"classic": "A", "panel": "B"}}
        rankings = {"pr-1": {"winner": "B", "reason": "r"}}
        unbl = ranking_unblind.unblind(rankings, assignment)
        res = ranking_unblind.apply_decision_rule(unbl, diff, cost_non_worse=None)
        self.assertEqual(res["rule3_cost"], "pending")
        self.assertFalse(res["flip"])
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tests/python && python3 -m unittest test_ranking_unblind -v`
Expected: FAIL — `No module named 'ranking_unblind'`.

- [ ] **Step 3: Write minimal implementation** — `tests/ab/lib/ranking_unblind.py`

```python
#!/usr/bin/env python3
"""ranking_unblind — join blind rankings to arm labels + the mechanical differential,
then apply the pre-registered decision rule. Pure-stdlib. NEVER calls an LLM. The
maintainer override of the 2/3 threshold, if used, must be logged by the caller
against this on-record value (the "keep me honest" contract).
"""
import argparse
import json
import os


def unblind(rankings, assignment):
    out = {}
    for slug, rk in rankings.items():
        amap = assignment[slug]                       # {"classic":"A","panel":"B"}
        label_to_arm = {v: k for k, v in amap.items()}
        winner = rk["winner"]
        winner_arm = "tie" if winner == "tie" else label_to_arm[winner]
        out[slug] = {"winner_arm": winner_arm, "reason": rk.get("reason", "")}
    return out


def _is_material(pr_diff):
    d = pr_diff["finding_delta"]
    if d["dropped"] or d["added"] or d["tier_moved"]:
        return True
    return pr_diff["classic_modal_verdict"] != pr_diff["panel_modal_verdict"]


def material_prs(differential):
    return [slug for slug, d in sorted(differential["prs"].items()) if _is_material(d)]


def apply_decision_rule(unblinded, differential, cost_non_worse=None):
    material = material_prs(differential)
    # Rule 1: panel wins-or-ties >= 2/3 of material PRs.
    wins_ties = sum(1 for slug in material
                    if unblinded.get(slug, {}).get("winner_arm") in ("panel", "tie"))
    rule1 = (wins_ties >= (2 / 3) * len(material)) if material else False

    # Rule 2: no PR where panel dropped a high-value finding AND ranking did not prefer panel.
    contradictions = []
    for slug, d in differential["prs"].items():
        dropped = bool(d["finding_delta"]["dropped"])
        preferred_panel = unblinded.get(slug, {}).get("winner_arm") == "panel"
        contradiction = dropped and not preferred_panel
        d["contradiction"] = contradiction
        if contradiction:
            contradictions.append(slug)
    rule2 = len(contradictions) == 0

    rule3 = "pending" if cost_non_worse is None else bool(cost_non_worse)
    flip = bool(rule1 and rule2 and rule3 is True)
    return {
        "rule1_ranking": rule1,
        "rule2_no_regression": rule2,
        "rule3_cost": rule3,
        "flip": flip,
        "contradictions": contradictions,
        "detail": {"material_prs": material, "material_wins_ties": wins_ties},
    }


def main(argv=None):
    p = argparse.ArgumentParser(prog="ranking_unblind")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--cost-non-worse", choices=["true", "false"], default=None)
    args = p.parse_args(argv)

    rd = args.run_dir
    with open(os.path.join(rd, "packets", "seed.json"), encoding="utf-8") as fh:
        assignment = json.loads(fh.read())["assignment"]
    with open(os.path.join(rd, "differential.json"), encoding="utf-8") as fh:
        differential = json.loads(fh.read())
    with open(os.path.join(rd, "rankings.json"), encoding="utf-8") as fh:
        rankings = json.loads(fh.read())

    cost = None if args.cost_non_worse is None else (args.cost_non_worse == "true")
    unbl = unblind(rankings, assignment)
    res = apply_decision_rule(unbl, differential, cost_non_worse=cost)
    out = {"unblinded": unbl, "decision": res}
    with open(os.path.join(rd, "unblinded.json"), "w", encoding="utf-8") as fh:
        fh.write(json.dumps(out, indent=2) + "\n")
    print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tests/python && python3 -m unittest test_ranking_unblind -v`
Expected: all `ranking_unblind` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/ranking_unblind.py tests/python/test_ranking_unblind.py
git commit -m "feat(ab): ranking unblind + pre-registered decision rule"
```

---

### Task 8: Pre-registration criteria capture + Phase A pilot gate

**Files:**
- Modify: `tests/ab/run.sh` (fill `_ab_orch_capture_criteria`; add `_ab_orch_pilot_gate`)
- Modify: `tests/lib/test_ab_orchestration.sh`

**Interfaces:**
- `_ab_orch_capture_criteria <phase> <timestamp>` — if `$_AB_RUN_DIR/criteria.md` or
  `$CLAUDE_TEMP_DIR/criteria.md` exists, copy it into the run dir AND mirror it to the durable honesty-anchor
  location `$HOME/.claude/code-review-suite/ab-criteria/<timestamp>-<phase>-criteria.md` (survives run-dir prune).
  If neither exists, print a hard-stop instruction telling the operator to write the criteria file BEFORE any
  ranking, and (pilot/full) exit non-zero so no run proceeds without a timestamped anchor.
- `_ab_orch_pilot_gate <run_dir>` — after a pilot sweep, run `differential.py --run-dir`, compute the min
  within-arm stability across PRs (the variance floor), and log the gate decision to
  `$run_dir/pilot-gate.log`: AUTO-PROCEED only when every PR's `within_arm_stability >= 0.8` AND no
  `HARVEST_MISS` markers exist; otherwise HARD-STOP with the reason. The gate always logs which path it took and
  why (spec §"Pilot gate").

- [ ] **Step 1: Write the failing test** — append to `tests/lib/test_ab_orchestration.sh`

```bash
test_orch_criteria_mirrored_to_durable_location() {
    local tmp run anchor
    tmp=$(mktemp -d); run="$tmp/run"; mkdir -p "$run"
    printf 'catches real bugs > low FP\n' > "$run/criteria.md"
    ( set -euo pipefail
      _AB_RUN_DIR="$run"
      HOME="$tmp/home"; mkdir -p "$HOME"
      source "$REPO_ROOT/tests/ab/run.sh" 2>/dev/null || true
      _ab_orch_capture_criteria pilot 20260710T000000Z )
    anchor="$tmp/home/.claude/code-review-suite/ab-criteria/20260710T000000Z-pilot-criteria.md"
    if [[ -f "$anchor" ]]; then
        pass "orch: criteria mirrored to durable anchor location"
    else
        fail "orch: criteria mirrored to durable anchor location" "missing $anchor"
    fi
    rm -rf "$tmp"
}

test_orch_pilot_gate_auto_proceeds_on_stable_low_variance() {
    local tmp run
    tmp=$(mktemp -d); run="$tmp/run"
    # two arms, all runs agree → stability 1.0, no HARVEST_MISS.
    local arm i
    for arm in classic panel; do
        for i in 1 2 3; do
            local td; td=$(printf '%s/pr-1/%s/trial-%03d' "$run" "$arm" "$i"); mkdir -p "$td"
            printf 'REQUEST_CHANGES\n' > "$td/verdict.txt"
            printf '{"type":"meta","orchestration_mode":"%s"}\n' "$arm" > "$td/durable-log.jsonl"
        done
    done
    ( set -euo pipefail
      _AB_RUN_DIR="$run"; source "$REPO_ROOT/tests/ab/run.sh" 2>/dev/null || true
      _ab_orch_pilot_gate "$run" )
    if grep -q 'AUTO-PROCEED' "$run/pilot-gate.log"; then
        pass "orch: pilot gate auto-proceeds on stable low-variance pilot"
    else
        fail "orch: pilot gate auto-proceeds on stable low-variance pilot" "$(cat "$run/pilot-gate.log" 2>&1)"
    fi
    rm -rf "$tmp"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep 'orch: criteria\|orch: pilot gate'`
Expected: FAIL — helpers not implemented.

- [ ] **Step 3: Write minimal implementation** — in `tests/ab/run.sh`

```bash
_ab_orch_capture_criteria() {
    local phase="$1" timestamp="$2"
    local src=""
    if [[ -f "$_AB_RUN_DIR/criteria.md" ]]; then
        src="$_AB_RUN_DIR/criteria.md"
    elif [[ -n "${CLAUDE_TEMP_DIR:-}" && -f "$CLAUDE_TEMP_DIR/criteria.md" ]]; then
        src="$CLAUDE_TEMP_DIR/criteria.md"
        cp "$src" "$_AB_RUN_DIR/criteria.md"
    fi
    if [[ -z "$src" ]]; then
        echo "orchestration: NO pre-registration criteria.md found." >&2
        echo "  Write your 'what is a better review' criteria to $_AB_RUN_DIR/criteria.md" >&2
        echo "  BEFORE any run — it is the timestamped honesty anchor. Refusing to proceed." >&2
        exit 1
    fi
    # Mirror to a durable location outside the run dir (survives scratch prune).
    local anchor_dir="$HOME/.claude/code-review-suite/ab-criteria"
    mkdir -p "$anchor_dir"
    cp "$_AB_RUN_DIR/criteria.md" "$anchor_dir/${timestamp}-${phase}-criteria.md"
}

_ab_orch_pilot_gate() {
    local run_dir="$1"
    local log="$run_dir/pilot-gate.log"
    local diff_json="$run_dir/differential.json"
    python3 "$SCRIPT_DIR/lib/differential.py" --run-dir "$run_dir" --out "$diff_json" >/dev/null

    local min_stab; min_stab=$(jq -r '[.prs[].within_arm_stability] | min // 0' "$diff_json")
    local harvest_misses; harvest_misses=$(find "$run_dir" -name HARVEST_MISS | wc -l | tr -d ' ')

    # bash has no float compare; use awk. Threshold 0.8.
    local stable; stable=$(awk -v s="$min_stab" 'BEGIN{print (s>=0.8)?"1":"0"}')
    if [[ "$stable" == "1" && "$harvest_misses" == "0" ]]; then
        {
            echo "AUTO-PROCEED"
            echo "reason: min within-arm stability=$min_stab (>=0.8), harvest_misses=0"
            echo "next: size Phase B N from observed variance (higher noise -> more runs/arm)"
        } > "$log"
    else
        {
            echo "HARD-STOP"
            echo "reason: min within-arm stability=$min_stab (need >=0.8), harvest_misses=$harvest_misses"
            echo "action: maintainer review before Phase B — check blinding held + harvest complete"
        } > "$log"
    fi
    cat "$log" >&2
}
```

Wire `_ab_orch_pilot_gate "$_AB_RUN_DIR"` into `_ab_run_orchestration` at the end of the loop when
`phase == pilot`.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep 'orch: criteria\|orch: pilot gate'`
Expected: both PASS.

- [ ] **Step 5: Full suite green**

Run: `bash tests/run.sh`
Expected: all structural tests PASS (including the housekeeper-engine gate that runs `unittest discover`, which now
also discovers `test_differential.py`, `test_ranking_packet.py`, `test_ranking_unblind.py`).

- [ ] **Step 6: Commit**

```bash
git add tests/ab/run.sh tests/lib/test_ab_orchestration.sh
git commit -m "feat(ab): pre-registration criteria anchor + Phase A pilot gate"
```

---

## Phase execution (organic, not automated — after the harness lands)

These are operator steps, gated by the harness above. They are NOT unit-testable (real Bedrock, real merged PRs,
human ranking) and are recorded here so the executor knows the end-to-end flow.

1. **Corpus selection (spec §"Corpus selection procedure").** Pick merged PRs; confirm none set `orchestration.*`
   at the repo layer; stratify (Phase A: diff-size × verdict + ≥1 hard PR); pin SHAs into `corpus.yaml`.
2. **Write `criteria.md`** (the pre-registration honesty anchor) BEFORE running anything.
3. **Phase A pilot:** `tests/ab/run.sh --mode orchestration --corpus <corpus.yaml> --arms "classic panel:3"
   --trials 3 --phase pilot`. Inspect `pilot-gate.log`. On AUTO-PROCEED, size Phase B N from observed variance; on
   HARD-STOP, review blinding + harvest by hand.
4. **Build packets + rank:** `ranking_packet.py --run-dir <dir> --seed <n>`; rank each PR's `A.md`/`B.md`
   side-by-side into `rankings.json`; then `ranking_unblind.py --run-dir <dir> --cost-non-worse <true|false>`
   (cost from `cost_model.py --runs <dir>` over the harvested `stream.jsonl`).
5. **Phase B full sweep** with the sized corpus + N. Produce the differential + rankings + decision → the
   flip/don't-flip recommendation, closing #63 and #65.

## Housekeeping (standing repo rule)

Run the freshness / dependency / GitHub-Actions / runner check during planning and propose any stale-dep work as a
**separate small PR landing first**, kept out of this feature PR:

- [ ] Run `code-review-suite:housekeeper-reviewer` (or `trivy config`) over the repo. The only CI surface is
  `.github/workflows/tests.yml` (already on `ubuntu-24.04`, `actions/checkout` pinned by SHA `@v6.0.2`) and
  `gitleaks.yml`. There is no package manifest (no `package.json` / `*.csproj` / `requirements.txt` at repo root),
  so the freshness surface is Actions + runners only. If the housekeeper flags anything, land it as a separate PR
  before this feature PR.

## Self-review checklist (completed during planning)

- **Spec coverage:** arm toggle (Task 1) ✓; durable-log harvest (Task 2) ✓; `--mode orchestration` dispatcher +
  no-post safety via merged-PR preflight (Task 3) ✓; verdict agreement within/cross-arm (Task 4) ✓; finding-set
  delta retention/additions/tier-move + noise-dominated flag (Task 5) ✓; blinding = bodyText-only + arm-tell
  normalisation + sealed A/B + pre-registration refusal (Task 6) ✓; unblind + decision rule + contradiction flag
  (Task 7) ✓; pre-registration durable anchor + pilot gate with logged path (Task 8) ✓; cost reuse via
  `cost_model.py` over harvested `stream.jsonl` (Task 3 stream capture + Phase execution step 4) ✓; wall-clock via
  `timing.json` (Task 3) ✓.
- **Data-blocked item handled without a placeholder:** arm-tell rules are produced by a real capture step (Task 6
  Step 1) into `arm_tells.json`; the normaliser is rules-file-driven and its test checks the *mechanism* (no
  `orchestration_mode` leak, deterministic-given-seed), which is knowable now.
- **Type consistency:** finding dicts carry `{tier, domain, severity, confidence, file, line, description,
  suggested_fix, verdict_relevant}` throughout (matches `review-core.mjs` schema); `findings_match` signature is
  stable across Tasks 5/6; `seal_assignment` / `unblind` share the `{arm: label}` map shape; the run-dir layout in
  "File structure" is the single source consumed by Tasks 4-8.
- **Contradiction flag ownership:** `differential.per_pr_differential` emits `contradiction: None`;
  `ranking_unblind.apply_decision_rule` fills it (it needs the ranking). Documented in both places so no task
  computes it twice.
