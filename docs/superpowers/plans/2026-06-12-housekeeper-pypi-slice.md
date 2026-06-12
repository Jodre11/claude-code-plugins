# Housekeeper PyPI Freshness Slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `pypi` source class to the `housekeeper-freshness` engine that flags Python dependency declarations (`pyproject.toml` PEP 621 + Poetry tables, and `requirements*.txt`) pinned behind their latest GA on PyPI, with a `yanked` health rider.

**Architecture:** Sixth source class on the proven freshness chassis. New PyPI-specific PEP 440 version core (`pypi_*` helpers, leaving the existing semver-ish core untouched for hash stability of the other five sources), a `pypi_strip_constraint` trust gate, two parsers (`parse_pyproject` via stdlib `tomllib`, `parse_requirements` line-oriented), a `Registry.pypi_releases` client hitting the PyPI JSON API with a fixture override, a `collect_pypi` collector, and a `pypi_scope_roots` resolver wired into `collect_findings`. Agent renderer, trigger lockstep across three synced files, README, on-disk fixture, and a single-arm haiku/low A/B corpus complete the slice.

**Tech Stack:** Python 3 (pure stdlib; `tomllib` requires 3.11+), `unittest` (pytest is NOT installed), bash structural test suite, YAML A/B corpus.

**Spec:** `docs/superpowers/specs/2026-06-12-housekeeper-pypi-slice-design.md`

---

## House rules (read before starting)

- **Direct-push to `main`; push immediately after each commit.** No Co-Authored-By / advertising trailers.
- **Bash hook rules (strict):** one command per Bash call — no `&&`/`||`/`;`, no `$(...)`/backticks, no subshells, no heredocs in Bash. Carve-out: the `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC IS permitted. For multi-line Python, Write a file under `$CLAUDE_TEMP_DIR` and run it.
- **`pytest` is NOT installed.** Run engine tests via `python3 -m unittest tests.python.test_housekeeper_engine -v` from the repo root.
- **`$CLAUDE_TEMP_DIR`** is the literal `/tmp/claude-<session-id>` path; use it in redirects and subagent prompts.
- **Subagents:** set `mode: "auto"` and a kebab-case `name` on every dispatch; pass the resolved `$CLAUDE_TEMP_DIR` literal into prompts.
- **Known test artifact:** `A/B run.sh: bad-config rejection leaves working tree clean` false-fails on a DIRTY tree. Commit first, then re-run `bash tests/run.sh` to confirm green.
- **Subagent Write-guard false-positive:** the Write tool may refuse to create `expected/findings-housekeeper.md` (matches a "subagent report file" heuristic on `findings`/`.md`). It is a legitimate corpus data fixture. Workaround: Write-to-`$CLAUDE_TEMP_DIR`-then-`cp`.

## File map

| File | Responsibility | Tasks |
|---|---|---|
| `plugins/code-review-suite/bin/housekeeper-freshness` | Engine: version core, parsers, registry, collector, scope, wiring | 1–8 |
| `tests/python/test_housekeeper_engine.py` | Engine unit + end-to-end tests | 1–9 |
| `tests/fixtures/static-analysis/housekeeper-pypi/` | On-disk Anchor-pull-in regression fixture | 9 |
| `plugins/code-review-suite/agents/housekeeper-reviewer.md` | Renderer: `pypi` rule + worked example | 10 |
| `plugins/code-review-suite/includes/review-pipeline.md` (+ 2 mirrors) | Step 2.6 trigger prose | 11 |
| `tests/lib/test_sync_notes.sh` | Trigger-mirror sync test | 11 |
| `plugins/code-review-suite/README.md` | Specialist table + prose | 12 |
| `tests/ab/corpus/housekeeper-pypi-stale-deps/`, `tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml`, `tests/ab/corpus/index.yaml` | Single-arm A/B corpus + config + index row | 13 |

---

## Task 1: PyPI PEP 440 version core

The existing `parse_version`/`is_ga`/`compare_versions`/`latest_ga`/`nearest_in_major` are semver-ish and mis-handle PEP 440 (prereleases have no hyphen; post-releases; epochs; local versions). Add a parallel `pypi_*` set, leaving the originals untouched so the other five sources keep their canonical hashes.

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add after the existing version-core block, before `strip_constraint`)
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPIVersionCoreTest` class)

- [ ] **Step 1: Write the failing tests**

Append to `tests/python/test_housekeeper_engine.py` (before the `if __name__` block):

```python
class PyPIVersionCoreTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_is_ga_rejects_pep440_prereleases(self):
        self.assertTrue(self.m.pypi_is_ga("1.2.3"))
        self.assertTrue(self.m.pypi_is_ga("2.0.0"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3rc1"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3a1"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3b2"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3.dev0"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3rc1.dev0"))

    def test_post_release_is_ga_and_newer(self):
        self.assertTrue(self.m.pypi_is_ga("1.2.3.post1"))
        self.assertEqual(self.m.pypi_compare("1.2.3.post1", "1.2.3"), 1)
        self.assertEqual(self.m.pypi_compare("1.2.3", "1.2.3.post1"), -1)

    def test_prerelease_sorts_below_final(self):
        self.assertEqual(self.m.pypi_compare("1.2.3rc1", "1.2.3"), -1)
        self.assertEqual(self.m.pypi_compare("1.2.3a1", "1.2.3b1"), -1)
        self.assertEqual(self.m.pypi_compare("1.2.3.dev0", "1.2.3a1"), -1)

    def test_epoch_sorts_above(self):
        self.assertEqual(self.m.pypi_compare("1!1.0", "2.0"), 1)

    def test_local_version_stripped_for_ordering(self):
        self.assertEqual(self.m.pypi_compare("1.2.3+ubuntu1", "1.2.3"), 0)
        self.assertTrue(self.m.pypi_is_ga("1.2.3+ubuntu1"))

    def test_trailing_zero_release_equal(self):
        self.assertEqual(self.m.pypi_compare("1.0", "1.0.0"), 0)
        self.assertEqual(self.m.pypi_compare("1.2.0", "1.2"), 0)

    def test_compare_orders_numerically(self):
        self.assertEqual(self.m.pypi_compare("1.10.0", "1.9.0"), 1)
        self.assertEqual(self.m.pypi_compare("2.0.0", "10.0.0"), -1)

    def test_unparsable_returns_none_or_zero(self):
        self.assertIsNone(self.m.pypi_version_key("not-a-version"))
        self.assertFalse(self.m.pypi_is_ga("garbage"))
        self.assertEqual(self.m.pypi_compare("garbage", "1.0.0"), 0)

    def test_latest_ga_skips_prereleases(self):
        versions = ["1.0.0", "2.0.0rc1", "1.9.0", "1.10.0", "2.0.0.dev1"]
        self.assertEqual(self.m.pypi_latest_ga(versions), "1.10.0")

    def test_nearest_in_major(self):
        versions = ["2.20.0", "2.28.1", "2.31.0", "3.0.0"]
        self.assertEqual(self.m.pypi_nearest_in_major("2.20.0", versions), "2.31.0")
        self.assertEqual(self.m.pypi_nearest_in_major("3.0.0", versions), "3.0.0")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIVersionCoreTest -v`
Expected: FAIL — `AttributeError: module ... has no attribute 'pypi_is_ga'`.

- [ ] **Step 3: Implement the version core**

In `plugins/code-review-suite/bin/housekeeper-freshness`, after the `strip_constraint` function (the npm one, ~line 315) add:

