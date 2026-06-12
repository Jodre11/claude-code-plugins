# Housekeeper PyPI dependency-freshness slice — design

**Date:** 2026-06-12
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (the personal plugin
marketplace — independently versioned, own CI/CLAUDE.md/test suite; push to its
own `origin`, NOT the `claude-settings` repo).
**Status:** design approved; pending spec review before writing-plans.

---

## 1. Goal

Add a **PyPI source class** to the `housekeeper-freshness` engine so the
housekeeper specialist flags Python dependency declarations whose pinned version
is behind the latest GA on PyPI. This is the **sixth** vertical slice on the same
chassis as github-actions / runner / npm / nuget / docker (slices 1–3). The
user's requested order is **PyPI next, then Go modules**. See
[[housekeeper-specialist-slice3]], [[housekeeper-specialist-slice2]],
[[housekeeper-specialist-slice1]].

The unifying principle holds: **the diff is a selector and target-modulator, not
a findings filter** — a changed source file selects which buildable unit to
audit; that unit's manifest is in scope because it belongs to the unit, and all
its dependencies are candidates (changed manifest lines only modulate the upgrade
target). See [[housekeeper-diff-is-selector-not-filter]].

---

## 2. Scope & trust gate

### 2.1 Which manifests are parsed

This slice parses:

- **`pyproject.toml`** — both:
  - **PEP 621** standard tables: `[project].dependencies` and
    `[project.optional-dependencies]` (the format new, well-run projects should
    use; tool-agnostic, read by pip/uv/Hatch/PDM/Poetry 2.0+).
  - **Poetry legacy** tables: `[tool.poetry.dependencies]` and
    `[tool.poetry.group.<name>.dependencies]`. NOT PEP 621 — a different version
    grammar (npm-style caret/tilde). Retained because a large installed base
    still uses it; dropping it would silently miss those projects.
- **`requirements*.txt`** — line-oriented pin files (`requirements.txt`,
  `requirements-dev.txt`, etc.). The dominant style for applications,
  deployments, and CI pins; not a "should-use" library format but overwhelmingly
  present and exactly the freshness reality the housekeeper exists to catch.

**Deliberately OUT this slice:**

- `setup.py` — arbitrary executable code; no safe static parse. Permanent out.
- `setup.cfg`, `Pipfile` — legacy-trending; extra grammar surface not justified
  in slice 1. Follow-on candidates on the same chassis if a real repo needs them.

### 2.2 Trust gate — act only on the floor of a single-anchor concrete version

Honours the engine's no-finding-without-a-trustworthy-latest-GA rule, and
mirrors the shipped, 20/20-validated npm `strip_constraint` behaviour (act on the
lower-bound concrete version of a single-anchor spec). A new
`pypi_strip_constraint(spec)` returns a concrete current version, or `None`.

**Act on** (extract the concrete floor and check freshness):

- `==1.2.3` — exact pin.
- `~=1.2.3` — compatible release (floor `1.2.3`).
- `>=1.2.3` — open lower bound (floor `1.2.3`).
- Poetry `^1.2.3` / `~1.2.3` — caret/tilde (floor `1.2.3`).
- bare `1.2.3` — Poetry / requirements implicit pin.

Pre-processing before the anchor test:

- **Extras** (`pkg[foo]==1.2.3`) → strip the `[foo]`, act on `pkg`.
- **Environment markers** (`pkg==1.2.3 ; python_version < "3.11"`) → strip the
  `; marker`, act on the version spec.

**Skip** (no trustworthy "current" — deliberately, to avoid an untrustworthy or
noisy answer):

- **Wildcards** (`==1.2.*`, `1.*`) — no single concrete version.
- **Upper-bounded multi-clause ranges** (`>=1.2,<2`) — the author deliberately
  capped the range; flagging it "behind 3.0" reports a choice they opted out of
  (the PyPI analogue of the Docker floating-tag skip). Skip.
