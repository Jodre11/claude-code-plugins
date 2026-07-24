# Flip built-in review orchestration default classic → panel

**Date:** 2026-07-24
**Status:** approved for implementation
**Relates to:** PR #117 (step 1, shipped), the staged orchestration default-flip plan
(`orchestration-default-flip-plan` memory), panel organic-validation decision (2026-07-17).

## Problem

The code-review suite ships **classic** as the built-in orchestration default. Panel mode
(N=3 opus panelists → deterministic tally → writer) has been the live default on the
author's machine since 16 Jul via an explicit `review_mode = "panel"` pin in
`~/.claude/code-review.toml`, and has been organically validated across real reviews:
verdict-correctness re-confirmed on both prior mis-verdict PRs (#98, #101) post-#109, and it
is faster wall-clock than classic. The author now wants panel to be the **shipped** default
for all marketplace consumers, with classic retired shortly after if no complaints surface.

This is precisely step 2 ("everyone-flip") of the staged plan. Step 1 (make orchestration
config resolution an explicit MUST-READ) shipped as PR #117. Step 3 (remove classic
entirely) is deferred to a tracked follow-up.

## Goal

Make **panel** the built-in default so that a consumer who sets no `review_mode` in any
config layer gets panel. Keep classic fully functional as an explicit opt-in
(`review_mode = "classic"`) so this PR is reversible without a code revert and the
subsequent retirement is a clean, separate step.

Non-goals (this PR):
- Removing the classic code path. That is the deferred follow-up (see "Deferred: PR 2").
- Changing panel behaviour, panel_size handling, or the concern brief.
- Editing the author's user-level `~/.claude/code-review.toml` (the explicit
  `review_mode = "panel"` pin is kept as-is — redundant after the flip but harmless and
  explicit; and it lives outside this marketplace repo).

## Design

### The default lives in two places that must agree

1. **Prose layers (three synced copies).** The `review-gh-pr` skill and its two synced
   copies document the resolution rule: read both toml layers, and *if neither sets
   `review_mode`, `$ORCHESTRATION_MODE = classic` (the built-in default)*. These layers
   always pass an **explicit** `orchestrationMode` ("classic" or "panel") into the engine.
2. **Engine fallback (`review-core.mjs`).** The engine has its own
   `orchestrationMode || 'classic'` fallback (line 213 label, line 214 panel_size, line 233
   log, line 311 behavioural switch). This fallback only bites when the engine is invoked
   **without** an explicit mode — e.g. a direct Workflow dispatch or the A/B harness.

Flipping only the prose would leave the engine's true no-arg fallback running classic while
the prose claims panel — label and behaviour would disagree for direct dispatch. So the flip
is done at **both** layers (approach B, "honest engine-level flip"): one normalised default,
prose and engine in agreement.

### Edits (PR 1)

All under `plugins/code-review-suite/`, on a feature branch → PR (main is branch-protected;
no admin-bypass).

**1. `workflows/review-core.mjs` — normalise the default to panel.**
Introduce a single normalised mode constant just after the args destructure (after line 193):

```js
// Built-in orchestration default is panel (classic is the explicit opt-in, being retired).
const mode = orchestrationMode === 'classic' ? 'classic' : 'panel'
```

Then thread `mode` through the four current `orchestrationMode`-keyed sites so the default is
panel everywhere:
- Line 213: `orchestration_mode: mode`
- Line 214: `panel_size: mode === 'panel' ? (panelSize ?? 3) : null`
- Line 233: log ternary keys off `mode === 'panel'`
- Line 311: `if (mode === 'panel')` (classic is now the fall-through opt-in branch)

Rationale for `=== 'classic' ? 'classic' : 'panel'` rather than `|| 'panel'`: any value that
is not the explicit string `"classic"` (including `undefined`, empty string, or a typo)
resolves to panel — the new default — which is the safe direction now that panel is intended.
An unrecognised non-empty value is still normalised to panel rather than silently running a
third thing.

**2. `skills/review-gh-pr/SKILL.md` (~line 1122).** Change the resolution rule to:
*"If neither layer sets `review_mode`, `$ORCHESTRATION_MODE = panel` (the built-in default);
otherwise it is the resolved `"classic"` or `"panel"`."* Keep the MUST-READ-both-layers
instruction (PR #117) intact. Update any surrounding "(default classic)" cue.

**3. `commands/pre-review.md` (~line 996).** Same edit — synced copy.

**4. `includes/review-pipeline.md` (~line 995).** Same edit — synced copy.

**5. `tests/lib/test_panel_wiring.sh` — `test_panel_review_mode_defaults_classic`.**
Rework to assert the prose now documents **panel** as the built-in default. Rename to
`test_panel_review_mode_defaults_panel`; change the regex from `review_mode.*classic` to match
the panel-default prose (e.g. `review_mode.*panel` on the built-in-default line, scoped so it
does not merely match the "otherwise resolved" clause). Verify it fails before the prose edits
and passes after.

### Deferred: PR 2 (classic retirement, ~1 week out)

Not built now. Tracked two ways:
- **GitHub issue** on `Jodre11/claude-code-plugins`: "Retire classic review orchestration",
  revisit ~2026-07-31, trigger = no complaints after panel-as-default ships. Depends on PR 1
  merged.
- **Memory note** `orchestration-default-flip-plan` updated: mark step 2 shipped, link the
  issue, note step 3 revisit date.

PR 2 scope (for reference, not this spec): delete the classic phase set (cross/synth/resample
phases in `meta`), the classic branch after line 311, the `NON_CROSS` classic-only simplification
noted at review-core.mjs:287-289, and the `review_mode = "classic"` handling in prose. The
`mode` constant collapses to unconditional panel.

## Verification

- `tests/run.sh` green — especially:
  - the reworked `test_panel_review_mode_defaults_panel`,
  - `test_sync_notes.sh` and any sync-consistency test (three prose copies must stay
    byte-aligned on the changed default line),
  - `test_panel_wiring.sh` other cases (param threading, panel_size validation) unaffected.
- Grep confirms no other test or doc still asserts classic-as-default
  (`defaults_classic`, `built-in default`, `default classic`).
- Confirm the engine's `mode` normalisation: a dispatch with no `orchestrationMode` now takes
  the panel branch (inspect by reading, or a targeted unit assertion if one exists for arg
  defaulting).
- **Not run:** a fresh live panel review. Panel is already organically validated — that
  validation is the precondition for this flip, not a step within it.

## Risks

- **Cost.** Panel = N=3 opus panelists per review vs classic's single opus synth, for every
  seed consumer who rides the default. This is a known, accepted implication of the flip
  (recorded in the flip plan). Consumers can opt back to classic via toml until PR 2.
- **Divergence between prose and engine defaults** — mitigated by doing both in approach B.
- **Sync drift across the three prose copies** — mitigated by the sync-notes test.