```python
# --- PyPI version core (PEP 440) -------------------------------------------

_PYPI_VERSION_RE = re.compile(
    r"^\s*v?"
    r"(?:(?P<epoch>\d+)!)?"
    r"(?P<release>\d+(?:\.\d+)*)"
    r"(?:[-_.]?(?P<pre_l>a|b|c|rc|alpha|beta|pre|preview)[-_.]?(?P<pre_n>\d+)?)?"
    r"(?:(?:[-_.]?(?P<post_l>post|rev|r)[-_.]?(?P<post_n>\d+)?)|(?:-(?P<post_imp>\d+)))?"
    r"(?:[-_.]?(?P<dev_l>dev)[-_.]?(?P<dev_n>\d+)?)?"
    r"(?:\+(?P<local>[a-z0-9]+(?:[-_.][a-z0-9]+)*))?"
    r"\s*$",
    re.IGNORECASE,
)

_PYPI_PRE_ORDER = {"a": 0, "alpha": 0, "b": 1, "beta": 1,
                   "c": 2, "rc": 2, "pre": 2, "preview": 2}


def _pypi_parse(s):
    """Parse a PEP 440 version string into its components, or None. Release has
    trailing zeros stripped so 1.0 == 1.0.0. Local version segments are parsed
    but ignored for ordering."""
    if not s:
        return None
    m = _PYPI_VERSION_RE.match(s.strip())
    if not m:
        return None
    release = tuple(int(p) for p in m.group("release").split("."))
    while len(release) > 1 and release[-1] == 0:
        release = release[:-1]
    pre = None
    if m.group("pre_l"):
        pre = (_PYPI_PRE_ORDER[m.group("pre_l").lower()], int(m.group("pre_n") or 0))
    post = None
    if m.group("post_l"):
        post = int(m.group("post_n") or 0)
    elif m.group("post_imp"):
        post = int(m.group("post_imp"))
    dev = None
    if m.group("dev_l"):
        dev = int(m.group("dev_n") or 0)
    return {"epoch": int(m.group("epoch") or 0), "release": release,
            "pre": pre, "post": post, "dev": dev}


def _pypi_stage_key(p):
    """Phase-first ordering tuple for the post-release portion. The leading
    phase int decides across phases (so mismatched tuple shapes are never
    compared element-for-element); within a phase the shape is uniform.
    Order: dev-of-final < prerelease(.dev) < final < post(.dev)."""
    pre, post, dev = p["pre"], p["post"], p["dev"]
    if pre is None and post is None and dev is not None:
        return (0, dev)
    if pre is not None:
        if dev is not None:
            return (1, pre[0], pre[1], 0, dev)
        return (1, pre[0], pre[1], 1, 0)
    if post is None and dev is None:
        return (2,)
    if dev is not None:
        return (3, post, 0, dev)
    return (3, post, 1, 0)


def pypi_version_key(s):
    """Return a comparable PEP 440 sort key (epoch, release, stage), or None."""
    p = _pypi_parse(s)
    if p is None:
        return None
    return (p["epoch"], p["release"], _pypi_stage_key(p))


def pypi_is_ga(s):
    """True if s is a PEP 440 GA release: parseable, not a pre-release, not a
    dev-release. Post-releases ARE GA."""
    p = _pypi_parse(s)
    return p is not None and p["pre"] is None and p["dev"] is None


def pypi_compare(a, b):
    """-1/0/1 by PEP 440 ordering; 0 if either is unparsable."""
    ka, kb = pypi_version_key(a), pypi_version_key(b)
    if ka is None or kb is None:
        return 0
    return (ka > kb) - (ka < kb)


def pypi_latest_ga(versions):
    """Highest GA version, or None if none are GA."""
    ga = [v for v in versions if pypi_is_ga(v)]
    if not ga:
        return None
    return max(ga, key=pypi_version_key)


def pypi_nearest_in_major(current, versions):
    """Highest GA version sharing current's major; falls back to current."""
    cp = _pypi_parse(current)
    if cp is None:
        return current
    cur_major = cp["release"][0]
    same = []
    for v in versions:
        vp = _pypi_parse(v)
        if vp is not None and pypi_is_ga(v) and vp["release"][0] == cur_major:
            same.append(v)
    if not same:
        return current
    best = max(same, key=pypi_version_key)
    return best if pypi_compare(best, current) > 0 else current
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIVersionCoreTest -v`
Expected: PASS (10 tests).

- [ ] **Step 5: Run the full engine suite (no regressions)**

Run: `python3 -m unittest tests.python.test_housekeeper_engine -v`
Expected: PASS — all existing tests still green (the new `pypi_*` functions are additive).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): PEP 440 version core for PyPI source class"
git push
```

---

## Task 2: `pypi_strip_constraint` trust gate + PEP 508 name/spec splitter

Act on the floor of single-anchor forms (`==`, `===`, `~=`, `>=`, Poetry `^`/`~`, bare). Skip wildcards, comma-compound/upper-bounded ranges, `!=`, plain `<`/`>`/`<=`, and URL/VCS/path. Plus a PEP 508 splitter that strips extras and markers.

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (after the version core from Task 1)
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPIConstraintTest` class)

- [ ] **Step 1: Write the failing tests**

Append to the test file:

```python
class PyPIConstraintTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_strip_acts_on_single_anchor_floors(self):
        self.assertEqual(self.m.pypi_strip_constraint("==1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("===1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("~=1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint(">=1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("^1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("~1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("==2.0.0rc1"), "2.0.0rc1")

    def test_strip_skips_untrustworthy_forms(self):
        self.assertIsNone(self.m.pypi_strip_constraint("==1.2.*"))
        self.assertIsNone(self.m.pypi_strip_constraint("1.*"))
        self.assertIsNone(self.m.pypi_strip_constraint(">=1.2,<2"))
        self.assertIsNone(self.m.pypi_strip_constraint("!=1.2.3"))
        self.assertIsNone(self.m.pypi_strip_constraint("<2.0"))
        self.assertIsNone(self.m.pypi_strip_constraint(">1.2"))
        self.assertIsNone(self.m.pypi_strip_constraint("<=1.0"))
        self.assertIsNone(self.m.pypi_strip_constraint(""))
        self.assertIsNone(self.m.pypi_strip_constraint("git+https://x/y.git"))

    def test_pep508_splits_name_and_spec(self):
        self.assertEqual(self.m._pypi_pep508_name_spec("requests>=2.0"),
                         ("requests", ">=2.0"))
        self.assertEqual(self.m._pypi_pep508_name_spec("requests==2.28.1"),
                         ("requests", "==2.28.1"))

    def test_pep508_strips_extras_and_markers(self):
        self.assertEqual(
            self.m._pypi_pep508_name_spec('requests[security]>=2.0 ; python_version < "3.11"'),
            ("requests", ">=2.0"))
        self.assertEqual(self.m._pypi_pep508_name_spec("flask[async]==2.0.0"),
                         ("flask", "==2.0.0"))

    def test_pep508_url_reference_returns_none(self):
        self.assertIsNone(self.m._pypi_pep508_name_spec("foo @ git+https://x/y.git"))
        self.assertIsNone(self.m._pypi_pep508_name_spec(""))
        self.assertIsNone(self.m._pypi_pep508_name_spec("# a comment"))

    def test_pep508_bare_name_no_spec(self):
        self.assertEqual(self.m._pypi_pep508_name_spec("requests"), ("requests", ""))
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIConstraintTest -v`
Expected: FAIL — `pypi_strip_constraint` undefined.

- [ ] **Step 3: Implement**

In the engine, after the Task-1 version core, add:

```python
_PYPI_FLOOR_RE = re.compile(
    r"^(?:===|==|~=|>=|\^|~)?\s*v?"
    r"(\d+(?:\.\d+)*"
    r"(?:[-_.]?(?:a|b|c|rc|alpha|beta|pre|preview|post|rev|r|dev)[-_.]?\d*)*"
    r"(?:\+[a-z0-9]+(?:[-_.][a-z0-9]+)*)?)\s*$",
    re.IGNORECASE,
)


def pypi_strip_constraint(spec):
    """Return the concrete floor version of a single-anchor PyPI constraint, or
    None for any form we cannot name a trustworthy 'current' for: wildcards,
    comma-compound/upper-bounded ranges, != exclusions, bare </> /<=, and
    URL/VCS/path references. Acts on ==, ===, ~=, >=, Poetry ^/~, and bare."""
    if not spec:
        return None
    s = spec.strip()
    if not s:
        return None
    if "://" in s or s.startswith(("git+", "file:", ".", "/")):
        return None
    if "," in s or "!=" in s or "*" in s:
        return None
    if s.startswith(("<", ">")) and not s.startswith(">="):
        return None
    m = _PYPI_FLOOR_RE.match(s)
    if not m:
        return None
    ver = m.group(1)
    return ver if _pypi_parse(ver) is not None else None


def _pypi_pep508_name_spec(req):
    """Split a PEP 508 requirement string into (name, version_spec), or None.
    Strips a trailing environment marker (; ...) and an [extras] group. Returns
    None for blank/comment lines and direct URL references (name @ url)."""
    if not req:
        return None
    s = req.strip()
    if not s or s.startswith("#"):
        return None
    s = s.split(";", 1)[0].strip()
    if "@" in s:
        return None  # direct URL reference — no registry version
    m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*(.*)$", s)
    if not m:
        return None
    return m.group(1), m.group(2).strip()
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIConstraintTest -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): PyPI constraint trust gate + PEP 508 splitter"
git push
```

---

## Task 3: `parse_requirements`

Line-oriented parse of `requirements*.txt`. Skip blanks, comments, option lines (`-r`/`-c`/`-e`/`--*`), and URL/VCS/path entries. Emit `(name, spec, line)`.

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness`
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPIRequirementsParseTest` class)

- [ ] **Step 1: Write the failing tests**

