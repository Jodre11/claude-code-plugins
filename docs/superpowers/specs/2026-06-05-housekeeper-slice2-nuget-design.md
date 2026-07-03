# Design — housekeeper specialist slice 2 (NuGet + maintenance-health + npm hardening)

> Brainstorming **design doc**. On approval it is committed here, then
> `superpowers:writing-plans` produces the task-by-task implementation plan. A
> LATER session executes via `superpowers:subagent-driven-development`.
> Supersedes nothing — it extends the shipped slice-1 chassis
> (`docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`,
> `docs/superpowers/plans/2026-06-05-housekeeper-specialist.md`).

## Context

Slice 1 shipped the `housekeeper-reviewer` static specialist (engine + GitHub
Actions / runners / npm collectors, agent, full pipeline wiring, A/B apparatus;
A/B EQUIVALENT 20/20 at haiku/low, cost ratio 2.38×). Slice 2 adds **NuGet** as
the next source class on the same `bin/housekeeper-freshness` chassis.

During slice-2 brainstorming the operator made three deliberate scope calls that
make this slice **comparable in size to slice 1**, not the "markedly smaller"
slice the handover anticipated:

1. **Maintenance-health is built into slice 2**, not deferred. This is the one
   decision that changes the engine's *tuple shape* (adds a non-freshness signal),
   so it is designed now — before the chassis ossifies around pure freshness.
2. **Licence-diff for NuGet is built** via the registration/catalog API (the
   flat-container endpoint is version-only and carries no licence).
3. **npm/runner hardening** surfaced by the slice-1 review is folded in.

**North star (carried):** flag everything versioned and external that is behind
its latest GA release — and now, additionally, flag anything the registry marks
**deprecated or unlisted**, because an abandoned-but-current dependency is a real
maintenance risk no specialist owns. Accuracy stays a hard constraint: **never
emit a finding without a trustworthy answer.** We review the *declared source*,
not the restored binary — we do not evaluate the MSBuild import graph, resolve
`$(properties)`, or reason about what a build would actually resolve.

## Settled decisions (operator-confirmed in brainstorming — do not re-litigate)

- **Maintenance-health: BUILD into slice 2.** Adds a `health` field to the tuple.
  Deterministic signals only (registry `deprecated` + `unlisted`/yank). The fuzzy
  signals (last-publish age, single-maintainer) are **deferred** — they need a
  threshold/clock judgement that breaks determinism and risks false positives,
  violating the static-specialist hash-stable A/B contract.
- **NuGet licence-diff: BUILD** via the registration API (same endpoint as health).
- **npm health rider: INCLUDE.** npm's registry doc already carries per-version
  `deprecated` (a string) — once the tuple has `health`, npm populates it for
  ~zero cost, keeping the axis consistent rather than NuGet-only.
- **Pure-health findings: EMIT.** The engine's emit rule widens from "stale" to
  "stale OR health-flagged", so an up-to-date-but-deprecated package surfaces.
- **npm/runner hardening: FOLD IN** (each with its own regression test):
  multi-section dep collapse, `.json` scope breadth, `LATEST_RUNNERS` cadence.
- **Scope gate:** nearest-ancestor `.csproj` is the NuGet buildable unit (npm's
  `package.json` analogue); `.sln` is NOT the gate. CPM versions resolve by
  walking up to the governing `Directory.Packages.props`.
- **Model tier:** stays `model: haiku` + `effort: low` (validated in slice 1).
  Build the A/B corpus + sweep anyway; sonnet is the fallback only on failure.

## Tuple shape change (ripples across ALL sources)

```
{source, item, current, latest_ga, target, file, line,
 licence_current, licence_latest,
 health}          # NEW
```

- `source` adds `nuget` (renders as `housekeeper/nuget`). Existing values unchanged.
- `health`: `null` when no maintenance signal (the common case). When present:
  `{state, detail}` where `state ∈ {"deprecated", "unlisted"}` and `detail` is the
  registry's deprecation message / unlisted reason (rendered verbatim, never
  judged). Deterministic and hash-stable — no thresholds, no clock reads.
- **Hash stability:** existing slice-1 fixtures keep their canonical hash because
  the findings hash keys only on `file/line/rule_id/severity/confidence` (version
  and metadata text are NOT hashed — carried from slice 1). The `health` field is
  default-`null` for all existing tuples.

## Version core change

