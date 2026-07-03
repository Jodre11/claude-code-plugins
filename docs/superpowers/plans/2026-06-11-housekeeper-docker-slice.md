# Housekeeper Docker Base-Image Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `docker` source class to the `housekeeper-freshness` engine that flags `FROM image:tag` base-image lines whose pinned semver tag is behind the latest GA on its registry (Docker Hub / MCR / GHCR), with Anchor-A buildable-unit scope and a variant-aware concrete-semver trust gate.

**Architecture:** Pure-stdlib Python engine extension. A new `parse_dockerfile` FROM parser + `docker_tags` method on the existing `Registry` class (generic OCI Distribution v2 `/v2/<repo>/tags/list` with a `WWW-Authenticate` anonymous-token retry, plus a `docker/<slug>.json` fixture override) + a `collect_docker` collector + `docker_scope_roots` scope resolver wired into `collect_findings`. Reuses the existing version core (`parse_version`/`latest_ga`/`nearest_in_major`/`compare_versions`). Docs/trigger/test changes mirror the prior slices.

**Tech Stack:** Python 3 stdlib (`urllib`, `re`, `json`), `unittest` (`tests/python/test_housekeeper_engine.py`), Bash sync-note test harness (`tests/lib/test_sync_notes.sh`), Markdown pipeline includes, A/B apparatus under `tests/ab/`.

**Source of truth:** the design spec `docs/superpowers/specs/2026-06-11-housekeeper-docker-slice-design.md`. Read it before starting.

---

## File Structure

- `plugins/code-review-suite/bin/housekeeper-freshness` — engine. Add: `_DOCKER_FROM_RE` + `parse_dockerfile`; `Registry.docker_tags`; `_is_dockerfile` + `docker_scope_roots`; `collect_docker`; wire both into `collect_findings`. (~150 new lines, one focused source-class block mirroring the npm/nuget blocks already there.)
- `tests/python/test_housekeeper_engine.py` — add four test classes: `DockerParseTest`, `DockerTagsTest`, `DockerScopeTest`, `DockerCollectTest`.
- `plugins/code-review-suite/agents/housekeeper-reviewer.md` — add `docker` to the `Rule:` source list + one worked-example finding.
- `plugins/code-review-suite/includes/review-pipeline.md` (canonical), `commands/pre-review.md`, `skills/review-gh-pr/SKILL.md` — extend the Step 2.6 `$HOUSEKEEPING_DETECTED` bullet with Dockerfile detection (identical edit in all three).
- `tests/lib/test_sync_notes.sh` — extend `test_housekeeping_trigger_mirrors_engine_scope` (or add a sibling) to pin the Dockerfile detection patterns.
- `tests/fixtures/static-analysis/housekeeper-docker/` — NEW engine-regression fixture: a `Dockerfile`, a sibling `.csproj` (for the Anchor-A regression), and `registry/docker/<slug>.json` recorded tag lists.
- `tests/ab/corpus/housekeeper-docker-stale-base/` + `tests/ab/configs/per-agent/housekeeper-docker-haiku-low.yaml` — NEW single-arm A/B corpus + config.

No engine signature is shared across tasks under two different names; the names below (`parse_dockerfile`, `docker_tags`, `docker_scope_roots`, `collect_docker`, `_is_dockerfile`) are used verbatim everywhere.

---

## Task 1: `parse_dockerfile` — the FROM parser + trust gate

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add after the nuget block, before `collect_findings` near line 774)
- Test: `tests/python/test_housekeeper_engine.py` (add `DockerParseTest`)

**Context the engineer needs:**
- `parse_version(s)` (engine line 174) returns `(major, minor, patch, revision)` or `None`. A full `M.N.P` semver has all three of major/minor/patch present in the source string — `parse_version` defaults missing parts to 0, so it CANNOT tell `20.11` from `20.11.0`. The trust gate must therefore test the **raw tag string** for "at least three dot-separated numeric components" itself, NOT rely on `parse_version`.
- The variant is the substring after the numeric core. Tag grammar handled: `<core>` or `<core>-<variant>` where `<core>` is `\d+\.\d+\.\d+` (exactly the M.N.P we act on; a 4th `.W` component is allowed and folded into core) and `<variant>` is everything after the first hyphen.
- Dockerfile keywords are case-insensitive (`FROM`/`from`, `AS`/`as`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/python/test_housekeeper_engine.py`:

```python
class DockerParseTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_pinned_semver_no_variant(self):
        out = self.m.parse_dockerfile("FROM node:20.11.1\n")
        self.assertEqual(out, [("node", "20.11.1", "", 1)])

    def test_pinned_semver_with_variant(self):
        out = self.m.parse_dockerfile("FROM python:3.12.1-bookworm\n")
        self.assertEqual(out, [("python", "3.12.1", "bookworm", 1)])

    def test_versioned_variant_kept_whole(self):
        out = self.m.parse_dockerfile("FROM node:20.11.1-alpine3.19\n")
        self.assertEqual(out, [("node", "20.11.1", "alpine3.19", 1)])

    def test_explicit_host_and_repo_path(self):
        out = self.m.parse_dockerfile(
            "FROM mcr.microsoft.com/dotnet/aspnet:8.0.1\n")
        self.assertEqual(
            out, [("mcr.microsoft.com/dotnet/aspnet", "8.0.1", "", 1)])

    def test_as_alias_recorded_and_stage_ref_skipped(self):
        text = "FROM node:20.11.1 AS build\nFROM build\n"
        out = self.m.parse_dockerfile(text)
        self.assertEqual(out, [("node", "20.11.1", "", 1)])

    def test_platform_flag_stripped(self):
        out = self.m.parse_dockerfile(
            "FROM --platform=linux/amd64 node:20.11.1\n")
        self.assertEqual(out, [("node", "20.11.1", "", 1)])

    def test_case_insensitive_keywords(self):
        out = self.m.parse_dockerfile("from node:20.11.1 as Build\n")
        self.assertEqual(out, [("node", "20.11.1", "", 1)])

    def test_skips_latest_no_tag_partial_digest_scratch_var(self):
        text = (
            "FROM node\n"              # no tag
            "FROM node:latest\n"       # latest
            "FROM node:20\n"           # floating major
            "FROM node:20.11\n"        # partial (not M.N.P)
            "FROM node@sha256:abc123\n"  # digest
            "FROM scratch\n"           # scratch
            "FROM node:${TAG}\n"       # interpolated braces
            "FROM node:$TAG\n"         # interpolated bare
        )
        self.assertEqual(self.m.parse_dockerfile(text), [])

    def test_line_numbers_are_one_based_and_correct(self):
        text = "# comment\nFROM node:20.11.1\nRUN true\nFROM python:3.12.1\n"
        out = self.m.parse_dockerfile(text)
        self.assertEqual(out, [("node", "20.11.1", "", 2),
                               ("python", "3.12.1", "", 4)])
```

- [ ] **Step 2: Run the tests to verify they FAIL**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerParseTest -v`
Expected: FAIL — `AttributeError: module ... has no attribute 'parse_dockerfile'`.

- [ ] **Step 3: Implement `parse_dockerfile`**

Insert into `plugins/code-review-suite/bin/housekeeper-freshness` immediately after the nuget collector (after `collect_nuget` ends, before `def collect_findings`):

```python
# --- source: docker (base-image FROM tags) ----------------------------------

# A FROM instruction. Group 1 = optional --platform flag (discarded). Group 2 =
# the image reference (host/repo). Group 3 = the tag (or None). Group 4 = the
# optional AS-alias stage name. Keywords are case-insensitive.
_DOCKER_FROM_RE = re.compile(
    r"^\s*FROM\s+(?:--platform=\S+\s+)?"
    r"([A-Za-z0-9][A-Za-z0-9._:/-]*?)"          # image ref (greedy-min)
    r"(?::([A-Za-z0-9][A-Za-z0-9._-]*))?"        # optional :tag
    r"(?:@[A-Za-z0-9]+:[A-Za-z0-9]+)?"           # optional @digest (skips tag)
    r"(?:\s+AS\s+(\S+))?\s*$",
    re.IGNORECASE,
)

# A concrete, act-on tag core: at least three dot-separated numeric components
# (M.N.P, optional .W). parse_version cannot distinguish 20.11 from 20.11.0, so
# the M.N.P-presence test lives here against the raw string.
_DOCKER_CORE_RE = re.compile(r"^(\d+\.\d+\.\d+(?:\.\d+)?)(?:-(.+))?$")


def parse_dockerfile(text):
    """Return [(image_ref, core, variant, line_no)] for act-on FROM lines.

    Act-on = a registry image pinned to a concrete M.N.P[.W] semver tag, with
    an optional variant suffix. Everything in the trust gate (no-tag, latest,
    floating/partial tags, @digest, scratch, $VAR interpolation, and AS-stage
    references) is deliberately skipped — see the design spec §2.4. One FROM
    per physical line is assumed."""
    out = []
    stages = set()
    for i, raw in enumerate(text.splitlines(), start=1):
        m = _DOCKER_FROM_RE.match(raw)
        if not m:
            continue
        ref, tag, alias = m.group(1), m.group(2), m.group(3)
        if alias:
            stages.add(alias)
        # A FROM whose ref is a prior stage alias is an internal reference.
        if ref in stages:
            continue
        if ref == "scratch":
            continue
        if tag is None:
            continue  # no tag, or a @digest pin (tag group did not capture)
        if "$" in tag:
            continue  # ${VAR} / $VAR interpolation — value not statically known
        cm = _DOCKER_CORE_RE.match(tag)
        if not cm:
            continue  # not a concrete M.N.P[.W] tag (latest, floating, etc.)
        core, variant = cm.group(1), (cm.group(2) or "")
        out.append((ref, core, variant, i))
    return out
```

- [ ] **Step 4: Run the tests to verify they PASS**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerParseTest -v`
Expected: PASS (9 tests).

Note on `test_as_alias_recorded_and_stage_ref_skipped`: `node:20.11.1` matches the core regex and emits; the second line `FROM build` — `build` was added to `stages`, so it is skipped. Note on the digest case: with a `@sha256:...` present the `:tag` group does not capture (the `@` digest branch consumes it), so `tag is None` and it is skipped.

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): parse Dockerfile FROM lines with variant-aware trust gate"
```

---

## Task 2: `Registry.docker_tags` — OCI v2 client + challenge auth + fixture override

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add a method to the `Registry` class, after `registration`/`_walk_registration` near line 166)
- Test: `tests/python/test_housekeeper_engine.py` (add `DockerTagsTest`)