```python
class PyPIRequirementsParseTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_parses_pinned_and_floored_lines(self):
        text = (
            "requests==2.28.1\n"
            "flask>=2.0\n"
            "django~=4.1.0\n"
        )
        out = self.m.parse_requirements(text)
        self.assertIn(("requests", "==2.28.1", 1), out)
        self.assertIn(("flask", ">=2.0", 2), out)
        self.assertIn(("django", "~=4.1.0", 3), out)

    def test_skips_comments_blanks_options_and_includes(self):
        text = (
            "# a comment\n"
            "\n"
            "-r base.txt\n"
            "-c constraints.txt\n"
            "-e .\n"
            "--index-url https://example/simple\n"
            "requests==2.28.1\n"
        )
        out = self.m.parse_requirements(text)
        self.assertEqual(out, [("requests", "==2.28.1", 7)])

    def test_strips_inline_comment_and_extras_and_marker(self):
        text = 'requests[security]==2.28.1  # pinned ; keep\n'
        out = self.m.parse_requirements(text)
        self.assertEqual(out, [("requests", "==2.28.1", 1)])

    def test_skips_url_and_vcs_entries(self):
        text = (
            "foo @ git+https://x/y.git\n"
            "https://example/pkg.whl\n"
        )
        self.assertEqual(self.m.parse_requirements(text), [])
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIRequirementsParseTest -v`
Expected: FAIL — `parse_requirements` undefined.

- [ ] **Step 3: Implement**

Add to the engine (after the Task-2 block):

```python
def parse_requirements(text):
    """Return [(name, spec, line)] from a requirements*.txt body. Skips blank
    lines, comments, option lines (-r/-c/-e/--flag), and URL/VCS/path entries.
    Inline '# comment' is stripped; extras and markers are dropped by the PEP
    508 splitter. One requirement per physical line."""
    out = []
    for i, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("-"):
            continue
        # Strip an inline comment (' #...'); keep '#' that is not preceded by ws.
        if " #" in line:
            line = line.split(" #", 1)[0].strip()
        ns = _pypi_pep508_name_spec(line)
        if ns is None:
            continue
        out.append((ns[0], ns[1], i))
    return out
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIRequirementsParseTest -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): requirements.txt parser for PyPI source"
git push
```

---

## Task 4: `parse_pyproject` (tomllib — PEP 621 + Poetry)

Parse `pyproject.toml` with stdlib `tomllib` (lazy import; returns `[]` on ImportError as belt-and-braces — the agent's tool-resolution is the user-facing ≥3.11 gate). Collect PEP 621 `[project].dependencies` + `[project.optional-dependencies]`, and Poetry `[tool.poetry.dependencies]` + group tables. Line numbers via a best-effort post-parse scan.

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness`
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPIProjectParseTest` class)

- [ ] **Step 1: Write the failing tests**

```python
class PyPIProjectParseTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_pep621_dependencies_and_optional(self):
        text = (
            "[project]\n"
            'name = "x"\n'
            "dependencies = [\n"
            '  "requests>=2.0",\n'
            '  "flask==2.0.0",\n'
            "]\n"
            "[project.optional-dependencies]\n"
            'dev = ["pytest==7.0.0"]\n'
        )
        out = self.m.parse_pyproject(text)
        names = {n: s for n, s, _ in out}
        self.assertEqual(names["requests"], ">=2.0")
        self.assertEqual(names["flask"], "==2.0.0")
        self.assertEqual(names["pytest"], "==7.0.0")

    def test_poetry_tables_and_python_skipped(self):
        text = (
            "[tool.poetry.dependencies]\n"
            'python = "^3.11"\n'
            'requests = "^2.28.0"\n'
            'flask = {version = "2.0.0", optional = true}\n'
            "[tool.poetry.group.dev.dependencies]\n"
            'pytest = "~7.0"\n'
        )
        out = self.m.parse_pyproject(text)
        names = {n: s for n, s, _ in out}
        self.assertNotIn("python", names)
        self.assertEqual(names["requests"], "^2.28.0")
        self.assertEqual(names["flask"], "2.0.0")
        self.assertEqual(names["pytest"], "~7.0")

    def test_line_numbers_point_at_declaration(self):
        text = (
            "[project]\n"
            "dependencies = [\n"
            '  "requests>=2.0",\n'
            "]\n"
        )
        out = self.m.parse_pyproject(text)
        self.assertEqual(out, [("requests", ">=2.0", 3)])

    def test_empty_or_no_deps_returns_empty(self):
        self.assertEqual(self.m.parse_pyproject('[project]\nname = "x"\n'), [])
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIProjectParseTest -v`
Expected: FAIL — `parse_pyproject` undefined.

- [ ] **Step 3: Implement**

Add to the engine:

```python
def parse_pyproject(text):
    """Return [(name, spec, line)] from a pyproject.toml: PEP 621
    [project].dependencies + [project.optional-dependencies], and Poetry
    [tool.poetry.dependencies] + [tool.poetry.group.<g>.dependencies]. Uses
    stdlib tomllib (lazy import; returns [] if unavailable — the agent gates on
    python>=3.11). tomllib discards line numbers, so each dependency's line is
    resolved by a best-effort first-occurrence scan for its name (one
    declaration per line assumed, consistent with the csproj/npm parsers)."""
    try:
        import tomllib
    except ImportError:
        return []
    try:
        data = tomllib.loads(text)
    except (ValueError, TypeError):
        return []
    lines = text.splitlines()

    def line_of(token):
        for i, ln in enumerate(lines, start=1):
            if token in ln:
                return i
        return 1

    out = []
    proj = data.get("project") or {}
    pep621 = list(proj.get("dependencies") or [])
    for grp in (proj.get("optional-dependencies") or {}).values():
        pep621.extend(grp or [])
    for dep in pep621:
        ns = _pypi_pep508_name_spec(dep)
        if ns is not None:
            out.append((ns[0], ns[1], line_of(ns[0])))

    poetry = (data.get("tool") or {}).get("poetry") or {}

    def poetry_table(tbl):
        for name, val in (tbl or {}).items():
            if name.lower() == "python":
                continue
            if isinstance(val, str):
                spec = val
            elif isinstance(val, dict):
                spec = val.get("version", "")
            else:
                spec = ""
            out.append((name, spec, line_of(name)))

    poetry_table(poetry.get("dependencies"))
    for grp in (poetry.get("group") or {}).values():
        poetry_table(grp.get("dependencies"))
    return out
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIProjectParseTest -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): pyproject.toml parser (PEP 621 + Poetry)"
git push
```

---

## Task 5: `Registry.pypi_releases` + fixture override

PyPI JSON API client with a `pypi/<slug>.json` fixture override (slug = PEP 503 normalised name). Returns the `releases` map (`{version: [file-records]}`) or `None`.

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add a method to `Registry`, and module-level `_pypi_normalize`)
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPIRegistryTest` class)

- [ ] **Step 1: Write the failing tests**

```python
class PyPIRegistryTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_normalize_pep503(self):
        self.assertEqual(self.m._pypi_normalize("Flask-SQLAlchemy"), "flask-sqlalchemy")
        self.assertEqual(self.m._pypi_normalize("zope.interface"), "zope-interface")
        self.assertEqual(self.m._pypi_normalize("ruamel_yaml"), "ruamel-yaml")

    def test_fixture_override_reads_releases(self):
        with tempfile.TemporaryDirectory() as d:
            fx = pathlib.Path(d) / "pypi"
            fx.mkdir()
            (fx / "requests.json").write_text(json.dumps({
                "info": {"version": "2.31.0"},
                "releases": {"2.28.1": [{"yanked": False}],
                             "2.31.0": [{"yanked": False}]},
            }))
            reg = self.m.Registry(fixtures_dir=d)
            rel = reg.pypi_releases("requests")
            self.assertIn("2.31.0", rel)
            self.assertEqual(rel["2.28.1"], [{"yanked": False}])

    def test_fixture_override_normalizes_slug(self):
        with tempfile.TemporaryDirectory() as d:
            fx = pathlib.Path(d) / "pypi"
            fx.mkdir()
            (fx / "flask-sqlalchemy.json").write_text(json.dumps({
                "releases": {"3.0.0": [{"yanked": False}]}}))
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIn("3.0.0", reg.pypi_releases("Flask-SQLAlchemy"))

    def test_fixture_miss_returns_none(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "pypi").mkdir()
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIsNone(reg.pypi_releases("nope"))
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIRegistryTest -v`
Expected: FAIL — `_pypi_normalize` / `pypi_releases` undefined.

- [ ] **Step 3: Implement**

Add a module-level helper near the other `_pypi_*` helpers:

```python
def _pypi_normalize(name):
    """PEP 503 project-name normalisation: lowercase, runs of [-_.] -> '-'."""
    return re.sub(r"[-_.]+", "-", name).lower()
