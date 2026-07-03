# Handover — execute Phase 3.3 trivy Tasks 6–7 (the gated 2×20 sweep + verdict)

**Date:** 2026-06-03
**Predecessor this session:** executed the trivy A/B plan Tasks 1–5 subagent-driven
(offline apparatus + the live worked-example capture-and-pin). All shipped to `main`.
**Your job:** run the matched 2×20 Sonnet/default vs Haiku/low sweep (Task 6, the main
Bedrock spend), then produce the verdict, result note, and memory update (Task 7).

---

## The one thing to do

**Execute `docs/superpowers/plans/2026-06-03-phase-3-3-trivy-ab-baseline.md`, Tasks 6
and 7.** Everything Tasks 1–5 set up is already committed and pushed; the apparatus is
proven working (a live re-capture parses to the correct 3 tuples). The only remaining
work is the spend + the analysis.

- **Task 6 is live Bedrock spend** (~$4 list price / ~25 min for 2×20 trials). The
  operator has gated it: **get a fresh, explicit go-ahead before running Task 6.**
  Confirm scope at the start of your session — do not assume "continue" authorises the
  spend.
- **Task 7 is offline** (verdict + result note + memory). No gate.

## State at handover (verified clean)

- **Working tree:** clean. `git status --porcelain` empty. `main` level with
  `origin/main`. Nothing to commit, push, or PR before starting. Direct-push to `main`
  is the established workflow here (branch-protection bypass is expected and reported by
  the remote; **no PR is used** in this repo for this programme).
- **Suite:** 353 passed / 1 skipped on a clean tree (the 1 skip is the
  `CLAUDE_CODE_E2E_TESTS=1`-gated behavioural smoke test — expected). The handover that
  seeded Tasks 1–3 predicted 345; that estimate counted test *functions*, but the runner
  counts individual *assertions* — 353 is the correct clean baseline, nothing is missing.
- **Commits shipped this session (Tasks 1–5), all pushed:**
  - `a56ad23` — corpus fixture (3-finding Dockerfile, `source.yaml` w/ no `setup:` block,
    `changed-lines.txt`, index registration).
  - `89dd7d0` — trivy parser-dispatch case in `agent_capture.sh` + captured-output fixture
    + 3 TDD parser tests.
  - `2fec715` — tidy-up of those tests (dead-var/`source`-convention nits from review).
  - `6fceb18` — `trivy-baseline.yaml` (sonnet/default) + `trivy-haiku-low.yaml`
    (haiku/low) per-agent configs + a mirrored config-parse test.
  - `323997a` — **the worked example.** Pinned the canonical §7 `### Finding —` layout
    into `trivy-reviewer.md` using the real captured findings, corrected the stale
    `AVD-XX-NNNN` rule-ID claim (line 73) to honestly cover both `DS-NNNN (Dockerfile)`
    and `AVD-` forms, and aligned the fixture provider casing to `(Dockerfile)`.

## What Tasks 4–5 established (load-bearing — do NOT re-derive)

The **worked-example gap is real and is now closed.** Task 4's first Sonnet/default
capture produced a correct 3-finding report but in a layout the §7 parser can't read
(it severity-grouped under `### Critical`/`### Suggestion` with `**Title:**`/`---` prose
blocks), so `findings.json` parsed to `[]`. Task 5 pinned the canonical worked example;
the gated re-capture then parsed cleanly to the expected three tuples:

```json
[{"file":"Dockerfile","line":1,"rule_id":"DS-0001","severity":"Suggestion","confidence":100},
 {"file":"Dockerfile","line":7,"rule_id":"DS-0004","severity":"Suggestion","confidence":100},
 {"file":"Dockerfile","line":9,"rule_id":"DS-0031","severity":"Critical","confidence":100}]
```

Canonical hash from that re-capture: `b0888193a342580fc476804f9a3d69a7b69cfd35f04008e8dd226c7c170e8a98`.
**Treat this as the expected canonical 3-tuple set for the Sonnet baseline arm** — but
re-establish it fresh at n=20 in Task 6 (don't trust a single trial's hash as the modal
hash; the eslint precedent re-established a symmetric n=20 baseline rather than carrying
a small-n hash forward).

**The agent emits bare `DS-NNNN` IDs with a capitalised `(Dockerfile)` provider token.**
This is confirmed live, not assumed. The fixture and worked example agree on this casing.

## The two facts that change how you run Task 6 (read before running)