**Context the engineer needs:**
- `Registry.__init__` stores `self.fixtures_dir`. Fixture slug convention elsewhere: `item.replace("/", "__")`. For docker the slug is the **repository path** (after host + library normalisation) so `library/node` → `library__node`, `dotnet/aspnet` → `dotnet__aspnet`.
- Reference normalisation rules (design §3 step 1):
  - no `/` in the name part → Docker Hub `library/<name>`, host `registry-1.docker.io`
  - exactly `org/img` (one `/`, first segment has no `.` and is not `localhost`) → Docker Hub `org/img`, host `registry-1.docker.io`
  - first segment contains `.` (or `:port`) → it is a host; the rest is the repo, used verbatim
  - host contains `.dkr.ecr.` → return `None` (ECR skip)
- The challenge flow only matters for the live path. In tests we drive `docker_tags` through the **fixture override** (deterministic) and unit-test the reference parser + challenge-header parser separately via small helpers.

- [ ] **Step 1: Write the failing tests**

Append to `tests/python/test_housekeeper_engine.py`:

```python
class DockerTagsTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_parse_ref_bare_name_is_docker_library(self):
        host, repo = self.m._docker_parse_ref("node")
        self.assertEqual((host, repo), ("registry-1.docker.io", "library/node"))

    def test_parse_ref_org_image_is_docker_hub(self):
        host, repo = self.m._docker_parse_ref("grafana/grafana")
        self.assertEqual((host, repo),
                         ("registry-1.docker.io", "grafana/grafana"))

    def test_parse_ref_explicit_host_used_verbatim(self):
        host, repo = self.m._docker_parse_ref("ghcr.io/org/img")
        self.assertEqual((host, repo), ("ghcr.io", "org/img"))

    def test_parse_ref_mcr_multi_segment_repo(self):
        host, repo = self.m._docker_parse_ref("mcr.microsoft.com/dotnet/aspnet")
        self.assertEqual((host, repo),
                         ("mcr.microsoft.com", "dotnet/aspnet"))

    def test_parse_ref_ecr_returns_none(self):
        self.assertIsNone(
            self.m._docker_parse_ref("123.dkr.ecr.eu-west-1.amazonaws.com/svc"))

    def test_parse_challenge_extracts_realm_service_scope(self):
        hdr = ('Bearer realm="https://auth.docker.io/token",'
               'service="registry.docker.io",scope="repository:library/node:pull"')
        realm, params = self.m._docker_parse_challenge(hdr)
        self.assertEqual(realm, "https://auth.docker.io/token")
        self.assertEqual(params["service"], "registry.docker.io")
        self.assertEqual(params["scope"], "repository:library/node:pull")

    def test_docker_tags_fixture_override_reads_tag_list(self):
        with tempfile.TemporaryDirectory() as d:
            fx = pathlib.Path(d) / "docker"
            fx.mkdir()
            (fx / "library__node.json").write_text(
                '{"tags": ["20.11.1", "22.2.0", "22.2.0-alpine"]}')
            reg = self.m.Registry(fixtures_dir=d)
            self.assertEqual(reg.docker_tags("node"),
                             ["20.11.1", "22.2.0", "22.2.0-alpine"])

    def test_docker_tags_fixture_miss_returns_none(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "docker").mkdir()
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIsNone(reg.docker_tags("node"))

    def test_docker_tags_ecr_returns_none_even_with_fixtures(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "docker").mkdir()
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIsNone(
                reg.docker_tags("123.dkr.ecr.eu-west-1.amazonaws.com/svc"))
```