```

Add this method to the `Registry` class (after `docker_tags`'s helpers, e.g. after `_docker_anon_token`):

```python
    # --- pypi (JSON API: releases map) -------------------------------------

    def pypi_releases(self, project):
        """Return the {version: [file-records]} releases map for a PyPI project,
        or None on any miss. Fixture mode reads <fixtures_dir>/pypi/<slug>.json
        (full JSON shape, slug = PEP 503 normalised name); live mode GETs
        https://pypi.org/pypi/<project>/json."""
        if self.fixtures_dir:
            slug = _pypi_normalize(project)
            path = os.path.join(self.fixtures_dir, "pypi", slug + ".json")
            try:
                with open(path, encoding="utf-8") as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                return None
            return doc.get("releases")
        doc = self.fetch("pypi", project,
                         "https://pypi.org/pypi/%s/json" % project)
        if not doc:
            return None
        return doc.get("releases")
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIRegistryTest -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): PyPI JSON registry client + fixture override"
git push
```

---

## Task 6: `collect_pypi` collector (freshness + yanked health)

Per manifest, per dependency: strip the constraint → fetch releases → exclude yanked from the target → compute latest GA, staleness, T3 target, and the yanked health rider. Emit the 10-key tuple (licence null this slice).

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness`
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPICollectTest` class)

- [ ] **Step 1: Write the failing tests**

```python
PYPI_REL = {
    "2.20.0": [{"yanked": False}],
    "2.28.1": [{"yanked": False}],
    "2.31.0": [{"yanked": False}],
    "3.0.0": [{"yanked": False}],
    "2.99.0": [{"yanked": True, "yanked_reason": "broken wheel"}],
}


class PyPICollectTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def _reg(self, releases):
        reg = self.m.Registry(fixtures_dir=None)
        reg.pypi_releases = lambda project: releases
        return reg

    def test_touched_line_targets_latest_ga(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(len(out), 1)
        f = out[0]
        self.assertEqual((f["source"], f["item"], f["current"], f["latest_ga"],
                          f["target"], f["file"], f["line"]),
                         ("pypi", "requests", "2.20.0", "3.0.0", "3.0.0",
                          "requirements.txt", 1))
        self.assertIsNone(f["health"])
        self.assertIsNone(f["licence_current"])

    def test_untouched_line_targets_nearest_in_major(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": set()}, reg)
        self.assertEqual(out[0]["target"], "2.31.0")  # nearest in major 2
        self.assertEqual(out[0]["latest_ga"], "3.0.0")

    def test_yanked_release_excluded_from_target(self):
        # latest non-yanked GA is 3.0.0; 2.99.0 (yanked) must not be the target.
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(out[0]["latest_ga"], "3.0.0")
        self.assertEqual(out[0]["target"], "3.0.0")

    def test_yanked_current_emits_health_rider(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.99.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(len(out), 1)
        f = out[0]
        self.assertEqual(f["health"], {"state": "yanked", "detail": "broken wheel"})
        self.assertEqual(f["current"], "2.99.0")
        self.assertEqual(f["target"], "3.0.0")  # stale AND yanked -> upgrade target

    def test_current_latest_but_yanked_is_pure_health(self):
        rel = {"3.0.0": [{"yanked": True, "yanked_reason": "security"}]}
        reg = self._reg(rel)
        # 3.0.0 is the only release and it is yanked -> no GA latest -> skip.
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==3.0.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(out, [])

    def test_pure_health_when_current_is_latest_ga_but_yanked(self):
        rel = {"2.0.0": [{"yanked": False}],
               "3.0.0": [{"yanked": True, "yanked_reason": "bad"}]}
        # current 3.0.0 is yanked (health) but the latest NON-yanked GA is 2.0.0,
        # which is not newer -> not stale -> pure-health, target == current.
        reg = self._reg(rel)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==3.0.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["health"]["state"], "yanked")
        self.assertEqual(out[0]["target"], "3.0.0")

    def test_not_stale_emits_nothing(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==3.0.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(out, [])

    def test_registry_miss_emits_nothing(self):
        reg = self._reg(None)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(out, [])

    def test_range_and_url_specs_skipped(self):
        reg = self._reg(PYPI_REL)
        text = "requests>=2.0,<3\nfoo @ git+https://x/y.git\n"
        out = self.m.collect_pypi({}, {"requirements.txt": text},
                                  {"requirements.txt": {1, 2}}, reg)
        self.assertEqual(out, [])

    def test_pyproject_source_routed_through_collector(self):
        reg = self._reg(PYPI_REL)
        text = ('[project]\ndependencies = [\n  "requests==2.20.0",\n]\n')
        out = self.m.collect_pypi({"pyproject.toml": text}, {},
                                  {"pyproject.toml": {3}}, reg)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["item"], "requests")
        self.assertEqual(out[0]["file"], "pyproject.toml")
        self.assertEqual(out[0]["line"], 3)
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPICollectTest -v`
Expected: FAIL — `collect_pypi` undefined.

- [ ] **Step 3: Implement**

Add to the engine:

```python
def _pypi_yanked(records):
    """True if a release's file records exist and are ALL yanked."""
    return bool(records) and all(r.get("yanked") for r in records)


def _pypi_yank_reason(records):
    """First non-empty yanked_reason among a release's records, or ''."""
    for r in records or []:
        if r.get("yanked") and r.get("yanked_reason"):
            return r["yanked_reason"]
    return ""


def collect_pypi(pyproject_text, requirements_text, changed_lines, registry):
    """pyproject_text / requirements_text map each in-scope manifest path -> its
    content. Emits a tuple per dependency that is stale OR yanked-current,
    comparing only non-yanked GA releases for the target. Licence is null this
    slice."""
    units = []
    for path, text in sorted(pyproject_text.items()):
        units.append((path, parse_pyproject(text)))
    for path, text in sorted(requirements_text.items()):
        units.append((path, parse_requirements(text)))

    findings = []
    for path, deps in units:
        touched = changed_lines.get(path, set())
        for name, spec, line in deps:
            current = pypi_strip_constraint(spec)
            if current is None:
                continue
            releases = registry.pypi_releases(name)
            if not releases:
                continue
            non_yanked = [v for v in releases if not _pypi_yanked(releases[v])]
            latest = pypi_latest_ga(non_yanked)
            if not latest:
                continue
            health = None
            cur_records = releases.get(current)
            if cur_records is not None and _pypi_yanked(cur_records):
                health = {"state": "yanked",
                          "detail": _pypi_yank_reason(cur_records)}
            stale = pypi_compare(latest, current) > 0
            if stale:
                if line in touched:
                    target = latest
                else:
                    target = pypi_nearest_in_major(current, non_yanked)
                    if pypi_compare(target, current) <= 0:
                        stale = False
            if not stale and health is None:
                continue
            if not stale:
                target = current
            findings.append({
                "source": "pypi", "item": name,
                "current": current, "latest_ga": latest, "target": target,
                "file": path, "line": line,
                "licence_current": None, "licence_latest": None,
                "health": health,
            })
    return findings
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPICollectTest -v`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): collect_pypi freshness + yanked health"
git push
```

---

## Task 7: `pypi_scope_roots` + `_PYPI_SCOPE_SUFFIXES`

A changed `.py`/`.pyi` walks up to its nearest-ancestor `pyproject.toml`; a directly-changed manifest is always in scope; a source file with no pyproject ancestor falls back to its nearest-ancestor `requirements*.txt`.

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness`
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPIScopeTest` class)

- [ ] **Step 1: Write the failing tests**

```python
class PyPIScopeTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_py_pulls_in_nearest_pyproject(self):
        pj, rq = self.m.pypi_scope_roots(
            ["pkg/app/module.py"],
            {"pyproject.toml", "pkg/app/pyproject.toml"}, set())
        self.assertEqual(pj, {"pkg/app/pyproject.toml"})
        self.assertEqual(rq, set())

    def test_pyi_stub_pulls_in_pyproject(self):
        pj, _ = self.m.pypi_scope_roots(
            ["pkg/types.pyi"], {"pkg/pyproject.toml"}, set())
        self.assertEqual(pj, {"pkg/pyproject.toml"})

    def test_directly_changed_pyproject_in_scope(self):
        pj, _ = self.m.pypi_scope_roots(
            ["pyproject.toml"], {"pyproject.toml"}, set())
        self.assertEqual(pj, {"pyproject.toml"})

    def test_directly_changed_requirements_in_scope(self):
        _, rq = self.m.pypi_scope_roots(
            ["requirements.txt"], set(), {"requirements.txt"})
        self.assertEqual(rq, {"requirements.txt"})
        _, rq2 = self.m.pypi_scope_roots(
            ["requirements-dev.txt"], set(), {"requirements-dev.txt"})
        self.assertEqual(rq2, {"requirements-dev.txt"})

    def test_source_with_no_pyproject_falls_back_to_requirements(self):
        pj, rq = self.m.pypi_scope_roots(
            ["svc/handler.py"], set(), {"svc/requirements.txt"})
        self.assertEqual(pj, set())
        self.assertEqual(rq, {"svc/requirements.txt"})

    def test_pyproject_wins_over_requirements_when_both_present(self):
        pj, rq = self.m.pypi_scope_roots(
            ["svc/handler.py"],
            {"svc/pyproject.toml"}, {"svc/requirements.txt"})
        self.assertEqual(pj, {"svc/pyproject.toml"})
        self.assertEqual(rq, set())

    def test_non_python_file_pulls_nothing(self):
        pj, rq = self.m.pypi_scope_roots(
            ["svc/README.md"], {"svc/pyproject.toml"}, {"svc/requirements.txt"})
        self.assertEqual((pj, rq), (set(), set()))

    def test_prefix_collision_does_not_cross_sibling_dirs(self):
        pj, _ = self.m.pypi_scope_roots(
            ["src/AppTests/test_x.py"],
            {"src/App/pyproject.toml", "src/AppTests/pyproject.toml"}, set())
        self.assertEqual(pj, {"src/AppTests/pyproject.toml"})
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIScopeTest -v`
Expected: FAIL — `pypi_scope_roots` undefined.

- [ ] **Step 3: Implement**

Add to the engine (near the other scope resolvers; reuses the existing `_dirname` / `_dir_is_ancestor_or_same`):

```python
# Source extensions that pull in their nearest-ancestor pyproject.toml (the T1
# Python solution gate). Mirror in the Step 2.6 trigger prose + sync test.
_PYPI_SCOPE_SUFFIXES = (".py", ".pyi")


def _is_requirements_file(base):
    """True if a basename is a requirements*.txt pin file."""
    return base.startswith("requirements") and base.endswith(".txt")


def _nearest_ancestor(fdir, manifests):
    """Deepest manifest whose directory is an ancestor-or-same of fdir, or None."""
    best = None
    best_dir = None
    for man in manifests:
        mdir = _dirname(man)
        if _dir_is_ancestor_or_same(mdir, fdir):
            if best is None or len(mdir) > len(best_dir):
                best, best_dir = man, mdir
    return best


def pypi_scope_roots(changed_files, all_pyprojects, all_requirements):
    """Return (in_scope_pyprojects, in_scope_requirements).

    A directly-changed pyproject.toml / requirements*.txt is always in scope. A
    changed .py/.pyi walks up to its nearest-ancestor pyproject.toml; if none
    exists, it falls back to its nearest-ancestor requirements*.txt (so a
    requirements-only project gets the same source-pull-in symmetry)."""
    pyprojects = set()
    requirements = set()
    for f in changed_files:
        base = f.rsplit("/", 1)[-1]
        if base == "pyproject.toml" and f in all_pyprojects:
            pyprojects.add(f)
            continue
        if _is_requirements_file(base) and f in all_requirements:
            requirements.add(f)
            continue
        if not f.endswith(_PYPI_SCOPE_SUFFIXES):
            continue
        fdir = _dirname(f)
        pj = _nearest_ancestor(fdir, all_pyprojects)
        if pj is not None:
            pyprojects.add(pj)
            continue
        rq = _nearest_ancestor(fdir, all_requirements)
        if rq is not None:
            requirements.add(rq)
    return pyprojects, requirements
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIScopeTest -v`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): PyPI scope resolver (.py/.pyi + requirements fallback)"
git push
```

---

## Task 8: Wire PyPI into `collect_findings`

Discover `pyproject.toml` + `requirements*.txt` in the `os.walk`, extend the prune set, resolve PyPI scope, read manifests, append `collect_pypi`. Also refresh the engine's module docstring to list all six sources.

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness:1017-1082` (`collect_findings`) and the module docstring (lines 1-7)
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPIWiringTest` class)

- [ ] **Step 1: Write the failing test**

```python
class PyPIWiringTest(unittest.TestCase):
    """Drives the engine as a subprocess against an on-disk tree with a recorded
    pypi fixture, proving collect_findings wires pypi in and that a SOURCE-only
    change pulls in its unit's pyproject.toml."""
    def _tree(self, d, requirements=False):
        root = pathlib.Path(d)
        (root / "pkg/app").mkdir(parents=True)
        (root / "pkg/app/module.py").write_text("x = 1\n")
        if requirements:
            (root / "pkg/app/requirements.txt").write_text("requests==2.20.0\n")
        else:
            (root / "pkg/app/pyproject.toml").write_text(
                '[project]\nname = "app"\ndependencies = [\n  "requests==2.20.0",\n]\n')
        fx = root / "registry/pypi"
        fx.mkdir(parents=True)
        (fx / "requests.json").write_text(json.dumps({
            "info": {"version": "2.31.0"},
            "releases": {"2.20.0": [{"yanked": False}],
                         "2.28.1": [{"yanked": False}],
                         "2.31.0": [{"yanked": False}]}}))
        return root

    def _run(self, root, changed):
        with tempfile.TemporaryDirectory() as t:
            files = pathlib.Path(t) / "files.txt"
            lines = pathlib.Path(t) / "lines.txt"
            files.write_text("".join(c + "\n" for c in changed))
            lines.write_text("Changed lines:\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE), "--root", str(root),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines),
                 "--registry-fixtures", str(root / "registry")],
                capture_output=True, text=True, check=True)
            return [f for f in json.loads(out.stdout) if f["source"] == "pypi"]

    def test_source_only_change_pulls_in_pyproject(self):
        with tempfile.TemporaryDirectory() as d:
            root = self._tree(d)
            pypi = self._run(root, ["pkg/app/module.py"])
            self.assertEqual(len(pypi), 1)
            self.assertEqual(pypi[0]["item"], "requests")
            self.assertEqual(pypi[0]["current"], "2.20.0")
            self.assertEqual(pypi[0]["latest_ga"], "2.31.0")
            self.assertEqual(pypi[0]["target"], "2.31.0")  # untouched -> nearest in major 2

    def test_source_only_change_pulls_in_requirements(self):
        with tempfile.TemporaryDirectory() as d:
            root = self._tree(d, requirements=True)
            pypi = self._run(root, ["pkg/app/module.py"])
            self.assertEqual(len(pypi), 1)
            self.assertEqual(pypi[0]["file"], "pkg/app/requirements.txt")
            self.assertEqual(pypi[0]["item"], "requests")
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIWiringTest -v`
Expected: FAIL — `pypi` source not present in output (collect_pypi not wired).

- [ ] **Step 3: Implement the wiring**

In `collect_findings`, extend the discovery loop. Change the prune line (currently `for prune in ("node_modules", "bin", "obj"):`) to:

```python
        for prune in ("node_modules", "bin", "obj",
                      ".venv", "__pycache__", ".tox", ".eggs"):
