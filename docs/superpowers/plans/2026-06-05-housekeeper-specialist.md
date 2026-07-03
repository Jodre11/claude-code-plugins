# Housekeeper Specialist (vertical slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working, dispatchable `housekeeper-reviewer` static specialist that flags stale-vs-latest-GA dependencies for three deterministic source classes (GitHub Actions `uses: org/action@vN`, workflow `runs-on:` runners, and npm `package.json`), backed by a net-new Python freshness engine, wired fully into the review pipeline, with security-reviewer's dead `#7` freshness path retired and the complete A/B apparatus in place.

**Architecture:** A single Python engine (`bin/housekeeper-freshness`) does all deterministic work: parse in-scope sources → extract current versions → fetch latest-GA from registries (or recorded fixtures) → GA-filter + semver-compare → emit a hash-stable JSON tuple set. The `housekeeper-reviewer` agent is a thin wrapper that runs the engine and renders its tuples as canonical §7 findings (uniform `Suggestion`, `Confidence: 100`), exactly like trivy/ruff render their tool output. The engine's pure core (version compare, GA filter, parsers, scope resolver) is unit-tested with stdlib `unittest` against recorded fixtures — no network — so it is deterministic and A/B-hash-stable. Live runs hit real registries; tests and the A/B sweep inject recorded registry JSON via `HOUSEKEEPER_REGISTRY_FIXTURES`.

**Tech Stack:** Python 3 (stdlib only — `urllib`, `json`, `re`, `argparse`; no PyYAML, no pip deps), bash test harness (`tests/`, `tests/ab/`), `python3 -m unittest`, jq/awk/yq, Claude Code per-agent stream-json capture.

---

## Scope of THIS plan (vertical slice 1)

In scope: engine chassis + version/GA core + **3 source classes** (GitHub Actions `@vN`, workflow runners, npm) + scope resolver + agent + full pipeline wiring + security `#7` retirement + synthesiser edits + sync-test extension + complete A/B apparatus + gated sweep.

Deferred to **follow-on plans** (each adds a parser + fixtures + a cookbook row to the same chassis — independently testable): NuGet, PyPI, crates.io, Go modules, RubyGems, Docker base-image tags, framework/SDK/runtime versions (`<TargetFramework>`, `global.json`, Node `engines`, `requires-python`, Go directive). Out of scope entirely (own accuracy designs): Tier-2 free-text `RUN`/`pip install` pins; free-alternative-package suggestions; live SHA→tag commit lookup (this slice trusts the `# vX.Y.Z` comment).

## Settled decisions (do not re-litigate — confirmed with the user 2026-06-05)

