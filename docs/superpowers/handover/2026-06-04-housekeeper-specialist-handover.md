# Handover — add a "housekeeper" specialist to the code-review-suite

**Date:** 2026-06-04
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (the personal plugin
marketplace; its own git remote `Jodre11/claude-code-plugins`, direct-push to
`main`, branch-protection-bypass notice on every push is expected and benign).
**Your job:** design and build a new **housekeeper** specialist for the
`code-review-suite` plugin, following the established specialist pattern. This is
NEW creative work — **START with `superpowers:brainstorming`** before any code.
Do not skip it; the scope/boundary questions below are exactly what brainstorming
exists to settle.

---

## What "housekeeper" means (the user's intent)

The user's global `~/.claude/CLAUDE.md` has a **"Repo Housekeeping (always while
we're here)"** section. They want a code-review specialist that automates checking
that domain on a PR/diff. The domain (verbatim drivers from CLAUDE.md):

- **Package-manager dependencies** — bump to latest GA. `dotnet list package
  --outdated` (or ecosystem equivalent); check `Directory.Packages.props` (CPM)
  first if present, else scan `*.csproj`.
- **GitHub Actions** — audit `.github/workflows/*.yml` for pinned old majors;
  bump `uses: org/action@vN` to latest stable major.
- **Workflow runners** — move `runs-on:` to latest supported (`ubuntu-24.04`,
  `windows-2025`, etc.).
- **Trivy / IaC** — outstanding findings on Dockerfiles, Terraform, K8s/Helm, CFN.

So "housekeeper" ≈ a **freshness/hygiene reviewer**: dependencies, Actions,
runners, IaC currency.

---

## CRITICAL — this is NOT a greenfield. Overlap MUST be resolved in brainstorming

There is **substantial existing coverage** of this domain. The single most
important brainstorming output is the **boundary**: what the housekeeper owns vs.
what already exists. Do not build until this is settled, or you will create
duplicate/conflicting findings the synthesiser then has to dedupe.

Existing coverage found (2026-06-04):
1. **`trivy-reviewer`** — already owns Trivy/IaC findings (Dockerfile/TF/K8s/Helm/
   CFN), dispatched on `$IAC_DETECTED`. A housekeeper that also runs trivy would
   double up. Decide: does housekeeper EXCLUDE IaC (defer to trivy), or is trivy
   folded in?
