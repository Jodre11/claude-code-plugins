# Handover — housekeeper source-file trigger + broader-applicability roadmap

**Date:** 2026-06-11
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (the personal plugin
marketplace — independently versioned, its own CI/CLAUDE.md/test suite; push to
its own `origin`, NOT the `claude-settings` repo).
**Branch:** `main` (house rule: direct-push to `main`, push immediately).

---

## 1. What to do first (the immediate task)

Execute the implementation plan at:

```
docs/superpowers/plans/2026-06-11-housekeeper-source-file-trigger.md
```

Use **`superpowers:executing-plans`** (inline, with checkpoints) — the change is
tiny (four tasks, three of them the same prose edit in three synced files, plus
one new Bash sync test). Subagent-driven is overkill here. The plan is TDD-first:
write the sync test red, then the three prose edits turn it green.

The paired **design spec** (read it for the "why" before executing) is:

```
docs/superpowers/specs/2026-06-11-housekeeper-source-file-trigger-design.md
```

Both were committed this session (spec commit `027471e`). The plan was written
but NOT yet executed — no prose or test changes have landed. Start clean.

---

## 2. The problem being fixed (one paragraph)

The housekeeper specialist's **engine** (`bin/housekeeper-freshness`) already
resolves per-ecosystem scope correctly: a changed `.cs` file walks up to its
nearest-ancestor `.csproj` and audits ALL that project's NuGet deps
(`nuget_scope_roots`, engine line 641); `.ts`/`.js`/etc. do the same for
`package.json` (`npm_scope_roots`, line 435). But the **dispatch gate**
`$HOUSEKEEPING_DETECTED` (`includes/review-pipeline.md:693`) only fires when a
*dependency-manifest file itself* is in the diff. So a source-only PR (the trigger
case: PR #566 on the `HavenEngineering/finance-erp` repo — seven `.cs` files, no
manifest) never invokes the engine, even though the engine would have surfaced
every stale NuGet package and a High-severity transitive advisory
(`Tmds.DBus.Protocol`). **The trigger is strictly narrower than the engine behind
it.** The fix widens the trigger to mirror the engine's scope-suffix constants —
nothing more.

---

## 3. Key decisions already settled (do not re-litigate)

- **Approach A, not B.** Widen the conditional trigger; do NOT promote the
  housekeeper to an always-on core specialist. Rationale: must stay cheap on
  docs-only PRs (trivial-mode + conditional gate exist precisely for this). User
  confirmed: "I don't really want to be running the housekeeper when it's just a
  documentation change."
- **"Both, per ecosystem"** scope unit: nearest `.csproj` for .NET source, nearest
  `package.json` for npm source. This also resolves open-item #3 (cross-ecosystem
  "buildable unit" definition) from the original housekeeper design spec.
- **Explicit extension lists, NOT semantic phrasing** ("any C#/npm source file").
  Explicit literals are more directive for the executing agent (a mechanical
  string match, no interpretation/drift — matters because the housekeeper runs
  haiku/low), uniform with every sibling detection flag, and the only form a sync
  test can pin against the engine constants.
- **Mirror contract** is the maintenance rule: trigger prose extensions are a
  projection of the engine's `_NUGET_SCOPE_SUFFIXES` (line 615) /
  `_NPM_SCOPE_SUFFIXES` (line 416). Future ecosystems add BOTH in lockstep. The
  new sync test enforces it.
- **`.targets` fold-in:** the edit also adds `.targets` to the manifest list in
  the prose (engine already scopes it; prose omitted it — a pre-existing minor
  mismatch). User was told and accepted.
- **Engine and agent code are NOT touched.** Docs/test-only change.

---

## 4. The three synced files (parity is enforced by tests)

The Step 2.6 "Housekeeping detection" bullet is byte-identical across all three;
edit all three identically:

1. `plugins/code-review-suite/includes/review-pipeline.md:693` (CANONICAL — edit first)
2. `plugins/code-review-suite/commands/pre-review.md:694`
3. `plugins/code-review-suite/skills/review-gh-pr/SKILL.md:799`

Exact before/after text is in the plan (Task 2 Step 1). An existing prose-parity
sync test will FAIL between edits and PASS once all three match — this is expected
mid-task; land all three before committing.

---

## 5. Verification

- `bash tests/run.sh` from the repo root — all tests green. Tests auto-discover by
  `test_` prefix (no registration). Harness primitives in `tests/lib/harness.sh`:
  `REPO_ROOT`, `pass`/`fail`/`skip`.
- The new test `test_housekeeping_trigger_mirrors_engine_scope` (appended to
  `tests/lib/test_sync_notes.sh`) must pass.
- Engine regression check (plan Task 4 Step 3): a `.cs`-only changed-files list
  against a fixture project returns that project's stale deps — proves the engine
  already honoured source-file scope.
- Known artifact: the `bad-config rejection` test false-fails on a dirty tree —
  commit first, then re-run.

## 6. House rules (this repo)

- Direct-push to `main`; push immediately after committing. No
  Co-Authored-By/advertising trailers.
- Bash hook rules: no `&&`/`||`/`;`/`$(...)`/subshells/pipes-where-avoidable —
  one command per Bash call. Carve-out: the `git commit -m "$(cat <<'EOF' … EOF)"`
  HEREDOC is permitted for multi-line commit bodies.
- Use `$CLAUDE_TEMP_DIR` (a `SessionStart` hook injects it) for all temp files.
- Plugin-authoring frontmatter conventions (see repo CLAUDE.md): every
  command/skill file needs `name` + `description` frontmatter and a blank line
  after the closing `---`.
- **Plugin cache staleness:** after pushing a `bin/` or prose change mid-session,
  run `/plugins update` (refreshes DISK from GitHub) THEN `/reload-plugins`
  (reloads in-memory registry from disk). For an A/B capture that exercises the
  engine binary, the cache MUST be refreshed first or you capture the stale
  chassis.

## 7. Memory to update after landing (in the `~/.claude` repo, committed separately)

Two slice memories record the trigger as "wired as conditional specialist
(`$HOUSEKEEPING_DETECTED`)" but did NOT capture the scope *philosophy* — that gap
is what made this session necessary. After landing, update:

- `project_housekeeper_specialist_slice1.md` and/or `slice2.md` — add a note that
  the trigger now fires on edited **source files** (not just manifests), mirroring
  the engine scope sets, pinned by `test_housekeeping_trigger_mirrors_engine_scope`.
- Consider a short **feedback** memory: the housekeeper's purpose is *housekeeping*
  (audit the touched project), not *diff-spotting* (audit only changed manifest
  lines) — the diff selects WHICH units to audit and modulates the target; it does
  not restrict findings to changed lines. This is the principle that generalises to
  all housekeeper threads.

The `~/.claude` repo's memory dir is exempt from org/identity scrubbing (private
repo; the public seed ships no memory). Secret-shaped patterns still bite.

---

## 8. The bigger picture — continuing to make the housekeeper broadly applicable

This trigger fix is one step in a standing goal: **the housekeeper should do
real housekeeping wherever a project is worked on.** The principle (Section 7,
second bullet) is the through-line for everything below.

### 8a. The general principle (applies to ALL housekeeper threads)

The diff is a *selector and target-modulator*, not a *findings filter*. Any future
work should preserve: changed file → containing buildable unit → audit ALL its
deps (T2), with changed lines only setting the upgrade target aggressiveness (T3).
Shared CI (`.github/workflows`, runners) is always in scope regardless of diff.

### 8b. Deferred ecosystems (same chassis — the natural next slices)

The engine is built to extend: add a parser + scope-suffix set + cookbook row +
recorded-registry fixtures + A/B configs per ecosystem, each independently
testable. Order is open; pick by what the user's repos actually use. Candidates,
all on the same chassis:

- **PyPI** (`pyproject.toml`/`requirements*.txt`/`setup.cfg`; scope file `.py`)
- **Go modules** (`go.mod`; scope file `.go`)
- **crates.io** (`Cargo.toml`; scope file `.rs`)
- **RubyGems** (`Gemfile`/`*.gemspec`; scope file `.rb`)
- **Docker base-image tags** (`FROM image:tag` — needs container-registry endpoints)
- **framework/SDK/runtime versions** (`<TargetFramework>`, `global.json`
  `sdk.version`, Node `engines`, `requires-python`, Go directive)

**Critical lockstep rule:** every new ecosystem extends BOTH the engine scope set
AND the Step 2.6 trigger prose (and the new sync test's extension loop). The whole
point of this session's fix was that those two had drifted.

### 8c. Maintenance-health axis (surfaced, recorded own-or-defer, default defer)

A 4th axis orthogonal to freshness/CVE/pinning: a dep can be on latest GA yet
abandoned (archived repo, single maintainer, stale last-publish, registry
`deprecated`/yank flag). Slice 2 already shipped a `health` field for NuGet
deprecation (see `_nuget_health`, engine ~line 672, rendered per
`housekeeper-reviewer.md:55`). Extending health reads to other registries is
near-zero marginal cost (the engine already fetches registry JSON for licence-diff)
and stays deterministic + hash-testable. See memory
`project_housekeeper_maintenance_health_axis.md`.

### 8d. Explicitly out of scope (own accuracy designs, do NOT fold in casually)

- Tier-2 free-text pins (`RUN apt-get install foo=1.2.3`, `pip install bar==1.0`)
  — parsing unreliable AND "latest GA" often distro-pinned/ambiguous; violates the
  no-finding-without-a-trustworthy-latest-GA rule.
- Free-alternative-package suggestions (non-deterministic, not hash-testable).
- Live SHA→tag commit lookup (engine trusts the `# vX.Y.Z` comment by design).
- IaC misconfig (trivy-reviewer owns it) and "should this be SHA-pinned"
  supply-chain judgement (security #6b owns it).

### 8e. The other open horizon item (not housekeeper-specific)

**Orchestrator → Workflow migration** (`project_orchestrator_workflow_migration`):
benefits all specialists, but only dissolves real fragility for the four static
ones (those with an A/B content parser). Don't "schema everything." Separate track
from the housekeeper ecosystem work — mentioned so you have the full map.

### 8f. A/B discipline (if you ship a new ecosystem)

Every other static specialist shipped sonnet first and earned a haiku/low flip via
a 20/20 recorded-fixture equivalence sweep. The housekeeper was shipped haiku/low
directly (user's call, recorded against discipline) and validated EQUIVALENT 20/20
twice (slice 1 ~2.38x, slice 2 ~2.06x). For a NEW ecosystem slice, run the
recorded-fixture A/B sweep post-build; sonnet is the fallback if equivalence fails.
A/B apparatus lives under `tests/ab/` (corpus, configs/per-agent, fixtures, lib).

---

## 9. Provenance / related reading

- Original design: `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`
  (the three-tier scope model T1/T2/T3 this fix completes).
- Slice plans/handovers under `docs/superpowers/plans/` and
  `docs/superpowers/handover/` dated 2026-06-05.
- Memories (in `~/.claude`): `project_housekeeper_specialist_slice1`,
  `…slice2`, `…maintenance_health_axis`, `project_code_review_suite_backlog`,
  `project_orchestrator_workflow_migration`.
- Engine: `plugins/code-review-suite/bin/housekeeper-freshness` (854 lines, stdlib
  Python, 31 unittests in `tests/python/test_housekeeper_engine.py`).
- Agent: `plugins/code-review-suite/agents/housekeeper-reviewer.md` (thin §7
  renderer, `model: haiku` + `effort: low`).
