# Handover — housekeeper PyPI dependency freshness slice

**Date:** 2026-06-12
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (the personal plugin
marketplace — independently versioned, its own CI/CLAUDE.md/test suite; push to
its own `origin`, NOT the `claude-settings` repo).
**Branch:** `main` (house rule: direct-push to `main`, push immediately after
each commit).

---

## 1. What this is

Add a **PyPI source class** to the `housekeeper-freshness` engine: flag Python
dependency declarations whose pinned version is behind the latest GA on PyPI.
This is the **next vertical slice** on the same chassis as slices 1–3
(Actions/runner → npm → NuGet → Docker). The user picked **PyPI next, then Go
modules** after that.

**This slice is NOT yet designed.** Unlike the Docker handover (which pointed at
a finished spec + plan), PyPI has neither. **Start at brainstorming**, then spec,
then plan, then implement — the full superpowers cycle. Do NOT jump to code.

---

## 2. First action (mandatory)

Invoke **`superpowers:brainstorming`** with the user before any design artifact.
The brainstorm must resolve the open design questions in §5 below. Only after the
user signs off on the shape do you write the spec (`superpowers:writing-plans`
precursor → a design spec under `docs/superpowers/specs/`), then the
implementation plan (`superpowers:writing-plans`), then execute it via
**`superpowers:subagent-driven-development`** (the user's chosen execution mode
for this programme — fresh implementer per task + two-stage review: spec
compliance then code quality).

Read these FIRST for context (they make the chassis obvious and most PyPI
decisions fall out by analogy):

- The slice-3 (Docker) design spec — the most recent, closest-shaped precedent:
  `docs/superpowers/specs/2026-06-11-housekeeper-docker-slice-design.md`
- The slice-3 plan (shows the task breakdown shape that worked):
  `docs/superpowers/plans/2026-06-11-housekeeper-docker-slice.md`
- The slice-3 result note (the single-arm A/B verdict + the execution learnings):
  `docs/superpowers/notes/2026-06-12-housekeeper-docker-haiku-low-result.md`
- The original chassis spec:
  `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`
- The source-file-trigger spec (explains the Step 2.6 lockstep + scope-suffix
  mirroring): `docs/superpowers/specs/2026-06-11-housekeeper-source-file-trigger-design.md`
- Engine: `plugins/code-review-suite/bin/housekeeper-freshness` (now ~1015 lines,
  5 source classes).
- Agent: `plugins/code-review-suite/agents/housekeeper-reviewer.md`.

---

## 3. The chassis — what every slice adds (proven 3× now)

A new ecosystem is a fixed checklist. For PyPI:

1. **Parser** — read Python dependency declarations into
   `[(name, spec, line)]`-shaped tuples. (Decide which files/formats — see §5.)
2. **Version/constraint strip** — a `pypi_strip_constraint(spec)` analogous to
   `strip_constraint` (npm) / `nuget_strip_constraint`: return a concrete pinned
   version, or None for anything we can't name a trustworthy "current" for
   (ranges, `>=`, wildcards, markers, URLs/VCS installs, extras).
3. **Registry client** — `Registry.pypi_*` hitting the PyPI JSON API
   (`https://pypi.org/pypi/<project>/json`) with a `pypi/<slug>.json` fixture
   override. Reuse the existing `is_ga`/`latest_ga`/`nearest_in_major`/
   `compare_versions` core (PEP 440 → semver-ish; see §5 for the prerelease/
   epoch wrinkle).
4. **Scope resolver** — a `pypi_scope_roots` analogous to `nuget_scope_roots`/
   `npm_scope_roots`: a changed Python source file (`.py`/`.pyi`?) pulls in its
   nearest-ancestor project manifest; audit ALL that project's deps, not just
   changed lines. Add a `_PYPI_SCOPE_SUFFIXES` set. (Anchor: the unit boundary —
   §5 decides what defines a Python "buildable unit".)
5. **Collector** — `collect_pypi` emitting the 10-key tuple
   (`source: "pypi"`, licence/health per §5).
6. **Wire into `collect_findings`** — discover manifests in the existing
   `os.walk` (mind the prune set: `node_modules`/`bin`/`obj` — add `.venv`/
   `__pycache__`/`.tox`?), resolve scope after the other roots, append
   `collect_pypi`.