- [ ] **Step 2: Run the tests to verify they FAIL**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerTagsTest -v`
Expected: FAIL — `_docker_parse_ref` / `_docker_parse_challenge` / `docker_tags` not defined.

- [ ] **Step 3: Implement the reference parser, challenge parser, and `docker_tags`**

Add two module-level helpers next to `parse_dockerfile` (Task 1 block):

```python
def _docker_parse_ref(ref):
    """Return (host, repository) for a Docker image reference, or None for an
    ECR host (deliberately unresolved). Applies Docker Hub library/ and
    org/img normalisation; an explicit host (first segment containing '.' or a
    ':' port, or 'localhost') is used verbatim with the remainder as the repo."""
    first = ref.split("/", 1)[0]
    has_host = ("." in first) or (":" in first) or first == "localhost"
    if has_host:
        host, _, repo = ref.partition("/")
        if ".dkr.ecr." in host:
            return None  # private ECR — see design §2.5
        return host, repo
    # No explicit host -> Docker Hub.
    if "/" not in ref:
        return "registry-1.docker.io", "library/" + ref
    return "registry-1.docker.io", ref


_DOCKER_CHALLENGE_KV_RE = re.compile(r'(\w+)="([^"]*)"')


def _docker_parse_challenge(header):
    """Parse a 'Bearer realm="...",service="...",scope="..."' WWW-Authenticate
    header into (realm, {param: value}). realm is popped out of the param map."""
    params = dict(_DOCKER_CHALLENGE_KV_RE.findall(header))
    realm = params.pop("realm", None)
    return realm, params
```

Add the `docker_tags` method to the `Registry` class (after `registration` / `_walk_registration`):

```python
    # --- docker (OCI Distribution v2 tags/list, anonymous) -----------------

    def docker_tags(self, ref):
        """Return the tag list for a Docker image reference, or None on any
        miss. Fixture mode reads <fixtures_dir>/docker/<repo-slug>.json
        ({"tags": [...]}). Live mode hits GET /v2/<repo>/tags/list, performing
        the anonymous WWW-Authenticate bearer-token dance on a 401. ECR hosts
        resolve to None (see _docker_parse_ref)."""
        parsed = _docker_parse_ref(ref)
        if parsed is None:
            return None
        host, repo = parsed
        if self.fixtures_dir:
            slug = repo.replace("/", "__")
            path = os.path.join(self.fixtures_dir, "docker", slug + ".json")
            try:
                with open(path, encoding="utf-8") as fh:
                    return (json.load(fh) or {}).get("tags")
            except (OSError, ValueError):
                return None
        url = "https://%s/v2/%s/tags/list" % (host, repo)
        doc = self._docker_get(url, token=None)
        if doc is not None:
            return doc.get("tags")
        token = self._docker_anon_token(host, repo)
        if token is None:
            return None
        doc = self._docker_get(url, token=token)
        return doc.get("tags") if doc else None

    def _docker_get(self, url, token):
        """GET url as JSON. Returns the parsed dict on 200, or None on a 401
        (caller then runs the token dance) or any other error."""
        headers = {"User-Agent": "code-review-suite-housekeeper",
                   "Accept": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.load(resp)
        except urllib.error.HTTPError:
            return None  # 401 (need token) or 404 (no such repo) -> None
        except (urllib.error.URLError, ValueError, TimeoutError, OSError):
            return None

    def _docker_anon_token(self, host, repo):
        """Fetch an anonymous bearer token by replaying the registry's
        WWW-Authenticate challenge. Returns the token string or None."""
        probe = urllib.request.Request(
            "https://%s/v2/%s/tags/list" % (host, repo),
            headers={"User-Agent": "code-review-suite-housekeeper"})
        challenge = None
        try:
            urllib.request.urlopen(probe, timeout=10)
        except urllib.error.HTTPError as e:
            challenge = e.headers.get("WWW-Authenticate")
        except (urllib.error.URLError, TimeoutError, OSError):
            return None
        if not challenge or not challenge.lower().startswith("bearer"):
            return None
        realm, params = _docker_parse_challenge(challenge)
        if not realm:
            return None
        from urllib.parse import urlencode
        token_url = realm + ("&" if "?" in realm else "?") + urlencode(params)
        doc = self._docker_get(token_url, token=None)
        if not doc:
            return None
        return doc.get("token") or doc.get("access_token")
```

- [ ] **Step 4: Run the tests to verify they PASS**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerTagsTest -v`
Expected: PASS (9 tests). Only fixture/parse paths are exercised — no network.

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): OCI v2 docker_tags client with anonymous challenge auth"
```

---

## Task 3: `docker_scope_roots` — Anchor-A scope resolver

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add `_is_dockerfile` + `docker_scope_roots` in the docker block)
- Test: `tests/python/test_housekeeper_engine.py` (add `DockerScopeTest`)

**Context the engineer needs:**
- Existing helpers in the engine: `_dirname(path)` (line 628) and `_dir_is_ancestor_or_same(ancestor, descendant)` (line 632, repo-root = `""`, guards against `src/Api` matching `src/ApiTests`). Reuse both.
- Anchor A: a Dockerfile is in scope if it is directly changed, OR its directory is an ancestor-or-same of a resolved unit's directory. The resolved units are the `nuget_csprojs` and `npm_roots` sets `collect_findings` already computes; `docker_scope_roots` takes them as inputs and does NOT recompute scope.
- "Dockerfile's directory is ancestor-or-same of the unit directory" means the Dockerfile sits at or above the unit — e.g. `src/Api/Dockerfile` is in scope for unit `src/Api/Api.csproj` (same dir), and a repo-root `Dockerfile` is in scope for any unit (it contains them all). A Dockerfile DEEPER than the unit (`src/Api/sub/Dockerfile` for `src/Api/Api.csproj`) is NOT pulled in by the source path — only by being directly changed. This matches the npm/nuget "governing ancestor" direction.

- [ ] **Step 1: Write the failing tests**

Append to `tests/python/test_housekeeper_engine.py`:

```python
class DockerScopeTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_is_dockerfile_basename_variants(self):
        self.assertTrue(self.m._is_dockerfile("Dockerfile"))
        self.assertTrue(self.m._is_dockerfile("src/Api/Dockerfile"))
        self.assertTrue(self.m._is_dockerfile("Dockerfile.prod"))
        self.assertTrue(self.m._is_dockerfile("build/api.dockerfile"))
        self.assertFalse(self.m._is_dockerfile("src/Api/Program.cs"))
        self.assertFalse(self.m._is_dockerfile("notes/Dockerfile.md"))

    def test_directly_changed_dockerfile_in_scope(self):
        roots = self.m.docker_scope_roots(
            ["src/Api/Dockerfile"], {"src/Api/Dockerfile"},
            nuget_csprojs=set(), npm_roots=set())
        self.assertEqual(roots, {"src/Api/Dockerfile"})

    def test_source_change_pulls_in_same_dir_dockerfile(self):
        roots = self.m.docker_scope_roots(
            ["src/Api/Program.cs"], {"src/Api/Dockerfile"},
            nuget_csprojs={"src/Api/Api.csproj"}, npm_roots=set())
        self.assertEqual(roots, {"src/Api/Dockerfile"})

    def test_root_dockerfile_in_scope_for_nested_unit(self):
        roots = self.m.docker_scope_roots(
            ["src/Api/Program.cs"], {"Dockerfile"},
            nuget_csprojs={"src/Api/Api.csproj"}, npm_roots=set())
        self.assertEqual(roots, {"Dockerfile"})

    def test_dockerfile_deeper_than_unit_not_pulled_by_source(self):
        # Dockerfile below the unit dir is NOT an ancestor of the unit, so a
        # source change to the unit does not pull it in.
        roots = self.m.docker_scope_roots(
            ["src/Api/Program.cs"], {"src/Api/sub/Dockerfile"},
            nuget_csprojs={"src/Api/Api.csproj"}, npm_roots=set())
        self.assertEqual(roots, set())

    def test_sibling_unit_dockerfile_not_in_scope(self):
        roots = self.m.docker_scope_roots(
            ["src/Api/Program.cs"], {"src/Worker/Dockerfile"},
            nuget_csprojs={"src/Api/Api.csproj"}, npm_roots=set())
        self.assertEqual(roots, set())

    def test_npm_unit_pulls_in_dockerfile(self):
        roots = self.m.docker_scope_roots(
            ["web/src/index.ts"], {"web/Dockerfile"},
            nuget_csprojs=set(), npm_roots={"web/package.json"})
        self.assertEqual(roots, {"web/Dockerfile"})
