# Handover — housekeeper specialist slice 2 (NuGet)

**Date:** 2026-06-05
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (own remote
`Jodre11/claude-code-plugins`; direct-push to `main`, push immediately;
the branch-protection-bypass notice on push is expected/benign).

**State:** Slice 1 is SHIPPED and proven (engine + Actions/runners/npm collectors,
agent, full pipeline wiring, security `#7` retirement, A/B apparatus). The A/B
sweep returned a clean EQUIVALENT (both arms 20/20, cost ratio 2.38×) and a live
smoke-test against a real diff confirmed end-to-end dispatch. Slice 2 has **no spec
and no plan yet** — this session starts at BRAINSTORMING, then writing-plans, then
(in a later session) execution. Do NOT jump straight to code.

**What slice 2 builds:** add **NuGet** as the next source class on the existing
`bin/housekeeper-freshness` chassis — a parser for `.csproj` / `Directory.Packages.props`
(CPM) / `packages.lock.json`, a registry fetch against the NuGet flat-container
endpoint, fixtures, a cookbook confirmation, and the A/B corpus + sweep. The chassis,
agent, pipeline wiring, synthesiser carve-out, and sync tests already exist — slice 2
should be markedly smaller than slice 1 (no new agent, no new wiring; mostly engine +
tests + one detection-flag extension).

---

## Context to load first (read in this order, do NOT re-derive)

1. **Slice-1 result + what shipped:** memory `project_housekeeper_specialist_slice1.md`
   in the `~/.claude` repo
   (`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`),
   and the A/B result note
   `docs/superpowers/notes/2026-06-05-housekeeper-haiku-low-result.md`.
2. **The design spec** (read the "Source classes — tiered by accuracy", scope-model,
   and Open-items sections):
   `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`.
3. **The slice-1 plan** as the chassis reference (how the engine, tests, A/B
   apparatus, and the npm collector are structured — slice 2 mirrors npm closely):
   `docs/superpowers/plans/2026-06-05-housekeeper-specialist.md`.
4. **The engine itself:** `plugins/code-review-suite/bin/housekeeper-freshness` —
   study `collect_npm`, `parse_package_json`, `npm_scope_roots`, the version core
   (`parse_version`/`is_ga`/`compare_versions`/`latest_ga`/`nearest_in_major`), and
   `collect_findings`'s wiring + tree-walk. NuGet slots in as a sibling collector.
5. **The agent + cookbook:** `plugins/code-review-suite/agents/housekeeper-reviewer.md`
   (the §7 renderer — NuGet tuples render identically, source = `nuget`) and
   `plugins/code-review-suite/includes/version-freshness-cookbook.md` (the NuGet row
   already exists: `https://api.nuget.org/v3-flatcontainer/<package-lower>/index.json`).

## Settled decisions carried from slice 1 (honour, do not re-litigate)

- Engine is stdlib-only Python in `bin/`, emitting a hash-stable JSON tuple set;
  the agent is a thin §7 renderer. NuGet adds a collector + parser, nothing else to
  the agent.
- Tuple shape is fixed: `{source, item, current, latest_ga, target, file, line,
  licence_current, licence_latest}`. NuGet `source` = `nuget`. Rule renders as
  `housekeeper/nuget`.
- Model tier stays `model: haiku` + `effort: low` (validated EQUIVALENT in slice 1).
  Build the A/B corpus + sweep anyway; sonnet is the fallback only if NuGet's sweep
  fails equivalence.
- The findings hash keys only on `file/line/rule_id/severity/confidence` — version
  text is NOT hashed, so the sweep is drift-proof against live-registry movement.

## Open design questions for BRAINSTORMING (the reason this starts at brainstorm, not plan)

These are genuine NuGet-specific decisions slice 1 did not face — resolve them in
brainstorming before writing the plan:

1. **Manifest formats + scope gate.** NuGet has three relevant files: per-project
   `.csproj` (`<PackageReference Include="X" Version="Y" />`), centralised
   `Directory.Packages.props` (CPM — `<PackageVersion Include="X" Version="Y" />`,
   versions live at the repo/solution root, NOT per-project), and `packages.lock.json`.
   The global CLAUDE.md says "Check `Directory.Packages.props` (CPM) first if it
   exists, otherwise scan all `*.csproj`." Decide: what is the NuGet "solution /
   buildable unit" for the T1 scope gate (the `.sln`? the directory holding
   `Directory.Packages.props`? the nearest `.csproj`?), and how does a changed `.cs`
   file pull in the right manifest. This is the analogue of npm's `npm_scope_roots`
   but the CPM indirection (version in a parent props file, reference in a child
   csproj) is new.