```

Add discovery sets. After `all_dockerfiles = set()` add:

```python
    all_pyprojects = set()
    all_requirements = set()
```

Inside the `for nm in names:` loop (after the dockerfile check), add:

```python
            if nm == "pyproject.toml":
                all_pyprojects.add(rel)
            elif nm.startswith("requirements") and nm.endswith(".txt"):
                all_requirements.add(rel)
```

After the docker scope/read block (after `dockerfile_text` is built), add:

```python
    pypi_pyprojects, pypi_requirements = pypi_scope_roots(
        changed_files, all_pyprojects, all_requirements)
    pyproject_text = {p: read(p) for p in pypi_pyprojects}
    pyproject_text = {p: t for p, t in pyproject_text.items() if t is not None}
    requirements_text = {p: read(p) for p in pypi_requirements}
    requirements_text = {p: t for p, t in requirements_text.items() if t is not None}
```

In the `findings +=` block, after the `collect_docker` line add:

```python
    findings += collect_pypi(pyproject_text, requirements_text, changed_lines, registry)
```

Update the module docstring (lines 4-6) to read:

```python
"""housekeeper-freshness — deterministic dependency/version freshness engine.

Emits a JSON array of stale-version tuples for the code-review-suite
housekeeper specialist. Pure-stdlib (pyproject parsing needs tomllib, 3.11+).
Source classes: github-actions, runner, npm, nuget, docker, pypi. See
agents/housekeeper-reviewer.md.
"""
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIWiringTest -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full engine suite**