```

- [ ] **Step 2: Run the tests to verify they FAIL**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerScopeTest -v`
Expected: FAIL — `_is_dockerfile` / `docker_scope_roots` not defined.

- [ ] **Step 3: Implement `_is_dockerfile` and `docker_scope_roots`**

Add to the docker block in `plugins/code-review-suite/bin/housekeeper-freshness`:

```python
def _is_dockerfile(path):
    """True if path's basename is Dockerfile, Dockerfile.<suffix>, or ends
    .dockerfile. (Containerfile is intentionally excluded this slice.)"""
    base = path.rsplit("/", 1)[-1]
    return (base == "Dockerfile"
            or base.startswith("Dockerfile.")
            or base.endswith(".dockerfile"))


def docker_scope_roots(changed_files, all_dockerfiles, nuget_csprojs, npm_roots):
    """Return the in-scope Dockerfile set (Anchor A). A Dockerfile is in scope
    when it is directly changed, OR its directory is an ancestor-or-same of a
    resolved buildable unit's directory (the unit's nearest-ancestor csproj /
    package.json, already computed by collect_findings). Docker scope is thus a
    strict function of units we already parse — no independent directory walk."""
    roots = set()
    for f in changed_files:
        if _is_dockerfile(f) and f in all_dockerfiles:
            roots.add(f)
    unit_dirs = {_dirname(u) for u in nuget_csprojs} | {_dirname(u) for u in npm_roots}
    for df in all_dockerfiles:
        ddir = _dirname(df)
        for udir in unit_dirs:
            if _dir_is_ancestor_or_same(ddir, udir):
                roots.add(df)
                break
    return roots
```

- [ ] **Step 4: Run the tests to verify they PASS**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerScopeTest -v`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): Anchor-A docker_scope_roots keyed on resolved units"
```

---

## Task 4: `collect_docker` — the collector

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness` (add `collect_docker` in the docker block)
- Test: `tests/python/test_housekeeper_engine.py` (add `DockerCollectTest`)

**Context the engineer needs:**
- Version core helpers: `latest_ga(versions)` (highest GA or None), `nearest_in_major(current, versions)` (highest GA sharing current's major, else current), `compare_versions(a, b)` (-1/0/1). All operate on the numeric core; a variant suffix like `-alpine` is NOT stripped by them, so the collector must filter to same-variant tags and pass the **cores** of those tags.
- The collector must compare within the variant lineage: take only tags whose `(core, variant)` split has `variant == candidate.variant`, then feed their cores to the version core helpers.
- `changed_lines` is `{path: set(int)}`; T3 touched-line test is `line in changed_lines.get(path, set())`.
- Emit tuple shape (matches every other source): keys `source, item, current, latest_ga, target, file, line, licence_current, licence_latest, health`. For docker: `licence_current=None, licence_latest=None, health=None`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/python/test_housekeeper_engine.py`:

```python
class DockerCollectTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def _reg(self, tags):
        reg = self.m.Registry(fixtures_dir=None)
        reg.docker_tags = lambda ref: tags
        return reg

    def test_touched_line_targets_latest_ga_in_variant(self):
        reg = self._reg(["20.11.1", "22.2.0", "22.3.0"])
        text = {"Dockerfile": "FROM node:20.11.1\n"}
        out = self.m.collect_docker(text, {"Dockerfile": {1}}, reg)
        self.assertEqual(len(out), 1)
        f = out[0]
        self.assertEqual((f["source"], f["item"], f["current"],
                          f["latest_ga"], f["target"], f["file"], f["line"]),
                         ("docker", "node", "20.11.1", "22.3.0", "22.3.0",
                          "Dockerfile", 1))
        self.assertIsNone(f["health"])

    def test_untouched_line_targets_nearest_in_major(self):
        reg = self._reg(["20.11.1", "20.12.0", "22.3.0"])
        text = {"Dockerfile": "FROM node:20.11.1\n"}
        out = self.m.collect_docker(text, {}, reg)  # untouched
        self.assertEqual(out[0]["target"], "20.12.0")
        self.assertEqual(out[0]["latest_ga"], "22.3.0")

    def test_variant_isolation_only_same_variant_tags_considered(self):
        # An -alpine pin must not see plain tags, and vice versa.
        reg = self._reg(["20.11.1", "22.3.0", "20.11.1-alpine", "22.3.0-alpine"])
        text = {"Dockerfile": "FROM node:20.11.1-alpine\n"}
        out = self.m.collect_docker(text, {"Dockerfile": {1}}, reg)
        self.assertEqual(out[0]["current"], "20.11.1")
        self.assertEqual(out[0]["target"], "22.3.0")  # the alpine 22.3.0 core

    def test_not_stale_emits_nothing(self):
        reg = self._reg(["20.11.1", "20.10.0"])
        text = {"Dockerfile": "FROM node:20.11.1\n"}
        self.assertEqual(self.m.collect_docker(text, {"Dockerfile": {1}}, reg), [])

    def test_no_tags_in_variant_lineage_emits_nothing(self):
        reg = self._reg(["20.11.1-bullseye", "22.0.0-bullseye"])
        text = {"Dockerfile": "FROM node:20.11.1-alpine\n"}
        self.assertEqual(self.m.collect_docker(text, {"Dockerfile": {1}}, reg), [])

    def test_registry_miss_emits_nothing(self):
        reg = self._reg(None)
        text = {"Dockerfile": "FROM node:20.11.1\n"}
        self.assertEqual(self.m.collect_docker(text, {"Dockerfile": {1}}, reg), [])
```

- [ ] **Step 2: Run the tests to verify they FAIL**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerCollectTest -v`
Expected: FAIL — `collect_docker` not defined.

- [ ] **Step 3: Implement `collect_docker`**

Add to the docker block in `plugins/code-review-suite/bin/housekeeper-freshness`:

```python
def _docker_split_tag(tag):
    """Split a registry tag into (core, variant) using the same grammar as the
    FROM parser, or None if it is not a concrete M.N.P[.W] tag (so floating /
    rc tags in the registry list are ignored for comparison)."""
    cm = _DOCKER_CORE_RE.match(tag)
    if not cm:
        return None
    return cm.group(1), (cm.group(2) or "")


