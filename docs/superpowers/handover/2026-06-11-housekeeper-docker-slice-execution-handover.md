# Handover — execute the housekeeper Docker base-image slice

**Date:** 2026-06-11
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (the personal plugin
marketplace — independently versioned, its own CI/CLAUDE.md/test suite; push to
its own `origin`, NOT the `claude-settings` repo).
**Branch:** `main` (house rule: direct-push to `main`, push immediately after
each commit).

---

## 1. What to do first (the immediate task)

Execute the implementation plan at:

```
docs/superpowers/plans/2026-06-11-housekeeper-docker-slice.md
```

Use **`superpowers:subagent-driven-development`** — the user chose
subagent-driven execution (a fresh subagent per task, two-stage review between
tasks). The plan is 10 TDD tasks, well-isolated, each producing a self-contained
commit. Start clean: **no plan code has landed yet** — the only commits so far
are the spec (`d5b747c`) and the plan (`8d516a9`), both already pushed.

The paired **design spec** (read it for the "why" before executing) is:

```
docs/superpowers/specs/2026-06-11-housekeeper-docker-slice-design.md
```

---

## 2. The one-paragraph problem

The `housekeeper-freshness` engine already audits npm / NuGet / GitHub-Actions /
runner freshness. This slice adds a **Docker base-image** source class: flag
`FROM image:tag` lines whose pinned semver tag is behind the latest GA on its
registry (Docker Hub / MCR / GHCR). It is the next vertical slice on the same
chassis as slices 1–2, and it completes the "base images" follow-on the original
housekeeper design deferred.

---

## 3. Key decisions already settled (do NOT re-litigate — they are in the spec)

- **Registries:** Docker Hub (`docker.io` / `registry-1.docker.io`, incl. implicit
  `library/`), MCR (`mcr.microsoft.com`), GHCR (`ghcr.io`) — anonymous/public via
  one generic **OCI Distribution v2** client (`/v2/<repo>/tags/list`) with a
  `WWW-Authenticate` anonymous-bearer-token retry. **Private ECR**
  (`*.dkr.ecr.*.amazonaws.com`) is **detect-and-skip** (no auth, no public
  latest-GA). ECR Public + docker-compose + `Containerfile` + the maintenance-
  health axis are all **deferred** (spec §10).
- **Trust gate:** act ONLY on **variant-aware concrete semver** — full `M.N.P`
  (optional `.W`) with an optional variant suffix (`-alpine`, `-bookworm`),
  comparing only within the **exact same variant string**. Skip: `latest`,
  floating/partial tags (`node:20`, `node:20.11`), `@sha256:` digests, `scratch`,
  `$VAR`/`${VAR}` interpolation, and `AS`-stage references. (Spec §2.4.)
- **Scope = Anchor A.** A Dockerfile is in scope when it is directly changed, OR
  its directory is an ancestor-or-same of a **resolved buildable unit's** directory
  (the unit's nearest-ancestor `.csproj`/`package.json` that `collect_findings`
  already computes). Docker scope is a strict function of units we already parse —
  no independent directory heuristic. Consequence: today only .NET/npm source
  changes pull in a Dockerfile; Go/Python coverage arrives with those slices. A
  directly-edited Dockerfile is always in scope regardless of ecosystem. (Spec §2.2.)
- **`health`/licence are `null`** this slice (a tag list carries neither).
- **Trivy boundary (spec §7):** trivy `DS-0001` owns `:latest`/unpinned; the
  housekeeper owns pinned-but-stale. Mutually exclusive line states → no
  double-reporting. **Maintenance invariant: never extend the housekeeper to flag
  `:latest`/floating** — that would collide with trivy. The trust gate already
  enforces this by skipping those forms.
- **A/B = single arm.** The user explicitly dropped the sonnet baseline: the
  chassis-equivalence question is settled (slices 1 & 2 both EQUIVALENT 20/20; the
  renderer is a thin §7 projection). Run a **single-arm haiku/low 20/20**
  recorded-fixture sweep — it guards apparatus determinism (empty-stdout, format
  drift, temp-dir self-abort), not the model tier. Sonnet is the documented
  fallback only if a tail appears. (Spec §9.)

---

## 4. Engine shape the plan builds (names are used verbatim — keep them)

All in `plugins/code-review-suite/bin/housekeeper-freshness`, a new "docker" block
after `collect_nuget` and before `collect_findings`:

- `_DOCKER_FROM_RE`, `_DOCKER_CORE_RE` — regexes (validated against representative
  cases during planning; the FROM regex correctly handles multi-segment hosts,
  `AS` aliases, `--platform`, variant splits, and all skip cases).
- `parse_dockerfile(text) -> [(image_ref, core, variant, line_no)]` (Task 1).
- `_docker_parse_ref(ref) -> (host, repo) | None`, `_docker_parse_challenge(hdr)`,
  `Registry.docker_tags(ref)`, `Registry._docker_get`, `Registry._docker_anon_token`
  (Task 2).
- `_is_dockerfile(path)`, `docker_scope_roots(changed_files, all_dockerfiles, nuget_csprojs, npm_roots)`
  (Task 3).
- `_docker_split_tag(tag)`, `collect_docker(dockerfile_text, changed_lines, registry)`
  (Task 4).
- `collect_findings` wiring: discover `all_dockerfiles` in the existing `os.walk`,
  resolve `docker_scope_roots` after the npm/nuget roots exist, append
  `collect_docker` to `findings` (Task 5).

The emit tuple keeps the existing 10-key schema (`source, item, current,
latest_ga, target, file, line, licence_current, licence_latest, health`) with
`source: "docker"` and licence/health `null`.

---

## 5. Tasks at a glance (full detail + exact code in the plan)

1. `parse_dockerfile` + trust gate — TDD, `DockerParseTest`.
2. `Registry.docker_tags` OCI v2 + challenge + fixture override — `DockerTagsTest`.
3. `_is_dockerfile` + `docker_scope_roots` (Anchor A) — `DockerScopeTest`.
4. `collect_docker` (variant-lineage comparison) — `DockerCollectTest`.
5. Wire into `collect_findings` — `DockerEndToEndTest` (subprocess).
6. Agent renderer: add `docker` to the `Rule:` list + one worked-example finding
   (`agents/housekeeper-reviewer.md`).
7. Trigger lockstep: extend the Step 2.6 `$HOUSEKEEPING_DETECTED` bullet across the
   THREE synced files + extend the sync test (`test_housekeeping_trigger_mirrors_engine_scope`).
8. On-disk regression fixture `tests/fixtures/static-analysis/housekeeper-docker/`
   (proves Anchor A: a `.cs`-only changeset surfaces the Dockerfile finding).
9. Single-arm A/B corpus `tests/ab/corpus/housekeeper-docker-stale-base/` + config
   `tests/ab/configs/per-agent/housekeeper-docker-haiku-low.yaml`.
10. Full verification + README + push + the A/B sweep handoff.

**Two plan watch-outs (the plan already flags these, but be alert):**
- **Task 9 expected `findings-housekeeper.md`:** the source-only (untouched-line)
  changeset targets nearest-in-major `18.20.4`, while the Description's `latest GA`
  is `22.3.0` — `target ≠ latest_ga` for untouched lines is correct. Confirm the
  rendered `Suggested fix` target against the Task 8 Step 3 captured tuple.
- **Task 9 `suite_sha: PENDING`** is an intentional capture-time value, not a
  placeholder — set it to the commit SHA when the sweep runs.

---

## 6. Verification

- Engine unittests: `python3 -m pytest tests/python/test_housekeeper_engine.py -v`
  (auto-run via `tests/run.sh` too).
- Structural/sync suite: `bash tests/run.sh` from the repo root — all green
  (auto-discovers `test_`-prefixed Bash tests; harness primitives in
  `tests/lib/harness.sh`: `REPO_ROOT`, `pass`/`fail`/`skip`).
- Known artifact: the `bad-config rejection` test false-fails on a dirty tree —
  commit first, then re-run.
- Engine regression (Task 8): a `.cs`-only changed-files list against the new
  fixture returns the stale base-image finding — proves Anchor A on disk.

---

## 7. The A/B sweep is a MANUAL, INTERACTIVE step (cannot be subagent-run)

Task 10 Steps 5–7 must be done in the interactive session, not a subagent/headless:

- **Cache refresh first:** after the final push, run `/plugins update` (refreshes
  DISK from GitHub) THEN `/reload-plugins` (reloads in-memory registry from disk).
  The A/B sweep exercises the engine BINARY — a stale cache captures the pre-Docker
  engine and the sweep is meaningless. This bit you on slice 1 (first capture
  returned `[]` against the stubbed chassis). See memory
  `project_plugin_cache_staleness` / `feedback_plugins_update_after_push`.
