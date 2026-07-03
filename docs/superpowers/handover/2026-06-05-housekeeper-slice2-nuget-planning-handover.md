# Handover — housekeeper slice 2 (NuGet) PLANNING session

**Date:** 2026-06-05
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (own remote
`Jodre11/claude-code-plugins`; direct-push to `main`, push immediately; the
branch-protection-bypass notice on push is expected/benign).

**State:** Slice-2 BRAINSTORMING is DONE. The design spec is written, committed,
and pushed (`9f91f57`):
`docs/superpowers/specs/2026-06-05-housekeeper-slice2-nuget-design.md`. This
session does ONE thing: run `superpowers:writing-plans` to turn that approved spec
into a task-by-task implementation plan under `docs/superpowers/plans/`. Do NOT
write engine/agent/test code — that is a LATER execution session
(`superpowers:subagent-driven-development`).

**This is OFFLINE planning** — no Bedrock-spend gate. But the eventual execution
session's A/B capture + sweep spend real Bedrock and STOP for explicit go-ahead
(carried in the spec). Don't bake any auto-spend into the plan.

---

## What slice 2 builds (operator-confirmed scope — do NOT re-litigate)

Three deliberate scope calls in brainstorming made slice 2 **comparable in size to
slice 1**, not the "markedly smaller" slice the earlier handover guessed:

1. **NuGet freshness** — the core: `.csproj` / `Directory.Packages.props` (CPM) /
   `Directory.Build.props` (global `PackageReference`s) parser, flat-container
   version fetch, semver compare, scope gate, T3 targets.
