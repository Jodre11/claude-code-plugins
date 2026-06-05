# Housekeeper Specialist (slice 2 — NuGet + maintenance-health + npm hardening) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the shipped `housekeeper-reviewer` static specialist with NuGet as a fourth source class (`.csproj` / `Directory.Packages.props` (CPM) / `Directory.Build.props` parsing, flat-container freshness, registration-API licence-diff), add a deterministic maintenance-health axis (registry `deprecated`/`unlisted`, with an npm `deprecated` rider) that widens the emit rule from "stale" to "stale OR health-flagged", and fold in the three npm/runner hardening fixes the slice-1 review surfaced.

**Architecture:** All deterministic work stays in the single stdlib-Python engine `bin/housekeeper-freshness`. Slice 2 makes ONE change to slice-1-proven code (`parse_version` → 4-tuple, backward-compatible by construction), adds a shared `Registry.registration()` client (gzip + pagination, fixture override) serving both NuGet licence-diff and health, a NuGet collector + scope resolver (nearest-ancestor `.csproj` gate, props walk-up, CPM resolution — declared source only, no MSBuild import-graph/property/condition evaluation), and a `health` tuple field defaulting to `null`. The `housekeeper-reviewer` agent gains a `nuget` rule and a health renderer; the worked example is extended with a NuGet finding and a health-flagged finding. Hash stability holds because the findings hash keys only on `file/line/rule_id/severity/confidence` — version and metadata text are not hashed.

**Tech Stack:** Python 3 (stdlib only — `urllib`, `gzip`, `json`, `re`, `argparse`; no PyYAML, no pip deps), bash test harness (`tests/`, `tests/ab/`), `python3 -m unittest`, Claude Code per-agent stream-json capture.

---

## Scope of THIS plan (slice 2)

In scope: `parse_version` 4-tuple extension (+ regression guard); `Registry.registration()` client (gzip + pagination + fixture override); NuGet parsers (`parse_csproj`, `parse_packages_props`, `nuget_strip_constraint`); NuGet scope resolver (`nuget_scope_roots` — nearest-ancestor `.csproj`, props walk-up, CPM resolution); `collect_nuget` (freshness + licence-diff + health + T3 + CLI tree-walk); maintenance-health axis (`health` tuple field, widened emit rule, npm `deprecated` rider, agent renderer); agent `nuget` rule + extended worked example; cookbook registration-endpoint note; detection-flag extension to `*.csproj`/`*.props`/`packages.lock.json` across the three pipeline files; npm/runner hardening (multi-section dep collapse, `.json` scope narrowing, `LATEST_RUNNERS` 180-day cadence self-check); README specialist-row update; full NuGet A/B apparatus (corpus + recorded flat-container + registration fixtures + config); hash-stability verification of the slice-1 corpus; gated 2×20 NuGet sweep.

Out of scope (deferred, with reason — carried from the spec): **fuzzy maintenance-health** (last-publish age, single-maintainer — needs a threshold/clock judgement that breaks determinism); **MSBuild import-graph evaluation / `$(property)` resolution / condition evaluation** (we review declared source, not the restored binary); **`.targets` files** (build logic, almost never package declarations); other ecosystems (PyPI, crates, Go, RubyGems, Docker base-image tags, framework/SDK versions — follow-on slices on the same chassis).

## Settled decisions (do not re-litigate — operator-confirmed in brainstorming, spec `9f91f57`)

- **Maintenance-health: BUILT into slice 2** (not deferred). Adds a `health` tuple field. Deterministic registry signals only (`deprecated` + `unlisted`/yank). Fuzzy signals deferred.
- **NuGet licence-diff: BUILT** via the registration API (flat-container is version-only). Shared client serves both licence-diff and health.
- **npm `deprecated` rider: INCLUDED** (near-zero cost — npm's registry doc already carries per-version `deprecated`).
- **Pure-health findings: EMIT.** Emit rule widens to "stale OR health-flagged"; a current-but-deprecated package surfaces with `target` = current.
- **Scope gate:** nearest-ancestor `.csproj` is the NuGet buildable unit (npm's `package.json` analogue). NOT `.sln`. CPM versions resolve by walking up to the governing `Directory.Packages.props`. We scan DECLARED source — no `<Import>` graph evaluation, no `$(property)` resolution, no condition evaluation.
- **No-untrustworthy-answer gate (no finding):** property refs `$(...)`, ranges `[1.0,2.0)`/`(,2.0]`, floating `1.*`/`1.2.*`. Only bare concrete `1.2.3`/`1.2.3.4` acted on. `VersionOverride` wins over CPM; csproj inline wins over props.
- **Model tier:** stays `model: haiku` + `effort: low` (validated in slice 1, EQUIVALENT 20/20, 2.38×). Build the NuGet A/B corpus + sweep anyway; sonnet is the fallback only on failure.

## Tuple shape (slice-2 delta)

```
{source, item, current, latest_ga, target, file, line,
 licence_current, licence_latest,
 health}          # NEW — null | {state, detail}
```

- `source` adds `nuget` (renders as `housekeeper/nuget`). Existing values unchanged.
- `health`: `null` when no maintenance signal (the common case). When present: `{"state": <"deprecated"|"unlisted">, "detail": <str>}` where `detail` is the registry's deprecation message / unlisted reason, rendered verbatim, never judged. Deterministic and hash-stable — no thresholds, no clock reads.
- **Hash stability:** existing slice-1 fixtures keep their canonical hash because the findings hash keys only on `file/line/rule_id/severity/confidence` (version and metadata text are NOT hashed). `health` is default-`null` for all existing tuples and is not rendered when null.

## File Structure

- `plugins/code-review-suite/bin/housekeeper-freshness` — MODIFY (4-tuple core; `Registry.registration`; NuGet parsers + scope + `collect_nuget`; `health` field + widened emit rule; npm `deprecated` rider + hardening; CLI tree-walk for `.csproj`/`.props`).
- `plugins/code-review-suite/agents/housekeeper-reviewer.md` — MODIFY (`nuget` rule in the Output section; health rendering rules; extended worked example with a NuGet finding AND a health-flagged finding).
- `plugins/code-review-suite/includes/version-freshness-cookbook.md` — MODIFY (add a registration-endpoint note for NuGet licence/health under the existing flat-container row).
- `plugins/code-review-suite/includes/review-pipeline.md` — MODIFY (Housekeeping detection trigger gains `*.csproj`/`*.props`/`packages.lock.json`).
- `plugins/code-review-suite/commands/pre-review.md` — MODIFY (same detection trigger, byte-identical).
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — MODIFY (same detection trigger, byte-identical).
- `plugins/code-review-suite/README.md` — MODIFY (specialist row + freshness prose mention NuGet).
- `plugins/code-review-suite/agents/review-synthesiser.md` / `includes/static-analysis-context.md` — NO CHANGE EXPECTED (NuGet renders under the existing source-agnostic `[housekeeper]` carve-out); CONFIRM by reading in Task 9.
- `tests/python/test_housekeeper_engine.py` — MODIFY (4-tuple regression, registration-client tests, NuGet parser/scope/collector tests, health tests, npm-hardening tests, `NuGetEndToEndTest`).
- `tests/lib/test_housekeeper_engine.sh` — unchanged (auto-runs the unittest suite).
- `tests/lib/test_runner_cadence.sh` — CREATE (`LATEST_RUNNERS` 180-day `Reviewed` stamp self-check).
- `tests/lib/test_sync_notes.sh` — NO CHANGE EXPECTED (the detection sync test asserts flag *presence*, not trigger-pattern content; CONFIRM in Task 9).
- `tests/ab/corpus/housekeeper-nuget-stale-deps/{source.yaml,diff/changed-lines.txt,expected/}` — CREATE.
- `tests/ab/corpus/index.yaml` — MODIFY (register the NuGet fixture).
- `tests/ab/fixtures/housekeeper-nuget-stdout.log` — CREATE (parser test input: a NuGet finding + a health-flagged finding).
- `tests/lib/test_ab_per_agent_lib.sh` — MODIFY (NuGet parser test asserting `housekeeper/nuget` tokenises whole + health finding parses; config-parse test for the NuGet config pair).
- `tests/ab/configs/per-agent/housekeeper-nuget-baseline.yaml` — CREATE (sonnet/default).
- `tests/ab/configs/per-agent/housekeeper-nuget-haiku-low.yaml` — CREATE (haiku/low).
- `tests/fixtures/static-analysis/housekeeper-nuget/` — CREATE (csproj + Directory.Packages.props + Directory.Build.props + recorded flat-container + registration fixtures; includes a deprecated-current package).
- `docs/superpowers/notes/2026-06-05-housekeeper-nuget-haiku-low-result.md` — CREATE (Task 13).

## Engine contract (referenced by multiple tasks — read once)

Invocation is unchanged from slice 1:
```
housekeeper-freshness --root <repo-root> --changed-files-from <path> --changed-lines-from <path>
```
Recorded-fixture override (tests + A/B): `--registry-fixtures <dir>` or env `HOUSEKEEPER_REGISTRY_FIXTURES`. Under that dir:
- Flat-container / npm / actions JSON: `<dir>/<source>/<slug>.json` (existing `Registry.fetch`). For NuGet flat-container, `source = "nuget"`, `slug = <name-lowercased>`.
- NuGet registration JSON (decompressed): `<dir>/nuget-registration/<slug>.json` (new `Registry.registration`). `slug = <name-lowercased>`.

Stdout: a JSON array of tuples, one per emitted item (stale OR health-flagged). The new key `health` is `null` for non-flagged tuples. The deterministic sort key is unchanged: `(file, line, source, item)`.

Exit codes unchanged: `0` on any completed run; non-zero only on engine crash.

---

### Task 1: `parse_version` → 4-tuple + regression guard

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness:92-105`
- Modify: `tests/python/test_housekeeper_engine.py:43-47` (existing parse_version assertions) + add a 4-part test

NuGet uses 4-part versions (`1.2.3.4`). `parse_version` returns a 4-tuple `(major, minor, patch, revision)`; `revision` defaults to `0`, so `v4 → (4,0,0,0)` and **every existing npm/Actions/runner comparison is unchanged by construction** (tuple ordering extends). This is the ONLY change to slice-1-proven code. The existing comparison tests (`compare_versions`, `latest_ga`, `nearest_in_major`) are the behavioural regression guard — they must stay green unchanged.

- [ ] **Step 1: Update the existing parse_version tests to the 4-tuple shape + add a 4-part test**

In `tests/python/test_housekeeper_engine.py`, change `test_parse_version_strips_v_prefix` (lines 43-47) to expect 4-tuples:
```python
    def test_parse_version_strips_v_prefix(self):
        self.assertEqual(self.m.parse_version("v4.2.1"), (4, 2, 1, 0))
        self.assertEqual(self.m.parse_version("4.2.1"), (4, 2, 1, 0))
        self.assertEqual(self.m.parse_version("v4"), (4, 0, 0, 0))
        self.assertEqual(self.m.parse_version("4.2"), (4, 2, 0, 0))
```
Change `test_parse_version_drops_prerelease_and_build` (lines 49-51):
```python
    def test_parse_version_drops_prerelease_and_build(self):
        self.assertEqual(self.m.parse_version("1.2.3-rc.1"), (1, 2, 3, 0))
        self.assertEqual(self.m.parse_version("1.2.3+build.5"), (1, 2, 3, 0))
```
Add a new test directly after `test_parse_version_drops_prerelease_and_build`:
```python
    def test_parse_version_four_part_nuget(self):
        # NuGet 4-part versions; revision defaults to 0 for shorter inputs.
        self.assertEqual(self.m.parse_version("1.2.3.4"), (1, 2, 3, 4))
        self.assertEqual(self.m.parse_version("13.0.3.0"), (13, 0, 3, 0))
        # Backward-compat: 3-part inputs compare identically to slice 1.
        self.assertEqual(self.m.parse_version("18.2.0"), (18, 2, 0, 0))

    def test_four_part_comparison_orders_revision(self):
        self.assertEqual(self.m.compare_versions("1.2.3.4", "1.2.3.5"), -1)
        self.assertEqual(self.m.compare_versions("1.2.3.4", "1.2.3.4"), 0)
        self.assertEqual(self.m.compare_versions("1.2.4.0", "1.2.3.9"), 1)
        # A 3-part version equals its 4-part .0 form (revision defaults to 0).
        self.assertEqual(self.m.compare_versions("1.2.3", "1.2.3.0"), 0)
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `parse_version` still returns 3-tuples (`AssertionError: (4,2,1) != (4,2,1,0)`); the new 4-part tests fail too.

- [ ] **Step 3: Extend `parse_version` to 4-tuple**

In `housekeeper-freshness`, replace `_VERSION_RE` (line 92) and `parse_version` (lines 95-105):
```python
_VERSION_RE = re.compile(r"^[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?")


def parse_version(s):
    """Return (major, minor, patch, revision) ints, or None if unparsable.

    Drops a leading v, a -prerelease suffix, and +build metadata. Missing
    parts default to 0, so 'v4' == (4, 0, 0, 0) and a 3-part '1.2.3'
    compares identically to its 4-part '1.2.3.0' form — backward-compatible
    with the slice-1 npm/Actions/runner sources by construction. NuGet's
    4-part versions ('1.2.3.4') populate the revision slot."""
    if not s:
        return None
    m = _VERSION_RE.match(s.strip())
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2) or 0),
            int(m.group(3) or 0), int(m.group(4) or 0))
```

- [ ] **Step 4: Run to verify they pass (and the regression guard stays green)**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `VersionCoreTest` pass, including the unchanged `compare_versions`/`latest_ga`/`nearest_in_major` tests (the behavioural regression guard) and the new 4-part tests.

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): parse_version 4-tuple for NuGet (backward-compatible) + regression guard"
git push origin main
```

---

### Task 2: `Registry.registration()` client (gzip + pagination + fixture override)

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness:8-14` (imports), `:52-87` (Registry class)
- Modify: `tests/python/test_housekeeper_engine.py` (add `RegistrationTest`)

The flat-container `index.json` is a bare version list. Licence and deprecation/unlisted metadata live in the **registration** resource (`registration5-gz-semver2`): gzipped, paginated (pages either inlined or external `@id` leaves needing a follow-up fetch). `Registry.registration()` returns a per-version map `{version: {licence, deprecation, listed}}`, or `None` on any miss. Live mode handles gzip + pagination; recorded-fixture mode reads decompressed JSON from `<fixtures>/nuget-registration/<slug>.json` (tests do not gzip; fixtures inline all pages).

- [ ] **Step 1: Write the failing registration tests**

Add a new test class to `tests/python/test_housekeeper_engine.py` after `VersionCoreTest`:
```python
# A registration index with an inlined page (no external @id fetch needed).
REG_INLINE = {
    "count": 1,
    "items": [
        {
            "@id": "https://example/page1",
            "count": 2,
            "items": [
                {"catalogEntry": {"version": "1.0.0", "licenseExpression": "MIT",
                                  "listed": True}},
                {"catalogEntry": {"version": "2.0.0", "licenseExpression": "Apache-2.0",
                                  "listed": True,
                                  "deprecation": {"message": "Use Foo.Bar instead",
                                                  "reasons": ["Legacy"]}}},
            ],
        }
    ],
}

# A registration index with an EXTERNAL page (no inline "items" -> needs a
# follow-up fetch to the page @id).
REG_EXTERNAL_INDEX = {
    "count": 1,
    "items": [{"@id": "https://example/pageA", "count": 1}],
}
REG_EXTERNAL_PAGE = {
    "items": [
        {"catalogEntry": {"version": "3.1.4", "licenseExpression": "MIT",
                          "listed": False}},
    ],
}


class RegistrationTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_registration_inline_page_extracts_per_version_map(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg._get_json = lambda url: REG_INLINE
        out = reg.registration("Foo.Bar")
        self.assertEqual(out["1.0.0"]["licence"], "MIT")
        self.assertEqual(out["2.0.0"]["licence"], "Apache-2.0")
        self.assertEqual(out["2.0.0"]["deprecation"]["message"], "Use Foo.Bar instead")
        self.assertTrue(out["1.0.0"]["listed"])

    def test_registration_external_page_is_fetched(self):
        reg = self.m.Registry(fixtures_dir=None)
        calls = []

        def fake_get(url):
            calls.append(url)
            return REG_EXTERNAL_INDEX if url.endswith("index.json") else REG_EXTERNAL_PAGE

        reg._get_json = fake_get
        out = reg.registration("Some.Pkg")
        # The index URL plus the external page @id were both fetched.
        self.assertEqual(len(calls), 2)
        self.assertIn("https://example/pageA", calls)
        self.assertEqual(out["3.1.4"]["licence"], "MIT")
        self.assertFalse(out["3.1.4"]["listed"])

    def test_registration_miss_returns_none(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg._get_json = lambda url: None
        self.assertIsNone(reg.registration("Nope"))

    def test_registration_fixture_override_reads_decompressed_json(self):
        with tempfile.TemporaryDirectory() as d:
            regdir = pathlib.Path(d) / "nuget-registration"
            regdir.mkdir()
            (regdir / "foo.bar.json").write_text(json.dumps(REG_INLINE))
            reg = self.m.Registry(fixtures_dir=d)
            out = reg.registration("Foo.Bar")  # slug lowercases the name
            self.assertEqual(out["2.0.0"]["licence"], "Apache-2.0")
            self.assertEqual(out["2.0.0"]["deprecation"]["reasons"], ["Legacy"])
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `Registry.registration` / `Registry._get_json` absent (`AttributeError`).

- [ ] **Step 3: Add gzip import + the registration client**

In `housekeeper-freshness`, add `import gzip` to the import block (after `import json`, line 9). Then add these methods to the `Registry` class (after `fetch`, before the closing of the class at line 87):
```python
    # --- NuGet registration (licence + deprecation/unlisted metadata) ------

    _REG_BASE = "https://api.nuget.org/v3/registration5-gz-semver2/%s/index.json"

    def _get_json(self, url):
        """Fetch a URL and parse JSON, transparently gunzipping the body.

        The registration5-gz endpoint always serves gzip; we gunzip best-effort
        and fall back to the raw body. Returns the parsed object or None."""
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "code-review-suite-housekeeper",
                "Accept": "application/json",
                "Accept-Encoding": "gzip",
                "Cache-Control": "no-cache",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                raw = resp.read()
        except (urllib.error.URLError, TimeoutError, OSError):
            return None
        try:
            raw = gzip.decompress(raw)
        except (OSError, gzip.BadGzipFile):
            pass  # body was not gzipped
        try:
            return json.loads(raw)
        except ValueError:
            return None

    def registration(self, item):
        """Return {version: {licence, deprecation, listed}} for a NuGet
        package, or None on any miss. Walks the paginated registration index,
        fetching external page leaves when a page omits inline 'items'.

        In fixture mode reads <fixtures_dir>/nuget-registration/<slug>.json
        (decompressed JSON; fixtures inline all pages, so no external page
        fetch is attempted)."""
        slug = item.lower().replace("/", "__")
        if self.fixtures_dir:
            path = os.path.join(self.fixtures_dir, "nuget-registration", slug + ".json")
            try:
                with open(path, encoding="utf-8") as fh:
                    index = json.load(fh)
            except (OSError, ValueError):
                return None
            return self._walk_registration(index, fetch_page=lambda _url: None)
        index = self._get_json(self._REG_BASE % slug)
        if index is None:
            return None
        return self._walk_registration(index, fetch_page=self._get_json)

    @staticmethod
    def _walk_registration(index, fetch_page):
        """Flatten a registration index into a {version: {...}} map. A page
        with inline 'items' is read directly; a page without is fetched via
        fetch_page(page['@id']). fetch_page may return None (fixture mode)."""
        result = {}
        for page in (index.get("items") or []):
            leaves = page.get("items")
            if leaves is None:
                page_id = page.get("@id")
                page_doc = fetch_page(page_id) if page_id else None
                leaves = (page_doc or {}).get("items") or []
            for leaf in leaves:
                ce = leaf.get("catalogEntry") or {}
                version = ce.get("version")
                if not version:
                    continue
                result[version] = {
                    "licence": ce.get("licenseExpression") or ce.get("licenseUrl"),
                    "deprecation": ce.get("deprecation"),
                    "listed": ce.get("listed", True),
                }
        return result or None
```

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `RegistrationTest` pass.

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): NuGet registration client (gzip + pagination + fixture override)"
git push origin main
```

---

### Task 3: NuGet parsers (`parse_csproj`, `parse_packages_props`, `nuget_strip_constraint`)

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add a `# --- source: nuget` section after the npm section)
- Modify: `tests/python/test_housekeeper_engine.py` (add `NuGetParseTest`)