7. **Agent renderer** — add `pypi` to the `Rule:` enumeration + a worked-example
   `### Finding` block (em-dash heading, exact §7 bullet field names).
8. **Trigger lockstep** — extend the Step 2.6 "Housekeeping detection" bullet
   BYTE-IDENTICALLY across the THREE synced files (`includes/review-pipeline.md`
   canonical, `commands/pre-review.md`, `skills/review-gh-pr/SKILL.md`) and
   extend the sync test `test_housekeeping_trigger_mirrors_engine_scope`
   (`tests/lib/test_sync_notes.sh`) to pin the new Python suffixes / manifest
   tokens against the engine scope constants. **Lockstep rule:** every new scope
   suffix extends BOTH the engine constant AND the trigger prose AND the sync
   test loop.
9. **On-disk regression fixture** under
   `tests/fixtures/static-analysis/housekeeper-pypi/` proving the Anchor scope
   pull-in on disk (a source-only changeset surfaces the manifest finding) +
   recorded `registry/pypi/<slug>.json` tag/release data.
10. **Single-arm A/B corpus + config** — `tests/ab/corpus/housekeeper-pypi-stale-deps/`
    (`source.yaml` + `diff/changed-lines.txt` + `expected/findings.json` +
    `expected/findings-<…>.md`) and `tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml`.
    **CRITICAL — do not repeat the slice-3 miss:** also add the corpus to
    `tests/ab/corpus/index.yaml` (the harness gates `fixture_load` on the index;
    a corpus dir without an index row fails preflight). Make this an explicit
    plan step.
11. **Full verification + push + the single-arm haiku/low 20/20 sweep** (manual
    interactive — see §6) + result note + memory.

---

## 4. Decisions ALREADY settled (carry from prior slices — do NOT re-litigate)

- **A/B is single-arm** (haiku/low 20/20 recorded-fixture sweep). The
  chassis-equivalence question is closed — slices 1, 2, 3 all EQUIVALENT 20/20;
  the renderer is a thin §7 projection. A single-arm sweep guards apparatus
  determinism (empty-stdout, format drift, temp-dir self-abort, install race),
  not the model tier. Sonnet is the documented fallback only if a tail appears.
- **Trust gate = act only on a concrete pinned version.** No ranges, no floating,
  no "no trustworthy current". This is also the boundary that keeps us from
  colliding with any CVE scanner (analogous to the Docker↔trivy boundary).
- **Diff is a selector, not a filter.** A changed source file selects WHICH unit
  to audit; it never restricts findings to changed lines — audit the whole
  touched project's deps. CI (`.github/workflows`) is always in scope. See memory
  `feedback_housekeeper_diff_is_selector_not_filter`.
- **Touched manifest line → latest GA; untouched (Anchor pull-in) → nearest
  in-major.** (The T3 target-modulation rule, uniform across sources.)
- **`health`/licence:** the maintenance-health axis exists (deprecated/unlisted)
  but is populated only where the registry gives a deterministic signal. PyPI's
  JSON has a `yanked` flag per release — decide in §5 whether to surface it as a
  health rider (likely yes — it's the PyPI analogue of npm `deprecated` / NuGet
  `unlisted`) or defer.
- **The shipped agent tier is `model: haiku` + `effort: low`** and is validated
  for all 5 current source classes. A clean EQUIVALENT VALIDATES the tier for
  PyPI; no flip needed.

---

## 5. Open design questions the BRAINSTORM must resolve

These are the genuinely PyPI-specific calls — the reason this slice needs a
brainstorm, not just a copy of the Docker plan:

1. **Which manifests do we parse, and in what priority?** Candidates:
   `pyproject.toml` (PEP 621 `[project].dependencies` + `[project.optional-dependencies]`;
   AND/OR Poetry `[tool.poetry.dependencies]`; AND/OR PDM/Hatch tables),
   `requirements*.txt` (and `-r` includes?), `setup.cfg`, `setup.py` (almost
   certainly OUT — arbitrary code, no static parse), `Pipfile`, `constraints.txt`.
   Recommendation to pose: start with `pyproject.toml` (PEP 621 + Poetry tables)
   and `requirements*.txt`, defer the rest — but let the user choose the scope.
   NOTE: stdlib has `tomllib` (3.11+) — confirm the engine's Python target allows
   it, else a hand parser or vendored fallback. The engine is pure-stdlib by
   design; a TOML parse is the one genuinely new capability this slice needs.