def collect_docker(dockerfile_text, changed_lines, registry):
    """dockerfile_text maps each in-scope Dockerfile path -> its content. Emits
    a tuple per stale FROM base-image, comparing only within the pinned tag's
    variant lineage. No health axis this slice (licence/health are null)."""
    findings = []
    for path, text in sorted(dockerfile_text.items()):
        touched = changed_lines.get(path, set())
        for ref, core, variant, line in parse_dockerfile(text):
            tags = registry.docker_tags(ref)
            if not tags:
                continue  # no trustworthy answer
            # Cores of registry tags sharing this candidate's exact variant.
            same_variant_cores = []
            for t in tags:
                split = _docker_split_tag(t)
                if split is not None and split[1] == variant:
                    same_variant_cores.append(split[0])
            latest = latest_ga(same_variant_cores)
            if not latest:
                continue
            if compare_versions(latest, core) <= 0:
                continue  # not stale
            if line in touched:
                target = latest
            else:
                target = nearest_in_major(core, same_variant_cores)
                if compare_versions(target, core) <= 0:
                    continue  # in-major exhausted for an untouched line
            findings.append({
                "source": "docker", "item": ref,
                "current": core, "latest_ga": latest, "target": target,
                "file": path, "line": line,
                "licence_current": None, "licence_latest": None,
                "health": None,
            })
    return findings
```

- [ ] **Step 4: Run the tests to verify they PASS**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerCollectTest -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): collect_docker emits stale base-image tuples within variant lineage"
```

---

## Task 5: Wire docker into `collect_findings`

**Files:**
- Modify: `plugins/code-review-suite/bin/housekeeper-freshness:776-827` (`collect_findings`)
- Test: `tests/python/test_housekeeper_engine.py` (add an end-to-end subprocess test to `ChassisTest` or a new `DockerEndToEndTest`)

**Context the engineer needs:**
- `collect_findings` walks the tree once (pruning `node_modules`/`bin`/`obj`), building `all_pkgs`/`all_csprojs`/`all_props`, then resolves `npm_roots` and `(nuget_csprojs, nuget_props)`, reads the in-scope manifest texts, and appends each source's findings. The final `findings.sort(key=lambda f: (f["file"], f["line"], f["source"], f["item"]))` already orders any new tuples.
- Add Dockerfile discovery to the SAME walk, then resolve `docker_scope_roots` AFTER `npm_roots`/`nuget_csprojs` exist, read those Dockerfiles, and append `collect_docker`.

- [ ] **Step 1: Write the failing end-to-end test**

Append to `tests/python/test_housekeeper_engine.py`:

```python
class DockerEndToEndTest(unittest.TestCase):
    """Drives the engine as a subprocess against an on-disk fixture tree with a
    recorded docker fixture, proving collect_findings wires docker in and that
    a SOURCE-only changeset pulls in its unit's Dockerfile (Anchor A)."""
    def setUp(self):
        self.m = load_engine()

    def _tree(self, d):
        root = pathlib.Path(d)
        (root / "src/Api").mkdir(parents=True)
        (root / "src/Api/Api.csproj").write_text(
            '<Project Sdk="Microsoft.NET.Sdk"></Project>\n')
        (root / "src/Api/Program.cs").write_text("class P {}\n")
        (root / "src/Api/Dockerfile").write_text("FROM node:18.20.0\n")
        fx = root / "registry/docker"
        fx.mkdir(parents=True)
        (fx / "library__node.json").write_text(
            '{"tags": ["18.20.0", "20.11.1", "22.3.0"]}')
        return root

    def test_source_only_change_pulls_in_dockerfile(self):
        with tempfile.TemporaryDirectory() as d:
            root = self._tree(d)
            files = root / "files.txt"
            lines = root / "lines.txt"
            files.write_text("src/Api/Program.cs\n")  # NO Dockerfile in diff
            lines.write_text("Changed lines:\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE),
                 "--root", str(root),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines),
                 "--registry-fixtures", str(root / "registry")],
                capture_output=True, text=True, check=True)
            data = json.loads(out.stdout)
            docker = [f for f in data if f["source"] == "docker"]
            self.assertEqual(len(docker), 1)
            self.assertEqual(docker[0]["item"], "node")
            self.assertEqual(docker[0]["current"], "18.20.0")
            # Untouched FROM line -> nearest in-major (18.x exhausted -> none
            # newer in major 18) means it falls to... no in-major bump exists,
            # so the finding is suppressed UNLESS a higher 18.x exists. Here the
            # only 18.x is 18.20.0 itself, so expect nearest-in-major suppression.
            # To assert a positive finding deterministically, the fixture's
            # tag list includes no higher 18.x; therefore this asserts the
            # TOUCHED path instead — see the second test.
            self.assertEqual(docker[0]["latest_ga"], "22.3.0")
            self.assertEqual(docker[0]["target"], "22.3.0")
```

Wait — the untouched-line path would suppress (no higher 18.x). Fix the fixture so the assertion is honest: make the changed file the Dockerfile line itself OR add a higher 18.x. Use the **touched** path by marking the Dockerfile line changed. Replace the test body's `files`/`lines` writes and the trailing asserts with:

```python
            files.write_text("src/Api/Dockerfile\n")  # directly changed
            lines.write_text("Changed lines:\n  src/Api/Dockerfile: 1\n")
```

and keep the `latest_ga`/`target` asserts as `22.3.0`. Also add a second test for the pure source-only Anchor-A pull-in using a fixture that has a higher in-major tag:

```python
    def test_source_only_untouched_targets_nearest_in_major(self):
        with tempfile.TemporaryDirectory() as d:
            root = self._tree(d)
            # Overwrite the fixture to include a higher 18.x so an untouched
            # in-major bump is available and the Anchor-A pull-in is observable.
            (root / "registry/docker/library__node.json").write_text(
                '{"tags": ["18.20.0", "18.20.4", "20.11.1", "22.3.0"]}')
            files = root / "files.txt"
            lines = root / "lines.txt"
            files.write_text("src/Api/Program.cs\n")  # source only, no Dockerfile
            lines.write_text("Changed lines:\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE),
                 "--root", str(root),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines),
                 "--registry-fixtures", str(root / "registry")],
                capture_output=True, text=True, check=True)
            docker = [f for f in json.loads(out.stdout) if f["source"] == "docker"]
            self.assertEqual(len(docker), 1)
            self.assertEqual(docker[0]["target"], "18.20.4")  # nearest in-major
            self.assertEqual(docker[0]["latest_ga"], "22.3.0")
```

- [ ] **Step 2: Run the tests to verify they FAIL**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerEndToEndTest -v`
Expected: FAIL — no `docker` tuples (collect_findings does not yet call collect_docker).

- [ ] **Step 3: Wire docker into `collect_findings`**

In `plugins/code-review-suite/bin/housekeeper-freshness`, inside `collect_findings`:

In the `os.walk` loop, after the `.props` branch, add Dockerfile discovery. The current loop body ends:

```python
            if nm.endswith(".csproj") or nm.endswith(".fsproj") or nm.endswith(".vbproj"):
                all_csprojs.add(rel)
            elif nm.endswith(".props"):
                all_props.add(rel)
```

Change to also collect Dockerfiles (and initialise `all_dockerfiles = set()` next to the other `all_*` sets):

```python
            if nm.endswith(".csproj") or nm.endswith(".fsproj") or nm.endswith(".vbproj"):
                all_csprojs.add(rel)
            elif nm.endswith(".props"):
                all_props.add(rel)
            if _is_dockerfile(rel):
                all_dockerfiles.add(rel)