- **`!=` exclusions** — no positive anchor.
- **URL / VCS / path / local installs** (`pkg @ git+https://…`,
  `pkg @ file://…`, `./pkg`, `-e …`) — value is not a registry version.
- Anything otherwise unparseable.

### 2.3 Tier model (uniform across sources)

- **T2 (which deps):** every act-on dependency in an in-scope manifest is a
  candidate — not only changed lines.
- **T3 (target modulation):** a dependency whose manifest line the diff touched
  is suggested at the **latest GA**; an untouched in-scope dependency (pulled in
  by Anchor scope) is suggested at the **nearest in-major**.

Severity is uniform `Suggestion` ("staleness is a smell, not a defect"); every
finding emits `Confidence: 100`.

---

## 3. PEP 440 version core (new engine capability)

The existing `parse_version` / `is_ga` are semver-ish and will **mis-handle**
PyPI versions. PyPI gets its own `pypi_parse_version` / `pypi_is_ga`:

- **Prereleases have NO hyphen** in PEP 440: `1.2.3rc1`, `1.2.3a1`, `1.2.3b2`,
  `1.2.3.dev0`. The existing `is_ga` ("no hyphen after the numeric core") would
  wrongly classify these as GA. `pypi_is_ga` must detect the `aN`/`bN`/`rcN`/
  `.devN` prerelease segments and return **False** for them.
- **Post-releases** (`1.2.3.post1`) are GA and **newer** than `1.2.3`.
- **Epochs** (`1!2.3`) sort above non-epoch versions regardless of release
  tuple.
- **Local versions** (`1.2.3+ubuntu1`) — strip the `+local` segment; compare as
  `1.2.3`.

The comparison key is `(epoch, release-tuple, post)` with prereleases sorting
**below** the corresponding bare release. This is the single biggest engine task
this slice — the analogue of the Docker `_DOCKER_CORE_RE` work. (Exact
regex/parse mechanism is an implementation-plan detail.)

`latest_ga` / `nearest_in_major` are reused, parameterised over the PyPI
GA-filter and compare (or PyPI-specific variants if the existing signatures
cannot be cleanly reused — an implementation detail, not a design constraint).

---

## 4. TOML parsing — `tomllib`, hard-require Python 3.11+

`pyproject.toml` requires reading TOML — the one genuinely new *capability* in
this slice (every prior source was regex-over-lines). The engine is pure-stdlib
by design; `tomllib` is stdlib but only on **Python 3.11+**.

**Decision: use `tomllib`; hard-require 3.11+.** On an older interpreter the
agent's tool-resolution step emits
`Skipped — python3 ≥3.11 required (PyPI TOML parsing)` and stops.

**Rationale.** The interpreter in question is the **reviewer's / CI runner's**,
not the reviewed project's Python (a 3.14 reviewer box audits a project that
targets `requires-python = ">=3.8"` fine). By mid-2026, 3.11 is ~3.5 years old
and 3.10 reaches end-of-life in October 2026 — a sub-3.11 review *environment* is
itself a thing to update. Surfacing that with an explicit skip message is more
honest than hiding a coverage gap behind a silent partial parse, and it keeps the
engine simpler (no per-manifest fallback branch). A hand-rolled minimal TOML
reader was rejected: re-implementing TOML (multiline arrays, inline tables,
quoting) is an error-prone maintenance liability — exactly the half-spec parser
that bites later.

`requirements*.txt` parsing is plain line-oriented and has no version floor.

---

## 5. Registry client & version selection

### 5.1 Endpoint

PyPI JSON API: `GET https://pypi.org/pypi/<project>/json`, returning
`{"info": {...}, "releases": {version: [file-records...]}}`. Pure `urllib`, the
same `fetch`-style path as npm — **no auth dance** (simpler than Docker's OCI
challenge).

