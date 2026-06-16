# Task 1 — Synthesiser per-agent feasibility spike

**Date:** 2026-06-16
**Plan:** `docs/superpowers/plans/2026-06-16-agent-hazard-ab-trial.md` (Task 1)
**Verdict:** **QUALIFIED GO** — the synthesiser can be driven synthetically, but the
plan's working-dir/SHA strategy (`live`) is unworkable as written and must be revised
before Task 3. The revision has non-obvious ripples; recommend a maintainer checkpoint
plus one confirmatory probe before building the fixtures.

---

## What was probed

One live `claude -p` dispatch (model `sonnet`), replicating the per-agent harness launch
shape by hand:

- System prompt = the frontmatter-stripped `review-synthesiser.md` body, via
  `--append-system-prompt-file` (mirrors `agent_dispatch_run_trial`).
- User message = a hand-built bundle mirroring `agent_dispatch_build_user_message` output
  plus a `Review mode: pr` line and a `Specialist findings:` block carrying ONE
  correctness finding rated Important on a real in-tree file/line (`tests/ab/README.md:9`).
- `Base branch: main`, `Head SHA:` = the real 40-hex HEAD
  (`141a1a47926b9bb1d93ecb2bd150a7aeafd61b6a`).
- cwd = the live marketplace repo (so the synthesiser's own `git diff` could run).

Probe command (assembled in a scratch script under `$CLAUDE_TEMP_DIR/synth-probe/`):

```
command claude -p --permission-mode bypassPermissions --model sonnet \
    --append-system-prompt-file <stripped-synth-body> \
    --exclude-dynamic-system-prompt-sections "<user-message>"
```

## What happened

The synthesiser **ran cleanly** (3667 bytes stdout, empty stderr, rc 0) and produced a
well-formed report: `## Summary`, `## Synthesiser Assessment`, a `## Verdict` block
(`Verdict: APPROVE` / `Rubric row applied: 4`), and a `## Dismissed Findings` section.
SHA validation passed; the `Base branch` / `Head SHA` / `Review mode` lines were all
consumed correctly. **The mechanical drive-and-parse path the trial depends on works.**

**But** the synthesiser ran its OWN `git diff main...HEAD -- tests/ab/README.md`, found it
empty, and **dismissed the planted finding on procedural grounds**, quoting:

> "`tests/ab/README.md` has no diff between `main` and this branch … The file is not in
> the changed set; this finding has no basis in the PR."

(It also found a substantive ground — my probe used a real file whose content did not
actually contradict the planted claim — but the procedural ground is independent and
sufficient.)

## The two blocking facts this surfaces

1. **The planted file:line MUST appear in the synthesiser's self-computed diff.** The
   synthesiser does not blindly trust the supplied specialist bundle; it cross-checks
   against `git diff $BASE...$HEAD_SHA` (three-dot, when `empty_tree_mode` is false —
   `review-synthesiser.md:68-69`) and dismisses findings on files outside that diff. A
   fixture that plants a finding on a file not in the diff measures a dismissal artefact,
   not the agent-hazard basis.

2. **`working_dir_strategy: live` is not a valid harness strategy.** `fixture.sh`
   (`_AB_FIXTURE_VALID_STRATEGIES="copy worktree patch"`) rejects any other value at
   `fixture_load_from_path`. The plan's Task 3 fixtures (`working_dir_strategy: live`,
   planted `lib/cache.py:42` that does not exist in the tree) would fail schema
   validation AND be dismissed for not being in the diff.

## Strategy analysis (a/b/c from the plan, re-evaluated against the probe)

- **(a) live-tree, real SHA, arbitrary file:line — NO.** Disproven directly: the file is
  not in `git diff`, so the finding is dismissed procedurally. Also `live` is not a valid
  strategy value.
- **(b) empty-tree copy — NO (as-is).** `copy` strategy materialises a *plain* directory
  (not a git repo) under `/tmp`; the synthesiser's `git diff` would fail outright. Existing
  per-agent fixtures work because static specialists run their tool on files, not `git`.
- **(c) git-backed worktree with the planted artefact genuinely committed — VIABLE, with
  ripples.** `worktree` strategy does `git worktree add --detach <dir> <head_sha>`; the
  synthesiser's `git diff $BASE...$HEAD_SHA` then shows the committed delta. To make
  `lib/cache.py:42` appear, the planted lying/vague file must be a **real commit** in repo
  history, referenced by the fixture's `head_sha` (with `base_sha` = its parent). Hit and
  near-miss need different content, so two commits / two head_shas.

## Ripples of strategy (c) the maintainer should weigh

