# Handover — Execute the per-cog I/O instrumentation plan (subagent-driven)

**Paste the block below into a clean session to continue.**

---

I'm executing an approved, committed implementation plan in the `code-review-suite` plugin
(`~/.claude/plugins/marketplaces/jodre11-plugins`). Planning is **done** — do NOT
re-plan, re-brainstorm, or re-design. Execute the existing plan **task-by-task using the
`superpowers:subagent-driven-development` skill**: dispatch a fresh subagent per task,
review the subagent's diff against the plan's stated code between tasks, and stop at each
checkpoint.

## Read first (in order)

1. **Plan (authoritative, execute this):**
   `docs/superpowers/plans/2026-06-19-phase-efficacy-instrumentation.md`
   — 7 tasks, each TDD (write failing test → run → implement → run → commit) with exact
   file paths, complete code, exact commands, and expected output. Read it in full.
2. **Spec (background / "why"):**
   `docs/superpowers/specs/2026-06-19-phase-efficacy-instrumentation-design.md`
   (committed at `cad16d7`) — problem, goal, the stored-vs-reconstructed decision, schema,
   testing. Read for context; the plan is what you implement.

## One-paragraph context

Forward-programme thread 2 (#63, phase-efficacy analysis) is observational and consumes
"the full unfiltered logs from real reviews" — but the durable full-log built by the
output-presentation work (#58/#59) only captures the FINAL synth envelope, not the per-phase
journey. This plan extends it into a **per-cog I/O fixture corpus**: every specialist,
cross-reviewer, and the synthesiser captured with its input (stored, or reconstructable from
meta SHA keys) and output, so any single cog can be replayed against frozen input. One
instrument serves three threads: #63 now, and the #64/#65 model sweeps later (A/B a cog on a
different model against the same recorded input).

## What the 7 tasks do (the plan has the detail)

1. `buildLogPayload(envelope, phaseLog)` — gains an optional 2nd arg; omits `meta`/`cogs`
   when `phaseLog` is undefined (back-compat with existing callers/tests).
2. Declare a write-only `phaseLog` accumulator in `run()`; capture round-1 specialist output
   per domain + the four meta reconstruction keys (`base`, `head_sha`, `empty_tree_mode`,
   `path_scope`). Thread `phaseLog` into both `buildLogPayload` call sites.
3. Change `crossAndSynth` to return `{envelope, crossByDomain}` (was a bare envelope);
   capture per-cog cross-review I/O (peer-set input + opinions/escalations output). Namespace
   the two draws as `cross` (round 1) vs `cross2` (round 2).
4. Capture the synth cog (input = findingsByDomain + cross opinions/escalations + intent
   ledger; output = tiers) and, when the boundary gate fires, `round2` specialist cogs + one
   `union` record + the round-2 synth cog. Gate-quiet runs have NO round2/union records —
   absence is the gate-fire signal.
5. Reconstruction round-trip test: prove the four meta keys regenerate the exact diff a
   specialist sees (uses this repo's own HEAD~1..HEAD as a stable fixture).
6. Extend `finding-schema.json` (`sealedBundle.log` gains optional `meta`/`cogs`) and the
   Step 7a host writer in BOTH `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md`
   (byte-identical block — a test asserts both carry the per-cog JSONL instructions).
7. Full suite green → push → PR (reference #63) → after merge `/plugins update` +
   `/reload-plugins` → live smoke with `full_log = true` on a real borderline PR.

## Key constraints / gotchas (the plan's Global Constraints is authoritative)

- **No behaviour change to reviews.** `phaseLog` is write-only during the run, read once at
  the end by `buildLogPayload`; verdict/posting/gate logic never read it.
- **The raw diff is NOT stored.** Meta carries `base`/`head_sha`/`empty_tree_mode`/
  `path_scope` (snake_case in JSONL; camelCase `base`/`headSha`/`emptyTreeMode`/`pathScope`
  in `resolvedArgs`). The diff is reconstructed on demand.
- **Behind the existing `full_log` flag** — off by default, local-only
  (`$HOME/.claude/code-review-suite/logs/`), never committed, never posted. No new knob; the
  bundle always carries `log.cogs`, but the host only WRITES it to disk under `full_log`.
- **Lightweight path is untouched** — it returns `buildLightweightBundle(...)` before
  `phaseLog` exists; emits no per-cog corpus by design.
- **Round-1/round-2 namespace isolation** — `crossAndSynth` is called twice; the call sites
  push into `cross` vs `cross2` and `synth` (twice) / `round2` / `union` so the two draws
  never collide. This is the drift risk that ruled out the "compose at call sites" approach.
- **Verified before handover:** no test invokes `crossAndSynth` directly (Task 3's
  return-shape change is safe), and no sync-note test currently guards the Step 7a block
  (Task 6 won't trip a hidden parity check). Re-confirm in Task 3 Step 6 / Task 6 Step 6.
- This is a Workflow-sandbox `.mjs`: no `import()`, no `Date.now()`/`Math.random()`; the
  runtime injects `agent`/`parallel`/`phase`/`log`/`args`. Tests strip the `export` and wrap
  the body in an async `new Function(...)` — see the existing
  `tests/lib/test_variance_resampling.sh` and `tests/lib/test_output_presentation.sh`
  harness, which the new `tests/lib/test_phase_efficacy.sh` mirrors.

## Subagent-driven execution discipline

- Use `superpowers:subagent-driven-development`. Dispatch ONE subagent per task; do not batch
  tasks. Review the subagent's diff against the plan's stated code before accepting —
  trust-but-verify (the subagent's summary describes intent, not necessarily what it did).
- Per my global directives: dispatch agents with `mode: "auto"` and a kebab-case `name`
  (e.g. `task-1-buildlogpayload`, `task-3-cross-capture`). Pass the resolved
  `CLAUDE_TEMP_DIR` value in each subagent prompt.
- Tasks are sequential (Task 2 depends on Task 1's signature; Task 3 changes the return shape
  Task 4 destructures; Task 6 documents what Tasks 2–4 produce). Do not parallelise.
- After every task: run `bash tests/run.sh` from the repo root and confirm `0 failed` before
  moving on. Each task ends with its own commit (commit messages are in the plan).

## Process

- Plugin repo with its own git + CI; commit and push **independently** (it does not appear in
  `claude-settings` history). It has branch protection on `main` — open a PR rather than
  admin-bypass pushing. PR description: brief non-technical context first (per the plan's
  Task 7 Step 2), then the technical change list; reference issue #63.
- After pushing/merging mid-session, run `/plugins update` then `/reload-plugins` (or start
  fresh) before the Task 7 live smoke.
- Honour `~/.claude/CLAUDE.md`: separate Bash calls (no `&&`/`;`/`|`/command-substitution),
  no Co-Authored-By trailers, no Claude Code advertising in PR descriptions, 2-space indent
  for JS/JSON/Markdown.

Start by reading the plan and the spec, then begin Task 1 with a fresh subagent.
