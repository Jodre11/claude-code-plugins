# Handover — Phase 3.4 jbinspect A/B: the GATED live phase (Tasks 4-7)

**Date:** 2026-06-04 (for a session picking up the Bedrock-spending half)
**Predecessor:** the offline apparatus (Tasks 1-3) is BUILT, committed, and pushed to
`main`. This handover covers only the live, operator-gated remainder.
**Your job:** capture one live Sonnet trial → pin the worked example → run the matched
2×20 sweep → write the verdict/note/memory → (on clean EQUIVALENT, operator-gated) flip
production. Finishing this closes the **entire Phase 3 static-specialist tuning sweep**
(jbinspect is the 4th and final specialist).

---

## Where you are now (verified clean state)

- **Working tree:** clean, `main` level with `origin/main` at **`d1f7cab`**. Direct-push
  to `main` is the established workflow — the remote reports a branch-protection bypass
  on every push; that is expected and benign. **No PR** in this repo for this programme.
- **Commits already landed this phase (offline Tasks 1-3 + plan):**
  - `ccdb14e` — `test(ab): add jbinspect-smoke-bad-cs corpus fixture (3 deterministic C# findings)`
  - `a7c8b03` — `test(ab): add jbinspect parser-dispatch case + captured-output tests`
  - `dbadd17` — `test(ab): add jbinspect baseline + haiku-low per-agent configs`
  - `d1f7cab` — `docs(ab): Phase 3.4 jbinspect A/B baseline implementation plan`
- **Suite:** 368 tests, 367 passed / 1 skipped, 0 failed on a clean tree (the skip is the
  `CLAUDE_CODE_E2E_TESTS=1`-gated behavioural smoke). NB the test
  `A/B run.sh: bad-config rejection leaves working tree clean` false-fails when the
  working tree is DIRTY mid-task — that is the KNOWN dirty-tree artifact, not a
  regression; it passes once committed clean.
- **Tooling present:** `jb` → InspectCode **2026.1.0.1**; dotnet SDK **10.0.300**
  (.NET 10 runtime). Verified working.
- **The full plan** (read it — your task texts live there):
  `docs/superpowers/plans/2026-06-04-phase-3-4-jbinspect-ab-baseline.md`. Tasks 4-7 are
  the remaining tasks; Tasks 1-3 are done.

### CRITICAL environment quirk (bit me, will bit you)

`$CLAUDE_TEMP_DIR` is **NOT exported into the Bash tool's shell**. If you write
`--output=$CLAUDE_TEMP_DIR/foo.xml` it collapses to `/foo.xml` (read-only root → error).
Use the **literal** session temp dir path from your SessionStart context (it looks like
`/tmp/claude-<session-id>/`). This matters in Task 4 capture and any manual `jb` re-run.
(This is a harness-shell quirk only — the A/B run.sh harness itself handles temp dirs
correctly; it only bites manual `jb inspectcode` invocations you run by hand.)

### CLAUDE.md bash rules (operator's global instructions — non-negotiable)

- No compound operators (`&&`, `||`, `;`) — each command a SEPARATE Bash call.
- No command substitution `$(...)` except the permitted `git commit -m "$(cat <<'EOF' …)"`
  HEREDOC carve-out. No subshells/grouping. Prefer dedicated tools over pipes/redirects.
- No Co-Authored-By trailers on commits. No Claude advertising in any PR (there is no PR).

---

## The established apparatus (what Tasks 1-3 built — your inputs)

- **Fixture:** `tests/fixtures/static-analysis/jbinspect/` — a real compilable C# project
  (`JbInspectSmoke.sln` classic format + `JbInspectSmoke.csproj` net10.0/nullable-off +
  `BadCode.cs`). `bin/`/`obj/` are gitignored. **No `setup:` block** — InspectCode
  restores + builds internally inside each hermetic per-trial copy (empirically verified:
  a clean no-`bin/obj` copy yields the identical finding set; no install race like
  trivy/ruff).
- **Ground truth (the canonical tuple set the sweep must reproduce)** — three findings,
  all line-bearing, all mapped `Important`:

  | TypeId | Line | Native | Mapped |
  |--------|------|--------|--------|
  | `RedundantUsingDirective` | 2 | WARNING | Important |
  | `PossibleNullReferenceException` | 11 | WARNING | Important |
  | `UnusedMember.Local` | 14 | WARNING | Important |

  ```json
  [{"file":"BadCode.cs","line":2,"rule_id":"RedundantUsingDirective","severity":"Important","confidence":100},
   {"file":"BadCode.cs","line":11,"rule_id":"PossibleNullReferenceException","severity":"Important","confidence":100},
   {"file":"BadCode.cs","line":14,"rule_id":"UnusedMember.Local","severity":"Important","confidence":100}]
  ```