2. **Version attribute parsing.** `.csproj`/props are XML; `Version="..."` can be a
   single version, a range (`[1.0,2.0)`), or a floating version (`1.2.*`, `1.*`).
   The engine is line-based for npm (to attribute a source line). Decide whether to
   stay line-based (regex over the XML) or parse XML properly — line-based keeps the
   `line` field cheap and matches the npm approach, but XML attributes can wrap. Lean
   line-based unless brainstorming finds a blocker.
3. **Latest-GA from NuGet.** The flat-container `index.json` returns ALL versions
   (including prerelease — `-preview`, `-rc`, `-beta`). The existing `is_ga`/`latest_ga`
   core already strips prerelease (hyphen rule) — confirm it handles NuGet's
   `1.0.0-preview.1.2` shape. NuGet has no `dist-tags.latest` equivalent, so
   `latest_ga(versions)` over the full list is the path (npm preferred dist-tags, then
   fell back to this — NuGet skips straight to the fallback).
4. **Licence field.** npm's registry JSON carries per-version `license`; the NuGet
   flat-container `index.json` does NOT (it's just a version list). Licence-diff may
   need a second endpoint (the registration/catalog API) or be DEFERRED for NuGet.
   Decide: licence-diff in scope for NuGet slice 2, or explicitly deferred? (Slice 1's
   licence-diff was an accepted feature; dropping it for NuGet is a conscious scope cut,
   not an omission.)
5. **CPM `target` modulation (T3).** A changed `.cs` file pulls in the solution but
   touches no manifest line → npm suggests nearest-in-major. For CPM the version line
   is in `Directory.Packages.props`, which the diff may or may not touch. Confirm the
   touched-line vs in-scope-untouched logic maps cleanly onto the props-file indirection.

## Likely scope of slice 2 (confirm/adjust in brainstorming)

- **Engine:** add `collect_nuget` + a `parse_csproj`/`parse_packages_props` parser +
  NuGet scope resolver. Reuse the version core unchanged.
- **CLI wiring:** extend `collect_findings`'s tree-walk to discover NuGet manifests
  and gate scope (sibling to the `package.json` walk).
- **Detection flag:** extend `$HOUSEKEEPING_DETECTED` in all three pipeline files
  (`review-pipeline.md`, `pre-review.md`, `SKILL.md`) to also fire on changed
  `*.csproj` / `Directory.Packages.props` / `packages.lock.json`. (The dispatch block,
  count, verify, and cross-review wiring already include the housekeeper — only the
  detection trigger needs the new file patterns.)
- **Tests:** `tests/python/test_housekeeper_engine.py` gets a `NuGetTest` class +
  `EndToEndTest` extension; new `tests/fixtures/static-analysis/housekeeper/` NuGet
  fixture + recorded registry JSON; A/B corpus entry + parser-fixture log + a NuGet
  config pair (or reuse the housekeeper configs with a NuGet corpus).
- **Cookbook:** the NuGet row already exists — confirm/annotate, don't duplicate.
- **NOT in scope:** no new agent, no new synthesiser carve-out, no new sync-test
  specialist enumeration (NuGet renders under the existing `[housekeeper]` tag and
  `housekeeper/nuget` rule — already covered by the slice-1 carve-out).

## Cheap hardening to fold in (surfaced by slice-1 review — optional, decide in brainstorm)

- **npm multi-section collapse:** a dep in both `dependencies` and
  `peerDependencies` keeps only the last occurrence (keyed by name in
  `parse_package_json`). Real for libraries. Cheap fix: key by `(section, name)`.
- **npm `.json` scope breadth:** any changed `.json` pulls the whole `package.json`
  into scope. Narrow `_NPM_SCOPE_SUFFIXES` to npm-meaningful json
  (`tsconfig*.json`, `*.config.json`) or document the broad trigger as deliberate.
- **`LATEST_RUNNERS` staleness:** the runner table is manually maintained with a
  "Reviewed 2026-06-05" stamp — decide a review cadence or a self-check.

These are NOT slice-2 blockers; fold them in only if they're a natural fit, with
their own regression tests. Don't let them balloon the NuGet slice.

## The strategic fork — DECIDE BEFORE THE PLAN FREEZES (recorded own-or-defer)

**Dependency maintenance-health** (archived repo / single maintainer / last-publish
age / registry `deprecated`/yank flag) is a *fourth axis* orthogonal to freshness,
CVE, and pinning — recorded as an own-or-defer Open item in the design spec
(`...housekeeper-specialist-design.md`, committed `e09e2c9`) and in memory
`project_housekeeper_maintenance_health_axis.md`. Default lean: **defer**. It is
near-zero marginal cost because the engine already fetches registry JSON per item.
**Make the build-or-defer call consciously during slice-2 brainstorming** — it is the
only item that changes the engine's *shape* (adds a non-freshness signal to the tuple)
rather than adding a parser, so deciding it before the chassis ossifies around pure
freshness avoids a retrofit. If "build," it is arguably its own slice, not bolted onto
NuGet.

## Known apparatus constraint (carried from slice 1)

The A/B harness CANNOT inject `HOUSEKEEPER_REGISTRY_FIXTURES` into the dispatched
subagent (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`), so the live capture + sweep run
against REAL registries. This was fine for slice 1's stable stale-pins (a v3 NuGet
package is unambiguously behind a v6) and the unittest `EndToEndTest` independently
guarantees engine determinism under recorded fixtures. If slice 2 (or a later slice)
wants a hermetic A/B corpus, fixing the env-passthrough in `tests/ab/lib/` becomes
worth scoping — flag it, don't silently depend on live network.

Also remember: the A/B harness reads the agent BODY from the working tree but resolves
the engine BINARY on PATH from the PLUGIN CACHE. After any mid-session `bin/` change,
run `/plugins update` + `/reload-plugins` before an A/B capture, or the dispatched
agent runs a stale engine (this cost a capture in slice 1 — see
`project_plugin_cache_staleness`).

## Process (workflow skills)

1. **`superpowers:brainstorming`** FIRST — resolve the open design questions above,
   especially the CPM scope gate (Q1) and the licence-diff decision (Q4), plus the
   maintenance-health build-or-defer fork. Produce a design doc under
   `docs/superpowers/specs/`.
2. **`superpowers:writing-plans`** — turn the approved design into a task-by-task plan
   under `docs/superpowers/plans/`, mirroring the slice-1 plan's structure (TDD per
   step, complete code/tests/commands, explicit commit+push points, a gated A/B sweep
   at the end).
3. A LATER session executes via `superpowers:subagent-driven-development` (fresh
   subagent per task, two-stage spec-then-quality review, commit+push per task).
4. Write a slice-2 execution handover (like this file) once the plan is committed.

## Hard house rules (from global + repo CLAUDE.md)

- Bash: NO compound operators (`&&`/`||`/`;`), NO command substitution `$(...)` except
  the permitted `git commit -m "$(cat <<'EOF' …)"` heredoc. One command per Bash call.
  A pre-commit hook enforces this.
- Temp files under the literal session `CLAUDE_TEMP_DIR` (`/tmp/claude-<id>/`), never
  bare `/tmp`. Pass the resolved value to any subagent that needs temp files.
- Commits: no Co-Authored-By, no Claude advertising. Push immediately after each commit
  (`autoUpdate` has wiped unpushed work in this dir before).
- Agents: always set `mode: "auto"` and a kebab-case `name`.
- Plugin authoring: frontmatter `name`+`description`, blank line after closing `---`,
  2-space indent for md/json, LF endings, `chmod +x` for `bin/`.
- `bash tests/run.sh` is the safety net; the
  `A/B run.sh: bad-config rejection leaves working tree clean` test false-fails on a
  dirty tree — known artifact, commit first.

## Gating

- Brainstorming + writing-plans are offline — no Bedrock-spend gate, but get design
  sign-off before writing the plan, and plan sign-off before any execution session.
- The eventual execution session's A/B capture + sweep spend real Bedrock — STOP for
  explicit go-ahead before each, exactly as slice 1 did. "Continue" does not
  pre-authorise either.
