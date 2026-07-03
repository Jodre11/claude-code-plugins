# Handover — Task 7 incident replay (variance-resampling boundary gate)

**Paste the block below into a CLEAN session whose working directory is the
finance-erp checkout. Do NOT run it from the plugin repo — the review-core
specialists `git diff`/`git show` from their CWD, so they must run inside the
repo that contains the incident commit.**

---

I'm running the live incident-replay leg of "Task 7" validation for the
variance-resampling boundary gate that just merged to the `code-review-suite`
plugin (plugin PR #60, squash `2754dfd` on the plugin marketplace repo). The
plugin cache is already refreshed (`/plugins update` + `/reload-plugins` done in
the originating session), so the live `review-core.mjs` includes the gate. The
code is DONE and merged — this is validation only, no code changes expected.

## What this leg proves

The incident: finance-erp PR #571 received two opposite verdicts on the SAME
commit `063d5becd5287da90a3abc6003a179119d0cecf9`:
- `dotnetAL` (our multi-agent pipeline): **CHANGES_REQUESTED**, 4 Important
- `Jodre11` (synthesiser): **APPROVE**, 3 findings, 1 contested

Root cause was single-draw specialist recall variance near the verdict boundary.
The fix re-dispatches the stochastic specialists for a 2nd draw when the round-1
verdict sits near the boundary, unions findings with an agreement count, and
re-synthesises. This replay confirms the gate fires on the real incident shape
and round 2 recovers the missed findings — flipping toward REQUEST_CHANGES.

## Setup (do this first, in the finance-erp checkout)

The repo is at `~/Repos/haven/finance-erp`. Its current HEAD is the merged
follow-up state (`3db5e0c6`), which has ALREADY FIXED the incident findings —
reviewing it proves nothing. You MUST replay the exact flip commit:

```
git -C ~/Repos/haven/finance-erp status --short      # confirm clean tree first
git -C ~/Repos/haven/finance-erp rev-parse HEAD       # record this to restore later: 3db5e0c6...
git -C ~/Repos/haven/finance-erp checkout 063d5becd5287da90a3abc6003a179119d0cecf9
```

This is a DETACHED checkout of the verified flip commit. When done, restore with
`git -C ~/Repos/haven/finance-erp checkout feat/kvp-dictionaries-partial-replace`
(the branch the repo was on — confirm before you start).

## The findings round 2 must recover (from dotnetAL's CHANGES_REQUESTED body)

- **[#4]** Trim the dictionary `Name` on the **definition side** — a trailing-space
  name slips past the blank check and is unreferenceable. (NB: commit `063d5bec`'s
  own subject is "trim dictionary name in **constructor**" — that is the CONSUMING
  side; the DEFINITION-side trim #4 was still open at this commit. No contradiction.)
- **[#2]** construction/predicate de-duplication (maintainability).
- Also in the set: [#3] naming collision (`KeyValuePairConfig` → `DictionaryItemConfig`),
  [#1] missing end-to-end test through `PrepareData()`/session.

## Run the replay — 5 times

For each of 5 runs, from a session with CWD = `~/Repos/haven/finance-erp` at the
detached `063d5bec`:

```
/code-review-suite:review-gh-pr 571
```

**Posting control:** the gate fires only on the FULL PR path, which ends at a
Class A confirmation prompt before posting. #571 is MERGED and team-visible — do
NOT post review noise onto it. At the Class A prompt, decline posting (choose the
no-post / cancel option) and instead capture the bundle the pipeline produced
(verdict + tiers + bodyText) to a file under `$CLAUDE_TEMP_DIR/`. You only need
the in-memory bundle, not a GitHub write. If the skill offers no clean no-post
exit, stop before the post and read the sealed bundle the `review-core` Workflow
returned (the skill stores it; do not re-render it).

NB: this is a re-review-aware skill. `Jodre11` and `dotnetAL` already have reviews
on #571, so it may detect self-re-review for the current gh user and switch modes
(suppresses alignment, reacts to the prior). If the current gh user has a prior
review on #571, that perturbs the fixture. To get a clean full-review fixture,
either run as a gh user with NO prior review on #571, or note the mode in results.

## What to record per run (append to a results file)

1. Did the **boundary gate fire**? (look for the log line `boundary gate fired —
   round 2 (stochastic resample)`). Which band — B1 (APPROVE + consensus Important
   in [60,80)), B2 (APPROVE + contested present), or B3 (RC + sole Important in
   [70,80))?
2. **Round-1 verdict vs post-round-2 verdict** — did round 2 change it? (the whole
   point: a borderline APPROVE moving toward REQUEST_CHANGES).
3. Did the **union recover [#4] (definition-side Name trim) and/or [#2] (predicate
   de-dup)**? Note the `agreement` counts on recovered findings (2 = both draws).
4. Specialist dispatch count round 1 vs round 2 (round 2 should re-dispatch only
   the ~8-10 stochastic specialists, never the 5 static ones, never the synth).
5. Token/cost if surfaced.

## Success criteria

- Gate fires on ≥ most runs (the incident shape is borderline by construction).
- Across the 5 draws, round 2 recovers #4 and/or #2 in at least some runs and the
  verdict moves toward REQUEST_CHANGES — demonstrating the variance the single-draw
  pipeline missed is now caught.
- Gate NEVER re-dispatches static specialists, cross-review, or the synthesiser.

If the gate does NOT fire on a clear-incident replay, that's a calibration finding:
the [60,80)/[70,80) bands may be too narrow for the real synth's confidence outputs —
record the actual round-1 consensus/contested confidences so the bands can be retuned
(`GATE_APPROVE_IMPORTANT_BAND` / `GATE_RC_IMPORTANT_BAND` in review-core.mjs).

## After the replay

1. `git -C ~/Repos/haven/finance-erp checkout feat/kvp-dictionaries-partial-replace`
   (restore the original branch — confirm it was the starting branch first).
2. Record the outcome in the plugin repo's SDD ledger
   (`~/.claude/plugins/marketplaces/jodre11-plugins/.git/sdd/progress.md`, Task 7
   section) and in auto-memory.
3. Remaining Task-7 legs still pending: (a) n≥10 clean-PR no-regression sweep — gate
   must NOT fire on a clean PR; (b) band/window calibration from observed confidences.

## Key facts

- Flip commit: `063d5becd5287da90a3abc6003a179119d0cecf9` (BOTH verdicts were against
  this exact SHA — verified via `gh pr view 571 --json reviews`).
- finance-erp checkout: `~/Repos/haven/finance-erp` (was on branch
  `feat/kvp-dictionaries-partial-replace`, clean tree, HEAD `3db5e0c6` before replay).
- review-core gate consts to retune if mis-calibrated: `GATE_APPROVE_IMPORTANT_BAND
  = [60, 80]`, `GATE_RC_IMPORTANT_BAND = [70, 80]`, `CLUSTER_WINDOW = 3` in
  `~/.claude/plugins/marketplaces/jodre11-plugins/plugins/code-review-suite/workflows/review-core.mjs`.