- **Engine form:** Python in `bin/` (deterministic, correct semver/JSON handling, minimal agent tokens). Adds `python3` as a plugin prerequisite.
- **Plan size:** vertical slice first (this plan), follow-on plans per remaining ecosystem.
- **SHA-pinned Actions:** trust the trailing `# vX.Y.Z` comment; if absent/unparseable, emit **no finding** (honours the no-untrustworthy-finding rule). No live commit lookup in this slice.
- **Model tier:** ship `model: haiku` + `effort: low` directly (against suite discipline — user's call), build the A/B harness anyway, sweep post-build, sonnet is the fallback if equivalence fails.

## File Structure

- `plugins/code-review-suite/bin/housekeeper-freshness` — CREATE (executable Python engine; the whole deterministic core lives here, written as one importable file so tests load it by path).
- `plugins/code-review-suite/agents/housekeeper-reviewer.md` — CREATE (thin agent: run engine, render §7).
- `plugins/code-review-suite/agents/security-reviewer.md` — MODIFY (retire `#7`: lines 90-104; FP-rule `#9`: 136-139; keep `#6a`/`#6b`).
- `plugins/code-review-suite/agents/review-synthesiser.md` — MODIFY (add `[housekeeper]` source tag line 221; add to carve-out anchor line 89 + line 125).
- `plugins/code-review-suite/includes/static-analysis-context.md` — MODIFY (§10 add `[housekeeper]` to the severity-lock enumeration).
- `plugins/code-review-suite/includes/review-pipeline.md` — MODIFY (detection flag 2.6; dispatch block after trivy ~921; `$SPECIALIST_COUNT` 933; verify 940; cross-review 1037).
- `plugins/code-review-suite/includes/version-freshness-cookbook.md` — MODIFY (add the runner latest-label table + Actions latest-major note).
- `plugins/code-review-suite/commands/pre-review.md` — MODIFY (detection 693; dispatch after trivy ~921; count; verify).
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — MODIFY (detection 798; dispatch after trivy ~1022; count; verify).
- `plugins/code-review-suite/README.md` — MODIFY (specialist table + prerequisites).
- `tests/python/test_housekeeper_engine.py` — CREATE (unittest core tests).
- `tests/lib/test_housekeeper_engine.sh` — CREATE (bash wrapper running unittest; auto-discovered by `run.sh`).
- `tests/lib/test_sync_notes.sh` — MODIFY (extend the static-specialist enumerations to include housekeeper).
- `tests/ab/lib/agent_capture.sh` — MODIFY (add `housekeeper|housekeeper-reviewer` parser-param case).
- `tests/ab/fixtures/housekeeper-stdout-three-findings.log` — CREATE (parser test input).
- `tests/lib/test_ab_per_agent_lib.sh` — MODIFY (housekeeper parser + config-parse tests).
- `tests/ab/configs/per-agent/housekeeper-baseline.yaml` — CREATE (sonnet/default).
- `tests/ab/configs/per-agent/housekeeper-haiku-low.yaml` — CREATE (haiku/low).
- `tests/fixtures/static-analysis/housekeeper/.github/workflows/ci.yml` — CREATE (fixture: stale Action + stale runner).
- `tests/fixtures/static-analysis/housekeeper/package.json` — CREATE (fixture: stale npm dep).
- `tests/fixtures/static-analysis/housekeeper/registry/` — CREATE (recorded registry JSON: npm doc + actions release).
- `tests/ab/corpus/housekeeper-smoke-stale-deps/{source.yaml,diff/changed-lines.txt,expected/}` — CREATE.
- `tests/ab/corpus/index.yaml` — MODIFY (register the fixture).
- `docs/superpowers/notes/2026-06-05-housekeeper-haiku-low-result.md` — CREATE (Task 14).

## Engine contract (referenced by multiple tasks — read once)

Invocation (the agent runs exactly this):
```
housekeeper-freshness --root <repo-root> --changed-files-from <path> --changed-lines-from <path>
```
- `--changed-files-from`: a file with one changed path per line (the agent writes `git diff --name-only` here).
- `--changed-lines-from`: the `Changed lines:` block text (the agent writes its prompt block here); used for T3 target modulation only.
- `--registry-fixtures <dir>` (or env `HOUSEKEEPER_REGISTRY_FIXTURES`): when set, read registry responses from `<dir>/<source>/<slug>.json` instead of HTTP. Tests + A/B set this; live runs omit it.

Stdout: a JSON array of tuples, one per **stale** item (non-stale items are dropped by the engine):
```json
{"source":"github-actions","item":"actions/checkout","current":"v3","latest_ga":"v4",
 "target":"v4","file":".github/workflows/ci.yml","line":12,
 "licence_current":null,"licence_latest":null}
```
- `source` ∈ `github-actions` | `runner` | `npm` (this slice).
- `target`: per T3 — if `line` ∈ changed-lines for `file` → `latest_ga` (full bump); else → nearest in-major minor/patch (npm) or `latest_ga` (Actions/runners, which float by major).
- Engine never emits non-stale tuples and never emits a tuple without a trustworthy `latest_ga` (a fetch miss / unparsable current → silently skipped).

Exit codes: `0` always on a completed run (even with findings). Non-zero only on engine crash. A missing `python3` is the agent's concern (skip-state), not the engine's.

---

### Task 1: Plugin scaffolding + engine chassis + unittest wiring

**Files:**
- Create: `plugins/code-review-suite/bin/housekeeper-freshness`
- Create: `tests/python/test_housekeeper_engine.py`
- Create: `tests/lib/test_housekeeper_engine.sh`

- [ ] **Step 1: Write the failing chassis test**

Create `tests/python/test_housekeeper_engine.py`:
```python
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
ENGINE = REPO / "plugins/code-review-suite/bin/housekeeper-freshness"


def load_engine():
    spec = importlib.util.spec_from_file_location("housekeeper_freshness", ENGINE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ChassisTest(unittest.TestCase):
    def test_empty_inputs_emit_empty_array(self):
        with tempfile.TemporaryDirectory() as d:
            files = pathlib.Path(d) / "files.txt"
            lines = pathlib.Path(d) / "lines.txt"
            files.write_text("")
            lines.write_text("Changed lines:\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE),
                 "--root", d,
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines)],
                capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(out.stdout), [])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `ENGINE` file does not exist (`exec_module` / subprocess raises).

- [ ] **Step 3: Write the engine chassis**

Create `plugins/code-review-suite/bin/housekeeper-freshness` (the deterministic core is built up across Tasks 1-5; this step lays the importable skeleton + CLI + fetch abstraction + changed-lines parser, and emits `[]`):
```python
#!/usr/bin/env python3
"""housekeeper-freshness — deterministic dependency/version freshness engine.

Emits a JSON array of stale-version tuples for the code-review-suite
housekeeper specialist. Pure-stdlib. Source classes in this slice:
github-actions, runner, npm. See agents/housekeeper-reviewer.md.
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request


# --- changed-lines parsing (for T3 target modulation) ----------------------

def parse_changed_lines(text):
    """Parse a 'Changed lines:' block into {path: set(int)}.

    Lines look like '  path/to/file: 1,2,5-7'. Range tokens expand. A
    '(empty — rename only)' marker yields an empty set. Robust to the
    trailing blank-line separator the pipeline appends.
    """
    result = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line == "Changed lines:" or line.endswith(":"):
            continue
        if ":" not in line:
            continue
        path, _, spec = line.partition(":")
        path = path.strip()
        spec = spec.strip()
        nums = set()
        if "empty" not in spec.lower():
            for tok in spec.split(","):
                tok = tok.strip()
                if "-" in tok:
                    a, _, b = tok.partition("-")
                    if a.isdigit() and b.isdigit():
                        nums.update(range(int(a), int(b) + 1))
                elif tok.isdigit():
                    nums.add(int(tok))
        result[path] = nums
    return result


# --- registry fetch abstraction --------------------------------------------

class Registry:
    """Fetches registry JSON, with an optional recorded-fixture override.

    When fixtures_dir is set, reads <fixtures_dir>/<source>/<slug>.json
    instead of the network. <slug> is the item name with '/' -> '__'.
    Returns the parsed JSON dict, or None on any miss/error (the caller
    then emits no finding — honouring the no-untrustworthy-answer rule).
    """

    def __init__(self, fixtures_dir=None):
        self.fixtures_dir = fixtures_dir

    def _slug(self, item):
        return item.replace("/", "__")

    def fetch(self, source, item, url):
        if self.fixtures_dir:
            path = os.path.join(self.fixtures_dir, source, self._slug(item) + ".json")
            try:
                with open(path, encoding="utf-8") as fh:
                    return json.load(fh)
            except (OSError, ValueError):
                return None
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "code-review-suite-housekeeper",
                "Accept": "application/json",
                "Cache-Control": "no-cache",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.load(resp)
        except (urllib.error.URLError, ValueError, TimeoutError, OSError):
            return None


# --- source collectors (filled in Tasks 3-5) -------------------------------

def collect_findings(root, changed_files, changed_lines, registry):
    """Return a list of stale-version tuples across all source classes.

    Each collector is added in a later task. The chassis returns [].
    """
    findings = []
    # findings += collect_github_actions(...)   # Task 3
    # findings += collect_runners(...)           # Task 4
    # findings += collect_npm(...)               # Task 5
    return findings


# --- CLI --------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(prog="housekeeper-freshness")
    parser.add_argument("--root", required=True)
    parser.add_argument("--changed-files-from", required=True)
    parser.add_argument("--changed-lines-from", required=True)
    parser.add_argument("--registry-fixtures",
                        default=os.environ.get("HOUSEKEEPER_REGISTRY_FIXTURES"))
    args = parser.parse_args(argv)

    with open(args.changed_files_from, encoding="utf-8") as fh:
        changed_files = [ln.strip() for ln in fh if ln.strip()]
    with open(args.changed_lines_from, encoding="utf-8") as fh:
        changed_lines = parse_changed_lines(fh.read())

    registry = Registry(args.registry_fixtures)
    findings = collect_findings(args.root, changed_files, changed_lines, registry)
    json.dump(findings, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Make the engine executable**

Run: `chmod +x plugins/code-review-suite/bin/housekeeper-freshness`

- [ ] **Step 5: Run the chassis test to verify it passes**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: PASS (`test_empty_inputs_emit_empty_array`).

- [ ] **Step 6: Wire unittest into the bash suite**

Create `tests/lib/test_housekeeper_engine.sh`:
```bash
#!/usr/bin/env bash
# tests/lib/test_housekeeper_engine.sh — runs the Python engine unittest
# suite as one gate inside the bash harness (run.sh auto-discovers this).

test_housekeeper_engine_unittest() {
    local repo="$REPO_ROOT"
    local suite="$repo/tests/python"

    if [[ ! -d "$suite" ]]; then
        skip "housekeeper engine unittest" "tests/python not present"
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip "housekeeper engine unittest" "python3 not on PATH"
        return
    fi

    local output
    if output=$(cd "$repo" && python3 -m unittest discover -s tests/python 2>&1); then
        pass "housekeeper engine unittest: all engine unit tests pass"
    else
        fail "housekeeper engine unittest: all engine unit tests pass" "$output"
    fi
}
```
Confirm `$REPO_ROOT` is the harness variable used elsewhere — grep `tests/lib/harness.sh` for `REPO_ROOT`; if the harness exports a different name (e.g. `$CR_ROOT`), use that instead.

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run.sh`
Expected: all pass except the known `A/B run.sh: bad-config rejection leaves working tree clean` dirty-tree artifact. The new `housekeeper engine unittest` test PASSES. Note the new total.

- [ ] **Step 8: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py tests/lib/test_housekeeper_engine.sh
git commit -m "feat(housekeeper): engine chassis + CLI + unittest wiring"
git push origin main
```

---

### Task 2: Version comparison + GA filter core (pure functions)

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness`
- Modify: `tests/python/test_housekeeper_engine.py`

- [ ] **Step 1: Write the failing core tests**

In `tests/python/test_housekeeper_engine.py`, add a new test class (after `ChassisTest`):
```python
class VersionCoreTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_parse_version_strips_v_prefix(self):
        self.assertEqual(self.m.parse_version("v4.2.1"), (4, 2, 1))
        self.assertEqual(self.m.parse_version("4.2.1"), (4, 2, 1))
        self.assertEqual(self.m.parse_version("v4"), (4, 0, 0))
        self.assertEqual(self.m.parse_version("4.2"), (4, 2, 0))

    def test_parse_version_drops_prerelease_and_build(self):
        self.assertEqual(self.m.parse_version("1.2.3-rc.1"), (1, 2, 3))
        self.assertEqual(self.m.parse_version("1.2.3+build.5"), (1, 2, 3))

    def test_parse_version_invalid_returns_none(self):
        self.assertIsNone(self.m.parse_version("latest"))
        self.assertIsNone(self.m.parse_version(""))

    def test_compare_versions_orders_numerically_not_lexically(self):
        # 1.10.0 > 1.9.0 is the classic lexical trap.
        self.assertEqual(self.m.compare_versions("1.10.0", "1.9.0"), 1)
        self.assertEqual(self.m.compare_versions("1.9.0", "1.10.0"), -1)
        self.assertEqual(self.m.compare_versions("4.2.1", "4.2.1"), 0)

    def test_is_ga_rejects_prerelease(self):
        self.assertTrue(self.m.is_ga("1.2.3"))
        self.assertTrue(self.m.is_ga("v4"))
        self.assertFalse(self.m.is_ga("1.2.3-rc.1"))
        self.assertFalse(self.m.is_ga("2.0.0-beta"))
        self.assertFalse(self.m.is_ga("1.0.0-0"))

    def test_latest_ga_picks_highest_non_prerelease(self):
        versions = ["1.0.0", "1.2.0", "2.0.0-rc.1", "1.9.0", "1.10.0"]
        self.assertEqual(self.m.latest_ga(versions), "1.10.0")

    def test_nearest_in_major_within_current_major(self):
        versions = ["17.0.0", "18.1.0", "18.2.0", "18.3.1", "19.0.0"]
        self.assertEqual(self.m.nearest_in_major("18.0.0", versions), "18.3.1")
        # No higher in-major version -> returns the current.
        self.assertEqual(self.m.nearest_in_major("19.0.0", versions), "19.0.0")

    def test_strip_constraint_extracts_pinned_version(self):
        self.assertEqual(self.m.strip_constraint("^18.2.0"), "18.2.0")
        self.assertEqual(self.m.strip_constraint("~1.4.3"), "1.4.3")
        self.assertEqual(self.m.strip_constraint(">=2.0.0"), "2.0.0")
        self.assertEqual(self.m.strip_constraint("18.2.0"), "18.2.0")
        self.assertIsNone(self.m.strip_constraint("*"))
        self.assertIsNone(self.m.strip_constraint("latest"))
        self.assertIsNone(self.m.strip_constraint("github:foo/bar"))
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `parse_version` etc. do not exist (`AttributeError`).

- [ ] **Step 3: Implement the version core**

In `housekeeper-freshness`, add these functions ABOVE `collect_findings`:
```python
# --- version core ----------------------------------------------------------

_VERSION_RE = re.compile(r"^[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?")


def parse_version(s):
    """Return (major, minor, patch) ints, or None if unparsable.

    Drops a leading v, a -prerelease suffix, and +build metadata. Missing
    minor/patch default to 0 (so 'v4' == (4, 0, 0))."""
    if not s:
        return None
    m = _VERSION_RE.match(s.strip())
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2) or 0), int(m.group(3) or 0))


def is_ga(s):
    """True if s is a general-availability version (no -prerelease marker)."""
    if not s:
        return False
    core = s.strip()
    if core[:1] in ("v", "V"):
        core = core[1:]
    # A hyphen after the numeric core marks a prerelease (1.2.3-rc.1, 2.0.0-beta).
    return parse_version(s) is not None and "-" not in core


def compare_versions(a, b):
    """-1 if a<b, 0 if equal, 1 if a>b (by parsed numeric tuple)."""
    pa, pb = parse_version(a), parse_version(b)
    if pa is None or pb is None:
        return 0
    return (pa > pb) - (pa < pb)


def latest_ga(versions):
    """Highest GA version in the list, or None if none are GA."""
    ga = [v for v in versions if is_ga(v)]
    if not ga:
        return None
    return max(ga, key=parse_version)


def nearest_in_major(current, versions):
    """Highest GA version sharing current's major; falls back to current."""
    cur = parse_version(current)
    if cur is None:
        return current
    same_major = [v for v in versions if is_ga(v) and parse_version(v)[0] == cur[0]]
    if not same_major:
        return current
    best = max(same_major, key=parse_version)
    return best if compare_versions(best, current) > 0 else current


def strip_constraint(spec):
    """Extract a concrete version from an npm version range, or None.

    Handles ^x.y.z, ~x.y.z, >=x.y.z, plain x.y.z. Returns None for
    wildcards, tags, and non-registry specs (git:, file:, workspace:)."""
    if not spec:
        return None
    spec = spec.strip()
    if any(spec.startswith(p) for p in ("github:", "git+", "git:", "file:", "workspace:", "link:", "npm:")):
        return None
    if spec in ("*", "latest", "next", "") or spec.startswith("http"):
        return None
    m = re.search(r"(\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z.\-]+)?)", spec)
    return m.group(1) if m else None
```

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `VersionCoreTest` pass.

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): version parse, GA filter, semver compare core"
git push origin main
```

---

### Task 3: GitHub Actions source collector

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness`
- Modify: `tests/python/test_housekeeper_engine.py`

GitHub Actions are **always in scope** (shared CI), regardless of solution membership. A `uses: org/action@vN` pinned to major `vN` is stale when the latest GA release's major exceeds `N`. SHA-pins read their version from the trailing `# vX.Y.Z` comment; no comment → no finding.

- [ ] **Step 1: Write the failing collector tests**

Add to `tests/python/test_housekeeper_engine.py`:
```python
class GitHubActionsTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_find_action_uses_extracts_tag_pins(self):
        text = (
            "jobs:\n"
            "  build:\n"
            "    steps:\n"
            "      - uses: actions/checkout@v3\n"
            "      - uses: actions/setup-node@v4.0.1\n"
        )
        uses = self.m.find_action_uses(text)
        self.assertIn(("actions/checkout", "v3", 4), uses)
        self.assertIn(("actions/setup-node", "v4.0.1", 5), uses)

    def test_find_action_uses_reads_sha_pin_version_comment(self):
        text = "      - uses: actions/checkout@abc123def  # v3.6.0\n"
        uses = self.m.find_action_uses(text)
        self.assertEqual(uses, [("actions/checkout", "v3.6.0", 1)])

    def test_find_action_uses_skips_sha_pin_without_comment(self):
        text = "      - uses: actions/checkout@abc123def456\n"
        # No trustworthy current version -> not collected.
        self.assertEqual(self.m.find_action_uses(text), [])

    def test_find_action_uses_skips_local_and_docker(self):
        text = (
            "      - uses: ./.github/actions/local\n"
            "      - uses: docker://alpine:3.18\n"
        )
        self.assertEqual(self.m.find_action_uses(text), [])

    def test_actions_finding_flags_stale_major(self):
        # checkout@v3, latest release tag_name v4.2.1 -> stale, target v4.
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: {"tag_name": "v4.2.1"}
        findings = self.m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: actions/checkout@v3\n"},
            {".github/workflows/ci.yml": {1}},
            reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["source"], "github-actions")
        self.assertEqual(f["item"], "actions/checkout")
        self.assertEqual(f["current"], "v3")
        self.assertEqual(f["latest_ga"], "v4.2.1")
        self.assertEqual(f["target"], "v4")

    def test_actions_finding_silent_when_current(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: {"tag_name": "v3.6.0"}
        findings = self.m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: actions/checkout@v3\n"},
            {".github/workflows/ci.yml": {1}},
            reg)
        self.assertEqual(findings, [])

    def test_actions_finding_silent_on_fetch_miss(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: None
        findings = self.m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: actions/checkout@v3\n"},
            {".github/workflows/ci.yml": {1}},
            reg)
        self.assertEqual(findings, [])
```
Note the tests pass a `file_text` map as the 2nd arg so the collector reads content without touching disk; the CLI builds that map from `root + path`.

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `find_action_uses` / `collect_github_actions` absent.

- [ ] **Step 3: Implement the Actions collector**

In `housekeeper-freshness`, add ABOVE `collect_findings`:
```python
# --- source: github-actions -------------------------------------------------

_USES_RE = re.compile(
    r"^\s*-?\s*uses:\s*([A-Za-z0-9._-]+/[A-Za-z0-9._/-]+)@(\S+)(?:\s*#\s*(v?\d[\w.\-]*))?\s*$"
)


def find_action_uses(text):
    """Return [(action, version, line_no)] for tag-pinned or
    sha+comment-pinned actions. Skips local (./), docker://, and
    bare-SHA pins without a version comment."""
    out = []
    for i, raw in enumerate(text.splitlines(), start=1):
        m = _USES_RE.match(raw)
        if not m:
            continue
        action, ref, comment = m.group(1), m.group(2), m.group(3)
        if action.startswith(".") or action.startswith("docker:"):
            continue
        # A tag-like ref (starts with v or a digit) is the current version;
        # otherwise it is a SHA pin and the version comes from the comment.
        if re.match(r"^v?\d", ref):
            current = ref
        elif comment:
            current = comment
        else:
            continue  # bare SHA, no trustworthy version -> skip
        out.append((action, current, i))
    return out


def collect_github_actions(changed_files, file_text, changed_lines, registry):
    findings = []
    for path in changed_files:
        if not (path.startswith(".github/workflows/")
                and path.endswith((".yml", ".yaml"))):
            continue
        text = file_text.get(path)
        if text is None:
            continue
        for action, current, line in find_action_uses(text):
            data = registry.fetch(
                "github-actions", action,
                "https://api.github.com/repos/%s/releases/latest" % action)
            if not data:
                continue
            latest = data.get("tag_name")
            if not latest or not is_ga(latest):
                continue
            if compare_versions(latest, current) <= 0:
                continue
            # Actions float by major: target is the latest major tag (vN).
            target = "v%d" % parse_version(latest)[0]
            findings.append({
                "source": "github-actions", "item": action,
                "current": current, "latest_ga": latest, "target": target,
                "file": path, "line": line,
                "licence_current": None, "licence_latest": None,
            })
    return findings
```

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `GitHubActionsTest` pass.

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): github-actions stale-major collector"
git push origin main
```

---

### Task 4: Workflow runner collector

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness`
- Modify: `tests/python/test_housekeeper_engine.py`

