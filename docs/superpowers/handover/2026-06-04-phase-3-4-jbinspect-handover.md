# Handover — Phase 3.4: jbinspect-reviewer Haiku/low A/B (the LAST static specialist)

**Date:** 2026-06-03 (for a session picking up 2026-06-04+)
**Predecessor:** Phase 3.3 trivy — shipped end-to-end this session. Verdict
EQUIVALENT after fix, production flipped to Haiku/low, live in the pipeline.
**Your job:** stand up the jbinspect A/B apparatus from scratch (it has none),
run the matched 2×20 Sonnet/default vs Haiku/low probe, produce the verdict +
result note + memory, and — on a clean EQUIVALENT — flip production. This is the
**4th and final** static specialist; finishing it closes the whole Phase 3
static-specialist tuning sweep.

---

## Where we've been (the programme arc — load-bearing context)

Phase 3 is a cost-tuning sweep: can each static-analysis specialist run on
**Haiku/low** instead of **Sonnet/default** without degrading findings? The test
is per-trial **findings-hash equivalence** at n=20 per arm on a deterministic
smoke fixture. Verdict framework (parent spec
`docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`):

- **EQUIVALENT** — Haiku matches the canonical hash within noise (clean,
  single-hash arm). → flip production.
- **INCONCLUSIVE (decision-4)** — mixed within-arm hashes default to inconclusive
  regardless of rate. → do not flip; characterise the tail.
- **WORSE** — >25 % NORMAL-rate drop. → do not flip.

**Results so far (3 of 4 done, all now flipped to Haiku/low):**

| Specialist | Verdict | Cost ratio | Production | Notes |
|---|---|---|---|---|
| ruff | EQUIVALENT (20/20) | ~2.2× | `haiku`+`effort:low` (`3b3a255`) | cleanest case |
| eslint | INCONCLUSIVE → fixed → EQUIVALENT (20/20) | 2.17× post-fix | `haiku`+`effort:low` (`3b3a255`) | PR C closed a tier-1 binary-resolution skip tail |
| trivy | INCONCLUSIVE → fixed → EQUIVALENT (20/20) | 2.34× post-fix | `haiku`+`effort:low` (`ee23a79`) | THIS session; see below |
| **jbinspect** | **unprobed** | — | `model: sonnet` | **your job** |

**The recurring pattern you should EXPECT (and not be alarmed by):** the initial
Haiku probe often shows one or two divergent trials that look like model failures
but are actually **agent-side over-literalism tripping a too-narrow harness
classifier**, which launders a *skip* into a false *0-findings* result. Both
eslint and trivy did exactly this. In every case the fix was a pair of
**general-correctness** changes (helping Sonnet too, so they pass the
tuning-to-the-test guard) — never a hash-chasing nudge — followed by a clean
re-sweep to 20/20. If jbinspect's first Haiku sweep is mixed, **diagnose before
despairing**: read the divergent trial's `stdout.log`, find the real mechanism,
and ask whether a model-agnostic fix closes it.

### What trivy (3.3) taught us — directly relevant to jbinspect

1. **Worked-example gap is real.** A specialist with NO `### Worked example`
   section in its agent body produces a §7 layout the parser can't read → parses
   to `[]` (zero tuples) even when the visible report is correct. trivy's first
   capture hit this. **jbinspect has NO worked example** (confirmed: only
   ruff/eslint/trivy do). You MUST do the capture-then-pin dance: capture one
   live Sonnet trial, see the REAL layout jbinspect emits, pin it as the worked
   example BEFORE the main sweep. Do not invent the example — capture it.