2. **Maintenance-health axis (BUILT, not deferred)** — adds a `health` field to the
   engine tuple. Deterministic registry signals ONLY: `deprecated` + `unlisted`/
   yank. Fuzzy signals (last-publish age, single-maintainer) are DEFERRED (break
   determinism). Emit rule widens from "stale" to "stale OR health-flagged" so a
   current-but-deprecated package surfaces. **npm `deprecated` rider INCLUDED**
   (near-zero cost — npm's registry doc already carries it).
3. **NuGet licence-diff (BUILT)** via the NuGet registration API (the flat-container
   endpoint is version-only; registration carries licence + deprecation). Shared
   client serves BOTH licence-diff and health.
4. **npm/runner hardening folded in** (each with its own regression test):
   multi-section dep collapse (`(section,name)` keying), `.json` scope narrowing,
   `LATEST_RUNNERS` 180-day self-check.

## Context to load first (read in this order — do NOT re-derive)

1. **The approved spec** (the contract for the plan):
   `docs/superpowers/specs/2026-06-05-housekeeper-slice2-nuget-design.md`.
2. **The slice-1 PLAN** as the structural template the new plan must mirror
   (task granularity, TDD-per-step with full code/tests/commands, explicit
   commit+push points, the gated A/B sweep as the final task):
   `docs/superpowers/plans/2026-06-05-housekeeper-specialist.md`.
3. **The engine** (what slice 2 modifies):
   `plugins/code-review-suite/bin/housekeeper-freshness` — study the version core
   (`parse_version`/`is_ga`/`compare_versions`/`latest_ga`/`nearest_in_major`/
   `strip_constraint`), the `Registry` fetch abstraction, `collect_npm` +
   `parse_package_json` + `npm_scope_roots` (NuGet's `collect_nuget` mirrors these),
   and `collect_findings`'s tree-walk + deterministic sort.
4. **The agent + cookbook:** `plugins/code-review-suite/agents/housekeeper-reviewer.md`
   (the §7 renderer — NuGet adds `housekeeper/nuget`; health appends to Description;
   pure-health changes the Suggested fix) and
   `plugins/code-review-suite/includes/version-freshness-cookbook.md` (the NuGet
   flat-container row exists; add a registration-endpoint note for licence/health).
5. **Slice-1 memory + result note:** memory
   `project_housekeeper_specialist_slice1.md` in the `~/.claude` repo
   (`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`)
   and `docs/superpowers/notes/2026-06-05-housekeeper-haiku-low-result.md`.

## Key design decisions the plan must encode (from the spec — verbatim, do not soften)

- **Tuple shape adds `health`** = `null | {state, detail}`, `state ∈
  {"deprecated","unlisted"}`, `detail` rendered verbatim, never judged. Default
  `null` keeps slice-1 fixture hashes stable (the findings hash keys only on
  `file/line/rule_id/severity/confidence` — metadata is NOT hashed).
- **`parse_version` → 4-tuple** `(major,minor,patch,revision)`, revision defaults
  to 0 → backward-compatible for npm/Actions/runners by construction. This is the
  ONLY change to slice-1-proven code; the plan MUST include a regression test
  pinning the preserved 3-part behaviour BEFORE the NuGet work builds on it.
- **`is_ga` unchanged** — already rejects NuGet prerelease (`-preview`/`-rc`/`-beta`).
  NuGet has no `dist-tags`; `latest_ga` over the full flat-container list is primary.
- **Scope gate = nearest-ancestor `.csproj`** (npm's `package.json` analogue). NOT
  `.sln`. CPM versions resolve by walking up to the governing
  `Directory.Packages.props`. Global `<PackageReference Version>` in any in-scope
  `.props` is honoured. **We scan DECLARED source — no `<Import>` graph evaluation,
  no `$(property)` resolution, no condition evaluation. `.targets` out of scope.**
- **No-untrustworthy-answer gate (no finding):** property refs `$(...)`, ranges
  `[1.0,2.0)`, floating `1.*`/`1.2.*`. Only bare concrete `1.2.3`/`1.2.3.4` acted on.
  `VersionOverride` wins over CPM; csproj inline wins over props.
- **Registration client** = new `Registry.registration()`, gzip + pagination
  (inlined or external `@id` leaves), fixture override at
  `<fixtures>/nuget-registration/<slug>.json` (decompressed JSON — tests don't gzip).
  A registration miss leaves `licence_*`/`health` null but does NOT suppress the
  freshness finding; only a flat-container miss suppresses entirely.
- **T3** falls out of the existing `nearest_in_major` machinery — the tuple's
  `file`/`line` already point at the literal version location (csproj or props), so
  "touched line → latest; untouched → nearest-in-major" needs no CPM-special logic.
- **Detection flag** `$HOUSEKEEPING_DETECTED` extends to changed `*.csproj` /
  `*.props` / `packages.lock.json` across `review-pipeline.md`, `pre-review.md`,
  `SKILL.md` in lockstep (sync-tested). Dispatch/count/verify/cross-review wiring
  already includes the housekeeper — only the trigger pattern changes.
- **Agent:** add `nuget` to the Rule enumeration; extend the worked example with a
  NuGet finding AND a health-flagged finding (worked-example-gap lesson — the small
  model needs a template). No new agent, no model-tier change (`haiku`/`low`).
- **Synthesiser / static-analysis-context** likely need NO change (NuGet renders
  under the existing `[housekeeper]` carve-out) — but the plan must CONFIRM this by
  reading, not assume.
- **npm hardening regression tests:** dual-section dep yields two findings; a stray
  `data.json` no longer drags `package.json` into scope; `LATEST_RUNNERS` self-check
  fails when the `Reviewed` stamp is > 180 days old.

## Plan-shaping guidance (mirror the slice-1 plan)

- TDD per step: failing test → run-to-fail → implement → run-to-pass → commit+push.
- One concern per task; complete code/tests/exact commands in each step (slice-1
  plan is the granularity bar).
- Suggested task spine (adjust as the writing-plans skill sees fit):
  1. `parse_version` 4-tuple + regression test (touches shared core first, safely).
  2. `Registry.registration()` client (gzip + pagination + fixture override).
  3. NuGet parsers (`parse_csproj`, `parse_packages_props`, NuGet `strip_constraint`).
  4. NuGet scope resolver (`nuget_scope_roots` — nearest-csproj, props walk-up, CPM).
  5. `collect_nuget` + licence + health + T3 + CLI tree-walk wiring.
  6. Health axis cross-source: widened emit rule + npm `deprecated` rider.
  7. Agent edits (`nuget` rule + extended worked example incl. health).
  8. Cookbook registration-endpoint note.
  9. Detection-flag extension across the three pipeline files (+ sync test if asserted).
  10. npm/runner hardening (3 items, each its own test).
  11. README specialist-row update.
  12. A/B apparatus (NuGet corpus, recorded flat-container + registration fixtures,
      parser fixture, config) — OFFLINE.
  13. GATED live capture + 2×20 sweep + verdict + memory — STOP for go-ahead.
- **Hash-stability task:** the plan must verify the slice-1 npm/Actions/runner corpus
  keeps its canonical hash after the 4-tuple + `health=null` change (check the
  existing npm fixture has no dual-section dep; if it does, its baseline re-captures
  under gate).
- End the plan with the same gated-sweep discipline as slice 1 (Task 14 there).

## Known constraints (carried)

- A/B harness CANNOT inject `HOUSEKEEPER_REGISTRY_FIXTURES` into the dispatched
  subagent (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`) — live capture/sweep hit REAL
  registries; the unittest `EndToEndTest` guarantees engine determinism under
  fixtures. Flag (don't silently depend on) live network if a hermetic corpus is
  wanted.
- After any mid-session `bin/` change, `/plugins update` + `/reload-plugins` before
  an A/B capture or the dispatched agent runs a stale engine from the plugin cache
  (cost a capture in slice 1).
- `bash tests/run.sh` is the safety net; the `A/B run.sh: bad-config rejection
  leaves working tree clean` test false-fails on a dirty tree — commit first.

## Hard house rules (global + repo CLAUDE.md)

- Bash: NO `&&`/`||`/`;`/`$(...)` except the permitted `git commit -m "$(cat
  <<'EOF' …)"` heredoc. One command per Bash call (pre-commit hook enforces).
- Temp files under the literal session `CLAUDE_TEMP_DIR` (`/tmp/claude-<id>/`),
  never bare `/tmp`. Pass the resolved value to any subagent needing temp files.
- Commits: no Co-Authored-By, no Claude advertising. Push immediately (autoUpdate
  has wiped unpushed work in this dir before).
- Plugin authoring: frontmatter `name`+`description`, blank line after `---`,
  2-space md/json indent, LF endings, `chmod +x` for `bin/`.
- 4-space indent for shell/Python; 120-col; source-gen logging / System.Text.Json
  conventions are C#-side (the engine is stdlib Python).

## Process

1. `superpowers:writing-plans` — produce
   `docs/superpowers/plans/2026-06-05-housekeeper-slice2-nuget.md`, mirroring the
   slice-1 plan's structure. Commit + push.
2. Get plan sign-off from the operator before any execution session.
3. A LATER session executes via `superpowers:subagent-driven-development` (fresh
   subagent per task, two-stage spec-then-quality review, commit+push per task).
4. Update memory `project_housekeeper_specialist_slice2.md` + MEMORY.md line in the
   `~/.claude` repo once the plan is committed (note: planning done, execution
   pending).