- **Drive the sweep** via `tests/ab/lib/` — mirror how the NuGet slice's sweep was
  driven (recorded in memory `project_housekeeper_specialist_slice2`). 20 trials,
  oracle = `expected/findings.json`, pass = 20/20 identical canonical hash, no
  skips / empty-stdout / format drift. If a tail appears, STOP and report — sonnet
  is the fallback.
- **Live-honesty:** the corpus base image (`node:18.20.0-alpine`) must be genuinely
  stale on the live registry so an optional live spot-check stays honest (the
  `WindowsAzure.Storage` lesson from slice 2).
- **Record result** to `docs/superpowers/notes/2026-06-11-housekeeper-docker-haiku-low-result.md`
  (mirror the slice-2 note) and update memory.

---

## 8. House rules (this repo)

- Direct-push to `main`; push immediately after each commit. No
  Co-Authored-By / advertising trailers.
- **Bash hook rules (strict):** one command per Bash call — no `&&`/`||`/`;`,
  no `$(...)`/backticks, no subshells, no heredocs in Bash (the hook rejects
  them). Carve-out: the `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC IS
  permitted for multi-line commit bodies. To run a multi-line Python snippet,
  Write it to a file under `$CLAUDE_TEMP_DIR` and run the file — do NOT pipe a
  heredoc to `python3`.
- Use `$CLAUDE_TEMP_DIR` (a `SessionStart` hook injects the literal path into
  context) for all temp files. Note: `$CLAUDE_TEMP_DIR` is NOT exported into the
  Bash shell env — use the literal path string from the session context, not the
  unexpanded variable, in Bash `>` redirects.
- **Agents:** set `mode: "auto"` and a kebab-case `name` on every dispatch (so a
  plan-mode parent doesn't stall the subagent). Pass the resolved
  `$CLAUDE_TEMP_DIR` literal into subagent prompts.
- Plugin-authoring frontmatter conventions (repo CLAUDE.md): command/skill files
  need `name` + `description` frontmatter and a blank line after the closing `---`.

---

## 9. Memory to update after landing (in the `~/.claude` repo, committed separately)

- Add a **slice-3 memory** `project_housekeeper_specialist_slice3.md` mirroring
  slice1/slice2: what shipped (docker source class, OCI v2 client, Anchor A),
  the single-arm A/B verdict + cost note, execution learnings. Link
  `[[housekeeper-specialist-slice2]]`, `[[housekeeper-diff-is-selector-not-filter]]`.
- Update `MEMORY.md` index with the one-line pointer.
- The `~/.claude` memory dir is exempt from org/identity scrubbing (private repo;
  public seed ships no memory). Secret-shaped patterns still bite.

---

## 10. After Docker: the next two slices (already tracked, do NOT start without the user)

The user requested **PyPI next, then Go modules** — each its own brainstorm → spec
→ plan → implement cycle on the same chassis (parser + scope-suffix set + cookbook
row + recorded-registry fixtures + single-arm haiku sweep, extending the engine
scope set AND the Step 2.6 trigger prose in lockstep). These are session tasks #9
and #10 in the originating session's task list; raise them with the user once
Docker ships. Do not fold them into this execution.

---

## 11. Provenance / related reading

- Design: `docs/superpowers/specs/2026-06-11-housekeeper-docker-slice-design.md`.
- Plan: `docs/superpowers/plans/2026-06-11-housekeeper-docker-slice.md`.
- Chassis & prior slices:
  `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`;
  source-file-trigger spec
  `docs/superpowers/specs/2026-06-11-housekeeper-source-file-trigger-design.md`.
- Engine: `plugins/code-review-suite/bin/housekeeper-freshness` (855 lines).
- Agent: `plugins/code-review-suite/agents/housekeeper-reviewer.md`.
- Trivy boundary: `plugins/code-review-suite/agents/trivy-reviewer.md`.
- Memories (in `~/.claude`): `project_housekeeper_specialist_slice1`, `…slice2`,
  `feedback_housekeeper_diff_is_selector_not_filter`,
  `project_housekeeper_maintenance_health_axis`,
  `project_plugin_cache_staleness`, `feedback_plugins_update_after_push`,
  `project_code_review_suite_backlog`.
