# Housekeeper Docker base-image freshness slice — design

**Date:** 2026-06-11
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (the personal plugin
marketplace — independently versioned, own CI/CLAUDE.md/test suite; push to its
own `origin`).
**Status:** design approved; pending spec review before writing-plans.

---

## 1. Goal

Add a **Docker base-image** source class to the `housekeeper-freshness` engine
so the housekeeper specialist flags `FROM image:tag` lines whose pinned tag is
behind the latest GA release on its registry. This is the next vertical slice on
the same chassis as github-actions / runner / npm / nuget (slices 1–2). See
[[housekeeper-specialist-slice1]], [[housekeeper-specialist-slice2]].

The unifying principle from the source-file-trigger fix holds: **the diff is a
selector and target-modulator, not a findings filter** — a changed file selects
which buildable unit to audit; that unit's Dockerfile is in scope because it
belongs to the unit, and all its `FROM` lines are candidates (changed `FROM`
lines only modulate the upgrade target). See
[[housekeeper-diff-is-selector-not-filter]].

---

## 2. Scope & trust gate

### 2.1 What is a Dockerfile

A file qualifies as a Dockerfile when its basename is `Dockerfile`, matches
`Dockerfile.*`, or ends `.dockerfile` — reusing the existing IaC / trivy
detection vocabulary (`Containerfile` is intentionally NOT included this slice;
add later if a repo uses Podman/Buildah). Only `FROM` instructions are parsed;
all other Dockerfile instructions are ignored.

### 2.2 When a Dockerfile is in scope

A Dockerfile is audited when **either**:

- it is itself in the changed-files list (it *is* the image manifest — directly
  edited manifests are always in scope, mirroring a changed `package.json`), OR
- a changed file resolves to a buildable unit (its nearest-ancestor
  `.csproj`/`.fsproj`/`.vbproj` via `nuget_scope_roots`, or its nearest-ancestor
  `package.json` via `npm_scope_roots`) whose directory subtree contains the
  Dockerfile (**Anchor A**).

**Anchor A keys off already-resolved units.** Docker scope is a strict function
of the `nuget_csprojs` / `npm_roots` sets `collect_findings` already computes —
no independent directory heuristic. Consequence: today a Dockerfile is pulled in
by source changes only in **.NET/npm** units; a Go-only or Python-only project's
source change does not yet reach its Dockerfile. That coverage arrives when those
ecosystems land (PyPI/Go slices extend the same resolver). A directly-edited
Dockerfile is always covered regardless of ecosystem.

### 2.3 Tier model (unchanged from prior slices)

- **T2 (which deps):** every `FROM` line in an in-scope Dockerfile is a candidate
  — not only changed lines.
- **T3 (target modulation):** a `FROM` line the diff touched is suggested at the
  latest GA in its variant lineage; an untouched in-scope `FROM` line is suggested
  at the nearest in-major within its variant lineage.

### 2.4 Trust gate — act only on variant-aware concrete semver

Honours the engine's no-finding-without-a-trustworthy-latest-GA rule.

**Act on** (emit a finding): a fully-pinned `M.N.P` semver tag, with an optional
variant suffix, comparing **only within the same variant lineage**. The variant
is the substring after the numeric core:

- `node:20.11.1` → core `20.11.1`, variant `""`
- `node:20.11.1-alpine` → core `20.11.1`, variant `alpine`
- `python:3.12.1-bookworm` → core `3.12.1`, variant `bookworm`

A finding compares a tag only against tags sharing its **exact** variant string,
so a `-alpine` pin is never suggested a non-alpine target (which would be a
different image). Exact-string variant matching also handles versioned variants
correctly: `20.11.1-alpine3.19` has variant `alpine3.19` and is compared only
against other `alpine3.19` tags — it is never offered an `alpine3.20` target,
because that is a different base-OS lineage the engine will not silently cross.
(Consequence: a newer alpine-minor within the same image is not suggested; this
is the safe, no-untrustworthy-answer default for this slice.)

**Skip** (no finding — deliberately, to avoid an untrustworthy or noisy answer):

- `latest` and no-tag (`FROM node`) — also trivy DS-0001's territory (see §7).
- Floating / partial tags: fewer than full `M.N.P` after the variant split
  (`node:20`, `node:20.11`). Often an intentional auto-update choice; flagging
  them fails the housekeeping-is-a-smell-not-a-defect bar.