2. **Constraint grammar (PEP 440).** `==1.2.3` is the obvious concrete pin.
   What about `~=1.2.3` (compatible release), `>=1.2,<2`, `==1.2.*`, extras
   (`pkg[foo]==1.2.3`), environment markers (`; python_version < "3.11"`), and
   Poetry's `^1.2.3`/`~1.2.3`? Decide which yield a trustworthy "current" and
   which are skipped. PEP 440 prerelease/epoch (`1!2.3`, `1.2.3rc1`,
   `1.2.3.post1`, `1.2.3.dev0`) needs a parse/`is_ga` decision — the existing
   `parse_version`/`is_ga` are semver-ish and will NOT correctly handle epochs or
   `rcN`-without-hyphen. This is the analogue of the Docker `_DOCKER_CORE_RE`
   work and is probably the single biggest engine task.
3. **What defines a Python "buildable unit" for Anchor scope?** The nearest-
   ancestor `pyproject.toml`? Or any of the manifest set? (npm = nearest
   `package.json`; NuGet = nearest `.csproj`.) And which source extensions pull a
   unit in — `.py`, `.pyi`, notebooks `.ipynb`? Define `_PYPI_SCOPE_SUFFIXES`.
4. **`requirements.txt` has no "unit" the way pyproject does** — a bare
   `requirements.txt` at a directory IS the manifest. Decide how it participates
   in Anchor scope (is the requirements file its own unit root? does a sibling
   `.py` change pull it in?).
5. **PyPI `yanked` → health rider, or defer?** (See §4.) Cheap to add if we're
   already in the JSON.
6. **Registry shape.** PyPI `https://pypi.org/pypi/<project>/json` returns
   `{"releases": {version: [...]}, "info": {...}}`. Decide: take
   `releases.keys()` and feed to `latest_ga`? Filter yanked? The `info.version`
   is "latest" but may be a prerelease — prefer the explicit GA computation.