2. **Temp-dir contract over-literalism.** The prompt carries the literal
   `Use $CLAUDE_TEMP_DIR for temporary files.` with the token UNEXPANDED (both
   production via the Agent tool AND the A/B harness — verified byte-identical).
   trivy's Haiku trial-016 read the unexpanded token as "temp dir missing" and
   self-aborted. **jbinspect ACTUALLY needs the temp dir** (it writes
   `inspectcode-<sln>.xml` there and parses it — unlike trivy/ruff/eslint which
   can stream stdout), so this failure mode is MORE likely to bite, not less.
   The fix that worked for trivy (`5ccb692`): clarify in the agent body that the
   literal token satisfies the contract and Bash resolves it at command time.
   jbinspect's body (line 43) has the same terse `Check $CLAUDE_TEMP_DIR is
   present` instruction — pre-emptively consider the same clarification, but only
   ship it if a trial actually trips on it (characterise, don't pre-author).
3. **Skip-sentinel width.** trivy's narrow `^Skipped — trivy not available` let a
   non-PATH skip launder to false-0. Fixed to broad `^Skipped — ` (`91bb36d`).
   When you author jbinspect's parser case, use the BROAD `^Skipped — ` opener
   from the start (jbinspect has a single logical skip path → any skip is full).

---

## Where you are now (verified clean state)

- **Working tree:** clean, `main` level with `origin/main` at `ee23a79`. Direct-
  push to `main` is the established workflow (branch-protection bypass is expected
  and reported by the remote; **no PR** in this repo for this programme).
- **Suite:** 353 passed / 1 skipped on a clean tree (the skip is the
  `CLAUDE_CODE_E2E_TESTS=1`-gated behavioural smoke test). NB: when your working
  tree is dirty mid-task, the test `A/B run.sh: bad-config rejection leaves
  working tree clean` false-fails — that is the KNOWN dirty-tree artifact, not a
  regression. It passes once committed clean.
- **Tooling is PRESENT (the spec's deferral condition is lifted):**
  - `jb` → `/Users/jodre11/.dotnet/tools/jb`, **InspectCode 2026.1.0.1**.
  - `dotnet` SDK **10.0.300** (.NET 10 runtime).
  - This is the heavier-provisioning specialist the spec flagged (line 238) — but
    the tools are installed, so you can proceed. The fixture must be a real,
    compilable C# project with a `.sln` + `.csproj` (InspectCode needs a solution
    to inspect, unlike a single Dockerfile/py/js file).

### jbinspect apparatus: NONE of it exists yet (all four pieces are greenfield)

Confirmed absent — you build all of these (mirror the trivy plan
`docs/superpowers/plans/2026-06-03-phase-3-3-trivy-ab-baseline.md` task-by-task):

1. **Corpus fixture** — `tests/ab/corpus/jbinspect-smoke-bad-cs/` does not exist.
   Needs a `source.yaml` (NO `setup:` block — jb/dotnet are global-on-PATH like
   trivy/ruff, no per-trial provisioning race), a `diff/changed-lines.txt`, the
   real C# project under `tests/fixtures/static-analysis/jbinspect/` (or similar —
   check the existing `tests/fixtures/static-analysis/{ruff,eslint,trivy}/` shape),
   and an `index.yaml` registration. The C# fixture per the spec (line 124):
   `UnusedMember.Local` + `RedundantUsingDirective` + a possible-NullReference.
   **Ground-truth discipline (spec lines 127-130):** author the fixture, run
   `jb inspectcode` on it INDEPENDENTLY, capture the XML, and use what the TOOL
   actually emits as the canonical tuple set — not what you think it should emit.
   Watch for line-bearing-ness: every finding needs a `Line` attribute to survive
   the §5 changed-line intersection (trivy had to add a `USER` directive to
   suppress a line-less finding — expect an analogous tweak here).
2. **Parser-dispatch case** — `agent_capture.sh` has no `jbinspect` case. Add one
   after the `trivy` case: heading `^## JetBrains InspectCode Findings$`, skip
   `^Skipped — ` (broad), zero-state `^0 findings — no C# files in diff\.`. Note
   jbinspect has THREE zero-state strings (lines 18-21, 35-39 of the agent body:
   "no C# files", "could not determine solution") — decide whether the parser
   treats the solution-discovery-miss as zero or skip (lean zero; it's a genuine
   "nothing to inspect", not a tool failure). The CamelCase rule-ID tokeniser
   question is ALREADY ANSWERED: the shared splitter `split(v, a, /[ \t(]/)`
   (agent_capture.sh:179) handles `UnusedMember.Local (CodeSmell)` →
   `UnusedMember.Local` cleanly (the dot has no space/paren before it). **No
   tokeniser change needed** — but add a parser TEST asserting it, mirroring the
   trivy `bare DS-NNNN tokenises cleanly` test.
3. **Configs** — `jbinspect-baseline.yaml` (sonnet/default) +
   `jbinspect-haiku-low.yaml` (haiku/low) under `tests/ab/configs/per-agent/`.
   Copy the trivy config shape exactly. Add the mirrored config-parse test.
4. **Worked example** — pin it in `jbinspect-reviewer.md` AFTER the live capture
   (see point 1 of the trivy lessons). The `Rule:` field is `TypeId (Category)`
   per the agent body line 86.

---

## The plan to write (then execute)