- Digest-only pins (`FROM image@sha256:…`) — no version to compare; the engine
  trusts digests by design (consistent with the github-actions SHA-without-comment
  skip).
- `scratch` — not a registry image.
- `ARG`/`$VAR`/`${VAR}`-interpolated tags — value not statically known.
- Multi-stage stage-name references (`FROM builder` where `builder` is a prior
  `AS builder`) — internal alias, not a registry image.

### 2.5 Registries

Resolved (anonymous / public): **Docker Hub** (`docker.io` /
`registry-1.docker.io`, incl. implicit `library/` for bare names), **MCR**
(`mcr.microsoft.com`), **GHCR** (`ghcr.io`).

**Private ECR** (`*.dkr.ecr.*.amazonaws.com`) is **recognised and deliberately
skipped** — it needs authenticated SigV4 (forfeits the pure-stdlib deterministic
sandbox chassis) and has no public latest-GA notion (images are first-party,
SHA/build-tagged). The reference parser returns `None` for an ECR host so the
behaviour is explicit, not an accidental non-match. **ECR Public**
(`public.ecr.aws/…`, anonymous, public) is a tractable follow-on and is deferred.

Any other host → skip (no trustworthy resolver).

---

## 3. Registry client — OCI Distribution v2 + challenge auth

All three registries implement the OCI Distribution spec; the only per-registry
difference is anonymous token acquisition, itself standardised via the
`WWW-Authenticate` challenge. One generic client therefore serves all three.

A new method on the existing `Registry` class:

```
docker_tags(ref) -> ["1.2.3", "1.2.3-alpine", ...]  or  None
```

**Live path:**

1. **Parse the reference** into `(host, repository, tag_or_digest)`:
   - bare name `node` → host `registry-1.docker.io`, repo `library/node`
   - `org/img` (no host) → Docker Hub, repo `org/img`
   - `ghcr.io/org/img`, `mcr.microsoft.com/dotnet/aspnet` → host used verbatim
   - host containing `.dkr.ecr.` → return `None` (ECR skip)
   - a `@sha256:` digest or a non-semver tag → caller skips before calling (so
     `docker_tags` is only invoked for act-on candidates)
2. `GET https://<host>/v2/<repo>/tags/list`. On `200`, return `json["tags"]`.
3. On `401`: parse `WWW-Authenticate: Bearer realm=…,service=…,scope=…`,
   `GET <realm>?service=…&scope=…` for an anonymous bearer token, retry the
   tags-list once with `Authorization: Bearer <token>`. Docker Hub and GHCR
   challenge; MCR usually returns `200` directly.
4. Any error / non-200 after the single retry → `None` (no untrustworthy answer).

This is pure `urllib` plus one 401-retry — consistent with the existing
stdlib-only constraint. The `WWW-Authenticate` parse is the only genuinely new
network logic in the slice.

**Fixture override** (makes the recorded-fixture sweep deterministic): when
`fixtures_dir` is set, read `<fixtures_dir>/docker/<slug>.json` where `slug` is
the full repository path with `/` → `__` (e.g. `library__node.json`,
`dotnet__aspnet.json`, `org__img.json`). File content is `{"tags": [...]}` — no
auth, no network. Same mechanism as the existing `fetch` / `registration`
overrides.

**Tag selection reuses the existing version core.** Within a candidate's variant
lineage: filter the returned tags to those whose core is GA and whose variant
equals the candidate's variant, then `latest_ga` / `nearest_in_major` (already in
the engine) pick the answer. `licence_current`/`licence_latest` and `health` are
`null` this slice (a tag list carries no per-tag licence; the maintenance-health
axis is deferred for Docker).

---

## 4. FROM parser & collector

### 4.1 `parse_dockerfile(text) -> [(image_ref, tag, variant, line_no)]`

Line-by-line scan for `FROM` instructions (Dockerfile keywords are
case-insensitive, so match `FROM`/`from` and `AS`/`as`). For each `FROM`:

- Strip a leading `--platform=…` flag before parsing the image reference.
- Record `AS <stage>` aliases so a later `FROM <stage>` is recognised as a stage
  reference and skipped (not treated as a registry image).
- Apply the §2.4 trust gate: skip no-tag, `latest`, `@sha256:` digests,
  `$VAR`/`${VAR}` interpolation, `scratch`, stage-name refs, and any tag that is
  not full `M.N.P` semver after the variant split.
- Emit `(image_ref, tag, variant, line_no)` only for act-on candidates.