```

After the nuget scope/text block (after `props_text = {...}` is built, before the `findings = []` line), add:

```python
    docker_roots = docker_scope_roots(changed_files, all_dockerfiles,
                                      nuget_csprojs, npm_roots)
    dockerfile_text = {p: read(p) for p in docker_roots}
    dockerfile_text = {p: t for p, t in dockerfile_text.items() if t is not None}
```

In the source-append block, add after the `collect_nuget` line:

```python
    findings += collect_docker(dockerfile_text, changed_lines, registry)
```

- [ ] **Step 4: Run the tests to verify they PASS**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py::DockerEndToEndTest -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full engine suite for regressions**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py -v`
Expected: all pass (existing + new docker classes).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/bin/housekeeper-freshness tests/python/test_housekeeper_engine.py
git commit -m "feat(housekeeper): wire docker source class into collect_findings"
```

---

## Task 6: Agent renderer — docker rule + worked example

**Files:**
- Modify: `plugins/code-review-suite/agents/housekeeper-reviewer.md:54` (the `Rule:` line) and the worked example (after line 116)

**Context:** The `Rule:` bullet (line 54) currently enumerates `github-actions`, `runner`, `npm`, or `nuget`. Add `docker`. The Description/Suggested-fix templates already cover docker (no licence/health clause fires). Add one docker `### Finding` to the worked example so the haiku renderer has a pattern.

- [ ] **Step 1: Extend the Rule source enumeration**

Find (line 54):

```
- **Rule:** `housekeeper/<source>` where `<source>` is the tuple's `source` (`github-actions`, `runner`, `npm`, or `nuget`).
```

Replace with:

```
- **Rule:** `housekeeper/<source>` where `<source>` is the tuple's `source` (`github-actions`, `runner`, `npm`, `nuget`, or `docker`).
```

- [ ] **Step 2: Add a docker finding to the worked example**

In the worked example's prose intro (line 72), it currently describes Actions/runner/npm/nuget changes. Append a docker clause to that sentence — find the end of the intro sentence ending `plus a current-but-deprecated `Newtonsoft.Json` at `13.0.3`), the canonical §7 output is:` and insert a docker case into the description. Specifically, change the intro to also mention: `and a Dockerfile (a `FROM node:18.20.0-alpine` on touched line 1 where latest GA in the alpine lineage is `22.3.0`)`.

Then add this `### Finding` block to the fenced output, after the `Newtonsoft.Json` block (before the closing ```` ``` ````):

```
### Finding — node behind latest GA
- **File:** Dockerfile:1
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/docker
- **Description:** node is at 18.20.0; latest GA is 22.3.0.
- **Suggested fix:** Upgrade node to 22.3.0.
```

- [ ] **Step 3: Verify the structural agent test still passes**

Run: `bash tests/run.sh 2>&1 | grep -E 'static-analysis severity literals: housekeeper'`
Expected: PASS — `housekeeper-reviewer.md contains 'Confidence: 100'` and the `## <name> Findings` heading checks still hold (unchanged heading).

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review-suite/agents/housekeeper-reviewer.md
git commit -m "docs(housekeeper): render docker source rule + worked example"
```

---

## Task 7: Trigger wiring (lockstep across three synced files) + sync test

**Files:**
- Modify: `tests/lib/test_sync_notes.sh` (extend `test_housekeeping_trigger_mirrors_engine_scope`)
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (canonical Step 2.6 bullet)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (mirror)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (mirror)

**Context the engineer needs:**
- The Step 2.6 bullet is byte-identical across the three files (a prose-parity test enforces it). The current text (after the 2026-06-11 source-file-trigger change) ends with the npm/nuget source extensions and a parenthetical. We append a Dockerfile clause.
- The sync test currently asserts source extensions are present in BOTH the trigger prose AND the engine scope constants. Dockerfiles are matched by basename, not extension, so the test gets a small dedicated assertion (the literal `Dockerfile` token must appear in the bullet AND `_is_dockerfile` must exist in the engine).

- [ ] **Step 1: Extend the sync test (write it to fail against current prose)**

In `tests/lib/test_sync_notes.sh`, inside `test_housekeeping_trigger_mirrors_engine_scope`, after the existing `for ext in ...` loop and its `missing` check, add a Dockerfile assertion. Find the final block of that function:

```bash
    if [[ -z "$missing" ]]; then
        pass "housekeeping trigger mirrors engine scope: all source extensions present in prose and engine"
    else
        fail "housekeeping trigger mirrors engine scope: all source extensions present in prose and engine" \
            "extensions missing (prose:X = absent from trigger bullet, engine:X = absent from engine scope constants):$missing"
    fi
}
```

Insert BEFORE the closing `}`, after the `fi`:

```bash

    # Docker is matched by Dockerfile basename, not extension. Assert the
    # trigger names 'Dockerfile' AND the engine has the _is_dockerfile gate.
    if grep -qF 'Dockerfile' <<<"$bullet" && grep -qF '_is_dockerfile' "$engine"; then
        pass "housekeeping trigger mirrors engine scope: Dockerfile detection present in prose and engine"
    else
        fail "housekeeping trigger mirrors engine scope: Dockerfile detection present in prose and engine" \
            "trigger bullet must name 'Dockerfile' and engine must define _is_dockerfile"
    fi