2. **`security-reviewer`** — already carries a **Version freshness (#7)** Focus
   Area (Suggestion-level, never Critical) for newly introduced/modified
   dependencies and GitHub Actions, AND a version-*safety* path (vulnerable old
   versions). It cites `includes/version-freshness-cookbook.md`. The synthesiser
   ALREADY dedupes when security's freshness path and another source flag the same
   dependency (`security-reviewer.md:128-130`). So freshness is NOT virgin
   territory — housekeeper would overlap security-reviewer directly.
3. **`includes/version-freshness-cookbook.md`** — the shared endpoint/ecosystem
   reference for freshness checks. Consumed by security-reviewer, pre-review,
   review-gh-pr SKILL. The housekeeper should almost certainly cite this rather
   than re-derive it.

**Brainstorming must decide:** is housekeeper a NEW specialist, or is this better
served by *strengthening security-reviewer's #7 Focus Area* + trivy? If a new
specialist is justified, the cleanest carve is probably "Actions + runners +
dependency-GA-currency (non-security)" — i.e. the hygiene that is NOT a
vulnerability and NOT IaC — leaving security-reviewer for version-*safety* and
trivy for IaC. But that is a hypothesis to test, not a decision. The user values
[[feedback-scope-discipline]] — don't over-build.

A second brainstorming axis: **static-analysis specialist vs LLM specialist?**
- The 4 static specialists (ruff/eslint/trivy/jbinspect) run a deterministic
  external tool, parse it, hash-comparable. They follow
  `includes/static-analysis-context.md` and have A/B harness coverage.
- The 8 core LLM specialists (security/correctness/…) are judgement reviewers
  following `includes/specialist-context.md`.
- Housekeeper is a HYBRID candidate: `dotnet list package --outdated` is a
  deterministic tool (static-style), but "is this Action major stale?" is
  judgement (LLM-style). Decide which contract it follows — or whether it is a
  static specialist with an LLM-ish output. This materially changes the wiring
  (detection flag, cross-review opt-out, A/B treatment).

---

## The specialist pattern (the concrete wiring surface)

Every specialist is wired into the pipeline at a fixed set of points. To add one,
you touch ALL of these (grep `trivy-reviewer` across the repo for the exact
template — it is the most recent and cleanest analogue):

1. **`plugins/code-review-suite/agents/<name>-reviewer.md`** — the agent
   definition. Frontmatter: `name`, `description`, `model`, `tools`,
   `background: true`. Body cites either `includes/static-analysis-context.md`
   (static) or `includes/specialist-context.md` (LLM). Output follows the canonical
   §7 finding shape: `### Finding — title` / `- **File:** path:line` /
   `Confidence` / `Severity` / `Description` / `Suggested fix`.
   - **Model tier:** all 4 static specialists are now `model: haiku` + `effort:
     low` (Phase 3 sweep just closed — see [[project-phase-3-4-jbinspect-shipped]]).
     A new specialist should ship `model: sonnet` first and earn a haiku flip via
     the A/B sweep, NOT start on haiku. (The whole Phase 3 programme was about
     proving haiku-equivalence per specialist before flipping.)
2. **`plugins/code-review-suite/includes/review-pipeline.md`** — the orchestration:
   - Detection flag (~line 687-692): add e.g. `$HOUSEKEEPING_DETECTED` with its
     trigger (changed `*.csproj`/`Directory.Packages.props`/`.github/workflows/*`/
     `packages.config`/`package.json`/etc.).
   - Conditional dispatch block (~line 911, copy the trivy block verbatim).
   - `$SPECIALIST_COUNT` accounting (line 933).
   - Verify-completeness self-check enumeration (line 940).
   - Cross-review collection rules (line 1037) — decide if housekeeper findings are
     shown to cross-reviewers (static specialists are shown but don't receive).
3. **`plugins/code-review-suite/agents/review-synthesiser.md`** — the source-tag
   list (line 221: `[security]`, `[ruff]`, … add `[housekeeper]`). If it gets the
   static-analysis carve-out (severity-locked, confidence-100), add it to the
   `[eslint]/[ruff]/[trivy]/[jbinspect]` carve-out lists (lines 89, 125, and
   `includes/static-analysis-context.md` §10). If it's an LLM specialist, it does
   NOT get the carve-out.
4. **`plugins/code-review-suite/commands/pre-review.md`** and
   **`skills/review-gh-pr/SKILL.md`** — parallel dispatch wiring (these mirror the
   pipeline; the sync-note tests enforce consistency).
5. **`plugins/code-review-suite/README.md`** — the specialist/plugin table.
6. **If static:** the full A/B apparatus — `tests/ab/lib/agent_capture.sh` parser
   case, `tests/ab/corpus/<id>/` fixture + `source.yaml` + `expected/`,
   `tests/ab/configs/per-agent/<name>-{baseline,haiku-low}.yaml`,
   `tests/ab/corpus/index.yaml`. (Only if you go the static route AND want a
   haiku flip — mirror the jbinspect plan
   `docs/superpowers/plans/2026-06-04-phase-3-4-jbinspect-ab-baseline.md`.)

**Sync-note discipline:** several of these files carry "keep in sync" directives
and `tests/run.sh` has sync-note tests that FAIL if dispatch enumerations / regexes
drift across pipeline ↔ pre-review ↔ SKILL. Run `bash tests/run.sh` after every
change. The test `A/B run.sh: bad-config rejection leaves working tree clean`
false-fails on a DIRTY tree — that is the known artifact, not a regression; it
passes once committed clean.

---

## Process / house rules (carried from this programme)

- **`superpowers:brainstorming` FIRST**, then `superpowers:writing-plans` if the
  build is multi-step, then implement. The user runs plan mode by default.
- **TDD** for any parser/detection logic (`superpowers:test-driven-development`).
  The structural test suite (`tests/run.sh`, ~370 tests) is the safety net.
- **Plugin authoring conventions** are in the repo `CLAUDE.md`: frontmatter
  `name`+`description` required, blank line after closing `---`, 2-space indent for
  md/json, LF endings, `chmod +x` for bin/tools. No `version` field in
  `plugin.json` (git-SHA versioning).
- **Bash rules** (user global CLAUDE.md, non-negotiable, a hook enforces them):
  NO compound operators (`&&`/`||`/`;`), NO command substitution `$(...)` except
  the permitted `git commit -m "$(cat <<'EOF' …)"` heredoc, separate Bash calls
  not pipes/redirects where avoidable. Each command its own Bash tool call.
- **Temp files:** use the literal session `CLAUDE_TEMP_DIR` (`/tmp/claude-<id>/`),
  never bare `/tmp`. (This is also what bit the A/B harness — see the backlog.)
- **Commits:** no Co-Authored-By trailers, no Claude advertising. Direct-push to
  `main`. Push immediately after committing — `autoUpdate` has wiped unpushed work
  in this dir before ([[project-marketplace-autoupdate-wiped-branch]]).
- **Memory:** when done, write a `project_housekeeper_specialist_*.md` memory in
  the `~/.claude` repo memory dir
  (`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`,
  the SEPARATE `~/.claude` git repo) + a MEMORY.md index line; commit + push it
  separately.

---

## Parked backlog — DO NOT lose, return to after housekeeper

Three code-review-suite improvements were deferred to build the housekeeper. Full
context in memory `project_code_review_suite_backlog.md`. Summary:
- **#2 Generalise the A/B harness hook-leak fix** — Phase 3.4 fixed bare-`/tmp` in
  the per-agent path only (`tests/ab/run.sh:251,254`, `830905b`); the harness leaks
  the operator's global hooks into subagents. **Do this BEFORE any Workflow
  migration** — it's a correctness bug in the measurement rig.
- **#3 Re-validate ruff/eslint/trivy** against the apparatus fix (they were flipped
  under the old harness).
- **#4 Port trivy/ruff/eslint to `--stdout`** inline streaming (efficiency;
  jbinspect just did this, cut turns ~40%).