Run: `python3 -m unittest tests.python.test_housekeeper_engine -v`
Expected: PASS — all classes green, no regressions in the other five sources.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): wire PyPI into collect_findings"
git push
```

---

## Task 9: On-disk regression fixture

A committed fixture tree proving Anchor pull-in on disk: a `.py`-only changeset surfaces the `pyproject.toml` stale-dep finding. Mirrors the slice-3 `housekeeper-docker` fixture layout.

**Files:**
- Create: `tests/fixtures/static-analysis/housekeeper-pypi/pkg/app/module.py`
- Create: `tests/fixtures/static-analysis/housekeeper-pypi/pkg/app/pyproject.toml`
- Create: `tests/fixtures/static-analysis/housekeeper-pypi/registry/pypi/requests.json`
- Test: `tests/python/test_housekeeper_engine.py` (new `PyPIOnDiskFixtureTest` class)

- [ ] **Step 1: Create the fixture files**

`tests/fixtures/static-analysis/housekeeper-pypi/pkg/app/module.py`:
```python
def handler():
    return "ok"
```

`tests/fixtures/static-analysis/housekeeper-pypi/pkg/app/pyproject.toml`:
```toml
[project]
name = "app"
version = "0.1.0"
dependencies = [
  "requests==2.20.0",
]
```

`tests/fixtures/static-analysis/housekeeper-pypi/registry/pypi/requests.json`:
```json
{"info": {"version": "2.31.0"}, "releases": {"2.20.0": [{"yanked": false}], "2.28.1": [{"yanked": false}], "2.31.0": [{"yanked": false}]}}
```

- [ ] **Step 2: Write the test**

```python
class PyPIOnDiskFixtureTest(unittest.TestCase):
    def test_source_only_change_surfaces_pyproject_finding(self):
        fixtures = REPO / "tests/fixtures/static-analysis/housekeeper-pypi"
        if not fixtures.exists():
            self.skipTest("housekeeper-pypi fixture not yet created")
        with tempfile.TemporaryDirectory() as d:
            files = pathlib.Path(d) / "files.txt"
            lines = pathlib.Path(d) / "lines.txt"
            files.write_text("pkg/app/module.py\n")  # source only, no manifest
            lines.write_text("Changed lines:\n")
            env = dict(os.environ,
                       HOUSEKEEPER_REGISTRY_FIXTURES=str(fixtures / "registry"))
            out = subprocess.run(
                [sys.executable, str(ENGINE), "--root", str(fixtures),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines)],
                capture_output=True, text=True, check=True, env=env)
            pypi = [f for f in json.loads(out.stdout) if f["source"] == "pypi"]
            self.assertEqual(len(pypi), 1)
            self.assertEqual(pypi[0]["item"], "requests")
            self.assertEqual(pypi[0]["file"], "pkg/app/pyproject.toml")
            self.assertEqual(pypi[0]["current"], "2.20.0")
            self.assertEqual(pypi[0]["target"], "2.31.0")  # untouched -> nearest in major
```

- [ ] **Step 3: Run to verify pass**

Run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIOnDiskFixtureTest -v`
Expected: PASS (1 test).

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/static-analysis/housekeeper-pypi tests/python/test_housekeeper_engine.py
git commit -m "test(housekeeper): on-disk PyPI fixture proving Anchor pull-in"
git push
```

---

## Task 10: Agent renderer — `pypi` rule + worked example

Add `pypi` to the `Rule:` enumeration, a `tomllib` probe to tool-resolution (the ≥3.11 hard-require gate), and a `pypi` `### Finding` block (stale pin + yanked-current) to the worked example.

**Files:**
- Modify: `plugins/code-review-suite/agents/housekeeper-reviewer.md`

- [ ] **Step 1: Add the ≥3.11 tomllib gate to tool resolution**

In the "## Tool resolution" section (after the `python3 --version` sentence, before the engine-on-PATH check), add:

```markdown
Then confirm TOML parsing is available (PyPI manifests need it): run `python3 -c "import tomllib"`. If it exits non-zero, emit `Skipped — python3 ≥3.11 required (PyPI TOML parsing).` and stop.
```

- [ ] **Step 2: Add `pypi` to the Rule enumeration**

In the "## Output" section, change the `Rule:` bullet's source list from:
```
(`github-actions`, `runner`, `npm`, `nuget`, or `docker`).
```
to:
```
(`github-actions`, `runner`, `npm`, `nuget`, `docker`, or `pypi`).
```

- [ ] **Step 3: Extend the worked example**

In the "### Worked example" prose sentence, extend the diff description to also mention pyproject (insert before "the canonical §7 output is:"):
```
, and `pyproject.toml` (a `requests==2.20.0` on untouched line 4 where latest GA is `2.31.0`, plus a yanked-current `urllib3==2.0.6`)
```

In the fenced canonical output block, after the `### Finding — node behind latest GA` block, add two PyPI findings:

```
### Finding — requests behind latest GA
- **File:** pyproject.toml:4
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/pypi
- **Description:** requests is at 2.20.0; latest GA is 2.31.0.
- **Suggested fix:** Upgrade requests to 2.28.1.

### Finding — urllib3 marked yanked
- **File:** pyproject.toml:5
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/pypi
- **Description:** urllib3 is at 2.0.6; latest GA is 2.0.6. Marked yanked in the registry: CVE-2023-45803.
- **Suggested fix:** Review: urllib3 is current but marked yanked.
```