- **`parse_version` → 4-tuple** `(major, minor, patch, revision)`. NuGet uses
  4-part versions (`1.2.3.4`). `revision` defaults to `0`, so `v4` → `(4,0,0,0)`
  and **every existing npm/Actions/runner comparison is unchanged by
  construction**. `_VERSION_RE` gains an optional fourth numeric group. A
  regression test pins the preserved 3-part behaviour. This is the only change
  touching slice-1-proven code.
- `is_ga` is unchanged: it already rejects anything with a post-core hyphen, so
  NuGet prerelease shapes (`1.0.0-preview.1.2`, `-rc`, `-beta`) are correctly
  excluded. NuGet has no `dist-tags.latest`, so `latest_ga(versions)` over the
  full flat-container list is the path (npm's fallback becomes NuGet's primary).

## Registration-API client (new, shared by licence + health)

The flat-container `index.json` is a bare version list. Licence and
deprecation/unlisted metadata live in the **registration** resource
(`registration5-gz-semver2`): gzipped, paginated (pages either inlined or
external `@id` leaves needing a follow-up fetch).

- New `Registry.registration(item, ...)` method, sibling to `fetch`. Returns a
  per-version map `{version: {licence, deprecation, listed}}`, or `None` on any
  miss. Live mode handles gzip + pagination; recorded-fixture mode reads
  decompressed JSON from `<fixtures>/nuget-registration/<slug>.json` (tests do not
  gzip).
- **No-untrustworthy-answer rule:** a registration miss does NOT suppress the
  freshness finding — the tuple still emits on flat-container data alone, with
  `licence_*`/`health` left `null`. Only a flat-container miss (no trustworthy
  latest GA) suppresses the finding entirely.

## NuGet collector + scope resolver

### Parsing (line-based regex — keeps `line` cheap, matches npm)

- `parse_csproj(text)` → `{name: (version_spec_or_None, line)}` from
  `<PackageReference Include="X" Version="Y" />` (inline) and the child-element
  form `<PackageReference Include="X"><Version>Y</Version></PackageReference>`
  (version on its own line). A version-less `<PackageReference Include="X" />`
  records `None` (resolved later through CPM). `VersionOverride="..."` is captured
  and wins over CPM when present.
- `parse_packages_props(text)` → `{name: (version, line)}` from
  `<PackageVersion Include="X" Version="Y" />` (CPM central versions). The same
  parser also reads `<PackageReference Include Version>` from props files (global
  deps declared in `Directory.Build.props` / imported props — see scope below).
- **No-untrustworthy-answer gate (no finding):** MSBuild property refs `$(...)`,
  version ranges `[1.0,2.0)` / `(,2.0]`, and floating wildcards `1.*` / `1.2.*`
  yield no finding — we cannot name a trustworthy "current" without evaluating the
  build. A NuGet-aware `strip_constraint` sibling returns `None` for these; only a
  bare concrete `1.2.3` / `1.2.3.4` is acted on.

### Scope model (Q1 — the genuinely new bit vs npm)

- **Buildable unit / T1 gate:** the nearest-ancestor `.csproj`. A changed
  C#-ecosystem file (`.cs`, `.fs`, `.vb`, `.razor`, `.cshtml`, `.csproj`, `.props`,
  `packages.lock.json`, …) pulls in its nearest-ancestor `.csproj`. `.sln` is an
  optional aggregator, often absent — not the gate. (Documented choice.)
- **`.props` scanning:** every `.props` file in an in-scope subtree is scanned for
  both `<PackageVersion>` (CPM central) and `<PackageReference Version>` (global
  deps). A `.props` is in scope when an in-scope `.csproj` lives at or below its
  directory (props auto-apply down the subtree). One in-scope project thus pulls
  in its governing `Directory.Build.props` AND `Directory.Packages.props` by
  walking up.
- **We scan declared files; we do NOT evaluate `<Import Project="..."/>` chains,
  resolve properties, or honour conditions.** Scanning all `.props` in an in-scope
  subtree is a cheap, deterministic over-approximation that catches both
  conventionally-named and custom-named props without an import evaluator. A
  never-imported `.props` carrying a concrete stale version is vanishingly rare
  and harmless to flag (it is still a real outdated pin in the tree). `.targets`
  are out of scope (build logic, almost never package declarations).
- **CPM resolution:** for each in-scope csproj, version-less `<PackageReference>`
  resolves to the matching `<PackageVersion>` in the governing
  `Directory.Packages.props`. The finding's `file`/`line` point at wherever the
  version literally sits (csproj inline, props PackageReference, or props
  PackageVersion) — which is exactly what T3 needs.