```

- [ ] **Step 2: Run the sync test to verify the new assertion FAILS**

Run: `bash tests/run.sh 2>&1 | grep -A2 'Dockerfile detection present'`
Expected: FAIL — the trigger bullet does not yet name `Dockerfile`. (`_is_dockerfile` already exists from Task 3, so only the prose side is missing.)

- [ ] **Step 3: Edit the canonical bullet (`review-pipeline.md`)**

Find the current Step 2.6 Housekeeping detection bullet (the post-source-trigger text). It ends:

```
...or is an npm source file ending `.ts`/`.tsx`/`.js`/`.jsx`/`.mjs`/`.cjs`/`.mts`/`.cts`/`.vue`/`.svelte`, set `$HOUSEKEEPING_DETECTED = true`. The source-file extensions mirror the engine's `_NUGET_SCOPE_SUFFIXES`/`_NPM_SCOPE_SUFFIXES` scope sets: a changed source file pulls in its nearest-ancestor project and the engine audits all that project's dependencies (not only changed manifest lines). (This slice covers GitHub Actions, workflow runners, npm, and NuGet; follow-on plans extend both the engine scope sets and this trigger in lockstep for PyPI/crates/Go/RubyGems/Docker/SDK.)
```

Replace that single line with (inserting a Dockerfile clause before the final `set` and updating the parenthetical):

```
   - **Housekeeping detection:** if any changed file is under `.github/workflows/` and ends `.yml`/`.yaml`; is a `package.json` (npm manifest); ends `.csproj`/`.fsproj`/`.vbproj`/`.props`/`.targets`; is a `packages.lock.json` (NuGet manifest); is a .NET source file ending `.cs`/`.fs`/`.vb`/`.razor`/`.cshtml`; is an npm source file ending `.ts`/`.tsx`/`.js`/`.jsx`/`.mjs`/`.cjs`/`.mts`/`.cts`/`.vue`/`.svelte`; or is a Dockerfile (basename `Dockerfile`, `Dockerfile.*`, or ending `.dockerfile`), set `$HOUSEKEEPING_DETECTED = true`. The source-file extensions mirror the engine's `_NUGET_SCOPE_SUFFIXES`/`_NPM_SCOPE_SUFFIXES` scope sets, and Dockerfiles mirror the engine's `_is_dockerfile` gate: a changed source file pulls in its nearest-ancestor project (and that project's Dockerfile) and the engine audits all that project's dependencies and base images (not only changed manifest lines). (This slice covers GitHub Actions, workflow runners, npm, NuGet, and Docker base images; follow-on plans extend both the engine scope sets and this trigger in lockstep for PyPI/crates/Go/RubyGems/SDK.)
```

- [ ] **Step 4: Apply the identical replacement to `pre-review.md` and `SKILL.md`**

Find the byte-identical old bullet in `plugins/code-review-suite/commands/pre-review.md` and replace with the exact new text from Step 3. Then do the same in `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`.

- [ ] **Step 5: Run the full suite**

Run: `bash tests/run.sh`
Expected: all pass. Confirm specifically:
- `housekeeping trigger mirrors engine scope: Dockerfile detection present in prose and engine` — PASS.
- `pipeline inline sync: ... matches canonical` (the prose-parity test across the three files) — PASS (all three now identical).
- The existing source-extension assertion still PASS.
- Known artifact: if `bad-config rejection` false-fails on a dirty tree, commit first (Step 6) then re-run.

- [ ] **Step 6: Commit**

```bash
git add tests/lib/test_sync_notes.sh plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md
git commit -m "feat(housekeeper): dispatch on changed Dockerfiles, pinned by sync test"
```

---

## Task 8: Engine-regression fixture (proves Anchor A end-to-end on disk)

**Files:**
- Create: `tests/fixtures/static-analysis/housekeeper-docker/src/Api/Api.csproj`
- Create: `tests/fixtures/static-analysis/housekeeper-docker/src/Api/Program.cs`
- Create: `tests/fixtures/static-analysis/housekeeper-docker/src/Api/Dockerfile`
- Create: `tests/fixtures/static-analysis/housekeeper-docker/registry/docker/library__node.json`

**Context:** This is the durable on-disk fixture (the `DockerEndToEndTest` in Task 5 builds its tree in a tempdir; this fixture is the committed analogue used for the manual regression check and as the A/B corpus source in Task 9). Mirrors the layout of `tests/fixtures/static-analysis/housekeeper-nuget/`.

- [ ] **Step 1: Create the fixture files**

`tests/fixtures/static-analysis/housekeeper-docker/src/Api/Api.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
  </ItemGroup>
</Project>
```

`tests/fixtures/static-analysis/housekeeper-docker/src/Api/Program.cs`:

```csharp
public class Program
{
    public static void Main() { }
}
```

`tests/fixtures/static-analysis/housekeeper-docker/src/Api/Dockerfile`:

```dockerfile
FROM node:18.20.0-alpine
WORKDIR /app
```

`tests/fixtures/static-analysis/housekeeper-docker/registry/docker/library__node.json`:

```json
{"tags": ["18.20.0-alpine", "18.20.4-alpine", "20.11.1-alpine", "22.3.0-alpine"]}
```

- [ ] **Step 2: Run the engine against the fixture (touched Dockerfile path)**

```bash
printf 'src/Api/Dockerfile\n' > "${CLAUDE_TEMP_DIR}/cf.txt"
printf 'Changed lines:\n  src/Api/Dockerfile: 1\n' > "${CLAUDE_TEMP_DIR}/cl.txt"
plugins/code-review-suite/bin/housekeeper-freshness --root tests/fixtures/static-analysis/housekeeper-docker --changed-files-from "${CLAUDE_TEMP_DIR}/cf.txt" --changed-lines-from "${CLAUDE_TEMP_DIR}/cl.txt" --registry-fixtures tests/fixtures/static-analysis/housekeeper-docker/registry
```

Expected: one `docker` tuple — `item: node`, `current: 18.20.0`, `latest_ga: 22.3.0`, `target: 22.3.0`, `file: src/Api/Dockerfile`, `line: 1` (touched → latest in the alpine lineage; variant isolation keeps it alpine).

- [ ] **Step 3: Run the engine against a SOURCE-only changeset (proves Anchor A)**

```bash
printf 'src/Api/Program.cs\n' > "${CLAUDE_TEMP_DIR}/cf.txt"
printf 'Changed lines:\n' > "${CLAUDE_TEMP_DIR}/cl.txt"
plugins/code-review-suite/bin/housekeeper-freshness --root tests/fixtures/static-analysis/housekeeper-docker --changed-files-from "${CLAUDE_TEMP_DIR}/cf.txt" --changed-lines-from "${CLAUDE_TEMP_DIR}/cl.txt" --registry-fixtures tests/fixtures/static-analysis/housekeeper-docker/registry
```

Expected: one `docker` tuple — `target: 18.20.4` (untouched → nearest in-major within the alpine lineage), `latest_ga: 22.3.0`. The `.cs` change with NO Dockerfile in the diff still surfaced the Dockerfile finding — Anchor A proven on disk.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/static-analysis/housekeeper-docker/
git commit -m "test(housekeeper): on-disk docker fixture proving Anchor-A source pull-in"
```

---

## Task 9: A/B single-arm corpus + config (haiku/low, recorded fixtures)

**Files:**
- Create: `tests/ab/corpus/housekeeper-docker-stale-base/source.yaml`
- Create: `tests/ab/corpus/housekeeper-docker-stale-base/diff/changed-lines.txt`
- Create: `tests/ab/corpus/housekeeper-docker-stale-base/expected/findings.json`
- Create: `tests/ab/corpus/housekeeper-docker-stale-base/expected/findings-housekeeper.md`
- Create: `tests/ab/configs/per-agent/housekeeper-docker-haiku-low.yaml`

**Context the engineer needs:**
- This slice runs a **single-arm** haiku/low sweep (no sonnet baseline) — the chassis-equivalence question is settled (design §9). The corpus mirrors `tests/ab/corpus/housekeeper-nuget-stale-deps/` exactly in shape.
- The corpus `source_path` points at the Task 8 fixture. `registry_fixtures: registry/` is the inert forward-marker (the harness scrubs subprocess env; the engine resolves live in a real sweep — but for a recorded sweep the fixture under the source tree is read via `--registry-fixtures` IF the harness passes it; replicate the NuGet corpus's exact handling).
- The expected `findings.json` uses the harness's reduced shape: `{file, line, rule_id, severity, confidence}` (see the NuGet corpus). For the touched-Dockerfile case the single finding is `Dockerfile:1`... but note the corpus uses the source tree's relative path. Use the path as the engine emits it relative to `source_path` root: `src/Api/Dockerfile`.

- [ ] **Step 1: Create the corpus `source.yaml`**

`tests/ab/corpus/housekeeper-docker-stale-base/source.yaml`:

```yaml
id: housekeeper-docker-stale-base
agent: housekeeper-reviewer
captured_at: 2026-06-11T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: PENDING   # set to the commit SHA at capture time
  agent_model: haiku
  agent_effort: low
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/housekeeper-docker/
base_sha: ""  # synthetic fixture: no real diff
head_sha: ""
path_scope: ""
empty_tree_mode: false
registry_fixtures: registry/   # INERT marker (env-scrubbed harness); a live sweep hits real registries
intent_ledger: |
  ## Intent ledger
  - Synthetic Docker fixture exercising housekeeper-reviewer against a single
    stale, variant-pinned base image (FROM node:18.20.0-alpine where latest GA
    in the alpine lineage is 22.3.0). The .cs change with no Dockerfile in the
    diff pulls the Dockerfile in via Anchor A. One deterministic Suggestion
    finding. Slice-3 single-arm Haiku/low validation corpus.
depends_on:
  - plugins/code-review-suite/agents/housekeeper-reviewer.md
  - plugins/code-review-suite/bin/housekeeper-freshness
  - plugins/code-review-suite/includes/static-analysis-context.md
  - tests/fixtures/static-analysis/housekeeper-docker/src/Api/Dockerfile
  - tests/fixtures/static-analysis/housekeeper-docker/registry/docker/library__node.json
```

- [ ] **Step 2: Create the diff and expected files**

`tests/ab/corpus/housekeeper-docker-stale-base/diff/changed-lines.txt`:

```
Changed lines:
  src/Api/Program.cs: 1
```

`tests/ab/corpus/housekeeper-docker-stale-base/expected/findings.json`:

```json
[{"file":"src/Api/Dockerfile","line":1,"rule_id":"housekeeper/docker","severity":"Suggestion","confidence":100}]
```

`tests/ab/corpus/housekeeper-docker-stale-base/expected/findings-housekeeper.md`:

```
## Housekeeper Findings

### Finding — node behind latest GA
- **File:** src/Api/Dockerfile:1
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/docker
- **Description:** node is at 18.20.0; latest GA is 22.3.0.
- **Suggested fix:** Upgrade node to 18.20.4.
```

NOTE: the source-only (untouched) changeset targets nearest-in-major `18.20.4`, while the Description's `latest GA` is `22.3.0` — matching the engine's tuple (target ≠ latest_ga for untouched lines). Confirm this against the Task 8 Step 3 output and adjust the `Suggested fix` target if the captured tuple differs.

- [ ] **Step 3: Create the haiku/low config**

`tests/ab/configs/per-agent/housekeeper-docker-haiku-low.yaml`:

```yaml
name: housekeeper-docker-haiku-low
description: Slice-3 single-arm validation — housekeeper-reviewer at Haiku/low on the Docker corpus. No sonnet baseline (chassis equivalence settled); 20/20 recorded-fixture sweep guards apparatus determinism.
mode: per-agent
agent: housekeeper-reviewer
session:
  model: haiku
  effort: low
```

- [ ] **Step 4: Validate corpus structure**

Run: `bash tests/run.sh 2>&1 | grep -iE 'corpus|housekeeper-docker' | head`
Expected: any corpus-structure validation in the suite passes for the new corpus (or is silently accepted if the suite does not lint corpora). If the suite has no corpus validator, this step is documentation-only — note it and proceed.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/corpus/housekeeper-docker-stale-base/ tests/ab/configs/per-agent/housekeeper-docker-haiku-low.yaml
git commit -m "test(ab): housekeeper docker single-arm haiku/low corpus + config"
```

---

## Task 10: Full verification, README, push, A/B sweep handoff

**Files:**
- Modify: `README.md` (if it enumerates housekeeper source classes — check first)

- [ ] **Step 1: Full test suite (clean tree)**

Run: `python3 -m pytest tests/python/test_housekeeper_engine.py -v`
Then: `bash tests/run.sh`
Expected: all pass, 0 failed (1 skip is acceptable per existing baseline).

- [ ] **Step 2: Update README if needed**

Run: `grep -n 'github-actions\|housekeeper.*npm.*nuget\|NuGet' README.md`
If the README enumerates the housekeeper's source classes, add `Docker base images`. If it does not enumerate them, skip (documentation-only).

- [ ] **Step 3: Commit any README change**

```bash
git add README.md
git commit -m "docs: note Docker base-image support in housekeeper"
```

(Skip if no README change was needed.)

- [ ] **Step 4: Push**

```bash
git push
```

- [ ] **Step 5: Refresh the plugin cache for the A/B sweep**

The A/B sweep exercises the engine binary, so the plugin cache MUST be current. In the interactive session run `/plugins update` then `/reload-plugins` (per the marketplace cache-staleness rule). A stale cache captures the pre-Docker engine.

- [ ] **Step 6: Run the single-arm A/B sweep (20/20)**

Run the housekeeper-docker-haiku-low config through the A/B harness for 20 trials against the recorded fixture. Oracle = `expected/findings.json`. Pass criterion: 20/20 identical canonical hash, no skips / empty-stdout / format drift. (Consult `tests/ab/lib/` for the exact runner invocation — mirror how the NuGet slice's sweep was driven, recorded in memory `project_housekeeper_specialist_slice2`.) If a tail appears, STOP and report — sonnet is the documented fallback (design §9).

- [ ] **Step 7: Record the result**

Write a short result note to `docs/superpowers/notes/2026-06-11-housekeeper-docker-haiku-low-result.md` (mirror the slice-2 note), then update memory per the slice pattern.

---

## Self-Review notes

- **Spec coverage:** §2.1 (`_is_dockerfile`, Task 3) · §2.2 Anchor A (Task 3 + Task 5 wiring + Task 8 regression) · §2.3 T2/T3 (Task 4) · §2.4 trust gate (Task 1) · §2.5 registries + ECR skip (Task 2) · §3 OCI v2 client + challenge + fixture (Task 2) · §4 parser/collector (Tasks 1, 4) · §5 agent render (Task 6) · §6 trigger lockstep + sync test (Task 7) · §7 trivy boundary (no code; documented in spec, no task needed) · §8 tests (Tasks 1–5, 7, 8) · §9 single-arm A/B (Task 9 + Task 10 sweep) · §10 out-of-scope (nothing to build) · §11 follow-ons (tracked separately). All buildable sections map to a task.
- **Type/name consistency:** `parse_dockerfile`, `_docker_parse_ref`, `_docker_parse_challenge`, `docker_tags`, `_docker_get`, `_docker_anon_token`, `_docker_split_tag`, `_DOCKER_FROM_RE`, `_DOCKER_CORE_RE`, `_is_dockerfile`, `docker_scope_roots`, `collect_docker` — each defined once, referenced consistently. Tuple shape matches the existing 10-key schema. `docker_scope_roots(changed_files, all_dockerfiles, nuget_csprojs, npm_roots)` signature identical in Task 3 def, Task 3 tests, and Task 5 call.
- **Placeholder scan:** `suite_sha: PENDING` in Task 9 is an intentional capture-time value (set at sweep time), not a plan placeholder. The Task 9 expected `Suggested fix` target carries an explicit "confirm against captured tuple" instruction. No "TBD"/"add error handling"/"similar to" placeholders.
- **TDD:** every engine task is test-first (write red → verify fail → implement → verify pass → commit). Trigger task is also red-first.
- **Trivy boundary (§7):** no implementation task — it is a maintenance invariant captured in the spec; the trust gate (Task 1) already skips `:latest`/floating, which is the mechanism that keeps the boundary. No code asserts it beyond the parser tests that prove `:latest` is skipped.