The big horizon item beyond those: the orchestrator → Workflow migration
([[project-orchestrator-workflow-migration]] — scoped: orchestration benefits all
specialists, schema-output only dissolves real fragility for the 4 static ones).

---

## Start by reading (in order)

1. **This handover.**
2. **The user's global "Repo Housekeeping" section** in `~/.claude/CLAUDE.md`
   (the intent source).
3. **`plugins/code-review-suite/agents/trivy-reviewer.md`** — the cleanest recent
   specialist to copy the pattern from (static, haiku+effort:low, worked example).
4. **`plugins/code-review-suite/agents/security-reviewer.md`** lines ~87-130 — the
   EXISTING version-freshness + version-safety coverage you must carve around.
5. **`plugins/code-review-suite/includes/version-freshness-cookbook.md`** — the
   shared freshness reference the housekeeper should cite, not re-derive.
6. **`plugins/code-review-suite/includes/review-pipeline.md`** Steps 4-5 (detection
   flags ~687, conditional dispatch ~861-921, cross-review ~1024-1058) — the wiring.
7. **`plugins/code-review-suite/includes/static-analysis-context.md`** (if static)
   or **`includes/specialist-context.md`** (if LLM) — the contract to follow.
8. **Memory:** `project_code_review_suite_backlog.md` (what's parked) and
   `project_phase_3_4_jbinspect_shipped.md` (the just-closed sweep + the
   ship-sonnet-then-flip-via-A/B discipline).