A new `Registry` method (shape analogous to the existing per-source methods),
e.g. `pypi_releases(project) -> {version: [file-records]} or None`. `None` on any
miss/error → caller emits no finding.

### 5.2 Fixture override

`<fixtures_dir>/pypi/<slug>.json`, where `<slug>` is the **PEP 503 normalised**
project name (lowercase; runs of `[-_.]` collapsed to a single `-`). Same
mechanism as the existing `fetch` / `registration` / `docker` overrides. File
content mirrors the live JSON shape (`{"info": {...}, "releases": {...}}`).

### 5.3 Version selection

- Candidate versions = `releases.keys()` — **not** `info.version` (which may be a
  prerelease); GA is computed explicitly via `pypi_latest_ga`.
- **Yanked filter (PEP 592):** a release whose file records are all
  `"yanked": true` is **excluded from the target** computation (never suggest
  upgrading *to* a yanked release). The current pin being yanked drives the
  health rider (§5.4), not the target.
- `latest = pypi_latest_ga(non_yanked_versions)`; if none, **skip** (no
  trustworthy answer).
- `stale = compare_versions(latest, current) > 0`.
- T3: `target = latest` if the manifest line is touched, else
  `nearest_in_major(current, non_yanked_versions)`; if the in-major target is not
  newer than current, `stale = False`.

### 5.4 Health rider — `yanked` (settled)