- **Where the ablation bites.** The arm-A/arm-B difference is carried by the synthesiser
  **agent body** (the agent-hazard basis is inlined into `review-synthesiser.md:91` by
  PR #52, not only in the include). `agent_dispatch_run_trial` reads the body from
  `$REPO_ROOT` and feeds it via `--append-system-prompt-file`, so `run-ablation.sh`
  swapping `review-synthesiser.md` in `$REPO_ROOT` **does** flip the system prompt between
  arms. Good — the primary signal is controllable.
- **The include read is NOT controllable in a worktree.** If the synthesiser also reads
  `includes/severity-definitions.md` at runtime, it reads it from its cwd (the worktree at
  `head_sha`), which the `$REPO_ROOT` ablation swap cannot reach. Because the basis text is
  already inlined in the body, swapping the body alone is *probably* sufficient to ablate —
  but this is an assumption the confirmatory probe should test (does arm A actually drop the
  hit to Suggestion when only the body is reverted?).
- **Cost/heaviness.** Committing planted artefacts + worktree-per-trial is the "heaviest"
  option, but it is the only one that satisfies the synthesiser's diff cross-check.

## Confirmatory probe (worktree, both arms) — result and a SECOND, larger finding

Built a throwaway git repo (`$CLAUDE_TEMP_DIR/synth-probe2/repo`) with a real two-commit
history: base (empty scaffold) → head (adds `lib/cache.py`). The planted artefact is the
plan's exact hit: an `evict` docstring claiming "least-recently-used" while the code does
`popitem(last=True)` (MRU). `lib/cache.py:42` is genuinely in `git diff base...head`.
Drove the synthesiser **twice**, cwd = the worktree:

- **Arm B** body = current `review-synthesiser.md` (basis present).
- **Arm A** body = `0c89cf6:…/review-synthesiser.md` stripped (basis absent — the only
  diff between the two bodies is the Severity Reclassification paragraph: single
  runtime-defect bar in A vs the two-bar agent-hazard text in B; confirmed by `diff`).

**Mechanical result (GO):** both arms ran cleanly, the in-diff finding was NOT dismissed
procedurally (the earlier probe's failure mode is gone once the file is genuinely in the
diff), and both produced parseable tiered reports with the finding under `### Important`.
The worktree strategy + body-only ablation is mechanically sound and scoreable.

**Discrimination result (the blocking finding): the fixture does NOT discriminate the
basis.** BOTH arms kept the finding at Important — but BOTH did so via **rubric row 1
("intent-ledger goal not achieved")**, not the agent-hazard basis. Arm A's verdict block:
`Rubric row applied: 1 — the implemented eviction policy is MRU … not LRU as documented,
rendering the helper broken`. Because the planted code has a **genuine runtime defect
today** (it really does evict MRU), it fails the stated goal "add a cache eviction helper",
and the synthesiser's goal-not-achieved escalation (`review-synthesiser.md:460`, which
**predates PR #52**) lifts it to Important in *both* arms. The agent-hazard basis is never
the load-bearing reason.

### Root cause: the plan's hit fixture conflates two distinct mechanisms

The agent-hazard basis is defined as a hazard "**with no runtime defect today**". The
plan's concrete Task 3 hit fixture plants a lying comment **on broken code** — a present
runtime defect — which trips the older goal-not-achieved / runtime-defect bar regardless of
the basis. To isolate the basis, the hit fixture must be a **lying comment on code that is
correct today**, so that:

- **Arm A** (single runtime-defect bar): "misleading comment, but no runtime defect and the
  goal is met" → downgrade to **Suggestion**.
- **Arm B** (agent-hazard bar present): recognise the lying comment as an agent-hazard →
  keep **Important**.

Concretely, the corrected hit should plant a comment that makes a **false claim about
correct code** (a false safety/invariant assertion, or a lie about *why* a workaround
exists) such that a future maintainer trusting it introduces a defect — while the code as
shipped works and satisfies the intent-ledger goal. The near-miss stays as the plan has it
(vague-but-honest, correct code) and must drop to Suggestion in both arms. The intent
ledger for both fixtures must describe a goal the shipped code **achieves**, so rubric row 1
never fires and the basis is the only thing that can move the hit.

## Second confirmatory probe (corrected fixture: lying comment on CORRECT code)

Built `$CLAUDE_TEMP_DIR/synth-probe3/repo` (same two-commit worktree shape). The planted
artefact is now a lying comment on **correct** code: `put` calls `move_to_end(key)` (load-
bearing for the re-insertion / LRU-promotion case), but the comment above it falsely calls
it *"redundant for new keys … safe to drop if this method is ever simplified."* The code
is LRU-correct today and satisfies the goal "add a bounded LRU cache helper"; the hazard is
purely that a maintainer trusting the comment deletes the line and silently breaks LRU
promotion on updates. No runtime defect today → rubric row 1 must NOT fire. Drove both arm
bodies (same arm-A/arm-B bodies as probe2), cwd = the probe3 worktree.

**Result (n=1, sonnet) — still no clean A→B difference:**

| Arm | Verdict | Rubric row | Severity of the planted finding |
|---|---|---|---|
| B (basis present) | REQUEST_CHANGES | 3 | **Important** (conf 85) — synth text: *"the agent-hazard bar is fully met … defect would be silent at runtime"* |
| A (basis absent) | REQUEST_CHANGES | 3 | **Important** (conf 85) — did NOT apply the single-bar downgrade to Suggestion |

The good news: rubric row 1 no longer fires (goal is achieved), so the corrected fixture
correctly isolates away the goal-not-achieved confound — that part of the fix worked. The
remaining issue: arm A **still kept Important** rather than downgrading to Suggestion as its
single-runtime-defect-bar text prescribes. At n=1 with sonnet the basis ablation produced
**no observable severity difference**.

### Interpretation — this is the TRIAL'S question, not a feasibility blocker

The apparatus is fully proven: drivable, in-diff finding honoured (no procedural dismissal),
parseable tiered output, body-only ablation is the right and only-needed lever, scoreable by
tier heading. What probe3 shows is a *substantive* signal about the basis itself: a capable
model may rate a concrete lying comment Important on general correctness judgement, whether
or not the basis text is in its instructions. That is exactly what the trial exists to
measure, and the plan's decision rule already has a branch for it ("**Failed firing** (arm A
≈ arm B): the basis is not changing synthesiser behaviour — record and escalate; do not
claim validation"). Two reasons n=1 here is NOT the trial's answer:

1. **n=1.** A single trial per arm cannot distinguish "no effect" from sampling noise; the
   trial runs 5/cell (→10 on ambiguity) precisely for this.
2. **Model mismatch.** The probes used **sonnet** for cost; the trial config pins **opus**
   (`synthesiser-baseline.yaml`, production synthesiser model). Opus may honour the arm-A
   single-bar downgrade more faithfully. The Task 7 run must use opus as specced.

## Recommendation / GO status (final)

- **Apparatus feasibility: GO.** Synthesiser drivable in per-agent mode; `worktree` strategy
  with a committed planted artefact satisfies the own-diff cross-check; body-only ablation
  (swap `review-synthesiser.md` in `$REPO_ROOT`) is the correct and sufficient lever (basis
  text is inlined in the body — confirmed by `diff` of the two arm bodies). Tasks 2/4/5/6
  unaffected.
- **Fixture design: REVISED — adopt the probe3 shape.** Task 3's hit must be a **lying
  comment on correct code** with a goal-satisfying intent ledger (probe3's `put`/`move_to_end`
  "safe to drop" artefact is the worked example; reuse it). This honours the basis definition
  ("no runtime defect today") and removes the rubric-row-1 confound that the plan's original
  broken-code hit suffered. NOT a re-opening of a decided fork — a content correction the
  design's own wording requires.
- **Strategy keys for Task 3 fixtures:** `working_dir_strategy: worktree`, `base_sha` =
  parent commit, `head_sha` = the commit that adds the planted file; the planted `file:line`
  MUST be inside `git diff base...head`. `live` is not a valid strategy value. The fixtures
  must commit the planted `lib/cache.py` into the marketplace repo history (or a referenced
  fixture-local committed blob) so the worktree at `head_sha` reproduces it. **This is a
  build-time deviation Task 3/6 must resolve** (how the planted commits are created and
  referenced) — flag to maintainer.
- **Honest caveat carried into Task 7:** the two sonnet probes both kept the hit at
  Important in BOTH arms. If the opus run at 5/cell also shows arm A ≈ arm B, the verdict is
  **FAILED firing / AMBIGUOUS**, not VALIDATED — and that is a legitimate, decision-rule-
  sanctioned outcome that becomes a follow-up spec (the basis may be behaviourally inert at
  the synthesiser for a capable model, or the guardrail/fixture needs a sharper contrast).
  Do NOT tune the fixture to manufacture a difference — that would be measuring the apparatus,
  not the basis.

**GO recorded.** Proceed to build Tasks 2–6 (all offline). Task 7 (live opus run) remains
gated on explicit maintainer go-ahead per the handover.