Line-based regex parsing (keeps `line` cheap, mirrors npm). `parse_csproj` distinguishes three reference shapes and records the line of the literal version that will be acted on. `parse_packages_props` reads both CPM central `<PackageVersion>` and global `<PackageReference Version>`. `nuget_strip_constraint` returns the concrete bare version, or `None` for property refs / ranges / floating wildcards (the no-untrustworthy-answer gate).

- [ ] **Step 1: Write the failing parser tests**

Add to `tests/python/test_housekeeper_engine.py` (after `RunnerTest`, before `NPM_DOC`):
```python
class NuGetParseTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_strip_constraint_concrete_three_and_four_part(self):
        self.assertEqual(self.m.nuget_strip_constraint("1.2.3"), "1.2.3")
        self.assertEqual(self.m.nuget_strip_constraint("1.2.3.4"), "1.2.3.4")
        self.assertEqual(self.m.nuget_strip_constraint("13.0.3"), "13.0.3")

    def test_strip_constraint_rejects_untrustworthy_forms(self):
        self.assertIsNone(self.m.nuget_strip_constraint("$(SerilogVersion)"))
        self.assertIsNone(self.m.nuget_strip_constraint("[1.0,2.0)"))
        self.assertIsNone(self.m.nuget_strip_constraint("(,2.0]"))
        self.assertIsNone(self.m.nuget_strip_constraint("1.*"))
        self.assertIsNone(self.m.nuget_strip_constraint("1.2.*"))
        self.assertIsNone(self.m.nuget_strip_constraint(""))

    def test_parse_csproj_inline_version(self):
        text = (
            '<Project Sdk="Microsoft.NET.Sdk">\n'
            '  <ItemGroup>\n'
            '    <PackageReference Include="Serilog" Version="2.10.0" />\n'
            '  </ItemGroup>\n'
            '</Project>\n'
        )
        refs = self.m.parse_csproj(text)
        self.assertEqual(refs["Serilog"], ("2.10.0", 3))

    def test_parse_csproj_version_override_wins(self):
        text = (
            '    <PackageReference Include="Newtonsoft.Json" VersionOverride="12.0.1" />\n'
        )
        refs = self.m.parse_csproj(text)
        self.assertEqual(refs["Newtonsoft.Json"], ("12.0.1", 1))

    def test_parse_csproj_versionless_records_none_for_cpm(self):
        text = (
            '    <PackageReference Include="Serilog" />\n'
        )
        refs = self.m.parse_csproj(text)
        self.assertEqual(refs["Serilog"], (None, 1))

    def test_parse_csproj_child_element_version(self):
        text = (
            '    <PackageReference Include="AutoMapper">\n'
            '      <Version>11.0.1</Version>\n'
            '    </PackageReference>\n'
        )
        refs = self.m.parse_csproj(text)
        # The acted-on line is the <Version> literal, not the opening tag.
        self.assertEqual(refs["AutoMapper"], ("11.0.1", 2))

    def test_parse_packages_props_central_and_global(self):
        text = (
            '<Project>\n'
            '  <ItemGroup>\n'
            '    <PackageVersion Include="Serilog" Version="3.1.1" />\n'
            '    <PackageReference Include="Microsoft.SourceLink.GitHub" Version="1.1.1" />\n'
            '  </ItemGroup>\n'
            '</Project>\n'
        )
        central, glob = self.m.parse_packages_props(text)
        self.assertEqual(central["Serilog"], ("3.1.1", 3))
        self.assertEqual(glob["Microsoft.SourceLink.GitHub"], ("1.1.1", 4))
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `nuget_strip_constraint` / `parse_csproj` / `parse_packages_props` absent.

- [ ] **Step 3: Implement the NuGet parsers**

In `housekeeper-freshness`, add a new section AFTER the npm section (after `collect_npm`, before `collect_findings`):
```python
# --- source: nuget ----------------------------------------------------------

# A PackageReference / PackageVersion attribute scan. We deliberately scan
# DECLARED source only: no <Import> graph evaluation, no $(property) resolution,
# no condition evaluation. .targets files are out of scope.