Known limitation (documented, consistent with the csproj one-per-line assumption):
one `FROM` per physical line.

### 4.2 `collect_docker(dockerfile_text, changed_lines, registry)`

`dockerfile_text` maps each in-scope Dockerfile path → its content. Mirrors
`collect_npm` / `collect_nuget`:

- For each Dockerfile, for each `(ref, tag, variant, line)`:
  - `tags = registry.docker_tags(ref)`; if `None`, skip (no trustworthy answer).
  - Filter `tags` to same-variant GA tags; `latest = latest_ga(filtered)`; if no
    GA tag in the variant lineage, skip.
  - `stale = compare_versions(latest, tag) > 0`.
  - T3: `target = latest` if the `FROM` line is touched, else
    `nearest_in_major(tag, filtered)`; if the in-major target is not newer than
    current, `stale = False`.
  - Emit only when `stale` (no health axis this slice, so no "stale OR
    health-flagged" branch):
    ```
    {"source": "docker", "item": <ref>, "current": <tag>,
     "latest_ga": <latest>, "target": <target>,
     "file": <path>, "line": <line>,
     "licence_current": null, "licence_latest": null, "health": null}
    ```

### 4.3 Scope wiring in `collect_findings`

- Extend the existing `os.walk` discovery (same `node_modules`/`bin`/`obj`
  pruning) to collect `all_dockerfiles` (by the §2.1 basename test).
- New `docker_scope_roots(changed_files, all_dockerfiles, nuget_csprojs, npm_roots)`
  returns the in-scope Dockerfile set =
  (directly-changed Dockerfiles) ∪ (Dockerfiles whose directory is
  ancestor-or-same of a resolved unit's directory — Anchor A, keyed on the
  already-computed `nuget_csprojs` and `npm_roots`).
- Read in-scope Dockerfiles, call `collect_docker`, append to `findings`. The
  existing deterministic sort (`file, line, source, item`) already orders the new
  tuples.

---

## 5. Agent rendering

`agents/housekeeper-reviewer.md`:

- Add `docker` to the `Rule:` source enumeration: `housekeeper/docker`.
- Description: `<ref> is at <tag>; latest GA is <latest_ga>.` (No licence/health
  clause fires — both null this slice.)
- Suggested fix: `Upgrade <ref> to <target>.`
- Add one Docker `### Finding` block to the worked example (e.g. a
  `FROM node:18.20.0-alpine` on a touched line where latest GA in the alpine
  lineage is `22.x`). The `### Finding` format, field names, and harness parser
  are unchanged.

---

## 6. Trigger wiring (lockstep mirror contract)

Per [[housekeeper-diff-is-selector-not-filter]], every new scope source extends
BOTH the engine AND the Step 2.6 `$HOUSEKEEPING_DETECTED` trigger prose in
lockstep. For Docker:

- Add Dockerfile detection (basename `Dockerfile`, `Dockerfile.*`, `*.dockerfile`)
  to the Step 2.6 bullet across all three synced files
  (`includes/review-pipeline.md` canonical, `commands/pre-review.md`,
  `skills/review-gh-pr/SKILL.md`).
- **No new source-file suffixes** — the `.cs`/`.ts`/etc. extensions already in the
  trigger (from the 2026-06-11 source-file-trigger change) now also serve Docker
  via Anchor A. A source edit already sets `$HOUSEKEEPING_DETECTED`; the engine's
  `docker_scope_roots` decides whether a Dockerfile comes along.
- Extend the sync test to assert the Dockerfile detection patterns are present in
  the trigger prose (the Docker analogue of
  `test_housekeeping_trigger_mirrors_engine_scope`).

---

## 7. Relationship to trivy-reviewer (no double-reporting)

`trivy-reviewer` runs `trivy config` (a *misconfiguration* scanner), not a
version checker. Its relevant Dockerfile rule is `DS-0001: ':latest' tag used`,
which flags **unpinned / floating** base images. It has no concept of "a newer
version exists".

The two specialists are complementary across **mutually-exclusive line states**:

- A `FROM` line is *floating* (`:latest`, `node:20`) → trivy DS-0001 fires;
  housekeeper **skips** it (§2.4).
- A `FROM` line is *concrete-pinned* (`node:18.2.0`) → trivy is silent;
  housekeeper checks freshness.

A single `FROM` line cannot be in both states, so the same line never draws a
finding from both specialists. Trivy nudges you *into* pinning; housekeeper keeps
the pin *fresh*.

**Maintenance rule:** the housekeeper must NEVER be extended to flag `:latest` or
floating tags — that would collide with trivy DS-0001. (CVE scanning of image
*contents* is `trivy image`, which this suite does not run; image CVEs are
security-reviewer #6a's concern, also orthogonal.)

---

## 8. Testing

- **Engine unittests** (`tests/python/test_housekeeper_engine.py`):
  - `parse_dockerfile`: each skip reason (no-tag, `latest`, digest, `$VAR`,
    `scratch`, stage-name, partial semver), `AS` alias tracking, variant split,
    `--platform=` stripping, case-insensitive keywords.
  - `docker_tags` reference parsing (bare → `library/`, `org/img`, explicit host,
    ECR → `None`) and the `WWW-Authenticate` challenge parse (unit-level, fixture
    or stub).
  - `docker_scope_roots`: Anchor A (source → unit → Dockerfile in subtree),
    directly-changed Dockerfile, Dockerfile outside any resolved unit excluded,
    ECR-only Dockerfile yields no finding.
  - `collect_docker` end-to-end against recorded `docker/<slug>.json` fixtures:
    stale pinned tag emits; same-variant target; untouched line → nearest-in-major.
- **Sync test:** extend the trigger-mirror test to assert the Dockerfile patterns.
- **Engine regression:** a source-only changeset in a unit containing a Dockerfile
  returns the stale base-image finding (proves Anchor A wiring).

---

## 9. A/B discipline — single arm (this session's explicit decision)

The sonnet-vs-haiku chassis-equivalence question is settled (slices 1 & 2 both
EQUIVALENT 20/20; the renderer is a thin §7 projection and a new ecosystem does
not make rendering harder). Per the user's call this session, the Docker slice
runs a **single-arm haiku/low** recorded-fixture sweep, not a two-arm A/B. The
sonnet arm is dropped.

What the single-arm 20/20 still guards is **apparatus determinism** — the failure
mode that actually bit prior slices (empty-stdout, format drift, temp-dir
self-abort, fixture round-trip), not the model tier. Build the full `tests/ab/`
Docker corpus (fixture Dockerfile with a stale pinned base image, recorded tag
lists, parser case, one haiku/low config). Oracle is the pinned expected tuples.
Pass = 20/20 identical canonical hash, no skips / empty-stdout / format drift.

**Live-honesty note** (the `WindowsAzure.Storage` lesson from slice 2): choose a
corpus base image that is genuinely stale on the live registry, so an optional
live spot-check does not diverge from the fixture.

If the single-arm sweep shows a tail, sonnet remains the documented fallback.

---

## 10. Explicitly out of scope (this slice)

- **docker-compose** `image:` tags — deferred to a follow-on on the same registry
  client.
- **Private ECR** resolution (auth + no public latest-GA) — detect-and-skip only.
- **ECR Public** (`public.ecr.aws`) — tractable follow-on, deferred.
- **`Containerfile`** basename — add when a repo needs Podman/Buildah.
- **Maintenance-health axis** for Docker (deprecated/EOL base images) — deferred;
  `health` is `null`. A tag list carries no deprecation signal; an EOL feed would
  be a separate data source.
- **Floating/`:latest` flagging** — permanently out (trivy DS-0001 owns it; §7).
- **Digest→tag reverse lookup** — out (engine trusts digests by design).

---

## 11. Follow-on slices (same chassis, user-requested order)

After Docker: **PyPI**, then **Go modules** (requested 2026-06-11). Each is an
independent spec → plan → implementation cycle: parser + scope-suffix set +
cookbook row + recorded-registry fixtures + single-arm haiku sweep, extending the
engine scope set AND the Step 2.6 trigger prose in lockstep.

---

## 12. Provenance / related reading

- Chassis & prior slices: `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`;
  memories [[housekeeper-specialist-slice1]], [[housekeeper-specialist-slice2]].
- Selector-not-filter principle: [[housekeeper-diff-is-selector-not-filter]];
  source-file-trigger spec
  `docs/superpowers/specs/2026-06-11-housekeeper-source-file-trigger-design.md`.
- Engine: `plugins/code-review-suite/bin/housekeeper-freshness`.
- Agent: `plugins/code-review-suite/agents/housekeeper-reviewer.md`.
- Trivy boundary: `plugins/code-review-suite/agents/trivy-reviewer.md`.