PyPI's per-release `yanked` flag is the direct analogue of npm `deprecated` /
NuGet `unlisted`, both already surfaced as a uniform `health` rider. If the
pinned **current** version is yanked → `health = {"state": "yanked", "detail":
<yank reason or "">}`. Emit rule mirrors npm/NuGet: **stale OR health-flagged** —
a current-but-yanked pin is flagged even when not behind, with no upgrade target
(pure-health render path, per the agent's existing rule).

### 5.5 Licence — deferred this slice

`licence_current` / `licence_latest` are **`null`** this slice (like Docker).

**Rationale.** PyPI licence data is cheap to fetch (a per-version
`…/<project>/<version>/json` endpoint exists) but **messy**: `info.license` is
free text — frequently the entire licence body inline, a short tag, or empty — and
the real signal often lives in the trove `classifiers` (`License :: …`) or the
newer PEP 639 `license-expression` SPDX field. Normalising free-text ∪ classifier
∪ SPDX into a comparable value risks a **false "licence changed" claim**, which
violates the no-untrustworthy-finding north star. And because the clean-signal
subset is small (much PyPI licence data is empty/free-text), the per-version
fetch + normalisation + fixture apparatus would buy low yield for real surface.
Licence-diff is therefore deferred to a focused **cross-source** follow-on (it
benefits all registry-backed sources uniformly, not PyPI alone), where the
normaliser can be designed and tested properly.

---

## 6. FROM-analogue parsers & collector

### 6.1 `parse_pyproject(text) -> [(name, spec, line_no)]`

Parse with `tomllib`. Collect dependency declarations from:

- PEP 621 `[project].dependencies` (list of PEP 508 requirement strings) and
  `[project.optional-dependencies].<group>` (each a list of requirement strings).
- Poetry `[tool.poetry.dependencies]` and
  `[tool.poetry.group.<name>.dependencies]` (table: `name = "<spec>"`, or
  `name = {version = "<spec>", ...}`). Skip the `python` pseudo-dependency.

`tomllib` does not expose source line numbers. The collector resolves each
dependency's `line_no` by a **post-parse line scan**: locate the first line whose
text contains the dependency name in a dependency context (the same
one-occurrence-per-line assumption the csproj/npm parsers already make). The
recorded line drives only T3 touched/untouched modulation; a best-effort line is
acceptable and consistent with prior sources. (Exact line-attribution mechanism
is an implementation-plan detail.)

### 6.2 `parse_requirements(text) -> [(name, spec, line_no)]`

Line-oriented. For each physical line: strip inline `#` comments; skip blank
lines, full comment lines, option lines (`-r`/`--requirement`, `-c`/
`--constraint`, `-e`/`--editable`, `--index-url`/`--extra-index-url`/`--hash`/
other `--flags`), and URL/VCS/path entries. Emit `(name, spec, line)` for the
rest; `pypi_strip_constraint` applies the §2.2 trust gate downstream.

Known limitation (documented, consistent with prior sources): one requirement per
physical line; `-r nested.txt` includes are NOT followed this slice.

### 6.3 `collect_pypi(pyproject_text, requirements_text, changed_lines, registry)`

Maps each in-scope manifest path → its content. Mirrors `collect_npm`:

- For each manifest, for each `(name, spec, line)`:
  - `current = pypi_strip_constraint(spec)`; if `None`, skip.
  - `releases = registry.pypi_releases(name)`; if `None`, skip.
  - Compute `non_yanked` versions; `latest = pypi_latest_ga(non_yanked)`; if no
    GA, skip.
  - `health` = yanked rider if `current` is yanked, else `None`.
  - `stale` + T3 `target` per §5.3.
  - Emit only when **stale OR health-flagged** (the npm/NuGet widened rule):
    ```
    {"source": "pypi", "item": <name>, "current": <current>,
     "latest_ga": <latest>, "target": <target>,
     "file": <path>, "line": <line>,
     "licence_current": null, "licence_latest": null, "health": <health>}
    ```
  - Pure-health (`health` set, not stale) → `target = current`.

### 6.4 Scope resolver

`_PYPI_SCOPE_SUFFIXES = (".py", ".pyi")`.

`pypi_scope_roots(changed_files, all_pyprojects, all_requirements)` returns the
in-scope `(pyproject set, requirements set)`:

- A changed `.py`/`.pyi` walks up to its **nearest-ancestor `pyproject.toml`**
  (deepest-dir wins, mirroring `nuget_scope_roots`/`npm_scope_roots`) → in-scope
  pyproject.
- A **directly-changed** `pyproject.toml` or `requirements*.txt` is always in
  scope (it *is* a manifest, like a changed `package.json`).
- A changed `.py`/`.pyi` with **no** pyproject ancestor but **with** a
  `requirements*.txt` in an ancestor dir pulls that requirements file in
  (sibling-source pull-in — gives the requirements-only project the same scope
  symmetry as the pyproject case).

### 6.5 `collect_findings` wiring

- Extend the existing `os.walk` discovery to collect `all_pyprojects` (basename
  `pyproject.toml`) and `all_requirements` (basename matches `requirements*.txt`).
- Extend the prune set: add `.venv`, `__pycache__`, `.tox`, `.eggs` to the
  existing `node_modules`/`bin`/`obj`.
- Resolve PyPI scope after the npm/nuget/docker roots; read in-scope manifests;
  call `collect_pypi`; append to `findings`. The existing deterministic sort
  (`file, line, source, item`) orders the new tuples.

---

## 7. Agent rendering

`agents/housekeeper-reviewer.md`:

- Add `pypi` to the `Rule:` source enumeration: `housekeeper/pypi`.
- Description: `<name> is at <current>; latest GA is <latest_ga>.` Health clause
  fires for a yanked current (`Marked yanked in the registry: <detail>.`); no
  licence clause (null this slice).
- Suggested fix: `Upgrade <name> to <target>.` Pure-health (yanked-but-current):
  `Review: <name> is current but marked yanked.`
- Add a `pypi` `### Finding` block to the worked example: a stale `==` pin (e.g.
  `requests==2.20.0` where latest GA is higher) **and** a yanked-current example
  to exercise the health rider. Em-dash heading; exact §7 bullet field names; the
  harness parser is unchanged.

---

## 8. Trigger wiring (lockstep mirror contract)

Per [[housekeeper-diff-is-selector-not-filter]] and the source-file-trigger
design, every new scope source extends BOTH the engine scope constant AND the
Step 2.6 `$HOUSEKEEPING_DETECTED` trigger prose AND the sync test, in lockstep.
For PyPI:

- Extend the Step 2.6 "Housekeeping detection" bullet **byte-identically** across
  the three synced files (`includes/review-pipeline.md` canonical,
  `commands/pre-review.md`, `skills/review-gh-pr/SKILL.md`):
  - new source-file suffixes `.py`, `.pyi`;
  - new manifest tokens `pyproject.toml`, `requirements*.txt`.
- Extend `test_housekeeping_trigger_mirrors_engine_scope`
  (`tests/lib/test_sync_notes.sh`) to assert the new Python suffixes appear in the
  trigger prose and are pinned against `_PYPI_SCOPE_SUFFIXES`.

**Lockstep rule:** every new scope suffix extends the engine constant AND the
trigger prose AND the sync-test loop.

---

## 9. Testing

### 9.1 Engine unittests (`tests/python/test_housekeeper_engine.py`, run via `unittest`)

`pytest` is NOT installed; the file is plain `unittest`. Run e.g.
`python3 -m unittest tests.python.test_housekeeper_engine.<Class> -v`.

- `pypi_parse_version` / `pypi_is_ga`: prerelease-without-hyphen (`1.2.3rc1`,
  `1.2.3a1`, `1.2.3.dev0`) → non-GA; post-release (`1.2.3.post1`) > `1.2.3`;
  epoch (`1!2.3`) sorts above; local-version strip (`1.2.3+ubuntu1`).
- `pypi_strip_constraint`: each act-on form (`==`, `~=`, `>=`, Poetry `^`/`~`,
  bare) → floor; each skip form (wildcard, upper-bounded range, `!=`, URL/VCS/
  path/editable); extras strip; marker strip.
- `parse_pyproject`: PEP 621 `dependencies` + `optional-dependencies`; Poetry
  `[tool.poetry.dependencies]` + group tables; `python` pseudo-dep skipped.
- `parse_requirements`: `name==1.2.3` emitted; `-r`/`-c`/`-e`/comment/option/URL
  lines skipped.
- `pypi_scope_roots`: `.py` → nearest pyproject; directly-changed manifest always
  in; sibling-source → requirements fallback when no pyproject ancestor; a `.py`
  under no manifest yields nothing.
- `collect_pypi` end-to-end against recorded `pypi/<slug>.json` fixtures: stale
  `==` pin emits; untouched line → nearest-in-major; yanked-current → health
  rider; a yanked release is excluded from the target.

### 9.2 On-disk regression fixture

`tests/fixtures/static-analysis/housekeeper-pypi/` proving Anchor scope pull-in on
disk: a source-only changeset (a `.py` edit) surfaces the manifest's stale-dep
finding, with recorded `registry/pypi/<slug>.json` release data.

### 9.3 Sync test

Extend `test_housekeeping_trigger_mirrors_engine_scope` to pin the new Python
suffixes / manifest tokens against the engine scope constant (§8).

### 9.4 Single-arm A/B sweep (settled discipline)

A **single-arm haiku/low** 20-trial recorded-fixture sweep. The sonnet-vs-haiku
chassis-equivalence question is closed (slices 1–3 all EQUIVALENT 20/20; the
renderer is a thin §7 projection). What the single-arm 20/20 guards is **apparatus
determinism** — empty-stdout, format drift, temp-dir self-abort, install race,
fixture round-trip — not the model tier. Sonnet is the documented fallback if a
tail appears.

Build:

- Corpus `tests/ab/corpus/housekeeper-pypi-stale-deps/` (`source.yaml` +
  `diff/changed-lines.txt` + `expected/findings.json` +
  `expected/findings-<…>.md`).
- Config `tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml`.
- **CRITICAL — corpus index row.** Add the corpus to
  `tests/ab/corpus/index.yaml` (the harness gates `fixture_load` on the index; a
  corpus dir without an index row fails preflight). This is an explicit plan step
  (the slice-3 near-miss).

**Live-honesty.** The harness scrubs subprocess env, so the engine hits real
pypi.org during the sweep, not the fixture. The corpus's stale package must be a
real package at a real old pin whose latest GA is unambiguously higher (the
`WindowsAzure.Storage` lesson from slice 2 / the `node:18.20.0-alpine` choice from
slice 3). The yanked example must use a genuinely-yanked release.

Sweep invocation (mirrors slice 3, run `run_in_background: true`):

```
tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml \
  --trials 20 --corpus housekeeper-pypi-stale-deps \
  --faithfulness-check --stream-json
```

Pass = exit 0 + "faithfulness check PASSED (20/20)" + all 20 `summary.csv` rows
share one `findings_hash`, no skips/inconclusive/timeouts.

---

## 10. Relationship to other specialists (no double-reporting)

- **security-reviewer** owns CVE/advisory safety (#6a) and pin-hygiene (#6b);
  freshness (#7) was retired to the housekeeper. A stale PyPI pin is freshness,
  not a CVE; the boundary is the same as every prior source.
- **No CVE collision.** Acting only on a concrete pinned version (the trust gate)
  is the boundary that keeps the housekeeper out of a CVE scanner's territory —
  the housekeeper reports "a newer GA exists", never "this version is
  vulnerable".

---

## 11. Repo housekeeping (standing rule — checked, nothing to do)

Per the user's standing rule, the marketplace repo itself was checked for
dep/action/runner/IaC freshness during the brainstorm:

- Runners: both workflows on `ubuntu-24.04` (latest GA). ✓
- Actions: `actions/checkout` and `gitleaks/gitleaks-action` are SHA-pinned WITH
  version comments (the endorsed GOOD state), pins recent. ✓
- IaC: no Dockerfile/Terraform/Helm/CFN. ✓
- No Python package of its own (no `pyproject.toml`/`requirements.txt`). ✓

Nothing to bump → no separate housekeeping PR needed.

---

## 12. Explicitly out of scope (this slice)

- `setup.cfg`, `setup.py` (arbitrary code), `Pipfile` — follow-ons / permanent
  out.
- **Licence-diff** — deferred to a cross-source follow-on (§5.5).
- `-r`/`-c` nested-include resolution in requirements files.
- `.ipynb` notebooks as a scope-pull-in source.
- Constraint files (`constraints.txt`) as a distinct type beyond the
  `requirements*.txt` glob.
- Tier-2 free-text installs (`RUN pip install x==1.2`, shell tool downloads) —
  deferred, own accuracy design (per the chassis spec).

---

## 13. Follow-on slices (same chassis, user-requested order)

After PyPI: **Go modules** (`go.mod`; proxy
`https://proxy.golang.org/<module>/@v/list`; Go's `vN+` major-suffix import-path
convention is the analogue of the Docker variant wrinkle). Its own brainstorm →
spec → plan → implement cycle. Do NOT fold into this slice.

---

## 14. Provenance / related reading

- Chassis & prior slices:
  `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`;
  Docker slice `docs/superpowers/specs/2026-06-11-housekeeper-docker-slice-design.md`;
  memories [[housekeeper-specialist-slice1]], [[housekeeper-specialist-slice2]],
  [[housekeeper-specialist-slice3]].
- Selector-not-filter principle: [[housekeeper-diff-is-selector-not-filter]];
  source-file-trigger spec
  `docs/superpowers/specs/2026-06-11-housekeeper-source-file-trigger-design.md`.
- Maintenance-health axis: [[housekeeper-maintenance-health-axis]].
- Engine: `plugins/code-review-suite/bin/housekeeper-freshness`.
- Agent: `plugins/code-review-suite/agents/housekeeper-reviewer.md`.