(The `requests` target is `2.28.1` — nearest in major 2 for an untouched line, matching the engine's T3 rule. The yanked block exercises the pure-health render path: `target == current`, so the "Review:" fix fires.)

- [ ] **Step 4: Verify the agent file parses (frontmatter intact, em-dash headings)**

Run: `grep -c "### Finding —" plugins/code-review-suite/agents/housekeeper-reviewer.md`
Expected: `8` (the six pre-existing finding blocks + two new PyPI blocks).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/agents/housekeeper-reviewer.md
git commit -m "feat(housekeeper): render pypi findings + 3.11 tomllib gate"
git push
```

---

## Task 11: Trigger lockstep + sync test

Extend the Step 2.6 "Housekeeping detection" bullet byte-identically across the three synced files to name `.py`/`.pyi` source suffixes and `pyproject.toml`/`requirements*.txt` manifests, and extend the sync test to pin the new suffixes against `_PYPI_SCOPE_SUFFIXES`.

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md:693`
- Modify: `plugins/code-review-suite/commands/pre-review.md:694`
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md:799`
- Modify: `tests/lib/test_sync_notes.sh:1349`

- [ ] **Step 1: Update the trigger bullet in all three files (byte-identical)**

In each of the three files, replace the existing "Housekeeping detection:" bullet with the version below. The change: add `pyproject.toml`/`requirements*.txt` manifests, add the `.py`/`.pyi` source clause, and update the parenthetical slice list. Apply the IDENTICAL replacement text to all three (the sync-note parity test requires byte-identical bullets).

New bullet text (single line):
```
   - **Housekeeping detection:** if any changed file is under `.github/workflows/` and ends `.yml`/`.yaml`; is a `package.json` (npm manifest); ends `.csproj`/`.fsproj`/`.vbproj`/`.props`/`.targets`; is a `packages.lock.json` (NuGet manifest); is a `pyproject.toml` or `requirements*.txt` (PyPI manifest); is a .NET source file ending `.cs`/`.fs`/`.vb`/`.razor`/`.cshtml`; is an npm source file ending `.ts`/`.tsx`/`.js`/`.jsx`/`.mjs`/`.cjs`/`.mts`/`.cts`/`.vue`/`.svelte`; is a Python source file ending `.py`/`.pyi`; or is a Dockerfile (basename `Dockerfile`, `Dockerfile.*`, or ending `.dockerfile`), set `$HOUSEKEEPING_DETECTED = true`. The source-file extensions mirror the engine's `_NUGET_SCOPE_SUFFIXES`/`_NPM_SCOPE_SUFFIXES`/`_PYPI_SCOPE_SUFFIXES` scope sets, and Dockerfiles mirror the engine's `_is_dockerfile` gate: a changed source file pulls in its nearest-ancestor project (and that project's Dockerfile) and the engine audits all that project's dependencies and base images (not only changed manifest lines). (This slice covers GitHub Actions, workflow runners, npm, NuGet, Docker base images, and PyPI; follow-on plans extend both the engine scope sets and this trigger in lockstep for crates/Go/RubyGems/SDK.)
```

- [ ] **Step 2: Extend the sync test to pin the Python suffixes**

In `tests/lib/test_sync_notes.sh`, in `test_housekeeping_trigger_mirrors_engine_scope`, change the `for ext in` loop (line ~1349) to add `.py` and `.pyi`:

```bash
    for ext in .cs .fs .vb .razor .cshtml .ts .tsx .js .jsx .mjs .cjs .mts .cts .vue .svelte .py .pyi; do
```

- [ ] **Step 3: Run the sync-note tests**

Run: `bash tests/lib/test_sync_notes.sh`
Expected: PASS — `housekeeping trigger mirrors engine scope: all source extensions present in prose and engine`, and the existing prose-parity (byte-identical across three files) tests stay green.

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md tests/lib/test_sync_notes.sh
git commit -m "feat(housekeeper): PyPI trigger lockstep + sync test"
git push
```

---

## Task 12: README specialist table + prose

Add PyPI (and fold in Docker, which shipped without a README mention) to the specialist row and the surrounding prose.

**Files:**
- Modify: `plugins/code-review-suite/README.md` (lines ~35, ~43-45, ~78, ~109)

- [ ] **Step 1: Update the intro prose (line ~35)**

Change:
```
`housekeeper-reviewer` (dependency/version freshness + maintenance-health: GitHub Actions,
workflow runners, npm, NuGet).
```
to:
```
`housekeeper-reviewer` (dependency/version freshness + maintenance-health: GitHub Actions,
workflow runners, npm, NuGet, Docker base images, PyPI).
```

- [ ] **Step 2: Update the version-freshness rule prose (line ~43)**

Change:
```
The `housekeeper-reviewer` verifies against the live registry that dependencies (npm +
NuGet), GitHub Actions, and runners are at their latest GA release, and flags packages the
registry marks deprecated or unlisted (maintenance-health).
```
to:
```
The `housekeeper-reviewer` verifies against the live registry that dependencies (npm,
NuGet, PyPI), GitHub Actions, runners, and Docker base images are at their latest GA
release, and flags packages the registry marks deprecated, unlisted, or yanked
(maintenance-health).
```

- [ ] **Step 3: Update the specialist table row (line ~78)**

Change the `housekeeper-reviewer` row to:
```
| `housekeeper-reviewer` | Dependency/version freshness + maintenance-health — flags GitHub Actions, workflow runners, npm, NuGet, Docker base images, and PyPI packages behind latest GA or marked deprecated/unlisted/yanked (conditional — workflows + `package.json` + `*.csproj`/`*.props` + `pyproject.toml`/`requirements*.txt` + Dockerfiles; registry-backed deterministic engine) |
```

- [ ] **Step 4: Update the prerequisites note (line ~109)**

Change:
```
- `python3` — required for the `housekeeper-reviewer` dependency-freshness engine (`bin/housekeeper-freshness`). Stdlib only; no pip packages. Live runs need outbound HTTPS to npm and the GitHub API.
```
to:
```
- `python3` (≥3.11 for PyPI `pyproject.toml` parsing via `tomllib`) — required for the `housekeeper-reviewer` dependency-freshness engine (`bin/housekeeper-freshness`). Stdlib only; no pip packages. Live runs need outbound HTTPS to npm, PyPI, container registries, and the GitHub API.
```

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/README.md
git commit -m "docs(housekeeper): README PyPI + Docker specialist coverage"
git push
```

---

## Task 13: Single-arm A/B corpus + config + index row

Build the haiku/low recorded-fixture corpus. **Live-honesty:** pick a real package at a real old pin whose latest GA is unambiguously higher, and a genuinely-yanked release — the harness scrubs subprocess env so a live sweep hits real pypi.org.

> **Suggested live-honest choices** (verify against live pypi.org during Task 14 before the sweep): `requests==2.20.0` (latest GA well above 2.x), and the genuinely-yanked `urllib3==2.0.6` (yanked for CVE-2023-45803). If either is no longer behind / no longer yanked at sweep time, pick another real stale/yanked pin and update the expected files in lockstep.

**Files:**
- Create: `tests/ab/corpus/housekeeper-pypi-stale-deps/source.yaml`
- Create: `tests/ab/corpus/housekeeper-pypi-stale-deps/diff/changed-lines.txt`
- Create: `tests/ab/corpus/housekeeper-pypi-stale-deps/expected/findings.json`
- Create: `tests/ab/corpus/housekeeper-pypi-stale-deps/expected/findings-housekeeper.md`
- Create: `tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml`
- Modify: `tests/ab/corpus/index.yaml`
- Also reuse the on-disk fixture from Task 9 as the corpus `source_path` (it already contains `registry/pypi/requests.json`); add a yanked package fixture for the health finding.

- [ ] **Step 1: Add a yanked-package registry fixture + a second dep to the Task-9 fixture**

Append a yanked dep to `tests/fixtures/static-analysis/housekeeper-pypi/pkg/app/pyproject.toml` so the corpus exercises both freshness and the yanked rider. New file content:
```toml
[project]
name = "app"
version = "0.1.0"
dependencies = [
  "requests==2.20.0",
  "urllib3==2.0.6",
]
```

Create `tests/fixtures/static-analysis/housekeeper-pypi/registry/pypi/urllib3.json`:
```json
{"info": {"version": "2.2.1"}, "releases": {"2.0.6": [{"yanked": true, "yanked_reason": "CVE-2023-45803"}], "2.0.7": [{"yanked": false}], "2.2.1": [{"yanked": false}]}}
```

Note: with this fixture, `urllib3==2.0.6` is yanked (health) AND stale (2.2.1 exists). For an **untouched** line the target is nearest-in-major 2 (`2.2.1`); the health rider rides along. Update the Task-9 `PyPIOnDiskFixtureTest` if it asserts a single finding — it now returns 2 (requests + urllib3). Adjust that assertion:

```python
            self.assertEqual(len(pypi), 2)
            items = {f["item"]: f for f in pypi}
            self.assertEqual(items["requests"]["target"], "2.31.0")
            self.assertEqual(items["urllib3"]["health"]["state"], "yanked")
```

(The `requests.json` fixture from Task 9 must include a 2.31.0 release; if you used the Task-9 content verbatim it does. The `latest_ga` for requests is whatever the fixture's highest non-yanked GA is — keep the fixture's highest at `2.31.0` so the expected files below are correct.)

Re-run: `python3 -m unittest tests.python.test_housekeeper_engine.PyPIOnDiskFixtureTest -v` → PASS.

- [ ] **Step 2: Create the corpus `source.yaml`**

`tests/ab/corpus/housekeeper-pypi-stale-deps/source.yaml` (mirror the docker corpus; set `suite_sha` to the current `main` HEAD — get it via `git rev-parse HEAD` before writing):
```yaml
id: housekeeper-pypi-stale-deps
agent: housekeeper-reviewer
captured_at: 2026-06-12T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: <CURRENT_MAIN_HEAD_SHA>
  agent_model: haiku
  agent_effort: low
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/housekeeper-pypi/
base_sha: ""  # synthetic fixture: no real diff
head_sha: ""
path_scope: ""
empty_tree_mode: false
registry_fixtures: registry/   # INERT marker (env-scrubbed harness); a live sweep hits real registries
intent_ledger: |
  ## Intent ledger
  - Synthetic PyPI fixture exercising housekeeper-reviewer against a pyproject.toml
    pulled in via Anchor scope by a .py-only change. Two deterministic Suggestion
    findings: requests==2.20.0 stale (untouched line -> nearest-in-major 2.31.0),
    and urllib3==2.0.6 stale-and-yanked (yanked health rider; CVE-2023-45803).
    Slice-4 single-arm Haiku/low validation corpus.
depends_on:
  - plugins/code-review-suite/agents/housekeeper-reviewer.md
  - plugins/code-review-suite/bin/housekeeper-freshness
  - plugins/code-review-suite/includes/static-analysis-context.md
  - tests/fixtures/static-analysis/housekeeper-pypi/pkg/app/pyproject.toml
  - tests/fixtures/static-analysis/housekeeper-pypi/registry/pypi/requests.json
  - tests/fixtures/static-analysis/housekeeper-pypi/registry/pypi/urllib3.json
```

- [ ] **Step 3: Create `diff/changed-lines.txt`**

`tests/ab/corpus/housekeeper-pypi-stale-deps/diff/changed-lines.txt`:
```
Changed lines:
  pkg/app/module.py: 1
```

- [ ] **Step 4: Create `expected/findings.json`**

Determine the deterministic ordering (engine sorts by `file, line, source, item`). Both findings are in `pkg/app/pyproject.toml`; `requests` is line 4, `urllib3` is line 5. So order is requests (line 4) then urllib3 (line 5).

`tests/ab/corpus/housekeeper-pypi-stale-deps/expected/findings.json`:
```json
[{"file":"pkg/app/pyproject.toml","line":4,"rule_id":"housekeeper/pypi","severity":"Suggestion","confidence":100},{"file":"pkg/app/pyproject.toml","line":5,"rule_id":"housekeeper/pypi","severity":"Suggestion","confidence":100}]
```

- [ ] **Step 5: Create `expected/findings-housekeeper.md`**

If the Write tool refuses (subagent Write-guard false-positive), Write to `$CLAUDE_TEMP_DIR/findings-housekeeper.md` then `cp` it into place.

`tests/ab/corpus/housekeeper-pypi-stale-deps/expected/findings-housekeeper.md`:
```
## Housekeeper Findings

### Finding — requests behind latest GA
- **File:** pkg/app/pyproject.toml:4
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/pypi
- **Description:** requests is at 2.20.0; latest GA is 2.31.0.
- **Suggested fix:** Upgrade requests to 2.31.0.

### Finding — urllib3 marked yanked
- **File:** pkg/app/pyproject.toml:5
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/pypi
- **Description:** urllib3 is at 2.0.6; latest GA is 2.2.1. Marked yanked in the registry: CVE-2023-45803.
- **Suggested fix:** Upgrade urllib3 to 2.2.1.
```

(Both lines are untouched — the `.py` change is the only diff — so `requests` targets nearest-in-major 2 = `2.31.0` and `urllib3` targets nearest-in-major 2 = `2.2.1`. urllib3 is stale AND yanked, so it gets a normal upgrade fix, not the pure-health "Review:" form. The Description appends the yanked clause because `health` is non-null.)

> Verify this expected output against the actual engine before committing: run the engine over the fixture (Task 9 invocation) and confirm the rendered tuples match. If the engine's `latest_ga`/`target` differ from the values above, update these expected files to match the engine (the engine is the oracle).

- [ ] **Step 6: Create the A/B config**

`tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml`:
```yaml
name: housekeeper-pypi-haiku-low
description: Slice-4 single-arm validation — housekeeper-reviewer at Haiku/low on the PyPI corpus. No sonnet baseline (chassis equivalence settled); 20/20 recorded-fixture sweep guards apparatus determinism.
mode: per-agent
agent: housekeeper-reviewer
session:
  model: haiku
  effort: low
```

(Match the exact key structure of `housekeeper-docker-haiku-low.yaml` — re-read it if unsure.)

- [ ] **Step 7: Add the corpus index row**

In `tests/ab/corpus/index.yaml`, append under `fixtures:`:
```yaml
  - id: housekeeper-pypi-stale-deps
    agent: housekeeper-reviewer
    type: synthetic
    description: Two-finding PyPI set (requests 2.20.0->2.31.0 stale via Anchor pull-in by a .py-only change; urllib3 2.0.6 stale-and-yanked health rider) via recorded PyPI JSON fixtures. Slice-4 baseline.
    tags: [smoke, deterministic]
```

- [ ] **Step 8: Validate the engine output matches the expected files**

Run the engine over the corpus fixture and eyeball the tuples against `expected/findings.json` + `findings-housekeeper.md`:

Run:
```bash
python3 plugins/code-review-suite/bin/housekeeper-freshness --root tests/fixtures/static-analysis/housekeeper-pypi --changed-files-from /dev/stdin --changed-lines-from tests/ab/corpus/housekeeper-pypi-stale-deps/diff/changed-lines.txt --registry-fixtures tests/fixtures/static-analysis/housekeeper-pypi/registry <<<'pkg/app/module.py'
```
(Heredoc/`<<<` is disallowed by the Bash hook — instead Write `pkg/app/module.py\n` to `$CLAUDE_TEMP_DIR/files.txt` and pass `--changed-files-from $CLAUDE_TEMP_DIR/files.txt`.)
Expected: two `"source":"pypi"` tuples, requests then urllib3, matching the expected files. If not, fix the expected files (engine is the oracle).

- [ ] **Step 9: Commit**

```bash
git add tests/ab/corpus/housekeeper-pypi-stale-deps tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml tests/ab/corpus/index.yaml tests/fixtures/static-analysis/housekeeper-pypi tests/python/test_housekeeper_engine.py
git commit -m "test(ab): housekeeper PyPI single-arm haiku/low corpus + config + index"
git push
```

---

## Task 14: Full verification + push

- [ ] **Step 1: Run the full engine unittest suite**

Run: `python3 -m unittest tests.python.test_housekeeper_engine -v`
Expected: PASS — all classes green (existing five sources + all new PyPI classes).

- [ ] **Step 2: Run the full structural suite**

Run: `bash tests/run.sh`
Expected: green. (If the `A/B run.sh: bad-config rejection leaves working tree clean` test false-fails, ensure the tree is committed first, then re-run — it passes on a clean tree. Expect the documented pre-existing skip count.)

- [ ] **Step 3: Confirm everything is committed and pushed**

Run: `git status`
Expected: clean working tree, `main` up to date with origin.

Run: `git log --oneline -12`
Expected: the Task 1–13 commits present on `main`.

- [ ] **Step 4: Live spot-check the corpus packages are genuinely behind/yanked**

Before the sweep, confirm live-honesty (the sweep hits real pypi.org). Write a small probe script to `$CLAUDE_TEMP_DIR/probe.py` that fetches `https://pypi.org/pypi/requests/json` and `https://pypi.org/pypi/urllib3/json` and prints the latest GA + whether `2.0.6` of urllib3 is yanked, then run it with `python3 $CLAUDE_TEMP_DIR/probe.py`. Confirm `requests` latest GA ≫ 2.20.0 and `urllib3==2.0.6` is yanked. If either no longer holds, update the corpus pins + expected files (Task 13) before sweeping.

---

## Task 15: A/B sweep (MANUAL, INTERACTIVE — not a subagent task)

> This step CANNOT be subagent-run. Execute it interactively in the main session after Task 14, per every prior slice.

- [ ] **Step 1: Refresh the plugin cache** (the sweep exercises the engine BINARY; a stale cache captures the pre-PyPI engine).
  - `/plugins update` (refreshes DISK from GitHub)
  - then `/reload-plugins` (reloads in-memory registry from disk)

- [ ] **Step 2: Confirm the corpus is in `tests/ab/corpus/index.yaml`** (the harness gates `fixture_load` on the index).

- [ ] **Step 3: Drive the sweep** (run `run_in_background: true`):
```
tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml \
  --trials 20 --corpus housekeeper-pypi-stale-deps \
  --faithfulness-check --stream-json
```
Pass = exit 0 + "faithfulness check PASSED (20/20)" + all 20 `summary.csv` rows share one `findings_hash`, no skips/inconclusive/timeouts. **If a tail appears, STOP and report — sonnet is the documented fallback.**

- [ ] **Step 4: Record the result** to `docs/superpowers/notes/2026-06-12-housekeeper-pypi-haiku-low-result.md` (mirror the slice-3 note: single-arm structure, headline, single-arm rationale, config, canonical hash, distribution, cost, live-registry note, pre-flight, verdict, production-flip decision — a clean EQUIVALENT VALIDATES the already-shipped haiku/low tier; no flip needed). Commit + push.

- [ ] **Step 5: Update memory** (in the `~/.claude` repo, committed separately): add `project_housekeeper_specialist_slice4.md` mirroring slice1/2/3 (what shipped, single-arm verdict + cost, execution learnings; link `[[housekeeper-specialist-slice3]]`, `[[feedback_housekeeper_diff_is_selector_not_filter]]`), and add the `MEMORY.md` index line. Commit + push in `~/.claude`.

---

## Self-review notes

- **Spec coverage:** §2 manifests → Tasks 3/4; §2.2 trust gate → Task 2; §3 PEP 440 → Task 1; §4 tomllib gate → Task 4 (engine lazy import) + Task 10 (agent ≥3.11 probe); §5 registry/yanked → Tasks 5/6; §5.5 licence null → Task 6 (asserted in tests); §6 parsers/collector/scope/wiring → Tasks 3–8; §7 renderer → Task 10; §8 trigger lockstep → Task 11; §9.1 unit tests → Tasks 1–8; §9.2 on-disk fixture → Task 9; §9.3 sync test → Task 11; §9.4 A/B → Tasks 13/15; §11 repo housekeeping → already checked in the spec (nothing to do); README → Task 12.
- **Type consistency:** `pypi_strip_constraint`, `pypi_releases`, `pypi_scope_roots`, `collect_pypi`, `parse_pyproject`, `parse_requirements`, `_pypi_normalize`, `_pypi_yanked`, `_pypi_yank_reason`, `pypi_latest_ga`, `pypi_nearest_in_major`, `pypi_compare`, `pypi_is_ga`, `pypi_version_key`, `_pypi_parse`, `_pypi_pep508_name_spec`, `_PYPI_SCOPE_SUFFIXES` — names used identically across tasks. The emitted tuple is the canonical 10-key shape (`source, item, current, latest_ga, target, file, line, licence_current, licence_latest, health`).
- **Live-honesty caveat:** Task 13's expected files assume `requests` latest-GA `2.31.0` and `urllib3` latest-GA `2.2.1` in the FIXTURE — these are frozen by the recorded JSON, so the recorded-fixture sweep is deterministic regardless of live drift. The live spot-check (Task 14 Step 4) only guards the optional live-honesty narrative, not the sweep oracle.
```
