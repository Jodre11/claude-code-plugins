# Handover — execute housekeeper specialist (vertical slice 1)

**Date:** 2026-06-05
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (own remote
`Jodre11/claude-code-plugins`; direct-push to `main`, push immediately;
branch-protection-bypass notice on push is expected/benign).

**State:** brainstorming + writing-plans are DONE. The spec
(`docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`) and the
implementation plan (`docs/superpowers/plans/2026-06-05-housekeeper-specialist.md`)
are committed + pushed (plan = `d593f61`). The next session EXECUTES the plan
task-by-task via subagent-driven-development. No code has been written yet.

**What is being built:** a new `housekeeper-reviewer` static specialist in the
`code-review-suite` plugin — a registry-backed dependency/version freshness
reviewer. Vertical slice 1 covers three source classes (GitHub Actions
`uses: org/action@vN`, workflow `runs-on:` runners, npm `package.json`) via a
net-new Python engine (`bin/housekeeper-freshness`), full pipeline wiring,
retirement of security-reviewer's dead `#7` freshness path, and the complete
A/B apparatus + a gated 2×20 Haiku/low sweep. 14 tasks, TDD throughout.

**The paste-ready prompt for the next session is in this repo's
`docs/superpowers/handover/2026-06-05-housekeeper-slice1-execution-handover.md`
(this file). It is reproduced verbatim below the line for copy/paste.**

---

Execute the implementation plan at
`docs/superpowers/plans/2026-06-05-housekeeper-specialist.md` in this repo
(`~/.claude/plugins/marketplaces/jodre11-plugins`).

Use the `superpowers:subagent-driven-development` skill: dispatch a fresh
subagent per task, two-stage review between tasks, commit + push after each
task as the plan specifies. Always set `mode: "auto"` and a kebab-case `name`
on every dispatched agent (per my global CLAUDE.md). Pass the resolved
`CLAUDE_TEMP_DIR` to any subagent that needs temp files.

Context to load first (read in this order, do NOT re-derive):
1. The plan: `docs/superpowers/plans/2026-06-05-housekeeper-specialist.md` — it
   is self-contained, with complete code/tests/commands per step.
2. The design spec it implements:
   `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`.
3. The template specialist to mirror:
   `plugins/code-review-suite/agents/trivy-reviewer.md` and the static-analysis
   contract `plugins/code-review-suite/includes/static-analysis-context.md`.

Settled decisions — honour, do not re-litigate:
- Engine is Python in `bin/` (stdlib only, no pip deps), emitting a hash-stable
  JSON tuple set; the agent is a thin §7 renderer.
- SHA-pinned Actions: trust the trailing `# vX.Y.Z` comment; no comment → no
  finding. No live commit lookup this slice.
- Model tier ships `model: haiku` + `effort: low` directly (my call, recorded
  against the suite's sonnet-then-flip discipline); the A/B harness is built
  anyway and swept post-build; sonnet is the fallback ONLY if equivalence fails.
- Slice 1 = Actions + runners + npm. NuGet/PyPI/crates/Go/RubyGems/Docker/SDK
  are deferred to follow-on plans on the same chassis — do NOT build them now.

Hard house rules (from my global + repo CLAUDE.md):
- Bash: NO compound operators (`&&`/`||`/`;`), NO command substitution `$(...)`
  except the permitted `git commit -m "$(cat <<'EOF' …)"` heredoc. One command
  per Bash call. A pre-commit hook enforces this.
- Temp files under the literal session `CLAUDE_TEMP_DIR` (`/tmp/claude-<id>/`),
  never bare `/tmp`.
- Commits: no Co-Authored-By, no Claude advertising. Push immediately after each
  commit (`autoUpdate` has wiped unpushed work in this dir before).
- Plugin authoring: frontmatter `name`+`description`, blank line after closing
  `---`, 2-space indent for md/json, LF endings, `chmod +x` for `bin/`.
- `bash tests/run.sh` is the safety net; the
  `A/B run.sh: bad-config rejection leaves working tree clean` test false-fails
  on a dirty tree — that is the known artifact, not a regression (commit first).

Execution sequencing notes baked into the plan — read them, they matter:
- Tasks 9 and 10 deliberately leave two sync-note tests RED until Task 12
  updates the test anchors in lockstep. Batch Tasks 9–12 before any green-bar
  gate, or accept the documented transient red. Do NOT "fix" the red by
  reverting the doc edits.
- Task 13 Step 4 has the one genuine unknown: whether the A/B harness can inject
  `HOUSEKEEPER_REGISTRY_FIXTURES` into the dispatched subagent's environment.
  Read `tests/ab/run.sh` and `tests/ab/lib/agent_dispatch.sh` to confirm; if it
  can't, the live capture runs against real registries (acceptable for these
  stable stale-pins) and the unittest `EndToEndTest` independently guarantees
  engine determinism. Adapt at that step; flag what you chose in the result note.

Gating — STOP for explicit operator go-ahead before spending Bedrock:
- Tasks 1–13 are fully offline; commit + push freely as you go.
- Task 14 (live worked-example capture, then the matched 2×20 sweep) spends real
  Bedrock — STOP and ask before the capture step AND before the sweep step.
  "Continue" does not pre-authorise either spend.
- The production-flip decision in Task 14 is operator-gated even on a clean
  EQUIVALENT verdict.

When the offline tasks (1–13) are complete, pause and report status before
Task 14. After Task 14, write the `project_housekeeper_specialist_slice1.md`
memory + MEMORY.md line in the SEPARATE `~/.claude` repo memory dir
(`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`),
commit + push that repo separately, then summarise what shipped and what the
follow-on plans should pick up.