- **Candidate set (T2):** every concrete-versioned package reachable from an
  in-scope csproj (resolving through CPM) is an upgrade candidate, not only
  changed lines — same as npm.

### T3 target modulation (Q5)

Identical to npm and falls out of the existing `nearest_in_major` machinery: if
the version's literal line (in csproj *or* props) is in the changed-lines set →
`target` = latest GA; else → nearest in-major. The tuple already carries the
correct `file`/`line`, so the CPM indirection needs no special T3 logic.

## Maintenance-health rendering + emit rule

- **Emit rule widens:** the engine emits a tuple when it is **stale OR
  health-flagged**. A current-but-deprecated package (latest GA, but registry
  `deprecated`) now surfaces; for it `target` = current.
- **Renderer (agent §7):** when `health.state` is set, append to the Description:
  ` Marked <state> in the registry: <detail>.` For a pure-health finding
  (not stale) the Suggested fix becomes `Review: <item> is current but marked
  <state>.` (no upgrade target exists). Severity stays uniform `Suggestion` — the
  housekeeper states the fact; `security-cross-review` judges supply-chain risk,
  exactly as it does for licence flips.
- **npm rider:** `collect_npm` reads per-version `deprecated` from the existing
  registry doc and populates `health` for ~zero marginal cost.

## Components / units (slice 2 delta)

1. **Version core** — `parse_version` 4-tuple extension (+ regression test).
2. **Registration client** — `Registry.registration()`, gzip + pagination, fixture
   override. Shared by licence-diff and health.
3. **NuGet collector** — `parse_csproj`, `parse_packages_props`, NuGet
   `strip_constraint` sibling, `nuget_scope_roots` (nearest-csproj + props walk-up
   + CPM resolution), `collect_nuget`. Reuses the version core unchanged.
4. **Health axis** — `health` tuple field, widened emit rule, npm `deprecated`
   rider, agent renderer.
5. **CLI wiring** — `collect_findings` tree-walk discovers `.csproj`/`.props`,
   gates scope (sibling to the package.json walk), runs `collect_nuget`.
6. **Detection flag** — extend `$HOUSEKEEPING_DETECTED` to fire on changed
   `*.csproj` / `*.props` / `packages.lock.json` across `review-pipeline.md`,
   `pre-review.md`, `SKILL.md` (lockstep, sync-tested). Dispatch/count/verify/
   cross-review wiring already includes the housekeeper — only the trigger changes.
7. **Agent** — add `nuget` to the Rule enumeration; extend the worked example with
   a NuGet finding AND a health-flagged finding (worked-example-gap lesson). No new
   agent, no model-tier change.
8. **Security cross-review** — confirm its prompt generalises over housekeeper
   findings (incl. the new health signal) or add an explicit mention.
9. **npm/runner hardening** (each with its own regression test):
   - **Multi-section collapse:** `parse_package_json` keys by `(section, name)`,
     so a dep in both `dependencies` and `peerDependencies` yields both findings.
   - **`.json` scope breadth:** narrow `_NPM_SCOPE_SUFFIXES` — drop bare `.json`,
     keep npm-meaningful (`package.json`, `tsconfig*.json`, `*.config.json`). Test
     asserts a stray `data.json` no longer drags `package.json` into scope.
   - **`LATEST_RUNNERS` cadence:** a self-check test fails if the `Reviewed` stamp
     is older than 180 days — turning silent staleness into a visible signal.
10. **A/B apparatus** — new NuGet corpus + recorded flat-container + registration
    fixtures + parser fixture + config (extend the existing housekeeper configs
    with the NuGet corpus, or a NuGet config pair).

## Critical files

- `plugins/code-review-suite/bin/housekeeper-freshness` — MODIFY (4-tuple core,
  `Registry.registration`, NuGet collector + scope, health field + emit rule, npm
  rider + hardening).
- `plugins/code-review-suite/agents/housekeeper-reviewer.md` — MODIFY (`nuget`
  rule, health rendering, extended worked example).
- `plugins/code-review-suite/includes/version-freshness-cookbook.md` — the NuGet
  flat-container row already exists; ADD a registration-endpoint note for
  licence/health.
- `plugins/code-review-suite/includes/review-pipeline.md`,
  `commands/pre-review.md`, `skills/review-gh-pr/SKILL.md` — MODIFY (detection-flag
  file patterns, lockstep).