- **Parser:** `tests/ab/lib/agent_capture.sh` has a `jbinspect|jbinspect-reviewer)` case
  (heading `^## JetBrains InspectCode Findings$`, broad skip `^Skipped — `, alternation
  zero-state for both the file-miss and solution-miss). The shared tokeniser handles
  `UnusedMember.Local (Category)` → `UnusedMember.Local` with no change (4 parser tests
  prove it).
- **Configs:** `tests/ab/configs/per-agent/jbinspect-baseline.yaml` (sonnet/default) and
  `jbinspect-haiku-low.yaml` (haiku/low).
- **Corpus id:** `jbinspect-smoke-bad-cs` (registered in `tests/ab/corpus/index.yaml`).
  Its `source.yaml` still carries `suite_sha: PLACEHOLDER_FILL_AT_CAPTURE` — you fill it
  in Task 4 Step 3.

---

## What is NOT yet done (the worked-example gap — expect a zero-tuple first capture)

`jbinspect-reviewer.md` has **NO `### Worked example` section**. Per
[[worked-example-gap]], a specialist with no worked example produces a §7 layout the
parser can't read → parses to `[]` (zero tuples) even when the visible report is correct.
**trivy's first capture hit exactly this.** So expect Task 4's first capture to parse to
`[]`; that is not a failure — it is the signal to pin the worked example (Task 5) and
re-capture. Do the **capture-then-pin dance**: capture a live Sonnet trial, read the REAL
§7 layout jbinspect emits, pin THAT as the worked example, re-capture to confirm the
parse closes. Do NOT invent the example — capture it.

The trivy worked example (`plugins/code-review-suite/agents/trivy-reviewer.md` lines
82-117) is your structural template. The plan's Task 5 Step 1 has a ready skeleton —
but **adjust the `Rule:` category text to match whatever Task 4 actually captured** (the
agent may emit the spaced `Category` form `(Redundancies in Code)` or the CamelCase
`CategoryId` form `(CodeRedundancy)` — pin what's real; the rule_id tokenises identically
either way).

---

## The likely tail to WATCH FOR (temp-dir over-literalism)

jbinspect is the specialist MOST likely to trip the temp-dir self-abort that hit trivy's
Haiku trial-016, because unlike trivy/ruff/eslint (which can stream stdout) **jbinspect
actually writes `inspectcode-<sln>.xml` to `$CLAUDE_TEMP_DIR` and parses it** — so the
prompt's literal unexpanded `$CLAUDE_TEMP_DIR` token is load-bearing, not incidental. If
a Haiku trial self-aborts citing a missing/absent temp dir, that is the known mechanism.

**Discipline:** do NOT pre-author a fix. Characterise it in the result note first. If the
2×20 sweep returns INCONCLUSIVE because of this tail, the fix that worked for trivy
(`5ccb692`) is the template: clarify in the jbinspect body's `## Tool invocation` section
(currently the terse line 43 `Check $CLAUDE_TEMP_DIR is present`) that the literal
unexpanded token in the prompt **satisfies** the §4 contract (Bash resolves it at command
time) and the agent must not abort on seeing it. **Any such fix must be a general
correctness improvement** (helps Sonnet too — the tuning-to-the-test guard) and earns its
own before/after re-sweep at n=20 on BOTH arms, mirroring the eslint PR-C / trivy
fix-validation arc.

### Sync coupling you MUST respect (jbinspect-specific — others didn't have this)

`jbinspect-reviewer.md`'s C#-specific solution-discovery + `jb inspectcode` invocation is
**mirrored** into `agents/code-analysis.md` (the monolith reviewer; both files carry a
"keep in sync" directive — jbinspect body line 92, code-analysis line 19).
- A **worked-example section added at the END of the jbinspect body** is a NEW section,
  not a change to the mirrored procedure → does **NOT** need mirroring (code-analysis has
  its own §7 format block). Task 5 Step 2 confirms this.
- BUT a **temp-dir-contract clarification in `## Tool invocation`** (if you ship the tail
  fix) DOES touch the mirrored invocation procedure → it **must** propagate to
  `code-analysis.md`'s InspectCode section (lines 13-19, 71-98).
- Either way: run `bash tests/run.sh` and watch for sync-note test failures.

---

## Gating (NON-NEGOTIABLE — get a FRESH explicit go-ahead per spend)

- **Task 4 (live worked-example capture, ~1-3 trials)** — GATED. Live Bedrock.
- **Task 5 Step 3 (re-capture to confirm the pin)** — GATED. Live Bedrock.
- **Task 6 (the 2×20 sweep)** — GATED. The main spend: **~$4-5 list price / ~25-40 min**.
  jbinspect trials are SLOWER than trivy (InspectCode loads a solution and runs the .NET
  analyser) — budget more wall-clock. "Continue" does NOT authorise the spend; get a
  fresh, explicit go-ahead. Consider `run_in_background: true` per arm and let the
  completion notification land (do not poll).