**Start by writing the plan** with `superpowers:writing-plans`, mirroring
`docs/superpowers/plans/2026-06-03-phase-3-3-trivy-ab-baseline.md` structure:
offline Tasks 1-3 (fixture, parser, configs — commit freely, no Bedrock), then
GATED Tasks 4-5 (live worked-example capture + pin), then GATED Task 6 (the 2×20
sweep), then Task 7 (verdict + note + memory). Use
`superpowers:subagent-driven-development` for the offline implementation tasks
(they have spec/quality gates), but run the SWEEP itself directly in the main
loop (it's spend-then-analyse — inspecting run artifacts is the value, subagents
add overhead; this was the operator's stated preference for trivy 3.3).

### Gating (NON-NEGOTIABLE)

- **Tasks 1-3 offline** — no gate, commit + push each.
- **Task 4 (worked-example capture, ~1-3 trials) is live Bedrock** — GATED.
- **Task 5 step "re-capture to confirm the worked example" is live** — GATED.
- **Task 6 (the 2×20 sweep, ~$4-5 list / ~25-40 min — jbinspect trials are
  SLOWER than trivy because InspectCode loads a solution and runs the .NET
  analyser; budget more wall-clock) is the main spend** — GATED. Get a fresh,
  explicit go-ahead. "Continue" does NOT authorise the spend.
- **Task 7 offline** — no gate. Production flip is **operator-gated** even on a
  clean EQUIVALENT (it changes a dispatched-agent definition).

---

## Task 6 commands (once apparatus is built + gated go-ahead given)

```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/jbinspect-baseline.yaml --corpus jbinspect-smoke-bad-cs --trials 20 --stream-json
bash tests/ab/run.sh --config tests/ab/configs/per-agent/jbinspect-haiku-low.yaml --corpus jbinspect-smoke-bad-cs --trials 20 --stream-json
```

(NO `--mode` flag — mode is config-derived.) Run both arms (full matched pair;
jbinspect has no prior data). Consider `run_in_background: true` per arm and let
the completion notification land. Each prints its git-ignored output dir.

**Tabulate (Task 6 Step 3):** per arm's `summary.csv` — count trials matching the
modal (canonical) hash; tally INCONCLUSIVE/skip; compute mean `total_cost_usd`
and the **Sonnet ÷ Haiku ratio** (report RATIO only — the stream cost is
Anthropic LIST price, not Bedrock). Expect ~2.2-2.5× by the three-specialist
precedent.

---

## Task 7 — verdict + note + memory + flip

1. **Verdict** — framework verbatim (above). If a real agent-side tail survives a
   clean apparatus, CHARACTERISE it, do not pre-author a fix; any fix must be a
   general correctness improvement earning its own before/after at n=20 on both
   arms (the eslint/trivy precedent).
2. **Result note** — `docs/superpowers/notes/2026-06-04-jbinspect-haiku-low-result.md`.
   Mirror the closest precedent `docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md`
   (it has the full shape: header block with run dirs + sweep SHA, sweep config,
   hash distribution table per arm, any agent-side tail characterised, cost delta
   + ratio with list-price caveat, verdict verbatim, production-flip rec, and — if
   you fix-and-re-sweep — a "Fixes SHIPPED + re-sweep VALIDATED" section).
3. **Memory** (SEPARATE `~/.claude` repo, NOT this clone:
   `projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`):
   add `project_phase_3_4_jbinspect_shipped.md` + a `MEMORY.md` index line. Commit
   + push `~/.claude` separately.
4. **Production flip (operator-gated, only on clean EQUIVALENT):** set BOTH
   `model: haiku` AND `effort: low` in `jbinspect-reviewer.md` frontmatter
   (mirror trivy `ee23a79` / eslint+ruff `3b3a255`). To make it live mid-session:
   `/plugins update` then `/reload-plugins` (the A/B harness reads the working-
   tree file directly via `agent_dispatch.sh:113`, so the SWEEP needs no reload —
   only the live `/code-review` pipeline does).

---

## Sync coupling you MUST respect (jbinspect-specific, others didn't have this)

`jbinspect-reviewer.md` is **mirrored** into `agents/code-analysis.md` (the
monolithic reviewer). Both the agent body (line 92) and `code-analysis.md`
(line 19) carry a "keep in sync" directive. If your worked-example pin or any
C#-procedure clarification changes the jbinspect body, **check whether
`code-analysis.md`'s InspectCode section (lines 13-19, 71-98) needs the mirror**.
The structural test suite enforces some of this — run `bash tests/run.sh` and
watch for sync-note failures. (ruff/eslint/trivy had no such monolith mirror, so
this is a new wrinkle for 3.4.)

---

## Start by reading (in order)

1. **The trivy plan** (your structural template):
   `docs/superpowers/plans/2026-06-03-phase-3-3-trivy-ab-baseline.md`.
2. **The trivy result note** (your result-note template, incl. the fix-and-
   re-sweep arc): `docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md`.
3. **The parent spec** (verdict framework + jbinspect fixture spec lines 124,
   238, 257): `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`.
4. **The jbinspect agent body** (what you're probing + the sync coupling):
   `plugins/code-review-suite/agents/jbinspect-reviewer.md` and the InspectCode
   section of `plugins/code-review-suite/agents/code-analysis.md`.
5. **Memory** (in `~/.claude`): `memory/project_phase_3_3_trivy_shipped.md`
   (the closest precedent — fix-then-flip arc, harness-reads-working-tree note)
   and `memory/project_worked_example_gap.md` (why a missing worked example
   parses to zero).

## After jbinspect (the horizon — NOT this handover)

Phase 3 is COMPLETE once jbinspect ships. The deferred longer-term item:
**convert the code-review orchestrator to a deterministic Workflow with
schema-validated specialist output** — dissolving the whole markdown-parse
apparatus (the §7 worked-example fragility this programme has repeatedly
patched). Start from `superpowers:brainstorming` if taken up. See
`memory/project_worked_example_gap.md` and
`memory/project_phase_3_2b_pr_a_apparatus_fix.md`.
