# Handover — add a "housekeeper" specialist to the code-review-suite

> **STATUS: DEFERRED (2026-06-04, same day as written) — do NOT build yet.**
> After this handover was drafted, the user chose to first FIX the root cause it
> identified rather than build around it: `security-reviewer` was granted
> `WebFetch + WebSearch` (commit `4a847e9`) and its #6a/#7 Focus Areas now name
> the fetch tool concretely, so it can actually verify versions against latest-GA
> live registry data — the capability gap that justified the housekeeper. The
> housekeeper is **parked pending evidence** of how the tweaked security-reviewer
> behaves in practice. If security-reviewer now covers freshness well, the
> housekeeper may not be needed at all. Revisit ONLY if real-world use shows
> security-reviewer's freshness coverage is insufficient or that a dedicated,
> deterministic, A/B-testable freshness specialist earns its keep. The design
> analysis below remains valid input for that decision.

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

### THE CORE PROBLEM the housekeeper solves (user's framing, 2026-06-04)

**`security-reviewer` does not actually check live data — and structurally
cannot.** Its body (`security-reviewer.md:87-95`) and the cookbook
(`version-freshness-cookbook.md:7`) both MANDATE a live registry fetch ("Live web
fetch is required; do not rely on cached or trained-knowledge answers"). But
`security-reviewer`'s tool grant is `Read, Grep, Glob, Bash` — **no `WebFetch` /
`WebSearch`**. So that instruction is UNENFORCEABLE: with no fetch tool the agent
falls back to trained-knowledge answers, which are stale and non-deterministic.
The "Version freshness (#7)" Focus Area is effectively a dead instruction.

**The user wants to AUTOMATE the live-data lookup and FEED IT INTO CROSS-REVIEW.**
That reframes the housekeeper entirely:

- The housekeeper is the agent that **actually fetches live registry data** — the
  cookbook endpoints (npm/NuGet/PyPI/RubyGems/crates/Go/GitHub Actions releases),
  parallel, capped at 10. It must therefore be granted a fetch capability:
  `WebFetch` in its `tools:` list, OR a deterministic `Bash` script that curls the
  registry JSON endpoints (the cookbook lists exact URLs + which field to read).
  **Prefer the deterministic-tool route** — relying on an LLM to remember to fetch
  10 registries reproduces exactly the failure security-reviewer has now. A script
  that emits `{package, current, latest, stale: bool}` tuples is hash-comparable
  and A/B-testable (this nudges housekeeper toward the STATIC-specialist contract).
- Its freshness findings are then **fed to the cross-reviewers** — especially
  `security-cross-review`, which can escalate any stale dependency that also
  carries a known advisory (the version-*safety* path security-reviewer DOES own).
  This is the "feed for cross review" requirement: housekeeper produces the live
  facts; security judges their security implications.

So the relationship is **not** overlap-and-dedupe — it's a **division of labour**:
housekeeper owns live-data freshness (because it's the only one that can fetch),
security owns vulnerability judgement and consumes housekeeper's findings via
cross-review.

---

## NOT a greenfield — existing coverage to carve around (and CLEAN UP)

There is existing coverage of this domain, but given the core problem above the
relationship is **division of labour**, not overlap-and-dedupe. Map it in
brainstorming, then act on it.

Existing coverage found (2026-06-04):
1. **`security-reviewer` "Version freshness (#7)"** (`security-reviewer.md:87-95`)
   — the DEAD path described above (mandates a live fetch it has no tool to do).
   **Brainstorming must decide what happens to it:** most likely the housekeeper
   TAKES OVER live freshness, and #7 is either removed from security-reviewer or
   reduced to "freshness is owned by housekeeper; consume its findings via
   cross-review." Leaving two specialists both claiming freshness (one of which
   can't actually fetch) is the worst outcome. Also touches False-Positive Rule #9
   and the dedupe note (`security-reviewer.md:127-130`) — both reference the #7
   path and must be updated in lockstep.
2. **`security-reviewer` version-*safety* path** — vulnerable old versions raised
   at Important/Critical. This STAYS with security (it's vulnerability judgement,
   not freshness). The housekeeper FEEDS this: housekeeper says "X is stale → Y is
   latest", security-cross-review escalates if X has a known advisory. Keep the
   boundary crisp: housekeeper = "is it current?" (live fact); security = "is the
   old version dangerous?" (judgement).
3. **`trivy-reviewer`** — owns Trivy/IaC findings (Dockerfile/TF/K8s/Helm/CFN) on
   `$IAC_DETECTED`. Housekeeper should **EXCLUDE IaC** (defer to trivy) unless
   brainstorming finds a strong reason to fold it in — running trivy in two places
   is pure duplication. The CLAUDE.md "Trivy/IaC" housekeeping bullet is already
   served by trivy-reviewer; the housekeeper's novel contribution is deps + Actions
   + runners freshness, not IaC.
4. **`includes/version-freshness-cookbook.md`** — the shared endpoint/ecosystem
   reference (exact registry URLs + which JSON field = "latest"). The housekeeper
   should CITE and CONSUME this (it is literally the fetch spec the housekeeper
   needs), not re-derive it. Currently consumed by security-reviewer, pre-review,
   review-gh-pr SKILL — check whether those citations move to housekeeper too.

**Brainstorming decides:** the housekeeper IS justified (it fills a real
capability gap security-reviewer structurally cannot). The open questions are
(a) the exact carve (recommend: deps + Actions + runners freshness, EXCLUDE IaC
and vulnerability-judgement), (b) how to retire/redirect security's dead #7 path,
and (c) the fetch mechanism (deterministic Bash/curl script vs `WebFetch` tool —
see the static-vs-LLM axis below). The user values [[feedback-scope-discipline]] —
the cleanup of the dead path is part of the job, not scope creep.

A second brainstorming axis: **static-analysis specialist vs LLM specialist?**
The live-fetch core problem pushes HARD toward the static/deterministic end —
re-read "THE CORE PROBLEM" above before deciding.
- The 4 static specialists (ruff/eslint/trivy/jbinspect) run a deterministic
  external tool, parse it, hash-comparable. They follow
  `includes/static-analysis-context.md` and have A/B harness coverage.
- The 8 core LLM specialists (security/correctness/…) are judgement reviewers
  following `includes/specialist-context.md`.
- Housekeeper leans STATIC: the whole point is to replace trained-knowledge
  guessing with a deterministic live lookup. A Bash/curl script hitting the
  cookbook endpoints and emitting `{package, current, latest, stale}` tuples is
  exactly the static-specialist shape (tool → parse → hash) and is A/B-testable.
  `dotnet list package --outdated` / `npm outdated` are also deterministic tools.
  The judgement-ish parts ("is this Action major bump safe to suggest?") are thin
  and can be left to the synthesiser/cross-review. **Recommendation to test in
  brainstorming: build it as a static specialist** following
  `static-analysis-context.md`, granted whatever fetch capability the chosen
  mechanism needs. If it's static, it also gets the §10 severity-locked/
  confidence-100 carve-out and an A/B sweep before any haiku flip.
- Caveat the static route must handle: live registry fetches are
  **non-deterministic across time** (today's "latest" differs from next month's),
  so the A/B corpus can't hash against a frozen "latest". Brainstorm how to make
  it testable — e.g. a mock/recorded registry fixture, or hash the
  stale-vs-current DECISION against a pinned fixture manifest rather than the live
  number. This is a genuinely new wrinkle none of the 4 existing static
  specialists had (their tools are offline/deterministic).

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