- **Task 7 (verdict + note + memory)** — offline, no gate.
- **Production flip (Task 7 Step 5)** — operator-gated **even on a clean EQUIVALENT** (it
  changes a dispatched-agent definition).

The operator's stated preference (carried from trivy 3.3): run the **sweep itself
directly in the main loop**, not via subagents — inspecting run artifacts is the value,
subagents add overhead. The offline Tasks 1-3 used subagent-driven development; the live
phase does not.

---

## Task 6 commands (once gated go-ahead is given)

```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/jbinspect-baseline.yaml --corpus jbinspect-smoke-bad-cs --trials 20 --stream-json
bash tests/ab/run.sh --config tests/ab/configs/per-agent/jbinspect-haiku-low.yaml --corpus jbinspect-smoke-bad-cs --trials 20 --stream-json
```

(NO `--mode` flag — mode is config-derived. Run BOTH arms, full matched pair; jbinspect
has no prior data.) Each prints its git-ignored output dir under `tests/ab/runs/`.

**Tabulate (Task 6 Step 3):** per arm's `summary.csv` — count trials matching the modal
(canonical) hash; tally INCONCLUSIVE/skip; compute mean `total_cost_usd` and the
**Sonnet ÷ Haiku ratio** (report RATIO only — the stream cost is Anthropic LIST price,
not Bedrock). Expect ~2.2-2.5× by the three-specialist precedent (ruff ~2.2×, eslint
2.17×, trivy 2.34×).

---

## Verdict framework (verbatim — Task 7)

- **EQUIVALENT** — Haiku matches the canonical hash within noise (clean, single-hash arm). → flip production.
- **INCONCLUSIVE (decision-4)** — mixed within-arm hashes default to inconclusive regardless of rate. → do not flip; characterise the tail.
- **WORSE** — >25 % NORMAL-rate drop. → do not flip.

If a real agent-side tail survives a clean apparatus, CHARACTERISE it; any fix must be a
general correctness improvement earning its own before/after at n=20 on both arms.

## Task 7 deliverables

1. **Result note:** `docs/superpowers/notes/2026-06-04-jbinspect-haiku-low-result.md`.
   Mirror the closest precedent `docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md`
   (full shape: header block with run dirs + sweep SHA, sweep config, per-arm hash
   distribution table, any agent-side tail characterised, cost delta + ratio with the
   list-price caveat, verdict verbatim, production-flip rec, and — if you fix-and-re-sweep
   — a "Fixes SHIPPED + re-sweep VALIDATED" section).
2. **Memory** (SEPARATE `~/.claude` repo, NOT this clone:
   `projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`): add
   `project_phase_3_4_jbinspect_shipped.md` + a `MEMORY.md` index line. Note it CLOSES the
   Phase 3 static-specialist sweep. Commit + push `~/.claude` separately.
3. **Production flip (operator-gated, clean EQUIVALENT only):** set BOTH `model: haiku`
   AND `effort: low` in `jbinspect-reviewer.md` frontmatter (mirror trivy `ee23a79` /
   eslint+ruff `3b3a255`). jbinspect's frontmatter currently has only `model: sonnet`
   (no `effort:` line) — ADD `effort: low`. To make it live mid-session: `/plugins update`
   then `/reload-plugins` (the A/B harness reads the working-tree file directly via
   `agent_dispatch.sh:113`, so the SWEEP needs no reload — only the live `/code-review`
   pipeline does).

---

## Start by reading (in order)

1. **This handover** (done).
2. **The plan** — `docs/superpowers/plans/2026-06-04-phase-3-4-jbinspect-ab-baseline.md`
   (Tasks 4-7 are your remaining task texts; Tasks 1-3 done).
3. **The trivy result note** — `docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md`
   (your result-note template + the fix-and-re-sweep arc + the temp-dir tail precedent).
4. **The jbinspect agent body** — `plugins/code-review-suite/agents/jbinspect-reviewer.md`
   (what you're probing; line 43 temp-dir instruction; line 86 `Rule: TypeId (Category)`;
   line 92 the sync directive) and the InspectCode section of `agents/code-analysis.md`.
5. **Memory** (in `~/.claude`): `memory/project_phase_3_3_trivy_shipped.md` (closest
   precedent — fix-then-flip arc, harness-reads-working-tree note) and
   `memory/project_worked_example_gap.md`.

## After jbinspect (the horizon — NOT this handover)

Phase 3 is COMPLETE once jbinspect ships. The deferred longer-term item: convert the
code-review orchestrator to a deterministic Workflow with schema-validated specialist
output — dissolving the markdown-parse apparatus (the §7 worked-example fragility this
programme has repeatedly patched). Start from `superpowers:brainstorming` if taken up.