_PR_INCLUDE_RE = re.compile(r'Include\s*=\s*"([^"]+)"')
_PR_VERSION_RE = re.compile(r'\bVersion\s*=\s*"([^"]+)"')
_PR_OVERRIDE_RE = re.compile(r'\bVersionOverride\s*=\s*"([^"]+)"')
_CHILD_VERSION_RE = re.compile(r"<Version>\s*([^<]+?)\s*</Version>")


def nuget_strip_constraint(spec):
    """Return a bare concrete NuGet version, or None for any form we cannot
    name a trustworthy 'current' for without evaluating the build:
    property refs $(...), version ranges [1.0,2.0) / (,2.0], and floating
    wildcards 1.* / 1.2.*. Concrete pins 1.2.3 / 1.2.3.4 (with an optional
    -prerelease) are returned verbatim."""
    if not spec:
        return None
    s = spec.strip()
    if "$(" in s or "*" in s:
        return None
    if s[:1] in "[(" or "," in s:
        return None  # version range
    if re.fullmatch(r"\d+(?:\.\d+){0,3}(?:-[0-9A-Za-z.\-]+)?", s):
        return s
    return None


def parse_csproj(text):
    """Return {name: (spec_or_None, line)} for <PackageReference> entries.

    spec is the raw version string from VersionOverride (wins), an inline
    Version attribute, or a child <Version> element. A version-less reference
    records (None, ref_line) -> resolved later via CPM. The recorded line is
    the literal version's line (or the opening-tag line when version-less)."""
    refs = {}
    pending = None  # (name, ref_line) awaiting a child <Version> element
    for i, raw in enumerate(text.splitlines(), start=1):
        if pending is not None:
            cm = _CHILD_VERSION_RE.search(raw)
            if cm:
                refs[pending[0]] = (cm.group(1).strip(), i)
                pending = None
                continue
            if "</PackageReference>" in raw:
                # Closed without a <Version> -> version-less (CPM-resolved).
                refs[pending[0]] = (None, pending[1])
                pending = None
                # fall through: this same line may open nothing else
        if "<PackageReference" not in raw:
            continue
        im = _PR_INCLUDE_RE.search(raw)
        if not im:
            continue
        name = im.group(1)
        override = _PR_OVERRIDE_RE.search(raw)
        version = _PR_VERSION_RE.search(raw)
        if override:
            refs[name] = (override.group(1), i)
        elif version:
            refs[name] = (version.group(1), i)
        elif "/>" in raw or "</PackageReference>" in raw:
            refs[name] = (None, i)  # self-closed version-less -> CPM
        else:
            pending = (name, i)  # multi-line: await a child <Version>
    if pending is not None:
        refs[pending[0]] = (None, pending[1])
    return refs


def parse_packages_props(text):
    """Return (central, global_refs) for a .props file.

    central: {name: (version, line)} from <PackageVersion Include Version>
             (CPM central versions).
    global_refs: {name: (version, line)} from <PackageReference Include Version>
             (global deps declared in props, e.g. Directory.Build.props).
    Only concrete attribute versions are recorded here; the collector applies
    nuget_strip_constraint before acting."""
    central = {}
    global_refs = {}
    for i, raw in enumerate(text.splitlines(), start=1):
        im = _PR_INCLUDE_RE.search(raw)
        vm = _PR_VERSION_RE.search(raw)
        if not im or not vm:
            continue
        name, version = im.group(1), vm.group(1)
        if "<PackageVersion" in raw:
            central[name] = (version, i)
        elif "<PackageReference" in raw:
            global_refs[name] = (version, i)
    return central, global_refs
```

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `NuGetParseTest` pass.

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): NuGet csproj/props parsers + concrete-version gate"
git push origin main
```

---

### Task 4: NuGet scope resolver (`nuget_scope_roots` + dir helpers)

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add to the `# --- source: nuget` section)
- Modify: `tests/python/test_housekeeper_engine.py` (add `NuGetScopeTest`)

The scope model is the genuinely new bit vs npm. **Buildable unit / T1 gate:** the nearest-ancestor `.csproj` of each changed C#-ecosystem file. **`.props` in scope:** any `.props` whose directory is an ancestor-or-same of an in-scope `.csproj` (props auto-apply down the subtree, so walking up from each in-scope csproj covers its governing `Directory.Build.props` AND `Directory.Packages.props`). We scan declared files; we do NOT evaluate `<Import>` chains, resolve properties, or honour conditions.

- [ ] **Step 1: Write the failing scope tests**

Add to `tests/python/test_housekeeper_engine.py` (after `NuGetParseTest`):
```python
class NuGetScopeTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_nearest_ancestor_csproj_is_the_gate(self):
        changed = ["src/Api/Controllers/Home.cs"]
        csprojs = {"src/Api/Api.csproj", "src/Worker/Worker.csproj"}
        props = set()
        in_csproj, in_props = self.m.nuget_scope_roots(changed, csprojs, props)
        self.assertEqual(in_csproj, {"src/Api/Api.csproj"})
        self.assertEqual(in_props, set())

    def test_non_csharp_file_does_not_pull_in_csproj(self):
        changed = ["src/Api/notes.txt"]
        csprojs = {"src/Api/Api.csproj"}
        in_csproj, _ = self.m.nuget_scope_roots(changed, csprojs, set())
        self.assertEqual(in_csproj, set())

    def test_changed_csproj_is_its_own_scope(self):
        changed = ["src/Api/Api.csproj"]
        csprojs = {"src/Api/Api.csproj"}
        in_csproj, _ = self.m.nuget_scope_roots(changed, csprojs, set())
        self.assertEqual(in_csproj, {"src/Api/Api.csproj"})

    def test_governing_props_walk_up(self):
        # A root Directory.Packages.props and a src-level Directory.Build.props
        # both govern an in-scope csproj deeper in the tree.
        changed = ["src/Api/Controllers/Home.cs"]
        csprojs = {"src/Api/Api.csproj"}
        props = {"Directory.Packages.props", "src/Directory.Build.props",
                 "other/Unrelated.props"}
        in_csproj, in_props = self.m.nuget_scope_roots(changed, csprojs, props)
        self.assertEqual(in_csproj, {"src/Api/Api.csproj"})
        self.assertEqual(in_props, {"Directory.Packages.props", "src/Directory.Build.props"})

    def test_sibling_subtree_props_not_in_scope(self):
        changed = ["src/Api/Home.cs"]
        csprojs = {"src/Api/Api.csproj"}
        props = {"src/Worker/Worker.props"}
        _, in_props = self.m.nuget_scope_roots(changed, csprojs, props)
        self.assertEqual(in_props, set())
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `nuget_scope_roots` absent.

- [ ] **Step 3: Implement the scope resolver**

In `housekeeper-freshness`, add to the `# --- source: nuget` section (after `parse_packages_props`):
```python
# Files that mark membership of a C#/.NET (NuGet) buildable unit. A changed
# file only pulls in its nearest-ancestor .csproj when it belongs to this
# ecosystem — a sibling JS/Python/etc. file under the same dir is a different
# buildable unit.
_NUGET_SCOPE_SUFFIXES = (
    ".cs", ".fs", ".vb", ".razor", ".cshtml", ".csproj", ".fsproj", ".vbproj",
    ".props", ".targets",
)


def _is_nuget_scope_file(path):
    base = path.rsplit("/", 1)[-1]
    if base == "packages.lock.json":
        return True
    return path.endswith(_NUGET_SCOPE_SUFFIXES)


def _dirname(path):
    return path.rsplit("/", 1)[0] if "/" in path else ""


def _dir_is_ancestor_or_same(ancestor, descendant):
    """True if directory `ancestor` is `descendant` itself or an ancestor of
    it. The repo root is represented by the empty string and is an ancestor of
    everything."""
    if ancestor == "":
        return True
    return descendant == ancestor or descendant.startswith(ancestor + "/")


def nuget_scope_roots(changed_files, all_csprojs, all_props):
    """Return (in_scope_csprojs, in_scope_props).

    in_scope_csprojs: for each changed C#-ecosystem file, its nearest-ancestor
    .csproj (the deepest csproj whose directory is an ancestor-or-same of the
    file's directory). in_scope_props: every .props whose directory is an
    ancestor-or-same of an in-scope csproj's directory (governing props found by
    walking up)."""
    csprojs = set()
    for f in changed_files:
        if not _is_nuget_scope_file(f):
            continue
        fdir = _dirname(f)
        best = None
        best_dir = None
        for c in all_csprojs:
            cdir = _dirname(c)
            if _dir_is_ancestor_or_same(cdir, fdir):
                if best is None or len(cdir) > len(best_dir):
                    best, best_dir = c, cdir
        if best is not None:
            csprojs.add(best)
    props = set()
    for c in csprojs:
        cdir = _dirname(c)
        for p in all_props:
            if _dir_is_ancestor_or_same(_dirname(p), cdir):
                props.add(p)
    return csprojs, props
```

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `NuGetScopeTest` pass.

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): NuGet scope resolver (nearest-csproj gate + props walk-up)"
git push origin main
```

---

### Task 5: `collect_nuget` (freshness + licence + health + T3) + CLI tree-walk wiring

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add `collect_nuget`; extend `collect_findings`)
- Modify: `tests/python/test_housekeeper_engine.py` (add `NuGetCollectTest` + `NuGetEndToEndTest`)

`collect_nuget` resolves a deduplicated candidate set across in-scope csprojs and props (version-less csproj refs resolve through the governing CPM `<PackageVersion>`; `VersionOverride` and inline versions win; global `<PackageReference Version>` in props are candidates too), then for each candidate fetches the flat-container version list (a miss suppresses the finding — no trustworthy latest) and the registration map (licence + health; a miss leaves licence/health `null` but does NOT suppress). The emit rule is **stale OR health-flagged**. T3 falls out of `nearest_in_major`: a touched literal line → latest GA; an untouched line → nearest in-major. The CLI tree-walk discovers `.csproj`/`.props` (pruning `bin`/`obj`/`node_modules`) and gates scope.

- [ ] **Step 1: Write the failing collector tests**

Add to `tests/python/test_housekeeper_engine.py` (after `NuGetScopeTest`):
```python
NUGET_FLAT = {"versions": ["2.10.0", "3.0.0", "3.1.1", "4.0.0"]}


def _reg_map(**versions):
    # Helper: build a registration map; each kwarg is version="MIT" or a dict.
    out = {}
    for v, meta in versions.items():
        v = v.replace("_", ".")
        out[v] = meta if isinstance(meta, dict) else {"licence": meta, "deprecation": None, "listed": True}
    return out


class NuGetCollectTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def _reg(self, flat, registration):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda source, item, url: flat
        reg.registration = lambda item: registration
        return reg

    def test_inline_version_stale_touched_targets_latest(self):
        reg = self._reg(NUGET_FLAT, _reg_map(**{"2_10_0": "MIT", "4_0_0": "MIT"}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["source"], "nuget")
        self.assertEqual(f["item"], "Serilog")
        self.assertEqual(f["current"], "2.10.0")
        self.assertEqual(f["latest_ga"], "4.0.0")
        self.assertEqual(f["target"], "4.0.0")
        self.assertEqual(f["file"], "Api.csproj")
        self.assertEqual(f["line"], 1)
        self.assertIsNone(f["health"])

    def test_untouched_line_targets_nearest_in_major(self):
        reg = self._reg(NUGET_FLAT, _reg_map(**{"3_0_0": "MIT", "3_1_1": "MIT"}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="3.0.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": set()}, reg)
        self.assertEqual(findings[0]["target"], "3.1.1")  # nearest in major 3

    def test_cpm_resolution_points_file_line_at_props(self):
        reg = self._reg(NUGET_FLAT, _reg_map(**{"3_1_1": "MIT", "4_0_0": "MIT"}))
        csproj = {"src/Api/Api.csproj": '    <PackageReference Include="Serilog" />\n'}
        props = {"Directory.Packages.props":
                 '    <PackageVersion Include="Serilog" Version="3.1.1" />\n'}
        findings = self.m.collect_nuget(csproj, props, {"Directory.Packages.props": {1}}, reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["current"], "3.1.1")
        self.assertEqual(f["file"], "Directory.Packages.props")  # literal lives in props
        self.assertEqual(f["line"], 1)
        self.assertEqual(f["target"], "4.0.0")

    def test_version_override_wins_over_cpm(self):
        reg = self._reg(NUGET_FLAT, _reg_map(**{"3_0_0": "MIT", "4_0_0": "MIT"}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" VersionOverride="3.0.0" />\n'}
        props = {"Directory.Packages.props":
                 '    <PackageVersion Include="Serilog" Version="3.1.1" />\n'}
        findings = self.m.collect_nuget(csproj, props, {"Api.csproj": {1}}, reg)
        self.assertEqual(findings[0]["current"], "3.0.0")
        self.assertEqual(findings[0]["file"], "Api.csproj")  # override literal in csproj

    def test_property_ref_and_range_yield_no_finding(self):
        reg = self._reg(NUGET_FLAT, None)
        csproj = {"Api.csproj":
                  '    <PackageReference Include="A" Version="$(AVersion)" />\n'
                  '    <PackageReference Include="B" Version="[1.0,2.0)" />\n'}
        self.assertEqual(self.m.collect_nuget(csproj, {}, {"Api.csproj": {1, 2}}, reg), [])

    def test_versionless_with_no_cpm_match_is_skipped(self):
        reg = self._reg(NUGET_FLAT, None)
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" />\n'}
        self.assertEqual(self.m.collect_nuget(csproj, {}, {"Api.csproj": set()}, reg), [])

    def test_flat_container_miss_suppresses(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: None
        reg.registration = lambda item: None
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        self.assertEqual(self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg), [])

    def test_registration_miss_keeps_freshness_finding_with_null_metadata(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NUGET_FLAT
        reg.registration = lambda item: None
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(len(findings), 1)
        self.assertIsNone(findings[0]["licence_current"])
        self.assertIsNone(findings[0]["health"])

    def test_licence_diff_against_target(self):
        reg = self._reg(
            NUGET_FLAT,
            _reg_map(**{"2_10_0": {"licence": "MIT", "deprecation": None, "listed": True},
                        "4_0_0": {"licence": "BSL-1.1", "deprecation": None, "listed": True}}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(findings[0]["licence_current"], "MIT")
        self.assertEqual(findings[0]["licence_latest"], "BSL-1.1")

    def test_deprecated_but_current_emits_pure_health(self):
        # Package is at the latest GA but the registry marks it deprecated.
        flat = {"versions": ["4.0.0"]}
        reg = self._reg(
            flat,
            _reg_map(**{"4_0_0": {"licence": "MIT", "listed": True,
                                  "deprecation": {"message": "Use Foo.Bar instead",
                                                  "reasons": ["Legacy"]}}}))
        csproj = {"Api.csproj": '    <PackageReference Include="Foo" Version="4.0.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["current"], "4.0.0")
        self.assertEqual(f["target"], "4.0.0")  # nothing newer; pure-health
        self.assertEqual(f["health"], {"state": "deprecated", "detail": "Use Foo.Bar instead"})

    def test_unlisted_current_emits_pure_health(self):
        flat = {"versions": ["4.0.0"]}
        reg = self._reg(flat, _reg_map(**{"4_0_0": {"licence": "MIT", "listed": False,
                                                    "deprecation": None}}))
        csproj = {"Api.csproj": '    <PackageReference Include="Foo" Version="4.0.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(findings[0]["health"]["state"], "unlisted")

    def test_duplicate_cpm_resolution_dedupes(self):
        # Two csprojs both reference Serilog version-lessly -> one CPM literal,
        # one finding (deduped by file/line/item).
        reg = self._reg(NUGET_FLAT, _reg_map(**{"3_1_1": "MIT", "4_0_0": "MIT"}))
        csproj = {
            "src/A/A.csproj": '    <PackageReference Include="Serilog" />\n',
            "src/B/B.csproj": '    <PackageReference Include="Serilog" />\n',
        }
        props = {"Directory.Packages.props":
                 '    <PackageVersion Include="Serilog" Version="3.1.1" />\n'}
        findings = self.m.collect_nuget(csproj, props, {"Directory.Packages.props": {1}}, reg)
        self.assertEqual(len(findings), 1)


class NuGetEndToEndTest(unittest.TestCase):
    def test_cli_against_inline_fixtures_incl_health(self):
        # A self-contained tree: CPM central versions, a global props dep, and a
        # deprecated-current package. Recorded flat-container + registration.
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d) / "repo"
            (root / "src/Api").mkdir(parents=True)
            (root / "src/Api/Api.csproj").write_text(
                '<Project Sdk="Microsoft.NET.Sdk">\n'
                '  <ItemGroup>\n'
                '    <PackageReference Include="Serilog" />\n'
                '    <PackageReference Include="Foo.Legacy" Version="4.0.0" />\n'
                '  </ItemGroup>\n'
                '</Project>\n')
            (root / "Directory.Packages.props").write_text(
                '<Project>\n'
                '  <ItemGroup>\n'
                '    <PackageVersion Include="Serilog" Version="2.10.0" />\n'
                '  </ItemGroup>\n'
                '</Project>\n')
            fx = pathlib.Path(d) / "fx"
            (fx / "nuget").mkdir(parents=True)
            (fx / "nuget-registration").mkdir(parents=True)
            (fx / "nuget" / "serilog.json").write_text(json.dumps({"versions": ["2.10.0", "3.1.1", "4.0.0"]}))
            (fx / "nuget" / "foo.legacy.json").write_text(json.dumps({"versions": ["4.0.0"]}))
            (fx / "nuget-registration" / "serilog.json").write_text(json.dumps({
                "items": [{"items": [
                    {"catalogEntry": {"version": "2.10.0", "licenseExpression": "Apache-2.0", "listed": True}},
                    {"catalogEntry": {"version": "4.0.0", "licenseExpression": "Apache-2.0", "listed": True}},
                ]}]}))
            (fx / "nuget-registration" / "foo.legacy.json").write_text(json.dumps({
                "items": [{"items": [
                    {"catalogEntry": {"version": "4.0.0", "licenseExpression": "MIT", "listed": True,
                                      "deprecation": {"message": "Abandoned; use Foo.Bar", "reasons": ["Legacy"]}}},
                ]}]}))
            files = pathlib.Path(d) / "files.txt"
            lines = pathlib.Path(d) / "lines.txt"
            files.write_text("src/Api/Api.csproj\n")
            lines.write_text("Changed lines:\n  src/Api/Api.csproj: 3,4\n")
            env = dict(os.environ, HOUSEKEEPER_REGISTRY_FIXTURES=str(fx))
            out = subprocess.run(
                [sys.executable, str(ENGINE), "--root", str(root),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines)],
                capture_output=True, text=True, check=True, env=env)
            tuples = json.loads(out.stdout)
            by_item = {t["item"]: t for t in tuples}
            # Serilog: version-less csproj ref -> CPM 2.10.0 in props -> stale (4.0.0).
            self.assertEqual(by_item["Serilog"]["current"], "2.10.0")
            self.assertEqual(by_item["Serilog"]["latest_ga"], "4.0.0")
            self.assertEqual(by_item["Serilog"]["file"], "Directory.Packages.props")
            # Foo.Legacy: current AND latest, but registry-deprecated -> pure-health.
            self.assertEqual(by_item["Foo.Legacy"]["health"]["state"], "deprecated")
            self.assertEqual(by_item["Foo.Legacy"]["target"], "4.0.0")
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `collect_nuget` absent; `NuGetEndToEndTest` fails (engine has no NuGet wiring yet).

- [ ] **Step 3: Implement `collect_nuget` + extend `collect_findings`**

In `housekeeper-freshness`, add `collect_nuget` to the `# --- source: nuget` section (after `nuget_scope_roots`):
```python
def _nuget_health(reg_entry):
    """Map a registration entry to a health dict, or None. Deterministic:
    deprecation wins over unlisted; detail is rendered verbatim, never judged."""
    if not reg_entry:
        return None
    dep = reg_entry.get("deprecation")
    if dep:
        detail = dep.get("message") or ", ".join(dep.get("reasons") or [])
        return {"state": "deprecated", "detail": detail or ""}
    if reg_entry.get("listed") is False:
        return {"state": "unlisted", "detail": ""}
    return None


def collect_nuget(csproj_text, props_text, changed_lines, registry):
    """csproj_text / props_text map each in-scope path -> its content. Builds a
    deduplicated candidate set (csproj refs resolved through CPM; props global
    refs), then emits a tuple per candidate that is stale OR health-flagged."""
    # CPM central versions and props global refs across all in-scope props.
    # On a multi-props collision, the deepest-dir declaration wins (tie-break
    # lexical) so resolution is deterministic.
    central = {}   # name -> (version, file, line)
    candidates = {}  # (file, line, name) -> (name, concrete, file, line)

    def _consider_props_winner(store, name, version, path, line):
        prev = store.get(name)
        if prev is None or (len(_dirname(path)), path) > (len(_dirname(prev[1])), prev[1]):
            store[name] = (version, path, line)

    props_globals = {}
    for path, text in sorted(props_text.items()):
        cen, glob = parse_packages_props(text)
        for name, (version, line) in cen.items():
            _consider_props_winner(central, name, version, path, line)
        for name, (version, line) in glob.items():
            _consider_props_winner(props_globals, name, version, path, line)

    def _add_candidate(name, spec, path, line):
        concrete = nuget_strip_constraint(spec)
        if concrete is None:
            return
        candidates[(path, line, name)] = (name, concrete, path, line)

    # csproj references (inline / override win; version-less -> CPM).
    for path, text in sorted(csproj_text.items()):
        for name, (spec, line) in parse_csproj(text).items():
            if spec is not None:
                _add_candidate(name, spec, path, line)
            else:
                cpm = central.get(name)
                if cpm is not None:
                    _add_candidate(name, cpm[0], cpm[1], cpm[2])
    # props global PackageReference declarations are candidates in their own right.
    for name, (version, path, line) in props_globals.items():
        _add_candidate(name, version, path, line)

    findings = []
    for (path, line, name) in sorted(candidates):
        _, current, _, _ = candidates[(path, line, name)]
        slug = name.lower()
        doc = registry.fetch(
            "nuget", slug,
            "https://api.nuget.org/v3-flatcontainer/%s/index.json" % slug)
        if not doc:
            continue  # no trustworthy latest -> suppress entirely
        versions = list(doc.get("versions") or [])
        latest = latest_ga(versions)
        if not latest:
            continue
        reg_map = registry.registration(name)
        health = _nuget_health((reg_map or {}).get(current))
        stale = compare_versions(latest, current) > 0
        touched = changed_lines.get(path, set())
        if stale:
            target = latest if line in touched else nearest_in_major(current, versions)
            if compare_versions(target, current) <= 0:
                stale = False  # in-major exhausted for an untouched line
        if not stale and health is None:
            continue  # widened emit rule: stale OR health-flagged
        if not stale:
            target = current
        lic_cur = (reg_map or {}).get(current, {}).get("licence")
        lic_new = (reg_map or {}).get(target, {}).get("licence")
        findings.append({
            "source": "nuget", "item": name,
            "current": current, "latest_ga": latest, "target": target,
            "file": path, "line": line,
            "licence_current": lic_cur, "licence_latest": lic_new,
            "health": health,
        })
    return findings
```
Then extend `collect_findings` (currently lines 410-445). Add NuGet discovery + scope after the npm block and before the `findings = []` assembly. Replace the tree-walk loop so it discovers `.csproj`/`.props` alongside `package.json` and prunes `bin`/`obj`:
```python
    all_pkgs = set()
    all_csprojs = set()
    all_props = set()
    for dirpath, dirs, names in os.walk(root):
        for prune in ("node_modules", "bin", "obj"):
            if prune in dirs:
                dirs.remove(prune)
        if "package.json" in names:
            rel = os.path.relpath(os.path.join(dirpath, "package.json"), root)
            all_pkgs.add(rel.replace(os.sep, "/"))
        for nm in names:
            rel = os.path.relpath(os.path.join(dirpath, nm), root).replace(os.sep, "/")
            if nm.endswith(".csproj") or nm.endswith(".fsproj") or nm.endswith(".vbproj"):
                all_csprojs.add(rel)
            elif nm.endswith(".props"):
                all_props.add(rel)
    npm_roots = npm_scope_roots(changed_files, all_pkgs)
    npm_text = {p: read(p) for p in npm_roots}
    npm_text = {p: t for p, t in npm_text.items() if t is not None}

    nuget_csprojs, nuget_props = nuget_scope_roots(changed_files, all_csprojs, all_props)
    csproj_text = {p: read(p) for p in nuget_csprojs}
    csproj_text = {p: t for p, t in csproj_text.items() if t is not None}
    props_text = {p: read(p) for p in nuget_props}
    props_text = {p: t for p, t in props_text.items() if t is not None}

    findings = []
    findings += collect_github_actions(changed_files, workflow_text, changed_lines, registry)
    findings += collect_runners(changed_files, workflow_text, changed_lines)
    findings += collect_npm(npm_text, changed_lines, registry)
    findings += collect_nuget(csproj_text, props_text, changed_lines, registry)
    findings.sort(key=lambda f: (f["file"], f["line"], f["source"], f["item"]))
    return findings
```
(Delete the old `all_pkgs = set()` / `os.walk` block being replaced — do not duplicate it.)

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `NuGetCollectTest` and `NuGetEndToEndTest` pass. The slice-1 `EndToEndTest` still passes (NuGet discovery finds no `.csproj` in that fixture).

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): NuGet collector (CPM resolution, licence diff, health, T3) + CLI tree-walk"
git push origin main
```

---

### Task 6: Health axis cross-source — uniform `health` key, npm `deprecated` rider, hash-stability check

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add `"health": None` to the three existing collectors; npm rider + widened npm emit rule)
- Modify: `tests/python/test_housekeeper_engine.py` (npm health-rider tests + a hash-stability assertion)

The tuple shape now carries `health` for all sources. The three slice-1 collectors emit `"health": None`. npm gains a `deprecated` rider: npm's registry doc carries per-version `deprecated` (a string), so `collect_npm` populates `health` and widens its emit rule to "stale OR health-flagged". This must NOT change the slice-1 fixture's canonical hash (the hash keys only on `file/line/rule_id/severity/confidence`; `health` is metadata, default-`null`, not rendered when null).

- [ ] **Step 1: Write the failing npm-rider + hash-stability tests**

Add to `tests/python/test_housekeeper_engine.py` `NpmTest` class:
```python
    def test_npm_deprecated_current_emits_pure_health(self):
        doc = {
            "dist-tags": {"latest": "4.0.0"},
            "versions": {"4.0.0": {"license": "MIT", "deprecated": "no longer maintained"}},
        }
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: doc
        text = '{\n  "dependencies": {\n    "left-pad": "4.0.0"\n  }\n}\n'
        findings = self.m.collect_npm({"package.json": text}, {"package.json": {3}}, reg)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["health"], {"state": "deprecated", "detail": "no longer maintained"})
        self.assertEqual(findings[0]["target"], "4.0.0")  # current; pure-health

    def test_npm_stale_finding_has_null_health(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NPM_DOC
        text = '{\n  "dependencies": {\n    "react": "^18.2.0"\n  }\n}\n'
        findings = self.m.collect_npm({"package.json": text}, {"package.json": {3}}, reg)
        self.assertIsNone(findings[0]["health"])
```
Add a hash-stability test as a new class after `EndToEndTest`:
```python
class HashStabilityTest(unittest.TestCase):
    def test_existing_collectors_carry_null_health(self):
        m = load_engine()
        # github-actions
        ga_reg = m.Registry(fixtures_dir=None)
        ga_reg.fetch = lambda *a, **k: {"tag_name": "v4.2.1"}
        ga = m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: actions/checkout@v3\n"},
            {".github/workflows/ci.yml": {1}}, ga_reg)
        self.assertIn("health", ga[0])
        self.assertIsNone(ga[0]["health"])
        # runner
        run = m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "    runs-on: ubuntu-22.04\n"},
            {".github/workflows/ci.yml": {1}})
        self.assertIsNone(run[0]["health"])
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — existing collectors emit no `health` key (`KeyError`/`assertIn` fails); npm has no deprecated rider.

- [ ] **Step 3: Add `"health": None` to the three existing collectors + npm rider**

In `collect_github_actions` (the findings.append dict, ~line 227), add `"health": None,` after the `licence_latest` line. Do the same in `collect_runners` (~line 285). In `collect_npm`, add the rider and widen the emit rule. Replace the body of the per-dep loop in `collect_npm` (from `current = strip_constraint(spec)` to the `findings.append`) so it reads:
```python
            current = strip_constraint(spec)
            if current is None:
                continue
            doc = registry.fetch("npm", name, "https://registry.npmjs.org/%s" % name)
            if not doc:
                continue
            versions = list((doc.get("versions") or {}).keys())
            vmap = doc.get("versions") or {}
            latest = (doc.get("dist-tags") or {}).get("latest")
            if not latest or not is_ga(latest):
                latest = latest_ga(versions)
            if not latest:
                continue
            dep = (vmap.get(current) or {}).get("deprecated")
            health = {"state": "deprecated", "detail": dep} if isinstance(dep, str) and dep else None
            stale = compare_versions(latest, current) > 0
            if stale:
                if line in touched:
                    target = latest
                else:
                    target = nearest_in_major(current, versions)
                    if compare_versions(target, current) <= 0:
                        stale = False  # nothing newer within the current major
            if not stale and health is None:
                continue  # widened emit rule: stale OR health-flagged
            if not stale:
                target = current
            lic_cur = (vmap.get(current) or {}).get("license")
            lic_new = (vmap.get(target) or {}).get("license")
            findings.append({
                "source": "npm", "item": name,
                "current": current, "latest_ga": latest, "target": target,
                "file": path, "line": line,
                "licence_current": lic_cur, "licence_latest": lic_new,
                "health": health,
            })
```

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all pass, including the slice-1 `EndToEndTest` and `NpmTest` licence/target tests (the rewritten loop preserves the licence-against-target behaviour from slice 1).

- [ ] **Step 5: Verify the slice-1 A/B fixture's canonical hash is unchanged**

The slice-1 corpus's expected hash is recorded in `tests/ab/corpus/housekeeper-smoke-stale-deps/expected/findings.json`. Confirm the engine still emits exactly three tuples with the same `file/line/source` against the slice-1 fixture (the hash keys on `file/line/rule_id/severity/confidence`, not on the new `health: null` key). The slice-1 npm fixture (`tests/fixtures/static-analysis/housekeeper/package.json`) is single-section (one `react` dep), so the multi-section hardening in Task 10 cannot perturb it.

Run (single Bash call each; resolve `$CLAUDE_TEMP_DIR` to the literal session path):
```
printf '.github/workflows/ci.yml\npackage.json\n' > $CLAUDE_TEMP_DIR/hk1-files.txt
```
```
printf 'Changed lines:\n  .github/workflows/ci.yml: 5,7\n  package.json: 4\n' > $CLAUDE_TEMP_DIR/hk1-lines.txt
```
```
HOUSEKEEPER_REGISTRY_FIXTURES=tests/fixtures/static-analysis/housekeeper/registry python3 plugins/code-review-suite/bin/housekeeper-freshness --root tests/fixtures/static-analysis/housekeeper --changed-files-from $CLAUDE_TEMP_DIR/hk1-files.txt --changed-lines-from $CLAUDE_TEMP_DIR/hk1-lines.txt
```
Expected stdout: a 3-element array, sources `github-actions`/`runner`/`npm`, each with `"health": null`, same `file`/`line` as the slice-1 baseline. The findings hash is therefore unchanged.

- [ ] **Step 6: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): uniform health field + npm deprecated rider (hash-stable)"
git push origin main
```

---

### Task 7: Agent — `nuget` rule, health rendering, extended worked example

**Files:**
- Modify: `plugins/code-review-suite/agents/housekeeper-reviewer.md:54` (Rule line), `:55` (Description/health), `:56` (Suggested fix), `:72-100` (worked example)

The agent is unchanged in structure — the engine already emits NuGet and health tuples; the agent just renders them. Add `nuget` to the rule enumeration, the health-rendering rules to Description and Suggested fix, and extend the worked example with a NuGet finding AND a health-flagged finding (the worked-example-gap lesson: the small model needs a template for the new shapes). No new agent, no model-tier change.

- [ ] **Step 1: Extend the Rule + Description + Suggested-fix rules**

In `housekeeper-reviewer.md`, change the `Rule` bullet (line 54):
```
- **Rule:** `housekeeper/<source>` where `<source>` is the tuple's `source` (`github-actions`, `runner`, `npm`, or `nuget`).
```
Change the `Description` bullet (line 55) to add the health clause:
```
- **Description:** `<item> is at <current>; latest GA is <latest_ga>.` If `licence_current` and `licence_latest` differ and both are non-null, append ` Licence changes <licence_current> → <licence_latest>.` If the tuple's `health` is non-null, append ` Marked <health.state> in the registry: <health.detail>.`
```
Change the `Suggested fix` bullet (line 56) to handle pure-health findings:
```
- **Suggested fix:** `Upgrade <item> to <target>.` For `github-actions` SHA-pins, add `Preserve the SHA pin: update both the pinned commit and the # <target> comment.` Never suggest unpinning. **When the finding is pure-health** (`health` is non-null and `target` equals `current`), the Suggested fix is instead `Review: <item> is current but marked <health.state>.` (no upgrade target exists).
```

- [ ] **Step 2: Extend the worked example with a NuGet finding and a health-flagged finding**

In `housekeeper-reviewer.md`, replace the worked-example intro sentence (line 72) and append two findings inside the example fence (after the `react` finding, before the closing fence at line 100). New intro:
```
For a diff that changes `.github/workflows/ci.yml` (a `uses: actions/checkout@v3` on line 12 where latest GA is `v4.2.1`, and a `runs-on: ubuntu-22.04` on line 15), `package.json` (a `"react": "^18.2.0"` on touched line 4 where latest GA is `19.0.0`), and `Directory.Packages.props` (a `<PackageVersion Include="Serilog" Version="2.10.0" />` on touched line 6 where latest GA is `4.0.0`, plus a current-but-deprecated `Newtonsoft.Json` at `13.0.3`), the canonical §7 output is:
```
Append these two findings inside the fence, after the existing `react` finding block:
```
### Finding — Serilog behind latest GA
- **File:** Directory.Packages.props:6
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/nuget
- **Description:** Serilog is at 2.10.0; latest GA is 4.0.0.
- **Suggested fix:** Upgrade Serilog to 4.0.0.

### Finding — Newtonsoft.Json marked deprecated
- **File:** Directory.Packages.props:7
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/nuget
- **Description:** Newtonsoft.Json is at 13.0.3; latest GA is 13.0.3. Marked deprecated in the registry: Use System.Text.Json instead.
- **Suggested fix:** Review: Newtonsoft.Json is current but marked deprecated.
```

- [ ] **Step 3: Validate frontmatter + run the suite**

Confirm `name`/`description` unchanged, blank line after `---` intact. Run `bash tests/run.sh` — the `static-analysis severity literals` test (which now includes `housekeeper-reviewer.md`) still passes (`Confidence: 100` and `## Housekeeper Findings` both present and unchanged).

- [ ] **Step 4: Commit + push**

```bash
git add plugins/code-review-suite/agents/housekeeper-reviewer.md
git commit -m "feat(housekeeper): agent renders nuget + health findings (extended worked example)"
git push origin main
```

---

### Task 8: Cookbook — NuGet registration-endpoint note

**Files:**
- Modify: `plugins/code-review-suite/includes/version-freshness-cookbook.md` (after the ecosystem table, ~line 22)

The flat-container row already exists (line 16). Add a note that NuGet licence + deprecation/unlisted metadata come from the registration resource, not the flat-container.

- [ ] **Step 1: Add the registration-endpoint note**

In `version-freshness-cookbook.md`, after the ecosystem table (after line 22, before `### Runner labels`), insert:
```markdown
### NuGet registration (licence + maintenance-health)

The flat-container `index.json` (the NuGet row above) is a bare version list —
it carries neither licence nor deprecation metadata. The housekeeper reads those
from the **registration** resource:

| Resource     | Endpoint pattern                                                                     | Fields read                                  |
|--------------|--------------------------------------------------------------------------------------|----------------------------------------------|
| registration | `https://api.nuget.org/v3/registration5-gz-semver2/<package-lower>/index.json` (gzip) | `catalogEntry.licenseExpression`, `deprecation`, `listed` |

The registration index is gzipped and paginated (pages either inlined or external
`@id` leaves needing a follow-up fetch); the engine handles both. A registration
miss leaves `licence_*`/`health` null but does NOT suppress the freshness finding —
only a flat-container miss (no trustworthy latest GA) suppresses entirely.
Maintenance-health is deterministic: `deprecation` → `deprecated`, `listed: false`
→ `unlisted`. Fuzzy signals (last-publish age, single-maintainer) are out of scope.
```

- [ ] **Step 2: Commit + push**

```bash
git add plugins/code-review-suite/includes/version-freshness-cookbook.md
git commit -m "docs(cookbook): add NuGet registration-endpoint note (licence + health)"
git push origin main
```

---

### Task 9: Detection-flag extension across the three pipeline files

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md:693`
- Modify: `plugins/code-review-suite/commands/pre-review.md:694`
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md:799`
- Confirm (no change expected): `tests/lib/test_sync_notes.sh`, `agents/review-synthesiser.md`, `includes/static-analysis-context.md`

The Housekeeping detection trigger currently fires on `.github/workflows/*.yml`/`*.yaml` and `package.json`. Extend it to also fire on `*.csproj`, `*.props`, and `packages.lock.json`. The three sentences are **byte-identical** across the three files (verify with grep before and after) — edit all three to the same new text. The detection sync test (`test_dispatcher_includes_new_static_analysis_flags`) asserts only the *presence* of `$HOUSEKEEPING_DETECTED` in SKILL.md + pre-review.md, NOT the trigger-pattern content, so it needs no change — but CONFIRM that by reading the test. The synthesiser carve-out and `static-analysis-context.md` §10 are source-agnostic (`[housekeeper]` already covers NuGet) — CONFIRM by reading; expect no change.

- [ ] **Step 1: Confirm the three detection sentences are byte-identical**

Run: `grep -n "Housekeeping detection" plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
Expected: three lines with identical wording (the slice-1 trigger). Note the exact current text so the replacement stays a clean single-substring edit per file.

- [ ] **Step 2: Edit the trigger in all three files (identical new text)**

In each of `review-pipeline.md:693`, `pre-review.md:694`, `SKILL.md:799`, replace the `**Housekeeping detection:**` bullet with:
```
   - **Housekeeping detection:** if any changed file is under `.github/workflows/` and ends `.yml`/`.yaml`, is a `package.json` (npm manifest), ends `.csproj`/`.props`, or is a `packages.lock.json` (NuGet manifests), set `$HOUSEKEEPING_DETECTED = true`. (This slice covers GitHub Actions, workflow runners, npm, and NuGet; follow-on plans extend the trigger to PyPI/crates/Go/RubyGems/Docker/SDK manifests.)
```

- [ ] **Step 3: Confirm the detection sync test asserts presence only (no change needed)**

Read `tests/lib/test_sync_notes.sh` `test_dispatcher_includes_new_static_analysis_flags` (~line 482-508): it loops `for flag in '$JS_DETECTED' '$PY_DETECTED' '$IAC_DETECTED' '$HOUSEKEEPING_DETECTED'` and only `grep -qF "$flag"` for presence. The trigger-pattern text is not asserted, so extending it needs no test change. (If, contrary to expectation, a test pins the trigger wording, extend it to the new text in lockstep here.)

- [ ] **Step 4: Confirm the synthesiser carve-out + §10 are source-agnostic (no change expected)**

Read `agents/review-synthesiser.md:89` and `:125` and `:221`, and `includes/static-analysis-context.md` §10. They enumerate `[housekeeper]` as a source tag, not per-source-class, so NuGet findings render under the existing carve-out unchanged. Confirm no `npm`/`github-actions`-specific literal exists that would need a `nuget` sibling. Expect no edit.

- [ ] **Step 5: Run the suite**

Run: `bash tests/run.sh`
Expected: all pass except the known dirty-tree artifact (`A/B run.sh: bad-config rejection leaves working tree clean`). The detection sync test stays green.

- [ ] **Step 6: Commit + push**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md
git commit -m "feat(pipeline): housekeeping detection fires on NuGet manifests (csproj/props/lock)"
git push origin main
```

---

### Task 10: npm/runner hardening (three fixes, each its own test)

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (`parse_package_json` keying; `_NPM_SCOPE_SUFFIXES`)
- Modify: `tests/python/test_housekeeper_engine.py` (three regression tests)
- Create: `tests/lib/test_runner_cadence.sh` (`LATEST_RUNNERS` 180-day stamp self-check)

Three independent hardening fixes the slice-1 review surfaced. Each gets its own failing test first.

#### 10a — Multi-section dep collapse

`parse_package_json` keys by name, so a dep in both `dependencies` and `peerDependencies` collapses to one entry (the last occurrence). Re-key by `(section, name)` so both yield findings, and have `collect_npm` iterate the richer structure.

- [ ] **Step 1: Write the failing multi-section test**

Add to `NpmTest`:
```python
    def test_parse_package_json_keeps_multi_section_deps(self):
        text = (
            '{\n'
            '  "dependencies": {\n'
            '    "react": "^18.2.0"\n'
            '  },\n'
            '  "peerDependencies": {\n'
            '    "react": "^18.0.0"\n'
            '  }\n'
            '}\n'
        )
        deps = self.m.parse_package_json(text)
        # Two distinct (section, name) entries, both for react, on their own lines.
        self.assertEqual(
            sorted((k[0], k[1], v[0], v[1]) for k, v in deps.items()),
            [("dependencies", "react", "^18.2.0", 3),
             ("peerDependencies", "react", "^18.0.0", 6)])

    def test_collect_npm_emits_both_sections(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NPM_DOC
        text = ('{\n  "dependencies": {\n    "react": "^18.2.0"\n  },\n'
                '  "peerDependencies": {\n    "react": "^18.0.0"\n  }\n}\n')
        findings = self.m.collect_npm({"package.json": text}, {"package.json": {3, 6}}, reg)
        self.assertEqual(len(findings), 2)
        self.assertEqual(sorted(f["line"] for f in findings), [3, 6])
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `parse_package_json` returns name-keyed dict (`react` collapses to one entry; `deps.items()` keys are strings not tuples).

- [ ] **Step 3: Re-key `parse_package_json` by `(section, name)` + update `collect_npm`**

In `parse_package_json`, track the current section name and key by `(section, name)`. Replace the function body:
```python
def parse_package_json(text):
    """Return {(section, name): (spec, line_no)} across all dependency sections.

    Keyed by (section, name) so a dep appearing in multiple sections (e.g. both
    dependencies and peerDependencies) yields a distinct entry per section
    rather than collapsing to the last occurrence."""
    deps = {}
    section = None
    for i, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.strip()
        hit = next((s for s in _DEP_SECTIONS
                    if ('"%s"' % s) in stripped and stripped.endswith("{")), None)
        if hit:
            section = hit
            continue
        if section is not None and stripped.startswith("}"):
            section = None
            continue
        if section is not None:
            m = _DEP_LINE_RE.match(raw)
            if m:
                deps[(section, m.group(1))] = (m.group(2), i)
    return deps
```
In `collect_npm`, change the dep-iteration header from `for name, (spec, line) in deps.items():` to:
```python
        for (section, name), (spec, line) in deps.items():
```
(The rest of the loop — added in Task 6 — is unchanged; `name` and `spec`/`line` are still bound.)

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `NpmTest` pass, including the two new multi-section tests. The single-section slice-1 fixture is unaffected.

#### 10b — `.json` scope narrowing

`_NPM_SCOPE_SUFFIXES` includes bare `.json`, so a stray `data.json` drags `package.json` into scope. Drop bare `.json`; keep npm-meaningful JSON via explicit basename/pattern checks.

- [ ] **Step 5: Write the failing scope-breadth test**

Add to `NpmTest`:
```python
    def test_stray_json_does_not_pull_in_package_json(self):
        roots = self.m.npm_scope_roots(["web/app/data.json"], {"web/app/package.json"})
        self.assertEqual(roots, set())

    def test_tsconfig_still_pulls_in_package_json(self):
        roots = self.m.npm_scope_roots(["web/app/tsconfig.json"], {"web/app/package.json"})
        self.assertEqual(roots, {"web/app/package.json"})
```

- [ ] **Step 6: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: `test_stray_json_does_not_pull_in_package_json` FAILS (bare `.json` matches, so `data.json` pulls in the manifest).

- [ ] **Step 7: Narrow `_NPM_SCOPE_SUFFIXES` + tighten `_is_npm_scope_file`**

Remove `".json"` from `_NPM_SCOPE_SUFFIXES` (line 332-335) so it reads:
```python
_NPM_SCOPE_SUFFIXES = (
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts",
    ".vue", ".svelte",
)
```
Update `_is_npm_scope_file` (lines 338-342) to keep npm-meaningful JSON explicitly:
```python
def _is_npm_scope_file(path):
    base = path.rsplit("/", 1)[-1]
    if base in ("package.json", "package-lock.json", ".npmrc", "yarn.lock", "pnpm-lock.yaml"):
        return True
    # npm-meaningful JSON only: tsconfig*.json and *.config.json. A bare
    # data.json must NOT drag a sibling package.json into scope.
    if base.startswith("tsconfig") and base.endswith(".json"):
        return True
    if base.endswith(".config.json"):
        return True
    return path.endswith(_NPM_SCOPE_SUFFIXES)
```

- [ ] **Step 8: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: both new scope tests pass; existing `test_npm_root_finds_nearest_package_json` (a `.ts` file) still passes.

#### 10c — `LATEST_RUNNERS` cadence self-check

The `LATEST_RUNNERS` table is manually maintained with a `# Reviewed YYYY-MM-DD` stamp. Add a self-check that fails when the stamp is older than 180 days, turning silent staleness into a visible signal.

- [ ] **Step 9: Create the cadence self-check test**

Create `tests/lib/test_runner_cadence.sh`:
```bash
#!/usr/bin/env bash
# tests/lib/test_runner_cadence.sh — fails when the LATEST_RUNNERS table's
# 'Reviewed YYYY-MM-DD' stamp in bin/housekeeper-freshness is older than 180
# days, surfacing silent runner-label staleness as a visible test signal.

test_runner_cadence_stamp_is_fresh() {
    local repo="$REPO_ROOT"
    local engine="$repo/plugins/code-review-suite/bin/housekeeper-freshness"

    if [[ ! -f "$engine" ]]; then
        skip "runner cadence stamp" "engine not present"
        return
    fi

    local stamp
    stamp=$(grep -oE 'Reviewed [0-9]{4}-[0-9]{2}-[0-9]{2}' "$engine" | head -n1 | awk '{print $2}')
    if [[ -z "$stamp" ]]; then
        fail "runner cadence stamp: LATEST_RUNNERS has a 'Reviewed YYYY-MM-DD' stamp" \
            "no 'Reviewed YYYY-MM-DD' comment found near LATEST_RUNNERS"
        return
    fi

    local stamp_epoch now_epoch age_days
    # BSD date (macOS) and GNU date (Linux) differ; try both.
    stamp_epoch=$(date -j -f "%Y-%m-%d" "$stamp" "+%s" 2>/dev/null || date -d "$stamp" "+%s" 2>/dev/null)
    now_epoch=$(date "+%s")
    if [[ -z "$stamp_epoch" ]]; then
        fail "runner cadence stamp: stamp '$stamp' parses as a date" "date parse failed"
        return
    fi
    age_days=$(( (now_epoch - stamp_epoch) / 86400 ))
    if (( age_days <= 180 )); then
        pass "runner cadence stamp: LATEST_RUNNERS reviewed ${age_days}d ago (<= 180)"
    else
        fail "runner cadence stamp: LATEST_RUNNERS reviewed within 180 days" \
            "stamp '$stamp' is ${age_days} days old — re-verify the latest runner labels (ubuntu/windows/macos) against GitHub's runner-images releases and bump the 'Reviewed' date"
    fi
}
```

- [ ] **Step 10: Run the new cadence test**

Run: `bash tests/run.sh 2>&1 | grep -i "runner cadence"`
Expected: PASS — the engine's `Reviewed 2026-06-05` stamp is well within 180 days of the execution date. (If the execution session is >180 days after 2026-06-05, the fix is to re-verify the runner labels and bump the stamp, which is exactly the signal this test exists to raise — do that in the engine, do not weaken the test.)

- [ ] **Step 11: Run the full suite**

Run: `bash tests/run.sh`
Expected: all pass except the known dirty-tree artifact. Note the new total (the cadence test is auto-discovered).

- [ ] **Step 12: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py tests/lib/test_runner_cadence.sh
git commit -m "fix(housekeeper): multi-section deps, narrow .json scope, runner-cadence self-check"
git push origin main
```

---

### Task 11: README specialist-row + freshness prose mention NuGet

**Files:**
- Modify: `plugins/code-review-suite/README.md:35` (conditional-specialist sentence), `:43-44` (freshness prose), `:77` (specialist table row)

The slice-1 README already lists `housekeeper-reviewer`; slice 2 just adds NuGet to its scope description.

- [ ] **Step 1: Update the conditional-specialist sentence (line 35)**

Change `housekeeper-reviewer` (dependency/version freshness: GitHub Actions, workflow runners, npm)` to include NuGet:
```
`housekeeper-reviewer` (dependency/version freshness + maintenance-health: GitHub Actions, workflow runners, npm, NuGet)
```

- [ ] **Step 2: Update the freshness prose (lines 43-44)**

Change the sentence beginning `The `housekeeper-reviewer` verifies against the live registry that dependencies, GitHub Actions, and runners are at their latest GA release.` to:
```
The `housekeeper-reviewer` verifies against the live registry that dependencies (npm + NuGet), GitHub Actions, and runners are at their latest GA release, and flags packages the registry marks deprecated or unlisted (maintenance-health).
```

- [ ] **Step 3: Update the specialist table row (line 77)**

Change the `housekeeper-reviewer` row to:
```
| `housekeeper-reviewer` | Dependency/version freshness + maintenance-health — flags GitHub Actions, workflow runners, npm, and NuGet packages behind latest GA or marked deprecated/unlisted (conditional — workflows + `package.json` + `*.csproj`/`*.props`; registry-backed deterministic engine) |
```

- [ ] **Step 4: Commit + push**

```bash
git add plugins/code-review-suite/README.md
git commit -m "docs(README): housekeeper covers NuGet + maintenance-health"
git push origin main
```

---

### Task 12: A/B apparatus (offline — NuGet fixture, recorded registries, parser case, configs)

**Files:**
- Create: `tests/fixtures/static-analysis/housekeeper-nuget/src/Api/Api.csproj`
- Create: `tests/fixtures/static-analysis/housekeeper-nuget/Directory.Packages.props`
- Create: `tests/fixtures/static-analysis/housekeeper-nuget/Directory.Build.props`
- Create: `tests/fixtures/static-analysis/housekeeper-nuget/registry/nuget/serilog.json`
- Create: `tests/fixtures/static-analysis/housekeeper-nuget/registry/nuget/newtonsoft.json.json`
- Create: `tests/fixtures/static-analysis/housekeeper-nuget/registry/nuget-registration/serilog.json`
- Create: `tests/fixtures/static-analysis/housekeeper-nuget/registry/nuget-registration/newtonsoft.json.json`
- Create: `tests/ab/corpus/housekeeper-nuget-stale-deps/source.yaml`
- Create: `tests/ab/corpus/housekeeper-nuget-stale-deps/diff/changed-lines.txt`
- Modify: `tests/ab/corpus/index.yaml`
- Create: `tests/ab/fixtures/housekeeper-nuget-stdout.log`
- Modify: `tests/lib/test_ab_per_agent_lib.sh`
- Create: `tests/ab/configs/per-agent/housekeeper-nuget-baseline.yaml`
- Create: `tests/ab/configs/per-agent/housekeeper-nuget-haiku-low.yaml`

A NuGet A/B corpus exercising CPM resolution, a global props dep, freshness, and a deprecated-current package. The `agent_capture.sh` parser is source-agnostic (`housekeeper/nuget` has no whitespace, so the shared `split(v, a, /[ \t(]/)` tokeniser keeps the slash whole) — **no parser-dispatch change needed**; the housekeeper case (`agent_capture.sh:65-72`) already matches NuGet output.

- [ ] **Step 1: Write the fixture sources (csproj + props)**

`tests/fixtures/static-analysis/housekeeper-nuget/src/Api/Api.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="Serilog" />
    <PackageReference Include="Newtonsoft.Json" />
  </ItemGroup>
</Project>
```
`tests/fixtures/static-analysis/housekeeper-nuget/Directory.Packages.props` (line 3 = Serilog central version, line 4 = Newtonsoft.Json central version):
```xml
<Project>
  <ItemGroup>
    <PackageVersion Include="Serilog" Version="2.10.0" />
    <PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
  </ItemGroup>
</Project>
```
`tests/fixtures/static-analysis/housekeeper-nuget/Directory.Build.props` (a benign governing props, present so the fixture proves the walk-up scans it without finding a stale global dep):
```xml
<Project>
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
</Project>
```

- [ ] **Step 2: Write the recorded flat-container + registration fixtures**

`registry/nuget/serilog.json`:
```json
{"versions": ["2.10.0", "3.1.1", "4.0.0"]}
```
`registry/nuget/newtonsoft.json.json` (slug is the lowercased name `newtonsoft.json`):
```json
{"versions": ["13.0.1", "13.0.3"]}
```
`registry/nuget-registration/serilog.json`:
```json
{
  "items": [
    {
      "items": [
        {"catalogEntry": {"version": "2.10.0", "licenseExpression": "Apache-2.0", "listed": true}},
        {"catalogEntry": {"version": "4.0.0", "licenseExpression": "Apache-2.0", "listed": true}}
      ]
    }
  ]
}
```
`registry/nuget-registration/newtonsoft.json.json` (current 13.0.3 is the latest GA but marked deprecated → pure-health):
```json
{
  "items": [
    {
      "items": [
        {"catalogEntry": {"version": "13.0.3", "licenseExpression": "MIT", "listed": true,
                          "deprecation": {"message": "Use System.Text.Json instead", "reasons": ["Legacy"]}}}
      ]
    }
  ]
}
```

- [ ] **Step 3: Verify the engine produces the expected two-finding set against the fixtures**

Run (single Bash calls; resolve `$CLAUDE_TEMP_DIR` to the literal session path):
```
printf 'src/Api/Api.csproj\n' > $CLAUDE_TEMP_DIR/hkn-files.txt
```
```
printf 'Changed lines:\n  src/Api/Api.csproj: 3,4\n  Directory.Packages.props: 3,4\n' > $CLAUDE_TEMP_DIR/hkn-lines.txt
```
```
HOUSEKEEPER_REGISTRY_FIXTURES=tests/fixtures/static-analysis/housekeeper-nuget/registry python3 plugins/code-review-suite/bin/housekeeper-freshness --root tests/fixtures/static-analysis/housekeeper-nuget --changed-files-from $CLAUDE_TEMP_DIR/hkn-files.txt --changed-lines-from $CLAUDE_TEMP_DIR/hkn-lines.txt
```
Expected stdout: a 2-element array, both `source: nuget`, both `file: Directory.Packages.props` (CPM resolution points the literal at props): Serilog at `2.10.0` → `latest_ga 4.0.0`, `health null`; Newtonsoft.Json at `13.0.3` → `latest_ga 13.0.3`, `target 13.0.3`, `health {state: deprecated, detail: "Use System.Text.Json instead"}`. (The `Directory.Packages.props: 3,4` changed-lines entry makes both literals touched, so Serilog targets latest GA.)

- [ ] **Step 4: Write the changed-lines + source.yaml + register the corpus**

`tests/ab/corpus/housekeeper-nuget-stale-deps/diff/changed-lines.txt`:
```
Changed lines:
  src/Api/Api.csproj: 3,4
  Directory.Packages.props: 3,4
```
`tests/ab/corpus/housekeeper-nuget-stale-deps/source.yaml` (mirror the slice-1 `housekeeper-smoke-stale-deps` shape; NO `setup:` — the engine ships in the plugin `bin/`):
```yaml
id: housekeeper-nuget-stale-deps
agent: housekeeper-reviewer
captured_at: 2026-06-05T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: PLACEHOLDER_FILL_AT_CAPTURE
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/housekeeper-nuget/
base_sha: ""  # synthetic fixture: no real diff
head_sha: ""
path_scope: ""
empty_tree_mode: false
registry_fixtures: registry/   # INERT: harness has no env-passthrough (CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1); the live capture (Task 13) hits real registries. Kept as a forward marker.
intent_ledger: |
  ## Intent ledger
  - Synthetic NuGet fixture exercising housekeeper-reviewer against a CPM
    solution (Directory.Packages.props central versions; version-less csproj
    refs resolving through CPM). Two deterministic Suggestion findings: Serilog
    2.10.0 -> 4.0.0 (stale) and Newtonsoft.Json 13.0.3 current-but-deprecated
    (pure-health). Slice-2 baseline for the Haiku/low cost-tuning probe.
depends_on:
  - plugins/code-review-suite/agents/housekeeper-reviewer.md
  - plugins/code-review-suite/bin/housekeeper-freshness
  - plugins/code-review-suite/includes/static-analysis-context.md
  - tests/fixtures/static-analysis/housekeeper-nuget/src/Api/Api.csproj
  - tests/fixtures/static-analysis/housekeeper-nuget/Directory.Packages.props
```
In `tests/ab/corpus/index.yaml`, append under the existing housekeeper entry:
```yaml
  - id: housekeeper-nuget-stale-deps
    agent: housekeeper-reviewer
    type: synthetic
    description: Two-finding NuGet set (Serilog 2.10.0->4.0.0 via CPM resolution; Newtonsoft.Json 13.0.3 current-but-deprecated pure-health) via recorded flat-container + registration fixtures. Slice-2 baseline.
    tags: [smoke, deterministic]
```

- [ ] **Step 5: Write the parser test fixture**

`tests/ab/fixtures/housekeeper-nuget-stdout.log` (preamble + canonical §7 block + trailing prose). Two findings — a stale NuGet finding and a pure-health finding:
```
Running the housekeeper-freshness engine over the changed NuGet manifests.

## Housekeeper Findings

### Finding — Serilog behind latest GA
- **File:** Directory.Packages.props:3
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/nuget
- **Description:** Serilog is at 2.10.0; latest GA is 4.0.0.
- **Suggested fix:** Upgrade Serilog to 4.0.0.

### Finding — Newtonsoft.Json marked deprecated
- **File:** Directory.Packages.props:4
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/nuget
- **Description:** Newtonsoft.Json is at 13.0.3; latest GA is 13.0.3. Marked deprecated in the registry: Use System.Text.Json instead.
- **Suggested fix:** Review: Newtonsoft.Json is current but marked deprecated.

That is all the freshness/health signal for this diff.
```

- [ ] **Step 6: Write the failing parser test**

In `tests/lib/test_ab_per_agent_lib.sh`, after the existing housekeeper tests (after `test_ab_agent_capture_housekeeper_skipped_marks_inconclusive`, ~line 691), add:
```bash
test_ab_agent_capture_housekeeper_nuget_parses_two_findings() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/housekeeper-nuget-stdout.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture housekeeper-nuget: lib + fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial housekeeper "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "2" "$count" "A/B agent_capture housekeeper-nuget: two findings extracted"

    # The slash-bearing rule_id must tokenise WHOLE — the shared tokeniser
    # splits on [ \t(], none of which appear in housekeeper/nuget.
    local nuget_rule
    nuget_rule=$(jq -r '.[] | select(.line == 3) | .rule_id' "$trial_dir/findings.json")
    assert_equals "housekeeper/nuget" "$nuget_rule" "A/B agent_capture housekeeper-nuget: slash-bearing rule_id tokenises whole"

    local sev
    sev=$(jq -r '.[] | select(.line == 4) | .severity' "$trial_dir/findings.json")
    assert_equals "Suggestion" "$sev" "A/B agent_capture housekeeper-nuget: pure-health severity is Suggestion"

    rm -rf "$trial_dir"
}
```
(This mirrors `test_ab_agent_capture_housekeeper_parses_three_findings` exactly: the `lib + fixture present` guard, the subshell `source "$lib"` + `agent_capture_parse_trial housekeeper "$trial_dir"`, and `jq`-based assertions.)

- [ ] **Step 7: Run to verify it passes (parser is source-agnostic)**

Run: `bash tests/run.sh 2>&1 | grep -i "housekeeper-nuget"`
Expected: PASS immediately — the `housekeeper` parser case already matches `## Housekeeper Findings` and the source-agnostic §7 state machine extracts `housekeeper/nuget` whole (no `[ \t(]` in the rule). If it FAILS with a tokenisation split, that contradicts the slice-1 finding and must be investigated, not patched around.

- [ ] **Step 8: Write the configs + config-parse test**

`tests/ab/configs/per-agent/housekeeper-nuget-baseline.yaml`:
```yaml
name: housekeeper-nuget-baseline
description: Production reference for housekeeper-reviewer on the NuGet corpus — sonnet at default effort.
mode: per-agent
agent: housekeeper-reviewer
session:
  model: sonnet
  effort: default
```
`tests/ab/configs/per-agent/housekeeper-nuget-haiku-low.yaml`:
```yaml
name: housekeeper-nuget-haiku-low
description: Slice-2 directional probe — housekeeper-reviewer at Haiku/low on the NuGet corpus. Compared against housekeeper-nuget-baseline (sonnet/default) on per-trial findings hash.
mode: per-agent
agent: housekeeper-reviewer
session:
  model: haiku
  effort: low
```
In `tests/lib/test_ab_per_agent_lib.sh`, add a config-parse test mirroring `test_ab_config_per_agent_housekeeper_haiku_low_parses` (~line 1040) but pointed at `housekeeper-nuget-haiku-low.yaml`, asserting `mode=per-agent`, `agent=housekeeper-reviewer`, `model=haiku`, `effort=low`.

- [ ] **Step 9: Run the full suite**

Run: `bash tests/run.sh`
Expected: all pass except the known dirty-tree artifact. Note the new total.

- [ ] **Step 10: Commit + push**

```bash
git add tests/fixtures/static-analysis/housekeeper-nuget tests/ab/corpus/housekeeper-nuget-stale-deps tests/ab/corpus/index.yaml tests/ab/fixtures/housekeeper-nuget-stdout.log tests/lib/test_ab_per_agent_lib.sh tests/ab/configs/per-agent/housekeeper-nuget-baseline.yaml tests/ab/configs/per-agent/housekeeper-nuget-haiku-low.yaml
git commit -m "test(ab): NuGet corpus fixture, recorded flat-container + registration, parser test, configs"
git push origin main
```

---

### Task 13: GATED live NuGet capture, 2×20 sweep, verdict, memory

**STOP. Task 13's capture and sweep steps spend real Bedrock. Get explicit operator go-ahead before each. "Continue" does NOT authorise the spend.**

**Files:**
- Modify: `tests/ab/corpus/housekeeper-nuget-stale-deps/source.yaml` (fill `suite_sha`)
- Create: `tests/ab/corpus/housekeeper-nuget-stale-deps/expected/findings-housekeeper.md`
- Create: `tests/ab/corpus/housekeeper-nuget-stale-deps/expected/findings.json`
- Possibly modify: `plugins/code-review-suite/agents/housekeeper-reviewer.md` (worked-example refinement only if the first capture parses to zero tuples)
- Create: `docs/superpowers/notes/2026-06-05-housekeeper-nuget-haiku-low-result.md`

> **Cache-staleness pre-flight (carried from slice 1, cost a capture there):** the A/B harness dispatches the agent BODY from the working tree but resolves the engine BINARY on PATH from the plugin CACHE. After all the mid-plan `bin/housekeeper-freshness` edits, run `/plugins update` then `/reload-plugins` (or start a fresh session) BEFORE the first capture, or the dispatched agent runs a stale engine. See memory `project_plugin_cache_staleness.md` / `feedback_plugins_update_after_push.md`.

> **Live-registry note (carried):** the harness scrubs the subagent env (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`), so `HOUSEKEEPER_REGISTRY_FIXTURES` is NOT injected — the live capture/sweep hit REAL nuget.org. This is fine for unambiguous stale pins (Serilog 2.10.0 ≪ current major) but the **Newtonsoft.Json deprecation is the live risk**: if nuget.org does NOT actually mark the chosen package deprecated, the pure-health finding will not appear live and the canonical hash will differ from the fixture's two-finding set. Before the capture, verify the live deprecation status of the chosen package (the engine determinism under fixtures is independently proven by `NuGetEndToEndTest`). If the chosen package is not live-deprecated, either pick a genuinely-deprecated NuGet package for the health slot OR scope the live sweep to the freshness finding only and record the health finding as fixture-verified-only in the result note. Decide and document — do not let a fixture/live divergence launder into a false INCONCLUSIVE.

- [ ] **Step 1: Capture ONE sonnet/default trial (GATED)**

Get go-ahead. Run:
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-nuget-baseline.yaml --corpus housekeeper-nuget-stale-deps --trials 1 --stream-json
```
Read the trial-001 `stdout.log`: confirm the agent ran the engine, got the tuples, and rendered the §7 block. If `findings.json` parsed to `[]` despite a visible report, refine `housekeeper-reviewer.md`'s worked example to match the real layout (per the worked-example-gap lesson), re-capture, confirm the parse.

- [ ] **Step 2: Promote the captured report as the expected baseline**

Copy the captured findings block to `expected/findings-housekeeper.md` and the parsed tuples to `expected/findings.json`. Fill `suite_sha` in `source.yaml` with the current HEAD. Record the canonical hash and the live registry values observed (they will drift; the hash will not — it keys on `file/line/rule_id/severity/confidence`).

- [ ] **Step 3: The matched 2×20 probe (GATED — the main Bedrock spend)**

Get explicit go-ahead. Run BOTH arms at n=20 (full matched pair — the NuGet corpus has no prior data):
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-nuget-baseline.yaml --corpus housekeeper-nuget-stale-deps --trials 20 --stream-json
```
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-nuget-haiku-low.yaml --corpus housekeeper-nuget-stale-deps --trials 20 --stream-json
```
Consider `run_in_background: true` per arm. NuGet is the most parse-heavy source (CPM indirection, props walk-up) so watch the hash distribution — but the agent's work is unchanged (run engine → render); the engine does the parsing, so haiku-risk is in rendering, not parsing.

- [ ] **Step 4: Tabulate + verdict**

Per `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`: **EQUIVALENT** (clean single-hash haiku arm matching baseline) → validates the shipped tier; **INCONCLUSIVE** (mixed within-arm hashes) → do not flip, characterise the tail; **WORSE** (>25% NORMAL-rate drop) → revert to sonnet. Compute the sonnet÷haiku cost RATIO (list-price caveat — the absolute dollars are Anthropic list price, not Bedrock; the ratio is the reportable figure, in family with slice-1's 2.38× and trivy 2.34×/eslint 2.17×). If a real agent-side tail survives, CHARACTERISE it — any fix must be a general correctness improvement (helping sonnet too) earning its own before/after re-sweep at n=20 on both arms.

- [ ] **Step 5: Write the result note**

Create `docs/superpowers/notes/2026-06-05-housekeeper-nuget-haiku-low-result.md` mirroring `docs/superpowers/notes/2026-06-05-housekeeper-haiku-low-result.md`: header (run dirs + sweep SHA), sweep config, per-arm hash distribution, the live-deprecation decision from the Task-13 pre-flight, any agent-side tail, cost ratio with the list-price caveat, verdict verbatim, production-flip recommendation.

- [ ] **Step 6: Production-flip decision (operator-gated)**

The agent already ships `model: haiku` + `effort: low`. On EQUIVALENT, NO frontmatter change is needed — record the validation. On INCONCLUSIVE/WORSE, the mitigation is to set `model: sonnet` (and `effort: default`) in `housekeeper-reviewer.md` and re-sweep later. This is operator-gated; the slice-1 tier already covers all four source classes, so a revert would affect npm/Actions/runner too — flag that trade-off explicitly if proposing a revert.

- [ ] **Step 7: Update memory (in the `~/.claude` repo, committed separately)**

Create `project_housekeeper_specialist_slice2.md` in the `~/.claude` repo memory dir (`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`, NOT this clone): slice 2 shipped, NuGet source class + maintenance-health axis + npm hardening, the engine deltas (4-tuple, registration client, `health` field), the verdict + cost ratio, whether haiku held, and the remaining deferred ecosystems (PyPI/crates/Go/RubyGems/Docker/SDK). Add the MEMORY.md index line. Update `project_housekeeper_specialist_slice1.md`'s "Next step" section to mark slice 2 done. Commit + push the `~/.claude` repo separately.

- [ ] **Step 8: Commit + push the result note + expected fixtures**

```bash
git add tests/ab/corpus/housekeeper-nuget-stale-deps/expected tests/ab/corpus/housekeeper-nuget-stale-deps/source.yaml docs/superpowers/notes/2026-06-05-housekeeper-nuget-haiku-low-result.md plugins/code-review-suite/agents/housekeeper-reviewer.md
git commit -m "docs(ab): housekeeper NuGet Haiku/low A/B result + verdict + expected baseline"
git push origin main
```

---

## Self-review notes

- **Spec coverage:** tuple `health` field (Task 5 NuGet emits it; Task 6 makes it uniform + npm rider); `parse_version` 4-tuple + regression guard (Task 1); registration client gzip+pagination+fixture override (Task 2); NuGet parsers incl. `VersionOverride`/child-element/version-less (Task 3); scope model nearest-csproj + props walk-up + CPM (Task 4); `collect_nuget` freshness + licence-diff + health + T3 + no-untrustworthy gate + CLI tree-walk (Task 5); widened emit rule "stale OR health-flagged" (Tasks 5/6); pure-health emit with `target = current` (Tasks 5/6 + agent renderer Task 7); npm `deprecated` rider (Task 6); agent `nuget` rule + health rendering + extended worked example (Task 7); cookbook registration note (Task 8); detection-flag extension across the three pipeline files (Task 9); synthesiser/§10 confirm-no-change (Task 9 Steps 3-4); npm/runner hardening — multi-section, `.json` narrowing, `LATEST_RUNNERS` cadence (Task 10); README (Task 11); A/B apparatus incl. registration fixture + health finding (Task 12); hash-stability verification (Task 6 Step 5); gated 2×20 sweep + verdict + memory (Task 13).
- **The ONE slice-1-proven-code change is isolated and guarded:** `parse_version` → 4-tuple (Task 1), with the existing comparison tests as the behavioural regression guard and explicit 3-part backward-compat assertions. Every other task is additive.
- **Hash stability is verified, not assumed:** Task 6 Step 5 runs the engine against the slice-1 fixture and confirms the three tuples keep their `file/line/source` with `health: null`. The slice-1 npm fixture is single-section, so the Task-10a multi-section change cannot perturb its baseline (noted in Task 6 Step 5 and Task 10a Step 4).
- **Placeholder scan:** every code step shows complete code; every doc edit shows the exact before/after literal; every command shows expected output. The only deliberate `PLACEHOLDER_FILL_AT_CAPTURE` is the `suite_sha`, filled in Task 13 Step 2 (same convention as slice 1).
- **Type/name consistency:** new engine symbols (`Registry.registration`, `Registry._get_json`, `Registry._walk_registration`, `nuget_strip_constraint`, `parse_csproj`, `parse_packages_props`, `nuget_scope_roots`, `_is_nuget_scope_file`, `_dirname`, `_dir_is_ancestor_or_same`, `_nuget_health`, `collect_nuget`) are used identically in tests and implementation across Tasks 2-6. The tuple gains exactly one key, `health`, defined in Task 5 and applied uniformly in Task 6. The `Rule:` value `housekeeper/nuget` matches the agent renderer (Task 7), the parser fixture (Task 12), and the source-agnostic parser case (`agent_capture.sh:65-72`, unchanged).
- **Parser-change avoidance is a deliberate, verified claim, not an assumption:** Task 12 Step 7 asserts the existing `housekeeper` parser case already handles `housekeeper/nuget` (slash with no whitespace survives the shared tokeniser — the slice-1 comment block at `agent_capture.sh:21-24` documents exactly this). If that assertion fails, the plan says investigate, not patch around.
- **Sync-test no-change is confirmed by reading, not guessed:** the detection sync test asserts flag *presence* only (`test_sync_notes.sh:499`), so extending the trigger pattern needs no test edit — Task 9 Step 3 reads the test to confirm. The fifth-static-specialist enumerations were already extended in slice 1 (`test_sync_notes.sh:519`, `:601`, `:612`, `:796`), so NuGet (a new *source class*, not a new specialist) touches none of them.
- **Live-registry divergence is the one genuine execution risk (Task 13):** the deprecated-current health finding depends on a live deprecation that the harness cannot stub. Task 13's pre-flight forces a verify-or-rescope decision and forbids laundering a fixture/live divergence into a false INCONCLUSIVE. The unittest `NuGetEndToEndTest` independently guarantees engine determinism under fixtures.
- **No `setup:` block** (Task 12): the engine ships in the plugin `bin/` (on PATH), like trivy/jb/slice-1 — no per-trial provisioning, no install race.
