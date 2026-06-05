# Design — `housekeeper` specialist (dependency/version freshness)

> This file is the brainstorming **design doc**. On approval it is committed to
> `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`, then the
> `superpowers:writing-plans` skill produces the implementation plan. (The
> earlier "#5 parser / n=20" plan that lived here is DONE and shipped — superseded.)

## Context

The user's global CLAUDE.md "Repo Housekeeping" section wants dependency/version
freshness automated as part of code review. The capability gap that originally
justified this: `security-reviewer`'s "Version freshness (#7)" Focus Area mandates
a live registry fetch but the agent has historically been unreliable at it, and
freshness is hygiene, not security — it sits in the wrong specialist. The
housekeeper takes freshness over as a dedicated, deterministic, registry-backed
reviewer, and `security-reviewer` retires #7 and keeps only vulnerability
judgement (#6a) + pinning hygiene (#6b), consuming housekeeper findings via
cross-review.

**North star:** flag **everything versioned and external** that is behind its
latest GA release — because a thing is versioned precisely because it may need
upgrading. Accuracy is a hard constraint: **never emit a finding without a
trustworthy latest-GA answer.**

## Core decisions (settled in brainstorming)

- **Identity:** new `housekeeper` specialist in `code-review-suite`. Classed as a
  **static specialist** (deterministic engine, §10 severity-locked + confidence-100
  carve-out, follows `includes/static-analysis-context.md`).
- **Where it runs:** **pipeline specialist**, diff-driven, dispatched in the PR
  review like peers. Findings are **show-only** to cross-review (it renders no
  cross-review opinions itself); `security-cross-review` judges version/licence
  risk on its findings; the synthesiser sees both fact + judgement in its dossier
  and tags findings `[housekeeper]`.
- **Engine:** **direct registry HTTP**, cache-busting, **GA-filtered** (strip
  prerelease/yanked), targeting **absolute latest GA** (so .NET 11 / ubuntu 25.04
  are flagged the day they ship — NOT latest-LTS). Reuses
  `includes/version-freshness-cookbook.md` for per-ecosystem endpoint + "which
  field is latest". Engine emits `{source, item, current, latest_ga, stale,
  licence_current, licence_latest}` tuples — hash-comparable.
- **Scope model (diff drives it, in three tiers):**
  - **T1 scope gate (changed files):** a changed file pulls in its **containing
    solution / buildable unit** (.NET `.sln`; npm workspace root; Python project
    root; Go module). Untouched solutions are excluded. **Shared CI**
    (`.github/workflows`, runners) is **always in scope**.
  - **T2 candidate set (changed solutions):** **every** external/versioned
    dependency in an in-scope solution is an upgrade candidate — not only the ones
    whose lines changed.
  - **T3 modulation (changed lines):** changed lines set the **upgrade target
    only** — a dependency whose manifest line the diff touched → suggest
    latest-GA (major); an in-scope-but-untouched dependency → suggest the nearest
    minor/patch. **Severity is uniform `Suggestion`** ("staleness is a smell, not
    a defect").
- **Source classes — tiered by accuracy:**
  - **Tier 1 (this build) — structured field + authoritative registry:**
    package manifests (npm/NuGet/PyPI/crates/Go/RubyGems), GitHub Actions
    (`uses: org/action@vN`), workflow runners (`runs-on:`), Docker base-image tags
    (`FROM image:tag` — needs container-registry endpoints), and
    **framework/SDK/runtime versions** (`<TargetFramework>`, `global.json`
    `sdk.version`, Node `engines`, `requires-python`, Go directive).
  - **Tier 2 (deferred — own accuracy design):** free-text / context-pinned
    versions — `RUN apt-get install foo=1.2.3`, `pip install bar==1.0`, shell tool
    downloads. Deferred because parsing is unreliable AND "latest GA" is often
    distro-pinned/ambiguous, which would violate the no-accuracy-loss rule. The
    spec documents these as known-not-covered with the reason; no committed
    timeline.
- **SHA-pinning (orthogonal to freshness):** a SHA-pin + version comment
  (`uses: actions/checkout@<sha>  # v4.2.1`) is the **GOOD** state and must NEVER
  be flagged as stale-because-unparseable or "unpinned". Resolve the SHA / read
  the version comment → compare to latest GA → if behind, suggest the new version
  **and its SHA** (preserve the pin). Never suggest unpinning. Whether something
  *should* be SHA-pinned is a supply-chain judgement owned by security #6b, not
  the housekeeper.
- **Licence-change detection (in scope):** the engine already fetches the registry
  JSON, so it reads the licence field for current vs latest-GA target and flags a
  change — especially permissive→restrictive (MIT/Apache → BSL/SSPL/commercial).
  `security-cross-review` judges the commercial/legal risk. **Free-alternative
  suggestion is deferred** (open-ended judgement, not deterministic, not
  hash-testable).
- **`security-reviewer` #7 retirement:** remove the #7 freshness Focus Area
  (`security-reviewer.md:90-104`) and update FP-rule #9 (`:136-139`) + the dedupe
  note in lockstep; keep #6a (CVE/advisory safety) and #6b (pinning). Single
  freshness owner; resolves the overlap.