1. **No `--mode` flag exists.** Mode is config-derived. Every run command in the plan
   omits it deliberately. (Per [[phase-3-2b-pr-a-apparatus-fix]].)

2. **The sweep does NOT need the `expected/` baseline.** The plan's Task 4 Step 3
   (promote captured report → `expected/findings-trivy.md` + `expected/findings.json`,
   fill `suite_sha` in `source.yaml`) was **deliberately not done** this session, and it
   is **not a blocker** for Task 6. Verified in code: `tests/ab/run.sh:298` only reads
   `expected/findings.json` when `faithfulness_check == "true"`, and that flag is set
   solely by the opt-in `--faithfulness-check` argument (`run.sh:81`). The Task 6 sweep
   commands do **not** pass that flag, so they compute the modal hash empirically from
   the trials themselves and never touch `expected/`. **You do not need to promote a
   baseline or fill `suite_sha` to run the sweep.** (Optional polish: if you want the
   fixture to carry a committed `expected/` baseline + real `suite_sha` for future
   faithfulness runs, you may promote it as a small offline follow-up — but it is out of
   the critical path and the operator has not asked for it. Mention it; don't assume it.)

## Method (operator's stated preference)

Run Task 6 **directly in the main loop**, not via a subagent. The trials are a long
foreground `bash tests/ab/run.sh` invocation each; the value is in *inspecting* the run
artifacts (`summary.csv`, per-trial `findings.json`/`findings_hash.txt`/`agent-output.md`),
which is analysis you do yourself. Tasks 1–5 used subagent-driven-development because they
were *implementation* tasks with spec/quality review gates; Tasks 6–7 are
spend-then-analyse, so subagents add overhead without the review benefit. (If you prefer,
Task 7's result-note *drafting* could be delegated, but the verdict judgement should be
yours.)

## House rules (non-negotiable — operator global CLAUDE.md; govern your Bash calls, not file content)

- NO compound shell (`&&`, `||`, `;`), NO `$(...)`/backticks, NO pipes/subshells in a
  single Bash call — separate calls, capture output, pass it on. A single `> file 2>&1`
  (or `2>/dev/null`) redirect is allowed; a lone `grep`/`jq`/`yq`/`awk` with no pipe is
  allowed. Carve-out: `git commit` HEREDOC for literal multi-line bodies.
- `git add` SPECIFIC paths only (never `-A`/`.`). Commit messages: NO Co-Authored-By, NO
  Claude advertising.
- **PUSH after every commit** — a prior autoUpdate reclone wiped an unpushed branch.
- 2-space indent for md/json/yaml; LF endings.
- Temp files: use the `CLAUDE_TEMP_DIR` the SessionStart hook injects into your context
  (path `/tmp/claude-<session_id>/`). It is NOT exported into the shell env, so pass the
  literal path into any redirect.

## Task 6 — the matched 2×20 probe (GATED, ~$4 list / ~25 min)

Get the go-ahead first. Then run BOTH arms at n=20 (the full matched pair — trivy has no
prior data, so do not shortcut to a Haiku-only arm).

**Arm 1 — Sonnet/default baseline, n=20:**
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/trivy-baseline.yaml --corpus trivy-smoke-bad-dockerfile --trials 20 --stream-json
```
**Arm 2 — Haiku/low, n=20:**
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/trivy-haiku-low.yaml --corpus trivy-smoke-bad-dockerfile --trials 20 --stream-json
```
These are long foreground runs — consider `run_in_background: true` per run and let the
completion notification land rather than polling. Each prints its output dir
(`tests/ab/runs/<ts>-trivy-baseline/` and `…-trivy-haiku-low/`); these are git-ignored.

**Tabulate (Task 6 Step 3):** for each arm's `summary.csv` — count trials whose
`findings_hash` equals the modal (canonical) hash; tally any INCONCLUSIVE/skip markers;
compute mean `total_cost_usd` per arm and the **Sonnet ÷ Haiku ratio**. Report the
**ratio only** — the stream `total_cost_usd` is Anthropic LIST price, not Bedrock, so the
absolute dollars are indicative of the ratio, not the bill (per
[[phase-3-2b-pr-b-reprobe]]). For comparison: ruff and eslint both landed ~2.2–2.5×.

## Task 7 — verdict + result note + memory (offline)

**Step 1 — Verdict framework** (verbatim from the plan / parent spec
`docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`):
- **EQUIVALENT** — Haiku matches the canonical hash within noise (clean, single-hash arm).
- **INCONCLUSIVE (decision-4)** — mixed within-arm hashes default to inconclusive
  regardless of rate.
- **WORSE** — >25 % NORMAL-rate drop.

If a real **agent-side tail** survives the clean apparatus (as eslint's tier-1
binary-resolution skip tail did — see the precedent note), **CHARACTERISE it, do not
pre-author a fix.** The tuning-to-the-test guard: any fix must be a *general correctness
improvement* that helps Sonnet too, and it earns its own before/after at n=20 on both
arms. Note the trivy agent has no provisioning/tier-resolution ladder (trivy is
global-on-PATH like ruff), so the eslint tier-1 mechanism is unlikely to recur — but watch
for trivy-specific tails (e.g. the severity-grouping layout drift that Task 4 exhibited
before the worked example; if Haiku reverts to it despite the pinned example, that's the
characterisable tail).

**Step 2 — Result note.** Create
`docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md`, mirroring
`docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md` (the closest
precedent — read it for the exact section shape): header block with run dirs + sweep SHA,
sweep configuration, hash distribution table per arm, any agent-side tail characterised,
cost delta table + ratio with the list-price caveat, verdict (framework verbatim), and a
production-flip recommendation.

**Production-flip note (important nuance, now resolved):** the eslint/ruff flip blocker is
gone. `effort:` **is** a documented subagent frontmatter key (low/medium/high/xhigh/max),
and eslint + ruff were flipped to `model: haiku` + `effort: low` earlier this programme
(commit `3b3a255`, live-verified). So on a clean **EQUIVALENT** verdict, the trivy flip is
to set BOTH `model: haiku` AND `effort: low` in `plugins/code-review-suite/agents/trivy-reviewer.md`
frontmatter (mirror what eslint/ruff now carry). On INCONCLUSIVE or WORSE, leave
`trivy-reviewer.md` as `model: sonnet` and report the probe as informational. **Whether to
execute the flip is operator-gated** — recommend in the note, but confirm before editing
production frontmatter (it changes a dispatched-agent definition; if you flip and want it
live mid-session, `/plugins update` then `/reload-plugins`).

**Step 3 — Memory** (in the SEPARATE `~/.claude` repo, NOT this clone —
`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`): add
`project_phase_3_3_trivy_shipped.md` (verdict, cost ratio, commits, whether production
flipped) and an index line in that dir's `MEMORY.md`. Commit + push the `~/.claude` repo
separately.

**Step 4 — Commit + push the result note** (this clone):
```
git add docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md
git commit -m "docs(ab): Phase 3.3 trivy Haiku/low A/B result + verdict"
git push origin main
```
(If the operator approves the production flip and/or you promote the `expected/` baseline,
those are separate commits — `feat(trivy-reviewer): flip to haiku/low` and a
`test(ab): promote trivy expected baseline` — each pushed.)

## Start by reading (in order)

1. **The plan — Tasks 6 & 7:**
   `docs/superpowers/plans/2026-06-03-phase-3-3-trivy-ab-baseline.md`.
2. **The closest result-note precedent (mirror it for Task 7):**
   `docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md`.
3. **The ruff EQUIVALENT precedent** (what a clean equivalent looks like):
   `docs/superpowers/notes/2026-06-02-ruff-haiku-low-result.md`.
4. **The parent spec (verdict framework):**
   `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`.
5. **Memory** (in `~/.claude`): `memory/project_phase_3_2b_pr_b_reprobe.md` (programme
   context + the resolved effort-flip story) and `memory/project_worked_example_gap.md`
   (why trivy's first capture parsed to zero — now closed; useful framing for the note).

## After trivy (NOT this handover — the horizon)

- **jbinspect is Phase 3.4, a SEPARATE plan** — the 4th and last static specialist.
  Heavier: needs .NET fixture provisioning + a CamelCase rule-ID tokeniser check. Do trivy
  end-to-end first (this handover) as the worked precedent.
- **Longer-term (deferred):** convert the code-review orchestrator to a deterministic
  Workflow with schema-validated specialist output — dissolving the whole markdown-parse
  apparatus (the §7 worked-example fragility this programme keeps patching). Start from
  `superpowers:brainstorming` if taken up. See `memory/project_worked_example_gap.md` and
  `memory/project_phase_3_2b_pr_a_apparatus_fix.md`.