7. **Housekeeping freshness scope (the user's standing rule):** while we're in
   here, surface any dep/action/runner/IaC freshness in THIS repo as part of the
   job — but this repo is a plugin marketplace (no Python package of its own), so
   likely nothing to bump. Confirm during brainstorm; raise as a separate small
   PR if anything turns up.

---

## 6. The A/B sweep is a MANUAL, INTERACTIVE step (cannot be subagent-run)

Same as every prior slice. After the final push:

- **Cache refresh first:** `/plugins update` (refreshes DISK from GitHub) THEN
  `/reload-plugins` (reloads in-memory registry from disk). The sweep exercises
  the engine BINARY — a stale cache captures the pre-PyPI engine and the sweep is
  meaningless. (Memory `project_plugin_cache_staleness` /
  `feedback_plugins_update_after_push`.)
- **Confirm the corpus is in `tests/ab/corpus/index.yaml`** before launching
  (slice-3 nearly tripped on this — see §3 step 10).
- **Drive the sweep** (the exact invocation that worked for slice 3):
  ```
  tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml \
    --trials 20 --corpus housekeeper-pypi-stale-deps \
    --faithfulness-check --stream-json
  ```
  Run it `run_in_background: true`. Pass = exit 0 + "faithfulness check PASSED
  (20/20)" + all 20 `summary.csv` rows share one `findings_hash`, no
  skips/inconclusive/timeouts. If a tail appears, STOP and report — sonnet is the
  fallback.
- **Live-honesty:** the corpus's stale package must be genuinely behind on the
  live registry (the harness scrubs subprocess env, so the engine hits real
  pypi.org, not the fixture). Pick a real package + an old-but-real pinned
  version whose latest GA is unambiguously higher (the `WindowsAzure.Storage`
  lesson from slice 2 / the `node:18.20.0-alpine` choice from slice 3). If you
  use the `yanked` health rider, the corpus health package must be genuinely
  yanked/withdrawn live.
- **Record the result** to
  `docs/superpowers/notes/2026-06-12-housekeeper-pypi-haiku-low-result.md` (mirror
  the slice-3 note: single-arm structure, headline, single-arm rationale, config,
  canonical hash, distribution, cost, live-registry note, pre-flight, verdict,
  production-flip decision) and update memory (see §8).

---

## 7. House rules (this repo)

- Direct-push to `main`; push immediately after each commit. No Co-Authored-By /
  advertising trailers.
- **Bash hook rules (strict):** one command per Bash call — no `&&`/`||`/`;`, no
  `$(...)`/backticks, no subshells, no heredocs in Bash. Carve-out: the
  `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC IS permitted for multi-line
  commit bodies. For multi-line Python, Write a file under `$CLAUDE_TEMP_DIR` and
  run it — do NOT pipe a heredoc to `python3`.
- `$CLAUDE_TEMP_DIR` is injected into context by a SessionStart hook but is NOT
  exported into the Bash shell env — use the LITERAL `/tmp/claude-<session-id>`
  path string in Bash `>` redirects, and pass it into subagent prompts.
- **Subagents:** set `mode: "auto"` and a kebab-case `name` on every dispatch
  (so a plan-mode parent doesn't stall the subagent). Pass the resolved
  `$CLAUDE_TEMP_DIR` literal into subagent prompts.
- **`pytest` is NOT installed on this machine.** The engine test file is plain
  `unittest`; run e.g.
  `python3 -m unittest tests.python.test_housekeeper_engine.<Class> -v` from the
  repo root. (The plan's per-task commands assume pytest; substitute unittest.)
- **Known test artifact:** `A/B run.sh: bad-config rejection leaves working tree
  clean` false-fails on a DIRTY tree. Commit first, then re-run `bash tests/run.sh`
  to confirm green (400 tests: 399 pass, 1 pre-existing skip).
- Plugin-authoring frontmatter conventions (repo CLAUDE.md): command/skill files
  need `name` + `description` frontmatter and a blank line after the closing `---`.
- **Subagent Write-guard false-positive (seen in slice 3):** the Write tool
  refused to create `expected/findings-housekeeper.md` (matched a "subagent report
  file" heuristic on `findings`/`.md`). It's a legitimate corpus data fixture. If
  it recurs, the workaround is Write-to-`$CLAUDE_TEMP_DIR`-then-`cp`; flag it.

---

## 8. Memory to update after landing (in the `~/.claude` repo, committed separately)

- Add a **slice-4 memory** `project_housekeeper_specialist_slice4.md` mirroring
  slice1/2/3: what shipped (PyPI source class, manifest parser, PEP 440 handling,
  scope), the single-arm A/B verdict + cost note, execution learnings. Link
  `[[housekeeper-specialist-slice3]]`,
  `[[feedback_housekeeper_diff_is_selector_not_filter]]`.
- Update `MEMORY.md` index with the one-line pointer.
- Commit + push in the `~/.claude` repo (`claude-settings`) — it is a SEPARATE
  git repo from the plugin marketplace with its own origin. The memory dir is
  exempt from org/identity scrubbing (private repo; public seed ships no memory).
  Secret-shaped patterns still bite.

---

## 9. After PyPI: Go modules (do NOT start without the user)

Go modules is the next slice after PyPI — its own brainstorm → spec → plan →
implement cycle on the same chassis (parse `go.mod`; the proxy
`https://proxy.golang.org/<module>/@v/list`; Go's `vN+` major-suffix import-path
convention is the analogue of the Docker variant wrinkle). Raise it with the user
once PyPI ships. Do not fold it into this slice.

---

## 10. Provenance / state at handover

- Slice 3 (Docker) SHIPPED + swept EQUIVALENT 20/20 on 2026-06-12. Engine commits
  `287b422`..`85b9b44`; corpus-index fix `a981b0a`; result note `85b9b44`. Memory
  `project_housekeeper_specialist_slice3` committed to `~/.claude` (`bc2a35c`).
- Current `main` HEAD of the plugin repo: `85b9b44` (verify with `git log`).
- Five source classes live: github-actions, runner, npm, nuget, docker. PyPI is
  the sixth.
- Relevant memories (in `~/.claude`): `project_housekeeper_specialist_slice3`,
  `…slice2`, `…slice1`, `feedback_housekeeper_diff_is_selector_not_filter`,
  `project_housekeeper_maintenance_health_axis`, `project_plugin_cache_staleness`,
  `feedback_plugins_update_after_push`, `project_code_review_suite_backlog`.