Runner labels (`runs-on: ubuntu-22.04`) have no live registry — "latest supported" is a curated constant maintained in the engine and documented in the cookbook. Only known families are flagged; unknown labels (self-hosted, custom) → no finding.

- [ ] **Step 1: Write the failing tests**

Add to `tests/python/test_housekeeper_engine.py`:
```python
class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_find_runner_labels(self):
        text = (
            "jobs:\n"
            "  a:\n"
            "    runs-on: ubuntu-22.04\n"
            "  b:\n"
            "    runs-on: windows-2022\n"
        )
        labels = self.m.find_runner_labels(text)
        self.assertIn(("ubuntu", "22.04", 3), labels)
        self.assertIn(("windows", "2022", 5), labels)

    def test_runner_flags_stale_known_family(self):
        findings = self.m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "    runs-on: ubuntu-22.04\n"},
            {".github/workflows/ci.yml": {1}})
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["source"], "runner")
        self.assertEqual(f["item"], "ubuntu")
        self.assertEqual(f["current"], "ubuntu-22.04")
        self.assertEqual(f["latest_ga"], "ubuntu-24.04")

    def test_runner_silent_when_latest(self):
        findings = self.m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "    runs-on: ubuntu-24.04\n"},
            {".github/workflows/ci.yml": {1}})
        self.assertEqual(findings, [])

    def test_runner_skips_unknown_and_latest_labels(self):
        text = (
            "    runs-on: ubuntu-latest\n"
            "    runs-on: self-hosted\n"
            "    runs-on: my-custom-runner\n"
        )
        findings = self.m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": text},
            {".github/workflows/ci.yml": {1, 2, 3}})
        self.assertEqual(findings, [])
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `find_runner_labels` / `collect_runners` absent.

- [ ] **Step 3: Implement the runner collector**

In `housekeeper-freshness`, add ABOVE `collect_findings`:
```python
# --- source: runner ---------------------------------------------------------

# Curated latest GitHub-hosted runner labels. MANUALLY MAINTAINED — there is
# no live registry for runner images. Keep in sync with the cookbook table.
# Reviewed 2026-06-05.
LATEST_RUNNERS = {
    "ubuntu": "24.04",
    "windows": "2025",
    "macos": "15",
}

_RUNS_ON_RE = re.compile(r"^\s*runs-on:\s*\[?\s*([A-Za-z0-9._-]+)\s*\]?\s*$")


def find_runner_labels(text):
    """Return [(family, version, line_no)] for known-family runner labels
    like ubuntu-22.04. '-latest' and unknown families are skipped here only
    if they fail the family-version split; collect_runners does the final
    known-family gate."""
    out = []
    for i, raw in enumerate(text.splitlines(), start=1):
        m = _RUNS_ON_RE.match(raw)
        if not m:
            continue
        label = m.group(1)
        if "-" not in label:
            continue
        family, _, version = label.partition("-")
        out.append((family, version, i))
    return out


def collect_runners(changed_files, file_text, changed_lines):
    findings = []
    for path in changed_files:
        if not (path.startswith(".github/workflows/")
                and path.endswith((".yml", ".yaml"))):
            continue
        text = file_text.get(path)
        if text is None:
            continue
        for family, version, line in find_runner_labels(text):
            latest = LATEST_RUNNERS.get(family)
            if latest is None:
                continue  # unknown family / -latest -> no trustworthy answer
            if compare_versions(version, latest) >= 0:
                continue
            findings.append({
                "source": "runner", "item": family,
                "current": "%s-%s" % (family, version),
                "latest_ga": "%s-%s" % (family, latest),
                "target": "%s-%s" % (family, latest),
                "file": path, "line": line,
                "licence_current": None, "licence_latest": None,
            })
    return findings
```
Note: `ubuntu-latest` splits to family `ubuntu`, version `latest`; `compare_versions("latest", "24.04")` parses `latest`→None→returns 0, so the `>= 0` guard drops it. `self-hosted` → family `self`, not in `LATEST_RUNNERS` → dropped. Both correct.

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `RunnerTest` pass.

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): workflow runner staleness collector"
git push origin main
```

---

### Task 5: npm collector + scope resolver + licence diff + T3 + CLI wire-up

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness`
- Modify: `tests/python/test_housekeeper_engine.py`

npm is the first **solution-gated** source: a changed file pulls in its containing npm package root (the nearest ancestor dir with a `package.json`); ALL deps in an in-scope `package.json` are candidates (T2), with the target modulated by whether the dep's line is in changed-lines (T3). The npm registry root doc supplies `dist-tags.latest`, the full `versions` map, and per-version `license` (licence-diff).

- [ ] **Step 1: Write the failing tests**

Add to `tests/python/test_housekeeper_engine.py`:
```python
NPM_DOC = {
    "dist-tags": {"latest": "19.0.0"},
    "versions": {
        "18.0.0": {"license": "MIT"},
        "18.2.0": {"license": "MIT"},
        "18.3.1": {"license": "MIT"},
        "19.0.0": {"license": "MIT"},
    },
}


class NpmTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_parse_package_json_deps_with_lines(self):
        text = (
            '{\n'
            '  "dependencies": {\n'
            '    "react": "^18.2.0",\n'
            '    "left-pad": "1.3.0"\n'
            '  }\n'
            '}\n'
        )
        deps = self.m.parse_package_json(text)
        self.assertEqual(deps["react"], ("^18.2.0", 3))
        self.assertEqual(deps["left-pad"], ("1.3.0", 4))

    def test_npm_root_finds_nearest_package_json(self):
        files = ["web/app/src/index.ts", "api/server.py"]
        roots = self.m.npm_scope_roots(files, {"web/app/package.json", "api/package.json"})
        # The .ts pulls in web/app (nearest ancestor with a package.json).
        self.assertEqual(roots, {"web/app/package.json"})

    def test_npm_finding_touched_line_targets_latest_ga(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NPM_DOC
        text = '{\n  "dependencies": {\n    "react": "^18.2.0"\n  }\n}\n'
        findings = self.m.collect_npm(
            {"package.json": text},
            {"package.json": {3}},  # react's line IS changed -> full bump
            reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["source"], "npm")
        self.assertEqual(f["item"], "react")
        self.assertEqual(f["current"], "18.2.0")
        self.assertEqual(f["latest_ga"], "19.0.0")
        self.assertEqual(f["target"], "19.0.0")
        self.assertEqual(f["line"], 3)

    def test_npm_finding_untouched_line_targets_nearest_in_major(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NPM_DOC
        text = '{\n  "dependencies": {\n    "react": "^18.2.0"\n  }\n}\n'
        findings = self.m.collect_npm(
            {"package.json": text},
            {"package.json": set()},  # in-scope solution but line not touched
            reg)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["target"], "18.3.1")  # nearest in major 18

    def test_npm_licence_change_recorded(self):
        doc = {
            "dist-tags": {"latest": "2.0.0"},
            "versions": {"1.0.0": {"license": "MIT"}, "2.0.0": {"license": "BSL-1.1"}},
        }
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: doc
        text = '{\n  "dependencies": {\n    "foo": "1.0.0"\n  }\n}\n'
        findings = self.m.collect_npm({"package.json": text}, {"package.json": {3}}, reg)
        self.assertEqual(findings[0]["licence_current"], "MIT")
        self.assertEqual(findings[0]["licence_latest"], "BSL-1.1")

    def test_npm_silent_on_fetch_miss_and_non_registry_specs(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: None
        text = '{\n  "dependencies": {\n    "react": "^18.2.0",\n    "x": "github:a/b"\n  }\n}\n'
        self.assertEqual(self.m.collect_npm({"package.json": text}, {"package.json": {3, 4}}, reg), [])


class EndToEndTest(unittest.TestCase):
    def test_cli_against_recorded_fixtures(self):
        # The engine emits stable tuples when pointed at recorded fixtures.
        repo = REPO  # the real fixture lives under tests/fixtures (Task 13)
        fixtures = repo / "tests/fixtures/static-analysis/housekeeper"
        if not fixtures.exists():
            self.skipTest("Task 13 fixture not yet created")
        with tempfile.TemporaryDirectory() as d:
            files = pathlib.Path(d) / "files.txt"
            lines = pathlib.Path(d) / "lines.txt"
            files.write_text(".github/workflows/ci.yml\npackage.json\n")
            lines.write_text("Changed lines:\n  .github/workflows/ci.yml: 12,15\n  package.json: 4\n")
            env = dict(os.environ,
                       HOUSEKEEPER_REGISTRY_FIXTURES=str(fixtures / "registry"))
            out = subprocess.run(
                [sys.executable, str(ENGINE), "--root", str(fixtures),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines)],
                capture_output=True, text=True, check=True, env=env)
            tuples = json.loads(out.stdout)
            sources = sorted(t["source"] for t in tuples)
            self.assertEqual(sources, ["github-actions", "npm", "runner"])
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: FAIL — `parse_package_json` / `npm_scope_roots` / `collect_npm` absent; `EndToEndTest` skips (fixture not yet built).

- [ ] **Step 3: Implement the npm collector + scope + CLI wire-up**

In `housekeeper-freshness`, add ABOVE `collect_findings`:
```python
# --- source: npm ------------------------------------------------------------

_DEP_LINE_RE = re.compile(r'^\s*"([^"]+)"\s*:\s*"([^"]+)"\s*,?\s*$')
_DEP_SECTIONS = ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies")


def parse_package_json(text):
    """Return {name: (spec, line_no)} across all dependency sections.

    Line-based so we can attribute a 1-based source line to each dep (the
    JSON parser loses line numbers). Tracks which dep-section we are inside
    via a brace-aware scan of the section headers."""
    deps = {}
    in_section = False
    for i, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.strip()
        if any(('"%s"' % s) in stripped and stripped.endswith("{") for s in _DEP_SECTIONS):
            in_section = True
            continue
        if in_section and stripped.startswith("}"):
            in_section = False
            continue
        if in_section:
            m = _DEP_LINE_RE.match(raw)
            if m:
                deps[m.group(1)] = (m.group(2), i)
    return deps


def npm_scope_roots(changed_files, all_package_jsons):
    """Map each changed file to the nearest ancestor package.json, returning
    the set of in-scope package.json paths (the T1 solution gate)."""
    roots = set()
    for f in changed_files:
        parts = f.split("/")
        for n in range(len(parts), 0, -1):
            cand = "/".join(parts[:n - 1] + ["package.json"]) if n > 1 else "package.json"
            if cand in all_package_jsons:
                roots.add(cand)
                break
    return roots


def collect_npm(file_text, changed_lines, registry):
    """file_text maps each in-scope package.json path -> its content."""
    findings = []
    for path, text in file_text.items():
        if not path.endswith("package.json"):
            continue
        deps = parse_package_json(text)
        touched = changed_lines.get(path, set())
        for name, (spec, line) in deps.items():
            current = strip_constraint(spec)
            if current is None:
                continue
            doc = registry.fetch("npm", name, "https://registry.npmjs.org/%s" % name)
            if not doc:
                continue
            versions = list((doc.get("versions") or {}).keys())
            latest = (doc.get("dist-tags") or {}).get("latest")
            if not latest or not is_ga(latest):
                latest = latest_ga(versions)
            if not latest or compare_versions(latest, current) <= 0:
                continue
            # T3: touched manifest line -> full bump; else nearest in-major.
            if line in touched:
                target = latest
            else:
                target = nearest_in_major(current, versions)
                if compare_versions(target, current) <= 0:
                    continue  # nothing newer within the current major
            vmap = doc.get("versions") or {}
            lic_cur = (vmap.get(current) or {}).get("license")
            lic_new = (vmap.get(latest) or {}).get("license")
            findings.append({
                "source": "npm", "item": name,
                "current": current, "latest_ga": latest, "target": target,
                "file": path, "line": line,
                "licence_current": lic_cur, "licence_latest": lic_new,
            })
    return findings
```
Then REPLACE the placeholder `collect_findings` body with the real wiring:
```python
def collect_findings(root, changed_files, changed_lines, registry):
    def read(path):
        try:
            with open(os.path.join(root, path), encoding="utf-8") as fh:
                return fh.read()
        except OSError:
            return None

    workflow_text = {
        p: read(p) for p in changed_files
        if p.startswith(".github/workflows/") and p.endswith((".yml", ".yaml"))
    }
    workflow_text = {p: t for p, t in workflow_text.items() if t is not None}

    # npm solution gate: discover every package.json in the tree, then map
    # changed files to their nearest ancestor manifest.
    all_pkgs = set()
    for dirpath, _dirs, names in os.walk(root):
        if "node_modules" in dirpath.split(os.sep):
            continue
        if "package.json" in names:
            rel = os.path.relpath(os.path.join(dirpath, "package.json"), root)
            all_pkgs.add(rel.replace(os.sep, "/"))
    npm_roots = npm_scope_roots(changed_files, all_pkgs)
    npm_text = {p: read(p) for p in npm_roots}
    npm_text = {p: t for p, t in npm_text.items() if t is not None}

    findings = []
    findings += collect_github_actions(changed_files, workflow_text, changed_lines, registry)
    findings += collect_runners(changed_files, workflow_text, changed_lines)
    findings += collect_npm(npm_text, changed_lines, registry)
    # Deterministic ordering for hash stability.
    findings.sort(key=lambda f: (f["file"], f["line"], f["source"], f["item"]))
    return findings
```

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: all `NpmTest` pass; `EndToEndTest` still skips (fixture built in Task 13).

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): npm collector, solution-gate scope resolver, licence diff, T3 targets"
git push origin main
```

---

### Task 6: Agent definition `housekeeper-reviewer.md`

**Files:**
- Create: `plugins/code-review-suite/agents/housekeeper-reviewer.md`

The agent is a thin wrapper: resolve base context, write the changed-files + changed-lines to temp files, run the engine, render each tuple as a canonical §7 finding. Uniform `Suggestion`, `Confidence: 100`. Heading `## Housekeeper Findings`. Rule field `housekeeper/<source>` (tokenises cleanly — slash is internal).

- [ ] **Step 1: Write the agent file**

