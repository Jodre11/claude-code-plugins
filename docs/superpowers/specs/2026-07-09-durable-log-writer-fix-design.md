# Durable full-log writer — reliability fix design

**Date:** 2026-07-09
**Plugin:** `code-review-suite`
**Tracking:** prerequisite for the panel-review redesign A/B (unblocks GitHub #63
phase-efficacy analysis, which consumes the durable log as its data source). Spec #1 of
the 3-spec decomposition of the panel-review build phase (the other two — panel Stage 2/3
build, and the old-vs-new A/B — are separate later designs).

## Problem

The per-cog durable full log (`orchestration.full_log`, designed 2026-06-19) **never
writes**, despite being enabled. Confirmed empirically:

- `~/.claude/code-review.toml` sets `full_log = true` (mtime 2026-06-19).
- Many PRs have been reviewed through the pipeline since (e.g. #82–#86).
- `$HOME/.claude/code-review-suite/logs/` **does not exist** — not one durable log across
  ~19 days of active reviewing.

The failure is **host-side, not workflow-side.** The workflow (`review-core.mjs`) correctly
populates `bundle.log` on both the PR and local paths (`finalizeBundle`, `:433` and `:448`;
`buildLogPayload`, `:700`). The gap is that writing the log to disk is **host-skill prose**
— "Step 7a" in `skills/review-gh-pr/SKILL.md:1064` and `commands/pre-review.md:959` — and
it must be, because the workflow runs in a sandbox with no filesystem access (grep confirms
`review-core.mjs` never touches `fs`). The workflow *returns* `bundle.log` as data; the host
model, executing SKILL.md, is the only actor that holds the data **and** has filesystem
access.

**Root cause (systematic, not a one-off):** Step 7a is a multi-step prose block positioned
*after* report presentation — the natural "end" of the task, where model attention has
already dropped. This is the standing "models overlook tuning hooks" failure mode: a buried
post-completion step with no forcing function is reliably skipped. 19 days of zero logs with
the flag on is the evidence.

### Why not a hook that removes the host entirely (rejected)

A `PostToolUse(Workflow)` hook cannot fix this: the Workflow tool is **asynchronous** — it
returns a task-id at launch and the sealed bundle arrives later via task-notification. A
PostToolUse hook fires at *launch* and never sees `bundle.log`. Separately, `bundle.log.meta`
carries `base`/`head_sha`/`empty_tree_mode`/`path_scope` (`review-core.mjs:142–147`) but
**not** the repo-slug or PR number needed to name the file — those live host-side in
`$ARGUMENTS`. So the only actor with both the data and the filename context is the host,
after the async workflow completes. Fully removing the host (having the workflow write the
log via a final Bash-capable agent step, "approach A′") was judged more invasive with an
unverified sandbox-filesystem story, and deferred.

## Goal

Make the durable log write **reliably**, respecting the async-workflow boundary, via three
coordinated moves:

1. **Reorder** the write to the earliest, highest-attention point — immediately after the
   bundle returns, *before* the model is absorbed in report presentation / comment
   reconciliation.
2. **Replace the fragile multi-step prose with one deterministic, unit-tested `bin/` script
   call** — the same "fragile mechanics belong in tested shell, never LLM-improvised prose"
   principle already applied to `bin/review-worktree`.
3. **Add a Stop-hook forcing function** that converts a silent skip into a loud,
   self-correcting failure: if a review ran this session (breadcrumb present) but no durable
   log was written for its head sha, the Stop hook blocks turn-end with a corrective message.

The three moves attack the three layers of the failure: attention (reorder), mechanics
(script), and the residual "model still has to choose to run it" (hook).

## Non-goals

- **No change to what is captured.** `bundle.log` shape (`meta` + `cogs` + `findings`) is
  unchanged; the workflow side is correct and untouched.
- **No change to the `full_log` default.** Stays OFF; two-layer TOML resolution unchanged.
- **No approach A′** (workflow self-writes the log). Deferred; out of scope.
- **No replay/analysis tooling.** Downstream of #63; this spec only makes the write reliable.
- **No live-capture automated test.** Shape + reliability are unit-tested; the end-to-end
  "turn it on and eyeball the file" remains the organic step.

## Architecture (data flow)

```
review-core.mjs (sandbox, no FS)
  └─ returns bundle { verdict, bodyText, comments, log }   ← async, via task-notification
        │
        ▼  host receives completed bundle
Step 3.6 (NEW position — earliest, high-attention):
  resolve full_log (two-layer TOML, unchanged)
  if true and bundle.log present:
    1. Write bundle.log JSON → $CLAUDE_TEMP_DIR/bundle-log.json      (also the breadcrumb)
    2. resolve $PLUGIN_SHA (git rev-parse --short, else "unknown")
    3. run bin/durable-log-write --repo-slug … --ident … --sha …
           --plugin-sha … --payload … --tokens … [--out-dir …]
        │
        ▼  deterministic, unit-tested shell
   writes  $HOME/.claude/code-review-suite/logs/{repo-slug}/{ident}-{sha}.md
           $HOME/.claude/code-review-suite/logs/{repo-slug}/{ident}-{sha}.jsonl
        │
        ▼  turn ends
Stop hook (hooks.json):
  if breadcrumb ($CLAUDE_TEMP_DIR/bundle-log.json) present
     AND no durable log exists for its meta.head_sha
  → block turn-end with "durable log not written — run bin/durable-log-write"
  else → no-op (inert on every non-review turn)
```

The hot path is unchanged; config resolution stays in prose (host-context, not fragile
mechanics). The script assumes the decision is already made and just writes.

The diagram shows the breadcrumb at `$CLAUDE_TEMP_DIR/bundle-log.json` for the *host's* write;
the Stop hook cannot read `$CLAUDE_TEMP_DIR` (it is not exported to hook subprocesses), so the
breadcrumb path/keying the hook actually uses is the session-scoped, disarmable, self-expiring
contract specified as a **hard requirement** in Component 3 — not a literal
`$CLAUDE_TEMP_DIR` read.

## Component 1 — `bin/durable-log-write`

Shell executable, `chmod +x`, `#!/usr/bin/env bash`, `set -euo pipefail`, 4-space indent —
matching `bin/review-worktree`.

**Invocation** (all values are host-context, already held at the call site):

```
durable-log-write \
  --repo-slug   <owner-name>            # reviewed repo owner/name, / → -
  --ident       <pr-N | branch-slug>    # PR mode: pr-$ARGUMENTS; local: slugified branch
  --sha         <12-char head sha>
  --plugin-sha  <marketplace short-sha | unknown>
  --payload     <path to bundle.log JSON the host Wrote>
  --tokens      <path to tokens.jsonl>  # optional; per-phase token rows
  --ts          <ISO-8601 UTC>          # optional; script stamps `date -u …` if omitted
  --out-dir     <base logs dir>         # optional; defaults to $HOME/.claude/code-review-suite/logs
```

`--out-dir` exists so the test suite writes to a temp dir (mirrors `review-worktree`'s
`[tempRoot]`); production omits it and gets the `$HOME` default. `CLAUDE_TEMP_DIR` is never
env-inferred — the host passes concrete paths (the `review-worktree` lesson: `CLAUDE_TEMP_DIR`
is not exported into Bash subprocesses).

**Behaviour:**

1. **Validate-or-die** (Phase 3.1c pattern): `--payload` must exist and parse as JSON with a
   `bodyText` key. Otherwise print a diagnostic to stderr and `exit 1`. A missing/malformed
   payload is a hard error, never a silent empty write.
2. `mkdir -p "<out-dir>/<repo-slug>"`.
3. Write `<ident>-<sha>.md`: line 1 is the provenance comment
   `<!-- plugin_sha: <plugin-sha> | ts: <ts> -->`, then `payload.bodyText` **verbatim**.
4. Write the sibling `<ident>-<sha>.jsonl`, one JSON object per line, **assembled with
   `jq -c`** (never shell string-building) in this fixed order:
   - `meta` line: `payload.meta` (`base`/`head_sha`/`empty_tree_mode`/`path_scope`) plus
     `plugin_sha` and `ts`, `type:"meta"`.
   - one `cog` line per `payload.cogs[]` entry, verbatim, `type:"cog"`.
   - one `finding` line per `payload.findings[]` entry, `type:"finding"`.
   - the per-phase token rows from `--tokens` appended verbatim (skip if the file is absent
     or empty). **Token rows are best-effort:** a malformed line in `--tokens` is skipped
     (warn to stderr), never fatal — unlike `--payload`, a junk `--tokens` file must not
     `exit 1` or abort the write (mind `set -euo pipefail`: guard the per-line `jq` so a
     parse failure doesn't kill the script).
   - `payload.cogs` absent (lightweight path) → meta + findings + tokens only.
5. `exit 0`.

**Overwrite semantics:** re-reviewing the same PR/branch at an unchanged head sha writes to
the same `<ident>-<sha>.{md,jsonl}` pair, overwriting the prior pair. This is **intentional
and idempotent** — the latest review of a given sha wins, and it keeps the disarm/gate logic
simple (one canonical file per sha). A new commit yields a new sha and thus a new file.

**Determinism / correctness win:** emitting the `.jsonl` via `jq -c` guarantees each line is
valid JSON regardless of finding text containing quotes or newlines. The current prose
hand-assembles JSONL and would silently corrupt the file on any finding text with a newline.

## Component 2 — prose changes at the two call sites

Both `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md` currently carry a 4-step
Step 7a block (`SKILL.md:1072–1119`, `pre-review.md:972–1014`). Both are **removed** and
replaced by a shorter block **relocated to a new Step 3.6** (immediately after the bundle
returns at Step 3.5, before posting/reconciliation/presentation):

> **Step 3.6: Durable full log.** Resolve `orchestration.full_log` (two-layer TOML —
> unchanged, verbatim from today). If `false`, skip. If `true` and `bundle.log` is present:
> 1. `Write` the `bundle.log` object to `$CLAUDE_TEMP_DIR/bundle-log.json`.
> 2. Resolve `$PLUGIN_SHA` (`git -C {marketplace-dir} rev-parse --short HEAD`, else `unknown`).
> 3. Run **one** command:
>    `"${CLAUDE_PLUGIN_ROOT}"/bin/durable-log-write --repo-slug <…> --ident <…> --sha <…>
>    --plugin-sha <…> --payload $CLAUDE_TEMP_DIR/bundle-log.json --tokens $CLAUDE_TEMP_DIR/tokens.jsonl`

The **only** per-site difference is `--ident`: `pr-$ARGUMENTS` (SKILL.md) vs the slugified
`git rev-parse --abbrev-ref HEAD` (pre-review). The shared body is otherwise identical.

**Sync note:** the two blocks are **not** under byte-parity sync today (they already differ
by the `pr-…`/branch line), and `includes/review-pipeline.md` does **not** carry Step 7a — so
this change touches exactly two files and breaks no existing `test_sync_notes.sh` assertion.
If a shared sub-block is worth pinning, add a new sync assertion rather than forcing full
byte-parity across the intentional `--ident` difference.

## Component 3 — Stop-hook forcing function

Add a `Stop` entry to `hooks/hooks.json` (alongside the existing `PreToolUse(Agent)`),
pointing at a new `hooks/durable-log-gate.sh`.

**Constraint:** a Stop hook fires on **every** turn end and does **not** receive
`CLAUDE_TEMP_DIR` (not exported to hook subprocesses — same as the existing
`reviewer-dispatch-observe.sh`, which falls back to `${TMPDIR:-/tmp}`). So the breadcrumb and
the hook must agree on a path the hook can find without that env var.

**Breadcrumb:** the `bundle-log.json` the host Writes in step 1 is the breadcrumb — its
existence means "a review produced a durable-log-eligible bundle this session", and its
`meta.head_sha` names the expected log file. The hook needs to locate it without
`CLAUDE_TEMP_DIR`.

**HARD REQUIREMENT — the breadcrumb contract must be session-scoped, disarmable, and
self-expiring.** A naïve `${TMPDIR:-/tmp}/claude-*/bundle-log.json` glob is a
**cross-session false-block landmine** and is rejected as-is: session A runs a review, writes
the breadcrumb, then dies (or the write errors) before the log is written; A's breadcrumb is
now stranded in `/tmp/claude-A/`; later an unrelated session B ends a turn, its Stop hook
globs the shared tree, finds A's breadcrumb with no matching log, and **blocks B on a review B
never ran and cannot fix** — a permanent trap until someone hand-clears `/tmp`. The plan MUST
therefore satisfy all three of:

1. **Session-scoping** — the hook judges only *its own* session's breadcrumb, never another
   session's. (The Stop hook payload carries the session id on stdin; the breadcrumb path or
   its contents must key off the same id so a foreign breadcrumb is invisible.)
2. **Disarm** — a successful `durable-log-write` (or an explicit skip when `full_log=false`)
   removes/neutralises the breadcrumb so the very next turn-end is a clean no-op. The gate must
   never fire twice for one write.
3. **Self-expiry / bounded fallback** — a stranded breadcrumb from a crashed session can never
   block indefinitely (e.g. ignore breadcrumbs older than a short TTL, and treat an
   unreadable/foreign one as absent). A dead session must not be able to wedge a live one.

The concrete path/keying mechanism is the plan-level decision; the spec fixes the *behaviour*
and these three invariants as non-negotiable.

**Sha-length reconciliation:** the durable filename uses the **12-char** sha, but
`bundle.log.meta.head_sha` is the **full 40-char** sha (`review-core.mjs:144`). The hook's
"does a log exist for this head_sha" check must compare on a normalised length (truncate
`meta.head_sha` to 12, or match on prefix) — a naïve full-vs-12 string compare never matches
and the gate would block on **every** review. Fix this explicitly in the hook.

**Hook behaviour:**
- No breadcrumb found → **no-op, exit 0** (the common case: every non-review turn is inert).
- Breadcrumb found, and a durable log file exists matching its `meta.head_sha` (normalised to
  the 12-char filename form) under `$HOME/.claude/code-review-suite/logs/**` → **pass, exit 0**
  (the write happened).
- Breadcrumb found, no matching durable log → **block** (non-zero / decision `block`) with a
  message instructing the host to run `bin/durable-log-write`. This makes a skip
  self-correcting: the model cannot cleanly end the turn having skipped the write.
- Cheap: a stat/glob check, `timeout` small (match the existing hook's `timeout: 5`).

**Residual risk (stated honestly):** this is *close to* "impossible to ignore" but not a
mathematical guarantee — the model must still execute step 1 (Write the breadcrumb) for the
gate to arm. If the model skips the *entire* Step 3.6 including the breadcrumb Write, the
gate never arms. Reorder-to-high-attention is what mitigates *that* residual; the hook
catches the far more likely "did the Write, skipped the script call" case. Fully removing the
model is approach A′, explicitly deferred.

## Testing

Shell suite (`tests/lib/`, sourced by `tests/run.sh`), matching existing patterns.

**Script unit tests (`tests/lib/test_durable_log_write.sh`):**
- fixture `bundle.log` → `.md` first line is the provenance comment, remainder is `bodyText`
  verbatim.
- `.jsonl` line order is meta → cogs → findings → tokens; **every line is valid JSON**
  (`jq -e . ` per line).
- **finding text containing a newline and a double-quote survives** as one valid JSON line
  (the correctness win over the prose version — this is the highest-value assertion).
- `cogs` absent → meta + findings + tokens only (lightweight path).
- `--tokens` file absent → no token rows, still exits 0.
- **`--tokens` file present but containing a malformed line → the bad row is skipped, the
  good rows still land, and the script still `exit 0`** (best-effort tokens; guards the
  `set -euo pipefail` regression).
- malformed / missing `--payload` → `exit 1`, nothing written.
- `--ident pr-86` vs `--ident my-branch` → correct filenames.
- writes under `--out-dir` (temp), never the real `$HOME` path, in tests.

**Stop-hook tests (`tests/lib/test_durable_log_gate.sh`):**
- breadcrumb present (own session) + matching log absent → hook blocks (non-zero / block
  decision).
- breadcrumb present + matching log present → hook passes (exit 0). Cover **sha-length
  normalisation**: breadcrumb `meta.head_sha` is 40-char, log filename is 12-char — the
  match must still succeed (guards the always-blocks regression).
- no breadcrumb → hook inert (exit 0) — guards against false blocks on non-review turns.
- **session-scoping: a breadcrumb belonging to a *different* session id → hook inert (exit
  0)** — the cross-session false-block landmine must not fire.
- **disarm: after a successful write the breadcrumb is neutralised, so a second consecutive
  turn-end is a clean no-op** — the gate never fires twice for one write.
- **self-expiry: a stranded breadcrumb older than the TTL → hook inert (exit 0)** — a dead
  session cannot wedge a live one indefinitely.

**Not automated:** the end-to-end live confirm — turn `full_log` on, run a real review,
eyeball the `.md` + `.jsonl`. (Same organic step as the 2026-06-19 spec. Note the
observer-effect caveat: a self-run by the same model that's primed on the fix is a weak
confirmation; a clean confirm is a fresh-session or blind-subagent run.)

## Deliverables

1. `plugins/code-review-suite/bin/durable-log-write` (+ `chmod +x`).
2. `plugins/code-review-suite/hooks/durable-log-gate.sh` (+ `chmod +x`) and a `Stop` entry in
   `hooks/hooks.json`.
3. Step 7a → Step 3.6 prose replacement in `skills/review-gh-pr/SKILL.md` and
   `commands/pre-review.md`.
4. `tests/lib/test_durable_log_write.sh` and `tests/lib/test_durable_log_gate.sh`, wired into
   `tests/run.sh`.

## What happens after this spec

With the durable log writing reliably, the maintainer turns `full_log` on (already on) and
accumulates real per-cog logs. That corpus is the data source for GitHub #63 (phase-efficacy)
and the frozen-input replay for the panel-vs-old A/B (spec #3). Spec #2 (panel Stage 2/3
build behind a flag) can proceed in parallel; the A/B (spec #3) depends on both this and #2.