- **Model tier:** **ship `model: haiku` + `effort: low` directly** (user's call).
  ⚠️ **Recorded against the suite's discipline** — every other static specialist
  shipped sonnet and earned a haiku flip via an A/B equivalence sweep; this session
  itself caught a haiku-specific scope-leak in ruff. The housekeeper is the most
  multi-step (and thus most haiku-risky) specialist yet. **Mitigation:** build the
  recorded-fixture A/B harness regardless, run a sweep post-build, and treat
  sonnet as the fallback if equivalence fails. (Author flagged; user chose haiku.)
- **Testability:** **recorded-registry fixtures** — pin a snapshot of registry
  JSON so "latest GA" is frozen for tests; the engine is then deterministic and
  hash-stable → standard static-specialist A/B apparatus. Live runs hit real
  registries; tests hit fixtures.

## Components / units

1. **Freshness engine** — pure, deterministic core: manifest/source parsers (per
   T1 source class) → version extractor (incl. SHA→version resolution) → registry
   client (cache-busting HTTP) → GA-filter + semver compare → licence-diff. Emits
   the tuple set. This is the reusable heart; keep it isolated and unit-testable
   against recorded fixtures.
2. **Scope resolver** — diff → in-scope solutions (T1 gate) + shared-CI always-in;
   maps each changed/candidate item to its solution; supplies the changed-line set
   for T3 modulation.
3. **Agent definition** `agents/housekeeper-reviewer.md` — wraps the engine,
   follows `static-analysis-context.md`, emits canonical §7 findings tagged
   `[housekeeper]`, Suggestion severity, with the target modulated per T3.
4. **Pipeline wiring** — detection flag (e.g. `$HOUSEKEEPING_DETECTED` on changed
   manifests/workflows/Dockerfiles/`global.json`/etc.), conditional dispatch,
   `$SPECIALIST_COUNT`, verify-completeness enumeration, cross-review collection
   (show-only). Mirror the trivy block across `review-pipeline.md`,
   `commands/pre-review.md`, `skills/review-gh-pr/SKILL.md` (sync-note tests
   enforce parity).
5. **Synthesiser + security-reviewer edits** — add `[housekeeper]` source tag and
   §10 carve-out lists in `review-synthesiser.md`; retire security #7.
6. **A/B apparatus** — recorded-registry fixture corpus + parser case +
   `{baseline,haiku-low}` configs, mirroring jbinspect.

## Critical files (grep `trivy-reviewer` for the template)

- `plugins/code-review-suite/agents/housekeeper-reviewer.md` (new)
- `plugins/code-review-suite/agents/security-reviewer.md` (retire #7: lines ~90-104,
  136-139, dedupe note)
- `plugins/code-review-suite/agents/review-synthesiser.md` (source tag + carve-out)
- `plugins/code-review-suite/includes/review-pipeline.md` (detection ~687, dispatch
  ~911, count ~933, verify ~940, cross-review ~1037)
- `plugins/code-review-suite/includes/version-freshness-cookbook.md` (cite/extend:
  add container-registry + framework-SDK endpoints)
- `plugins/code-review-suite/commands/pre-review.md`,
  `skills/review-gh-pr/SKILL.md` (sync wiring)
- `plugins/code-review-suite/README.md` (specialist table)
- `tests/` — recorded-registry fixtures, `agent_capture` parser case, A/B configs,
  structural sync-note coverage for the new specialist.

## Open items for the implementation plan (not blocking the spec)

- Exact SHA→version resolution mechanism (registry commit lookup vs trusting the
  `# vX.Y.Z` comment).
- Per-source "latest GA" endpoint + field for the new T1 classes (Docker base
  images, framework/SDK) — extend the cookbook.
- The cross-ecosystem definition of "solution / buildable unit" for the scope gate.
- Recorded-fixture maintenance strategy (how snapshots are refreshed).

## Verification

- Engine unit tests against recorded fixtures: GA-filter, semver compare, SHA
  resolution, licence-diff, scope-gate — all deterministic.
- Structural suite `bash tests/run.sh` green (sync-note tests for the new specialist
  wiring; the `bad-config rejection` test false-fails on a dirty tree — commit
  first).
- End-to-end: run the housekeeper against a fixture repo with a known-stale dep +
  a licence-changing major + a SHA-pinned Action behind latest; confirm canonical
  §7 findings, correct targets per T3, licence flag, and SHA-pin preserved.
- Post-build A/B sweep (recorded fixtures) to validate the haiku tier; revert to
  sonnet if equivalence fails.

## House rules (carried)

Direct-push to `main`, push immediately; no Co-Authored-By/advertising; Bash hook
rules (no `&&`/`;`/`$(...)` except the commit heredoc); TDD for engine/parser
logic; `CLAUDE_TEMP_DIR` for temp files; plugin-authoring frontmatter conventions;
ship-sonnet-then-flip is the norm being consciously overridden here. Memory:
write `project_housekeeper_specialist_*.md` + MEMORY.md line in the `~/.claude`
repo, commit+push separately.

## Out of scope

- Tier-2 free-text `RUN`-installed packages (deferred, own accuracy design).
- Free-alternative-package suggestions (deferred, non-deterministic).
- IaC misconfig (trivy-reviewer keeps it) and supply-chain "should this be
  SHA-pinned" judgement (security #6b).