- `plugins/code-review-suite/agents/review-synthesiser.md` /
  `includes/static-analysis-context.md` — no change expected (NuGet renders under
  the existing `[housekeeper]` carve-out); confirm during the plan.
- `plugins/code-review-suite/README.md` — MODIFY (specialist row mentions NuGet).
- `tests/python/test_housekeeper_engine.py` — MODIFY (`NuGetTest`, registration
  tests, health tests, 4-tuple regression, npm-hardening tests, `EndToEndTest`).
- `tests/lib/test_housekeeper_engine.sh` — unchanged (auto-runs unittest).
- `tests/lib/test_sync_notes.sh` — MODIFY only if the detection-flag enumeration is
  sync-asserted; confirm in the plan.
- `tests/lib/` — NEW `LATEST_RUNNERS` cadence self-check (or fold into the engine
  unittest).
- `tests/ab/` — new NuGet corpus, recorded flat-container + registration fixtures,
  parser fixture, config; `corpus/index.yaml` registration.
- `tests/fixtures/static-analysis/housekeeper/` — NuGet fixture (csproj +
  Directory.Packages.props + Directory.Build.props + recorded registry).

## Verification

- Engine unit tests against recorded fixtures: csproj/props parsing, CPM walk-up,
  `VersionOverride` precedence, property-ref/range/floating skips, 4-tuple compare,
  `latest_ga` over flat-container, T3 targets, registration licence + health
  extraction, gzip+pagination, graceful misses, pure-health emit, npm `deprecated`
  rider, npm-hardening behaviours — all deterministic.
- `EndToEndTest` extension: NuGet fixture (CPM + global props + a deprecated-current
  package) → expected tuple set incl. a health-flagged finding.
- Structural suite `bash tests/run.sh` green (the `bad-config rejection` test
  false-fails on a dirty tree — commit first).
- **Hash-stability check:** the slice-1 npm/Actions/runner corpus keeps its
  canonical hash after the 4-tuple + `health=null` change (verify the existing npm
  fixture has no dual-section dep; if it does, re-capture its baseline under gate).
- **GATED post-build A/B sweep** (NuGet corpus): 2×20 matched pair to validate
  haiku/low; sonnet fallback only on failure. Real Bedrock spend — STOP for
  explicit go-ahead before the capture and before the sweep. "Continue" does not
  pre-authorise either.

## Apparatus constraint (carried from slice 1)

The A/B harness cannot inject `HOUSEKEEPER_REGISTRY_FIXTURES` into the dispatched
subagent (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`), so the live capture + sweep run
against REAL registries. Fine for stable stale-pins (a v3 NuGet package is
unambiguously behind v6) and a registry-deprecated package stays deprecated; the
unittest `EndToEndTest` independently guarantees engine determinism under recorded
fixtures. If a hermetic NuGet A/B corpus is wanted, fixing the env-passthrough in
`tests/ab/lib/` becomes worth scoping — flag it, do not silently depend on live
network. Also: after any mid-session `bin/` change, run `/plugins update` +
`/reload-plugins` before an A/B capture, or the dispatched agent runs a stale
engine from the plugin cache (cost a capture in slice 1).

## Out of scope (deferred, with reason)

- **Fuzzy maintenance-health** (last-publish age, single-maintainer) — needs a
  threshold/clock judgement that breaks determinism; deferred to preserve the
  hash-stable static-specialist contract.
- **MSBuild import-graph evaluation / property resolution / condition evaluation**
  — we review declared source, not the restored binary.
- **`.targets` files** — build logic, almost never package declarations.
- Other ecosystems (PyPI, crates, Go, RubyGems, Docker base-image tags,
  framework/SDK versions) — follow-on slices on the same chassis.

## House rules (carried)

Direct-push to `main`, push immediately; no Co-Authored-By / advertising; Bash hook
rules (no `&&`/`||`/`;`/`$(...)` except the commit heredoc — one command per call);
TDD per engine function; `CLAUDE_TEMP_DIR` for temp files; plugin-authoring
frontmatter conventions (frontmatter `name`+`description`, blank line after `---`,
2-space md/json indent, LF, `chmod +x`). Memory: write/update
`project_housekeeper_specialist_slice2.md` + MEMORY.md line in the `~/.claude`
repo, commit+push separately. Agents dispatched with `mode: "auto"` + kebab `name`.
