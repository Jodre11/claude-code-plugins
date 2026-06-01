# Phase 3.1c brainstorm — handover (mid-flow, post-clarifying-questions)

**Date:** 2026-06-01
**Status:** Brainstorm in progress — clarifying questions answered, approach
proposed, awaiting user approval before writing the design doc.
**Continues:** Phase 3.1a empty-stdout investigation
([../notes/2026-05-29-empty-stdout-investigation-result.md](../notes/2026-05-29-empty-stdout-investigation-result.md),
PR #36, merged commit `dae8ca4`).
**Resumes into:** `superpowers:brainstorming` skill, mid-checklist between
"Propose 2-3 approaches" (done) and "Present design in sections" (next).
**Branch this handover lives on:** `feat/phase-3-1c-handover` (off `origin/main`,
unrelated to whatever branch the new session starts on).

## What Phase 3.1c is

Phase 3.1c is the cross-cutting "tighten contracts + fail-loud" sub-phase of
the per-agent A/B harness programme. It addresses the two apparatus problems
that 3.1a's 20-trial sweep at Haiku/`low` against `ruff-smoke-bad-py`
documented:

1. **EMPTY incidence 30 %** (Wilson 95 % CI [14.55 %, 51.90 %]) — Category C
   envelope-final-text emission gap inside the Claude Code CLI's stream-json
   pipeline. The model emits 364–671 chars of canonical text across
   `assistant.message.content[].text` blocks, then the terminal
   `{type:"result", subtype:"success"}` envelope's `.result` field is the
   empty string.
2. **DRIFT incidence 65 %** (Wilson 95 % CI [43.29 %, 81.88 %]) — free-form
   ruff prose the harness's findings parser cannot match. The §7 markdown
   contract in `static-analysis-context.md` has already drifted in the
   captured baseline (see "Concrete observations from the read-through"
   below).

Phase 3.1c sits in the programme between 3.1a (now complete) and 3.1b (the
re-probe of ruff cost-tuning, blocked on 3.1c):

```
Phase 3.1   abandoned-for-cause                 (PR #35)
  ↓
Phase 3.1a  empty-stdout investigation          (PR #36, merged dae8ca4)
  ↓
Phase 3.1c  tighten contracts + fail-loud       ← THIS, mid-brainstorm
  ↓
Phase 3.1b  redo ruff cost-tuning               (richer fixture, separated axes)
  ↓
Phase 3.2 / 3.3 / 3.4   eslint / trivy / jbinspect
```

## Where the new session needs to pick up

The brainstorming-skill checklist position:

```
1. Explore project context              [DONE]
2. Offer Visual Companion               [SKIPPED — non-visual topic]
3. Ask clarifying questions             [DONE — five answered]
4. Propose 2-3 approaches               [DONE — Approach A recommended]
5. Present design in sections           [NEXT — awaiting user approval of A]
6. Write design doc                     [pending]
7. Spec self-review                     [pending]
8. User reviews written spec            [pending]
9. Transition to writing-plans          [pending]
```

The terminal state is invoking `superpowers:writing-plans`. Do NOT invoke
any other implementation skill.

## The five clarifying questions and their answers

These five answers narrow the design space — re-grounding any new session.

| # | Question | Answer |
|---|---|---|
| 1 | Single 3.1c spec covering both EMPTY and DRIFT, or split? | **Single coherent spec**, one PR. |
| 2 | Harness fallback always-on or `--stream-json`-conditional? | **`--stream-json`-conditional.** Without stream-json there is no JSONL substrate to recover from. |
| 3 | Validate-or-die assertion site? | **In `launch_run_per_agent_trial`**, after rc capture. Fallback gets first chance; only unrecoverable cases trigger fail-loud. |
| 4 | Contract-pinning aggressiveness? | **Pin to canonical §7, fix the baseline, retighten the parser.** Drop the `**Finding N**` retrofit and `**Message:**` / `**Detail:**` synonyms. Add a fully-formed §7 example block to the agent-prompt anchor (location TBD in design). |
| 5 | Validating the contract pin? | **Re-run the 20-trial sweep at Sonnet/default** after the pin lands. DRIFT target <10 %; EMPTY stays at the 30 % floor (recovered by fallback into NORMAL). |
| 6 | Other static-specialist parsers (eslint/trivy/jbinspect)? | **Ruff only.** Contract pin is cross-cutting in `static-analysis-context.md`; future specialists' parsers will be authored from the start against the pinned contract. |
| 7 | Upstream Claude Code bug filing? | **Track as a 3.1c side artefact, file independently.** Note in the spec's "related work" section; don't gate the PR on it. |

(That's seven Q&A — questions 6 and 7 were follow-ups on parser scope and
upstream filing within the post-recommendation flow. The first five were the
core clarifying-question pass.)

## The recommended approach (Approach A — already presented to the user)

**One PR**, branch `feat/phase-3-1c-tighten-contracts`, ships four
deliverables:

1. **Harness fallback** in `tests/ab/lib/launch.sh` — extend the existing
   `jq` reconstruction at lines 265–270 so when `.result == ""` it falls
   back to concatenating `assistant.message.content[].text` blocks.
   Stream-json-conditional. Estimated ~10 lines.
2. **Validate-or-die** in `launch_run_per_agent_trial` after rc capture —
   fail loud (non-zero rc + structured stderr) when
   `stdout.log ≤ 1 byte AND (stream.jsonl missing OR no terminal result event
   OR result.subtype=error)`. Fallback runs first; only unrecoverable cases
   trigger the assertion. Extract a small assert helper (~10 lines) so
   `launch.sh` doesn't grow yet another responsibility.
3. **Contract pin** — establish canonical §7 of
   `plugins/code-review-suite/includes/static-analysis-context.md` as
   authoritative; regenerate
   `tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md` to
   canonical form (`### Finding — title`, `**Description:**`,
   `**Suggested fix:**`); tighten `agent_capture_parse_ruff_trial` in
   `tests/ab/lib/agent_capture.sh` to drop the `**Finding N**` retrofit and
   the `**Message:**` / `**Detail:**` synonyms. Add a fully-formed §7
   example block at an agent-prompt anchor — location TBD in the design
   (likely as an additional include cited from `ruff-reviewer.md`, or
   inline in the agent file itself).
4. **20-trial Sonnet/default validation sweep** — runs after the pin lands.
   Target: DRIFT <10 %; EMPTY stays at the 30 % floor (now recovered into
   NORMAL via the fallback). ~50 k tokens.

**Why this shape:** the user has already confirmed single-spec scope, and
the actual code surface is small (~50–80 lines across 4 files plus
spec/baseline/agent-prompt edits). Splitting introduces sequencing churn
without reducing risk. The validation sweep is the load-bearing
proof-of-fix — it belongs in the same PR as the changes it proves out, not
a follow-up.

The user has been asked: **"Does Approach A look right? If yes, I'll move
into the design proper section by section."** That message is the most
recent assistant turn before the handover request.

## Concrete observations from the read-through (load-bearing)

These two facts surfaced during context exploration and shape the design:

1. **The §7 contract has already drifted in the baseline itself.**
   `static-analysis-context.md §7` specifies `### Finding — [title]` with
   `**Description:**` and `**Suggested fix:**`. The captured baseline at
   `tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md` uses
   `**Finding 1**` with `**Message:**` and `**Detail:**`. The parser was
   empirically retrofitted to the drift. So "pin the contract" means
   deciding which of (canonical §7, retrofitted parser-accepted, both) is
   the source of truth — and the user picked canonical §7.

2. **The harness fallback already partially exists.**
   `tests/ab/lib/launch.sh` lines 265–270: when `stream.jsonl` is non-empty,
   the harness runs `jq -r 'select(.type == "result" and .subtype == "success") | .result' > stdout.log`.
   This is exactly the path that produces empty stdout in the EMPTY trials —
   `.result == ""`. The fix is a 5–10 line extension to that jq filter, not
   a new module.

## Files to read on resume (in order)

1. `docs/superpowers/notes/2026-05-29-empty-stdout-investigation-result.md`
   — the 3.1a result report; load-bearing for everything below.
2. `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md` —
   parent Phase 3 spec; 3.1c is one of its dependencies.
3. `plugins/code-review-suite/includes/static-analysis-context.md` —
   canonical §7 contract.
4. `plugins/code-review-suite/agents/ruff-reviewer.md` — agent prompt;
   currently `model: sonnet`.
5. `tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md` — the
   already-drifted baseline.
6. `tests/ab/lib/launch.sh` — the harness primitive (esp. lines
   ~242–290 around the stream-json fallback).
7. `tests/ab/lib/agent_capture.sh` — the parser to retighten.

The auto-memory entries `[[phase-3-1a-empty-stdout-investigation]]`,
`[[phase-3-1-ruff-haiku-low-probe]]`,
`[[orchestrator-empty-stdout-anomaly]]`, and
`[[models-overlook-tuning-hooks]]` will autoload at session start.

## Out of scope for 3.1c (do not get distracted)

- Touching `plugins/code-review-suite/agents/*-reviewer.md` `model:` fields.
  Those stay at `model: sonnet` until 3.1b's re-probe completes.
- End-to-end mode `--stream-json` plumbing. The user explicitly out-of-scoped
  this unless the brainstorm decides it's load-bearing for validate-or-die.
  The current design uses the per-agent codepath only.
- Authoring eslint / trivy / jbinspect parsers. Those are 3.2 / 3.3 / 3.4
  work; only ruff's parser is retightened in 3.1c.
- Revisiting 3.1a's verdict.
- Filing the upstream Claude Code bug — tracked as a side artefact, not a
  PR gate.

## Verbatim resume instruction for the new session

> Phase 3.1c brainstorm is mid-flow. The brainstorming-skill checklist is
> through "Propose 2-3 approaches"; the next step is "Present design in
> sections." Approach A (single PR, four deliverables: harness fallback +
> validate-or-die + contract pin + validation sweep) has been recommended
> to the user and is awaiting their yes/no. Read this handover, the 3.1a
> result report, and the seven files listed in "Files to read on resume",
> then ask the user whether Approach A still looks right. If yes, move
> directly into presenting the design in sections (architecture →
> components → data flow → error handling → testing) per the
> superpowers:brainstorming skill, getting user approval after each
> section. Do NOT re-litigate the five clarifying questions unless the user
> raises one. Do NOT skip ahead to writing the design doc until the
> sections-walkthrough is approved. Do NOT invoke writing-plans until
> after the spec is written, self-reviewed, and the user has approved it.

## Cross-references

- Phase 3.1a result report:
  `docs/superpowers/notes/2026-05-29-empty-stdout-investigation-result.md`
- Phase 3.1a investigation handover (precedent for this handover's format):
  `docs/superpowers/handover/2026-05-29-phase-3-1a-empty-stdout-handover.md`
- Phase 3 sweep spec (parent of 3.1c):
  `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`
- Phase 3.1 abandoned-for-cause carrier PR: #35
- Phase 3.1a investigation PR: #36 (commit `dae8ca4`)
- Per-agent harness Phase 2 chassis PR: #33 (commit `b214944`)