Create `plugins/code-review-suite/agents/housekeeper-reviewer.md`:
```markdown
---
name: housekeeper-reviewer
description: Flags dependencies, GitHub Actions, and workflow runners that are behind their latest GA release, via a deterministic registry-backed freshness engine. Standalone or dispatched by the review include.
model: haiku
effort: low
tools: Read, Grep, Glob, Bash
background: true
---

You are a static-analysis reviewer that runs the deterministic `housekeeper-freshness` engine over the current diff and reports dependencies that are behind their latest general-availability (GA) release.

Follow the cross-cutting static-analysis procedure in `includes/static-analysis-context.md`. The sections below contribute the housekeeper-specific bits.

## What is in scope

This specialist does NOT use the per-line `$CHANGED_LINES` output filter the way other static specialists do (see §5 of the static-analysis context). Instead the engine applies a three-tier scope model:

- **Shared CI is always in scope:** every `.github/workflows/*.yml` in the diff is scanned for stale `uses: org/action@vN` Actions and stale `runs-on:` runner labels.
- **Solution gate:** a changed file pulls in its nearest-ancestor npm `package.json`; ALL dependencies in an in-scope `package.json` are upgrade candidates, not only the changed lines.
- **Changed lines set the target only:** a dependency whose manifest line the diff touched is suggested at the latest GA; an in-scope-but-untouched dependency is suggested at the nearest in-major minor/patch. The engine computes this — render its `target` field verbatim.

Severity is uniform `Suggestion` ("staleness is a smell, not a defect"). Every finding emits `Confidence: 100` per §6.

## Tool resolution

Run `python3 --version`. If absent, emit `Skipped — python3 not available on PATH.` and stop. The engine ships in the plugin's `bin/` directory (on PATH as `housekeeper-freshness`); if `command -v housekeeper-freshness` is empty, emit `Skipped — housekeeper-freshness not available on PATH.` and stop.

## Tool invocation

The temp-dir contract (`includes/static-analysis-context.md` §4) is satisfied by the literal `Use $CLAUDE_TEMP_DIR for temporary files.` line in your prompt. That line carries `$CLAUDE_TEMP_DIR` **unexpanded** — Bash expands it from your environment when a command runs. Seeing the literal token is expected and DOES satisfy the contract; do not treat it as a missing temp dir and abort.

1. Write the changed file list to `$CLAUDE_TEMP_DIR/housekeeper-files.txt`:
   ```
   git diff --name-only <diff-args> > $CLAUDE_TEMP_DIR/housekeeper-files.txt
   ```
   Use the diff syntax determined by `$EMPTY_TREE_MODE` (two-arg when true, three-dot when false), as resolved by the base-context procedure.
2. Write the `Changed lines:` block from your prompt verbatim to `$CLAUDE_TEMP_DIR/housekeeper-lines.txt`.
3. Run the engine (live registry mode — no `--registry-fixtures`):
   ```
   housekeeper-freshness --root . --changed-files-from $CLAUDE_TEMP_DIR/housekeeper-files.txt --changed-lines-from $CLAUDE_TEMP_DIR/housekeeper-lines.txt
   ```
   It prints a JSON array of stale-version tuples to stdout. Parse it inline.

The engine is the sole source of truth for "what is stale" — it fetches live registry data and never emits a tuple without a trustworthy latest-GA answer. Do NOT add, drop, or re-judge tuples from trained knowledge.

## Output

Per `includes/static-analysis-context.md` §7. Heading: `## Housekeeper Findings`.

For each tuple, emit one finding:
- **File:** `<file>:<line>` from the tuple.
- **Confidence:** `100`.
- **Severity:** `Suggestion`.
- **Rule:** `housekeeper/<source>` where `<source>` is the tuple's `source` (`github-actions`, `runner`, or `npm`).
- **Description:** `<item> is at <current>; latest GA is <latest_ga>.` If `licence_current` and `licence_latest` differ and both are non-null, append ` Licence changes <licence_current> → <licence_latest>.`
- **Suggested fix:** `Upgrade <item> to <target>.` For `github-actions` SHA-pins, add `Preserve the SHA pin: update both the pinned commit and the # <target> comment.` Never suggest unpinning.

If the engine emits `[]`, emit the canonical zero-state and stop:

```
## Housekeeper Findings

0 findings — no stale versioned dependencies in scope.
```

If the engine crashes (non-zero exit), emit `Skipped — housekeeper-freshness engine error.` and stop.

After rendering, clean up the two temp files.

### Worked example

For a diff that changes `.github/workflows/ci.yml` (a `uses: actions/checkout@v3` on line 12 where latest GA is `v4.2.1`, and a `runs-on: ubuntu-22.04` on line 15) and `package.json` (a `"react": "^18.2.0"` on touched line 4 where latest GA is `19.0.0`), the canonical §7 output is:

```
## Housekeeper Findings

### Finding — actions/checkout behind latest GA
- **File:** .github/workflows/ci.yml:12
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/github-actions
- **Description:** actions/checkout is at v3; latest GA is v4.2.1.
- **Suggested fix:** Upgrade actions/checkout to v4.

### Finding — ubuntu runner behind latest GA
- **File:** .github/workflows/ci.yml:15
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/runner
- **Description:** ubuntu-22.04 is at ubuntu-22.04; latest GA is ubuntu-24.04.
- **Suggested fix:** Upgrade ubuntu to ubuntu-24.04.

### Finding — react behind latest GA
- **File:** package.json:4
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/npm
- **Description:** react is at 18.2.0; latest GA is 19.0.0.
- **Suggested fix:** Upgrade react to 19.0.0.
```

The heading is `### Finding — <title>` (em-dash, U+2014). The bullet field names are exactly `File`, `Confidence`, `Severity`, `Rule`, `Description`, `Suggested fix` — do not substitute synonyms, do not group findings under a `### <Severity>` sub-heading, and do not use a prose-block or `---`-separated layout; the harness parser pins to the §7 names and per-finding `### Finding` blocks. Severity is always `Suggestion`; confidence is always `100`.
```

- [ ] **Step 2: Validate plugin frontmatter conventions**

Confirm: `name` matches filename, `description` present, blank line after closing `---`, 2-space indentation in any nested markdown. Run `bash tests/run.sh` and confirm no NEW failures (the `static-analysis severity literals` sync test still enumerates only the original four agents at this point — it will be extended in Task 12; it does not yet assert on housekeeper, so it stays green).

- [ ] **Step 3: Commit + push**

```bash
git add plugins/code-review-suite/agents/housekeeper-reviewer.md
git commit -m "feat(housekeeper): housekeeper-reviewer agent (renders engine tuples as §7)"
git push origin main
```

---

### Task 7: Extend the version-freshness cookbook

**Files:**
- Modify: `plugins/code-review-suite/includes/version-freshness-cookbook.md`

- [ ] **Step 1: Add the runner table + Actions latest-major note**

After the existing ecosystem table (line 22), insert:
```markdown
### Runner labels (no live registry)

GitHub-hosted runner images have no registry endpoint. The housekeeper engine
ships a manually-maintained latest-label table (`LATEST_RUNNERS` in
`bin/housekeeper-freshness`). Keep this table in sync with that constant.
Reviewed 2026-06-05.

| Family   | Latest GA label |
|----------|-----------------|
| ubuntu   | `ubuntu-24.04`  |
| windows  | `windows-2025`  |
| macos    | `macos-15`      |

Unknown families (self-hosted, custom) and `-latest` floating labels are never
flagged — there is no trustworthy "latest GA" answer for them.

### GitHub Actions latest-major

A `uses: org/action@vN` pin floats minor/patch within major `N`. The housekeeper
reads the latest release `tag_name` (the existing GitHub Actions row above) and
flags only when the latest GA major exceeds `N`; the suggested target is the
latest major tag (`vM`). SHA pins (`@<sha>  # vX.Y.Z`) read the current version
from the trailing comment; a SHA pin without a version comment is never flagged.
```

- [ ] **Step 2: Commit + push**

```bash
git add plugins/code-review-suite/includes/version-freshness-cookbook.md
git commit -m "docs(cookbook): add runner latest-label table + Actions latest-major note"
git push origin main
```

---

### Task 8: Retire security-reviewer `#7` freshness path

**Files:**
- Modify: `plugins/code-review-suite/agents/security-reviewer.md`

Freshness moves wholly to the housekeeper. Security keeps `#6a` (CVE/advisory safety) and `#6b` (pinning). The `#7` Focus Area, FP-rule `#9`'s freshness clause, and the dedupe note are removed in lockstep.

- [ ] **Step 1: Remove the `#7` Focus Area**

Delete the entire `- **Version freshness (#7)** …` bullet and its sub-bullets (security-reviewer.md lines 90-104, the block ending `- Do not flag versions the diff did not touch.`).

- [ ] **Step 2: Rewrite FP-rule `#9`**

Replace the current rule 9 (lines 136-139):
```
9. Outdated third-party library versions WITHOUT a known advisory — handle these via the
   version-freshness Focus Area (Suggestion-level, never Critical). Vulnerable old versions
   ARE in scope via version-safety. Note: when both this path and the version-freshness
   Focus Area surface a finding for the same dependency, the synthesiser deduplicates.
```
with:
```
9. Outdated third-party library versions WITHOUT a known advisory — version freshness is owned
   by the `housekeeper` specialist (Suggestion-level), not security. Vulnerable old versions
   ARE in scope here via version-safety (#6a): if a stale dependency the housekeeper flags also
   carries a known advisory, escalate it via #6a at Important/Critical through cross-review.
```

- [ ] **Step 2.5: Check the cookbook citation**

Grep security-reviewer.md for `version-freshness-cookbook`. The `#7` block was the only consumer of the cookbook in this file; with `#7` gone, confirm no dangling citation remains in security-reviewer. The cookbook is now consumed by the housekeeper engine + agent. (Other consumers — `pre-review.md`, `SKILL.md` — are addressed in Task 10; verify there whether their freshness sentences should now name the housekeeper.)

- [ ] **Step 3: Run the suite + commit + push**

Run: `bash tests/run.sh` (expect green bar the dirty-tree artifact). No sync test asserts the `#7` text, so removal is safe.
```bash
git add plugins/code-review-suite/agents/security-reviewer.md
git commit -m "refactor(security-reviewer): retire dead #7 freshness path (now owned by housekeeper)"
git push origin main
```

---

### Task 9: Synthesiser source tag + carve-out (and §10 include)

**Files:**
- Modify: `plugins/code-review-suite/agents/review-synthesiser.md`
- Modify: `plugins/code-review-suite/includes/static-analysis-context.md`

The housekeeper is a static specialist, so it joins the severity-locked + confidence-100 carve-out. This requires lockstep edits to three enumerations (synthesiser line 89 anchor, synthesiser line 125, include §10 line 136-137) AND the source-tag list (line 221) — plus the sync test in Task 12.

- [ ] **Step 1: Add `[housekeeper]` to the source-tag list**

In `review-synthesiser.md` line 221, add `[housekeeper]` to the tag enumeration (after `[trivy]`, before `[ui]`):
```
... `[eslint]`, `[ruff]`, `[trivy]`, `[housekeeper]`, `[jbinspect]`, `[ui]`, `[synthesiser]`.
```

- [ ] **Step 2: Add `[housekeeper]` to the carve-out anchor (line 89)**

Change:
```
Findings tagged `[eslint]`, `[ruff]`, `[trivy]`, or `[jbinspect]` are exempt from
```
to:
```
Findings tagged `[eslint]`, `[ruff]`, `[trivy]`, `[jbinspect]`, or `[housekeeper]` are exempt from
```

- [ ] **Step 3: Add `[housekeeper]` to the dismissal-exception list (line 125)**

Change the parenthetical `(except for \`[eslint]\`, \`[ruff]\`, \`[trivy]\`, or \`[jbinspect]\` findings …)` to include `\`[housekeeper]\``:
```
(except for `[eslint]`, `[ruff]`, `[trivy]`, `[jbinspect]`, or `[housekeeper]` findings — see the Static-analysis carve-out under Severity Reclassification; those land in Contested instead).
```

- [ ] **Step 4: Add `[housekeeper]` to §10 of the include (lines 136-137)**

In `static-analysis-context.md` §10, change the two enumerations:
```
The synthesiser's "Severity Reclassification" pass skips findings tagged `[eslint]`, `[ruff]`, `[trivy]`, or `[jbinspect]`.
```
to add `[housekeeper]`, and add a parallel clause to the Critical-allow-list sentence noting the housekeeper is uniform `Suggestion` (no Critical-allow-list). Add after the existing allow-list paragraph:
```
The `housekeeper` specialist emits a uniform `Suggestion` severity (staleness is a smell, not a defect) and has no Critical-allow-list — its findings are severity-locked at `Suggestion`.
```

- [ ] **Step 5: Run the suite (note: sync test will FAIL until Task 12)**

Run: `bash tests/run.sh 2>&1 | grep -iE "carve-out|severity lock|housekeeper"`
Expected: the `static-analysis severity lock` sync test now FAILS because its anchor literal still reads the four-tag form. This is EXPECTED — Task 12 updates the test anchor in lockstep. Do not "fix" it by reverting; proceed to Task 12 before the final green run. Commit this together with Task 12, OR commit now and accept one red test until Task 12 lands in the same session.

- [ ] **Step 6: Commit + push**

```bash
git add plugins/code-review-suite/agents/review-synthesiser.md plugins/code-review-suite/includes/static-analysis-context.md
git commit -m "feat(synthesiser): add [housekeeper] source tag + severity-lock carve-out"
git push origin main
```

---

### Task 10: Pipeline wiring (review-pipeline.md + pre-review.md + SKILL.md)

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md`
- Modify: `plugins/code-review-suite/commands/pre-review.md`
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`

The housekeeper is a conditional pipeline specialist gated on `$HOUSEKEEPING_DETECTED`. The same edits mirror across all three files (sync-note tests enforce flag parity).

- [ ] **Step 1: Add the detection flag (review-pipeline.md Step 2.6, after the IaC line ~693)**

Insert:
```
   - **Housekeeping detection:** if any changed file is under `.github/workflows/` and ends `.yml`/`.yaml`, OR is a `package.json` (npm manifest), set `$HOUSEKEEPING_DETECTED = true`. (This slice covers GitHub Actions, workflow runners, and npm; follow-on plans extend the trigger to NuGet/PyPI/crates/Go/RubyGems/Docker/SDK manifests.)
```

- [ ] **Step 2: Add the conditional dispatch block (review-pipeline.md, after the trivy `$IAC_DETECTED` block ~921)**

Insert:
```
If `$HOUSEKEEPING_DETECTED`, also dispatch:
\```
Agent({
    description: "Dependency freshness review",
    subagent_type: "code-review-suite:housekeeper-reviewer",
    name: "housekeeper-reviewer",
    mode: "auto",
    run_in_background: true,
    prompt: $AGENT_PROMPT
})
\```
```
(Use a real triple-backtick fence in the file, not the escaped form shown here.)

- [ ] **Step 3: Update `$SPECIALIST_COUNT` accounting (line 933)**

Change the parenthetical to include housekeeper:
```
Store `$SPECIALIST_COUNT` = number of specialists dispatched (8 core only; 9–14 with conditionals: +1 each for `$CSHARP_DETECTED`, `$UI_DETECTED`, `$JS_DETECTED`, `$PY_DETECTED`, `$IAC_DETECTED`, `$HOUSEKEEPING_DETECTED`) and note the dispatch timestamp.
```
Also update the **polyglot fallback** note (~931) and the batching note (925-926): the conditional set is now up to 6 (jbinspect, ui, eslint, ruff, trivy, housekeeper); Batch 2 / Batch 3 enumerations should mention housekeeper.

- [ ] **Step 4: Update verify-completeness (line 940)**

Append to the conditional list:
```
… plus `trivy-reviewer` if `$IAC_DETECTED`, plus `housekeeper-reviewer` if `$HOUSEKEEPING_DETECTED`)
```

- [ ] **Step 5: Wire cross-review feed (Step 5.2 sub-step 3, line 1037-1038)**

The housekeeper is a static specialist: its findings ARE shown to all cross-reviewers but it does NOT receive cross-review. Add `housekeeper` to the static-specialist enumeration in sub-step 3 and to the detection-flag omission rule:
```
3. Include findings from any static-analysis specialist (`jbinspect`, `eslint`, `ruff`, `trivy`, `housekeeper`) for ALL cross-reviewers … Omit any `### <name>-reviewer findings` block whose corresponding detection flag is false (`$CSHARP_DETECTED`, `$JS_DETECTED`, `$PY_DETECTED`, `$IAC_DETECTED`, `$HOUSEKEEPING_DETECTED` respectively) …
```
Also update Step 5.0's "EXCLUDING the four static-analysis specialists" phrasing (line 1003) to "the five static-analysis specialists (`jbinspect`, `eslint`, `ruff`, `trivy`, `housekeeper`)". `$CROSS_REVIEW_COUNT` is unaffected (static specialists never contribute to it — line 1013 already says so; leave it).

- [ ] **Step 6: Mirror Steps 1-5 into pre-review.md**

Apply the same detection flag (after its IaC line ~693), the same `$HOUSEKEEPING_DETECTED` dispatch block (after its trivy block), count, and verify edits. pre-review has no cross-review of its own beyond what the pipeline include drives — confirm by reading its dispatch section. Also: if pre-review.md carries a freshness sentence naming security-reviewer (grep `freshness`), update it to name the housekeeper (per Task 8 Step 2.5).

- [ ] **Step 7: Mirror Steps 1-5 into SKILL.md**

Apply the same detection flag (after its IaC line ~798), the `$HOUSEKEEPING_DETECTED` dispatch block (after its trivy block ~1022), count (~1039), verify (~1046), and the cross-review enumeration edits (~1108, ~1143). Grep SKILL.md for `freshness` and update any security-reviewer freshness sentence to name the housekeeper.

- [ ] **Step 8: Run the suite**

Run: `bash tests/run.sh 2>&1 | grep -iE "dispatcher flags|housekeeping|HOUSEKEEPING|cross-feed"`
Expected: the `static-analysis dispatcher flags` test still passes (it asserts `$JS_DETECTED/$PY_DETECTED/$IAC_DETECTED` presence — unaffected). The `static-analysis cross-feed` enumeration test (asserts all static specialists appear in both canonicals) may now FAIL because it enumerates only `jbinspect eslint ruff trivy` — Task 12 extends it. Note which tests are red pending Task 12.

- [ ] **Step 9: Commit + push**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md
git commit -m "feat(pipeline): wire housekeeper-reviewer as conditional specialist across pipeline/pre-review/SKILL"
git push origin main
```

---

### Task 11: README specialist table + prerequisites

**Files:**
- Modify: `plugins/code-review-suite/README.md`

- [ ] **Step 1: Add the housekeeper row to the specialist table**

After the `trivy-reviewer` row (line 75), add:
```
| `housekeeper-reviewer` | Dependency/version freshness — flags GitHub Actions, workflow runners, and npm packages behind latest GA (conditional — workflows + `package.json`; registry-backed deterministic engine) |
```

- [ ] **Step 2: Update the specialist prose (lines 30-35)**

Add `housekeeper-reviewer` to the conditional-specialist sentence. Note the static-analysis-specialist count changes from "four" to "five" wherever the README says "the four static-analysis specialists" — grep and update each (lines 34-35, 57). The housekeeper shares the static-analysis carve-out.

- [ ] **Step 3: Update the freshness sentence (line 42)**

Line 42 currently credits `security-reviewer` with live-registry freshness. Rewrite to credit the housekeeper:
```
The `housekeeper-reviewer` verifies against the live registry that dependencies, GitHub Actions, and runners are at their latest GA release.
```

- [ ] **Step 4: Add the prerequisite (line ~99-106)**

Add to the Prerequisites list:
```
- `python3` — required for the `housekeeper-reviewer` dependency-freshness engine (`bin/housekeeper-freshness`). Stdlib only; no pip packages. Live runs need outbound HTTPS to npm and the GitHub API.
```

- [ ] **Step 5: Commit + push**

```bash
git add plugins/code-review-suite/README.md
git commit -m "docs(README): add housekeeper-reviewer to specialist table + python3 prerequisite"
git push origin main
```

---

### Task 12: Extend the sync-note tests for the fifth static specialist

**Files:**
- Modify: `tests/lib/test_sync_notes.sh`

The sync tests hardcode the four static specialists. Adding the housekeeper means extending each enumeration in lockstep with the doc edits made in Tasks 9-10. This task makes the red tests from Tasks 9 and 10 green.

- [ ] **Step 1: Extend the severity-lock anchor + tag loop (test_sync_static_analysis_severity_lock, ~line 601-612)**

Change the anchor literal:
```bash
local anchor='Findings tagged `[eslint]`, `[ruff]`, `[trivy]`, `[jbinspect]`, or `[housekeeper]` are exempt from'
```
and add `[housekeeper]` to the tag loop:
```bash
for tag in '[eslint]' '[ruff]' '[trivy]' '[jbinspect]' '[housekeeper]'; do
```

- [ ] **Step 2: Extend the cross-feed specialist enumeration (test, ~line 796)**

Change:
```bash
for name in jbinspect eslint ruff trivy; do
```
to:
```bash
for name in jbinspect eslint ruff trivy housekeeper; do
```

- [ ] **Step 3: Decide on the severity-mapping/heading test (~line 519)**

`test_static_analysis_specialists_have_required_severity_mapping` loops over the four agent files asserting each contains `Confidence: 100` and a `## <name> Findings` heading. The housekeeper agent satisfies both (it has `## Housekeeper Findings` and renders `Confidence: 100`). Add `housekeeper-reviewer.md` to that loop (~line 519):
```bash
for agent in eslint-reviewer.md ruff-reviewer.md trivy-reviewer.md jbinspect-reviewer.md housekeeper-reviewer.md; do
```
Note the agent body's `Confidence:` literal appears as `- **Confidence:** \`100\`` in the worked example and the instruction `emits \`Confidence: 100\``; confirm a bare `Confidence: 100` substring is present (the §6 reference line "Every finding emits `Confidence: 100`" — add that exact phrase to the agent body if grep does not find it, mirroring trivy-reviewer.md:78).

- [ ] **Step 4: Add the dispatcher-flag assertion for the new flag (~line 499)**

Extend the flag loop so the new flag's mirror across SKILL + pre-review is enforced:
```bash
for flag in '$JS_DETECTED' '$PY_DETECTED' '$IAC_DETECTED' '$HOUSEKEEPING_DETECTED'; do
```

- [ ] **Step 5: Run the full suite — expect green**

Run: `bash tests/run.sh`
Expected: ALL pass except the known dirty-tree artifact. The Task-9 and Task-10 red tests are now green. If `test_static_analysis_specialists_have_required_severity_mapping` fails on the `Confidence: 100` substring, add the exact `Every finding emits the literal \`Confidence: 100\`` line to the agent body (Step 3 note) and re-run.

- [ ] **Step 6: Commit + push**

```bash
git add tests/lib/test_sync_notes.sh plugins/code-review-suite/agents/housekeeper-reviewer.md
git commit -m "test(sync): enforce housekeeper in static-specialist enumerations"
git push origin main
```

---

### Task 13: A/B apparatus (offline — fixture, recorded registry, parser case, configs)

**Files:**
- Create: `tests/fixtures/static-analysis/housekeeper/.github/workflows/ci.yml`
- Create: `tests/fixtures/static-analysis/housekeeper/package.json`
- Create: `tests/fixtures/static-analysis/housekeeper/registry/github-actions/actions__checkout.json`
- Create: `tests/fixtures/static-analysis/housekeeper/registry/npm/react.json`
- Create: `tests/ab/corpus/housekeeper-smoke-stale-deps/source.yaml`
- Create: `tests/ab/corpus/housekeeper-smoke-stale-deps/diff/changed-lines.txt`
- Modify: `tests/ab/corpus/index.yaml`
- Modify: `tests/ab/lib/agent_capture.sh`
- Create: `tests/ab/fixtures/housekeeper-stdout-three-findings.log`
- Modify: `tests/lib/test_ab_per_agent_lib.sh`
- Create: `tests/ab/configs/per-agent/housekeeper-baseline.yaml`
- Create: `tests/ab/configs/per-agent/housekeeper-haiku-low.yaml`

- [ ] **Step 1: Write the fixture sources**

`tests/fixtures/static-analysis/housekeeper/.github/workflows/ci.yml`:
```yaml
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v3
      - run: echo build
```
(Line 5 is `runs-on: ubuntu-22.04`; line 7 is `uses: actions/checkout@v3`.)

`tests/fixtures/static-analysis/housekeeper/package.json`:
```json
{
  "name": "housekeeper-smoke",
  "dependencies": {
    "react": "^18.2.0"
  }
}
```
(Line 4 is the `react` dep.)

- [ ] **Step 2: Write the recorded registry fixtures**

`tests/fixtures/static-analysis/housekeeper/registry/github-actions/actions__checkout.json`:
```json
{"tag_name": "v4.2.1"}
```
`tests/fixtures/static-analysis/housekeeper/registry/npm/react.json`:
```json
{
  "dist-tags": {"latest": "19.0.0"},
  "versions": {
    "18.0.0": {"license": "MIT"},
    "18.2.0": {"license": "MIT"},
    "18.3.1": {"license": "MIT"},
    "19.0.0": {"license": "MIT"}
  }
}
```

- [ ] **Step 3: Verify the engine produces the three expected tuples against fixtures**

Run (single Bash call; resolve `$CLAUDE_TEMP_DIR` to the literal session path):
```
printf '.github/workflows/ci.yml\npackage.json\n' > $CLAUDE_TEMP_DIR/hk-files.txt
```
Then:
```
printf 'Changed lines:\n  .github/workflows/ci.yml: 5,7\n  package.json: 4\n' > $CLAUDE_TEMP_DIR/hk-lines.txt
```
Then (separate call):
```
HOUSEKEEPER_REGISTRY_FIXTURES=tests/fixtures/static-analysis/housekeeper/registry python3 plugins/code-review-suite/bin/housekeeper-freshness --root tests/fixtures/static-analysis/housekeeper --changed-files-from $CLAUDE_TEMP_DIR/hk-files.txt --changed-lines-from $CLAUDE_TEMP_DIR/hk-lines.txt
```
Expected stdout: a 3-element JSON array with sources `github-actions` (checkout v3→target v4), `runner` (ubuntu-22.04→ubuntu-24.04), `npm` (react 18.2.0→19.0.0, target 19.0.0 because line 4 is touched). Confirm the `EndToEndTest` in `tests/python` now passes: `python3 -m unittest discover -s tests/python -v`.

- [ ] **Step 4: Write the changed-lines + source.yaml + register the fixture**

`tests/ab/corpus/housekeeper-smoke-stale-deps/diff/changed-lines.txt`:
```
Changed lines:
  .github/workflows/ci.yml: 5,7
  package.json: 4
```
`tests/ab/corpus/housekeeper-smoke-stale-deps/source.yaml` (copy the trivy shape; NO `setup:` — the engine ships in the plugin `bin/`):
```yaml
id: housekeeper-smoke-stale-deps
agent: housekeeper-reviewer
captured_at: 2026-06-05T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: PLACEHOLDER_FILL_AT_CAPTURE
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/housekeeper/
base_sha: ""  # synthetic fixture: no real diff
head_sha: ""
path_scope: ""
empty_tree_mode: false
registry_fixtures: registry/   # engine reads HOUSEKEEPER_REGISTRY_FIXTURES from here
intent_ledger: |
  ## Intent ledger
  - Synthetic smoke fixture exercising housekeeper-reviewer against a workflow
    (stale actions/checkout@v3 line 7, stale runs-on: ubuntu-22.04 line 5) and a
    package.json (stale react ^18.2.0 line 4). Three deterministic Suggestion
    findings via recorded registry fixtures. Vertical-slice-1 baseline for the
    Haiku/low cost-tuning probe.
depends_on:
  - plugins/code-review-suite/agents/housekeeper-reviewer.md
  - plugins/code-review-suite/bin/housekeeper-freshness
  - plugins/code-review-suite/includes/static-analysis-context.md
  - tests/fixtures/static-analysis/housekeeper/.github/workflows/ci.yml
  - tests/fixtures/static-analysis/housekeeper/package.json
```
In `tests/ab/corpus/index.yaml`, append under `fixtures:`:
```yaml
  - id: housekeeper-smoke-stale-deps
    agent: housekeeper-reviewer
    type: synthetic
    description: Three-finding freshness set (actions/checkout v3→v4, ubuntu-22.04→24.04, react 18.2.0→19.0.0) via recorded registry fixtures. Vertical-slice-1 baseline.
    tags: [smoke, deterministic]
```
NOTE: the `registry_fixtures` key in source.yaml is new. Check whether the A/B harness must set `HOUSEKEEPER_REGISTRY_FIXTURES` from it. **Read `tests/ab/run.sh` and `tests/ab/lib/agent_dispatch.sh`** to find how per-trial env is passed to the dispatched subagent. If the harness has no env-passthrough, the live worked-example capture (Task 14) runs against LIVE registries (acceptable — the fixture pins the diff, and live npm/checkout values for these specific stale pins are stable enough that v3<v4 and 18<19 hold regardless of exact latest). Document whichever path is taken in the result note. The unittest `EndToEndTest` already proves engine determinism under fixtures independent of the harness.

- [ ] **Step 5: Write the parser test fixture**

`tests/ab/fixtures/housekeeper-stdout-three-findings.log` (preamble + canonical §7 block + trailing prose). Use the three findings from the agent worked example (Task 6), with `Rule:` values `housekeeper/github-actions`, `housekeeper/runner`, `housekeeper/npm`. (Copy the worked-example block verbatim, wrapped in some preamble/trailing prose lines.)

- [ ] **Step 6: Write the failing parser tests**

In `tests/lib/test_ab_per_agent_lib.sh`, after the jbinspect parser tests, add `test_ab_agent_capture_housekeeper_parses_three_findings` (mirror the jbinspect three-finding test: assert `length == 3`, assert the slash-bearing `rule_id` tokenises to the full `housekeeper/github-actions` — the slash is internal so the `split(v, a, /[ \t(]/)` tokeniser keeps it whole; assert severity `Suggestion`), `test_ab_agent_capture_housekeeper_zero_findings_is_empty_array` (feed `## Housekeeper Findings\n\n0 findings — no stale versioned dependencies in scope.\n`, assert empty array), and `test_ab_agent_capture_housekeeper_skipped_marks_inconclusive` (feed `## Housekeeper Findings\n\nSkipped — python3 not available on PATH.\n`, assert the `INCONCLUSIVE` marker). Use the jbinspect tests (plan 2026-06-04-phase-3-4 Task 2 Step 2) as the exact structural template.

- [ ] **Step 7: Run to verify they fail**

Run: `bash tests/run.sh 2>&1 | grep -i housekeeper`
Expected: the new housekeeper parser tests FAIL with "unknown agent: housekeeper".

- [ ] **Step 8: Add the parser-dispatch case**

In `tests/ab/lib/agent_capture.sh` `_agent_capture_params()`, after the `jbinspect` case (line 60), add:
```bash
        housekeeper|housekeeper-reviewer)
            _AC_HEADING='^## Housekeeper Findings$'
            # The engine runs via one Bash call; any 'Skipped — …' opener
            # (python3 absent, engine-not-on-PATH, engine error) is a full
            # skip -> INCONCLUSIVE.
            _AC_SKIP='^Skipped — '
            _AC_ZERO='^0 findings — no stale versioned dependencies in scope\.'
            ;;
```
Update the header comment block (lines 11-20) to note the housekeeper's `housekeeper/<source>` rule IDs contain an internal slash with no whitespace, so the shared `split(v, a, /[ \t(]/)` tokeniser keeps the full ID — no tokeniser change.

- [ ] **Step 9: Run to verify they pass**

Run: `bash tests/run.sh 2>&1 | grep -i housekeeper`
Expected: the new housekeeper parser tests PASS.

- [ ] **Step 10: Write the configs + config-parse test**

`tests/ab/configs/per-agent/housekeeper-baseline.yaml`:
```yaml
name: housekeeper-baseline
description: Production reference for housekeeper-reviewer — sonnet at default effort.
mode: per-agent
agent: housekeeper-reviewer
session:
  model: sonnet
  effort: default
```
`tests/ab/configs/per-agent/housekeeper-haiku-low.yaml`:
```yaml
name: housekeeper-haiku-low
description: Vertical-slice-1 directional probe — housekeeper-reviewer at Haiku/low. Compared against housekeeper-baseline (sonnet/default) on per-trial findings hash.
mode: per-agent
agent: housekeeper-reviewer
session:
  model: haiku
  effort: low
```
In `tests/lib/test_ab_per_agent_lib.sh`, add `test_ab_config_per_agent_housekeeper_haiku_low_parses` mirroring the jbinspect config-parse test (assert mode=per-agent, agent=housekeeper-reviewer, model=haiku, effort=low).

- [ ] **Step 11: Run the full suite**

Run: `bash tests/run.sh`
Expected: all pass except the known dirty-tree artifact. Note the new total.

- [ ] **Step 12: Commit + push**

```bash
git add tests/fixtures/static-analysis/housekeeper tests/ab/corpus/housekeeper-smoke-stale-deps tests/ab/corpus/index.yaml tests/ab/lib/agent_capture.sh tests/ab/fixtures/housekeeper-stdout-three-findings.log tests/lib/test_ab_per_agent_lib.sh tests/ab/configs/per-agent/housekeeper-baseline.yaml tests/ab/configs/per-agent/housekeeper-haiku-low.yaml
git commit -m "test(ab): housekeeper corpus fixture, recorded registry, parser case, configs"
git push origin main
```

---

### Task 14: GATED live worked-example capture, 2×20 sweep, verdict, memory

**STOP. Tasks 14's capture and sweep steps spend real Bedrock. Get explicit operator go-ahead before each. "Continue" does NOT authorise the spend.**

**Files:**
- Modify: `tests/ab/corpus/housekeeper-smoke-stale-deps/source.yaml` (fill `suite_sha`)
- Create: `tests/ab/corpus/housekeeper-smoke-stale-deps/expected/findings-housekeeper.md`
- Create: `tests/ab/corpus/housekeeper-smoke-stale-deps/expected/findings.json`
- Possibly modify: `plugins/code-review-suite/agents/housekeeper-reviewer.md` (worked-example refinement if the first capture parses to zero tuples)
- Create: `docs/superpowers/notes/2026-06-05-housekeeper-haiku-low-result.md`

- [ ] **Step 1: Capture ONE sonnet/default trial (GATED)**

Get go-ahead. Run:
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-baseline.yaml --corpus housekeeper-smoke-stale-deps --trials 1 --stream-json
```
(No `--mode` flag — mode is config-derived.) Read the trial-001 `stdout.log`: confirm the agent ran the engine, got the three tuples, and rendered the §7 block. If `findings.json` parsed to `[]` despite a visible report, the worked example needs refining — adjust `housekeeper-reviewer.md`'s worked example to match the real layout (per [[worked-example-gap]]), re-capture, confirm the parse.

- [ ] **Step 2: Promote the captured report as the expected baseline**

Copy the captured findings block to `expected/findings-housekeeper.md` and the parsed tuples to `expected/findings.json` (three `Suggestion` findings: checkout, ubuntu runner, react). Fill `suite_sha` in `source.yaml` with the current HEAD.

- [ ] **Step 3: The matched 2×20 probe (GATED — the main Bedrock spend)**

Get explicit go-ahead. Run BOTH arms at n=20 (full matched pair — housekeeper has no prior data):
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-baseline.yaml --corpus housekeeper-smoke-stale-deps --trials 20 --stream-json
```
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-haiku-low.yaml --corpus housekeeper-smoke-stale-deps --trials 20 --stream-json
```
Consider `run_in_background: true` per arm. The housekeeper is the most multi-step specialist (resolve diff → write temp files → run engine → render N findings), so it is the most haiku-risky — watch the hash distribution closely.

- [ ] **Step 4: Tabulate + verdict**

Per `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`: **EQUIVALENT** (clean single-hash haiku arm matching baseline) → flip production; **INCONCLUSIVE** (mixed within-arm hashes) → do not flip, characterise the tail; **WORSE** (>25% NORMAL-rate drop) → do not flip. Compute the sonnet÷haiku cost RATIO (list-price caveat per [[phase-3-2b-pr-b-reprobe]]). If a real agent-side tail survives the clean apparatus, CHARACTERISE it — any fix must be a general correctness improvement (helping sonnet too) earning its own before/after re-sweep at n=20 on both arms.

- [ ] **Step 5: Write the result note**

Create `docs/superpowers/notes/2026-06-05-housekeeper-haiku-low-result.md` mirroring `docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md`: header (run dirs + sweep SHA), sweep config, per-arm hash distribution, any agent-side tail, cost ratio with the list-price caveat, verdict verbatim, production-flip recommendation.

- [ ] **Step 6: Production-flip decision (operator-gated, only on clean EQUIVALENT)**

The agent already ships `model: haiku` + `effort: low` (the user's up-front call). So on EQUIVALENT, NO frontmatter change is needed — record the validation. On INCONCLUSIVE/WORSE, the mitigation per the design is to REVERT to `model: sonnet` (remove `effort: low` or set `effort: default`) in `housekeeper-reviewer.md` and re-sweep later. This is operator-gated.

- [ ] **Step 7: Update memory**

Add `project_housekeeper_specialist_slice1.md` to the `~/.claude` repo memory dir (`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`, NOT this clone): the slice shipped, the three source classes, the engine location, the verdict + cost ratio, whether haiku held or reverted to sonnet, and the deferred follow-on ecosystems. Add the MEMORY.md index line. Commit + push the `~/.claude` repo separately.

- [ ] **Step 8: Commit + push the result note + expected fixtures**

```bash
git add tests/ab/corpus/housekeeper-smoke-stale-deps/expected tests/ab/corpus/housekeeper-smoke-stale-deps/source.yaml docs/superpowers/notes/2026-06-05-housekeeper-haiku-low-result.md plugins/code-review-suite/agents/housekeeper-reviewer.md
git commit -m "docs(ab): housekeeper Haiku/low A/B result + verdict + expected baseline"
git push origin main
```

---

## Self-review notes

- **Spec coverage:** Identity/static-specialist classing (Task 6 frontmatter + §10 carve-out Tasks 9/12); pipeline specialist + show-only cross-review (Task 10 Step 5); direct-registry GA-filtered engine (Tasks 1-5); three-tier scope — T1 solution gate + always-in CI (Task 5 `npm_scope_roots` + Tasks 3-4 always-in workflows), T2 all-deps candidates (Task 5 `collect_npm` iterates all deps), T3 target modulation (Task 5 touched-line branch); Tier-1 source classes realised = Actions/runners/npm (Tasks 3-5), remaining T1 classes explicitly deferred to follow-on plans (Scope section); SHA-pin preservation + comment-trust (Task 3 `find_action_uses` + Task 6 suggested-fix); licence-diff (Task 5 + Task 6 Description); security #7 retirement in lockstep (Task 8); model tier haiku-direct + A/B harness + sweep (Tasks 6/13/14); recorded-registry-fixture testability (Tasks 1/5/13). The spec's four "open items" are resolved: SHA mechanism = comment-trust (Task 3); per-source endpoints/fields = cookbook (Task 7) + engine (Tasks 3-5); "solution/buildable unit" = nearest-ancestor `package.json` for npm, always-in for CI (Task 5); fixture-refresh strategy = recorded JSON committed under `tests/fixtures/.../registry/` (Task 13, refreshed by re-recording).
- **The §5 exception is explicit:** Task 6's "What is in scope" section states the housekeeper does NOT obey the per-line §5 filter — it gates on solution membership. The handover flagged this as the one novel exception; it is documented in the agent body and the scope is enforced engine-side, not by the prompt's `Changed lines:` directive.
- **Placeholder scan:** every code step shows complete code; every doc edit shows the exact before/after literal; every command shows the expected output. The only deliberate `PLACEHOLDER_FILL_AT_CAPTURE` is the `suite_sha`, filled in Task 14 Step 2 (same convention as the jbinspect plan).
- **Type/name consistency:** engine function names (`parse_version`, `compare_versions`, `is_ga`, `latest_ga`, `nearest_in_major`, `strip_constraint`, `find_action_uses`, `collect_github_actions`, `find_runner_labels`, `collect_runners`, `parse_package_json`, `npm_scope_roots`, `collect_npm`, `collect_findings`, `Registry.fetch`) are used identically in tests and implementation across Tasks 1-5. Tuple keys (`source/item/current/latest_ga/target/file/line/licence_current/licence_latest`) are stable from Task 3 through Task 6's renderer. The `Rule:` value `housekeeper/<source>` matches the parser-case expectation in Task 13.
- **Red-test sequencing:** Tasks 9 and 10 deliberately leave sync tests red until Task 12 updates the test anchors in lockstep. This is called out in each task and is the correct order (edit the doc, then the test that pins the doc). If executing task-by-task with a green-bar gate, batch Tasks 9-12 before the gate, or accept the documented transient red.
- **Harness env-passthrough risk (Task 13 Step 4):** the one genuine unknown is whether `tests/ab/run.sh` can inject `HOUSEKEEPER_REGISTRY_FIXTURES` into the dispatched subagent's environment. The plan instructs reading `run.sh`/`agent_dispatch.sh` to confirm; if it cannot, the live capture runs against real registries (acceptable for these specific stable stale-pins) and the unittest `EndToEndTest` independently guarantees engine determinism. This is the only step that may need an adaptation during execution — flagged, not hidden.
- **No `setup:` block** (Task 13): the engine ships in the plugin `bin/` (on PATH), like trivy/jb — no per-trial provisioning, no install-race.
