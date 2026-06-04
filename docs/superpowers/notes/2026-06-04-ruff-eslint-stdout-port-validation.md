# ruff / eslint `--stdout` port — live validation + scope-anchor fix (backlog #4)

**Date:** 2026-06-04
**Outcome:** eslint port proven (5/5). ruff port exposed a faithfulness
regression that a follow-up scope-anchor commit fixed (5/5 after). Net: both
specialists ship the `--stdout` invocation; ruff + eslint also gained a
"Scope first" changed-files anchor.

## Why a live sweep happened

The #4 port (`403c375`) was committed on an offline byte-equivalence argument
(ruff/eslint write the same JSON to stdout that the old form redirected to a
temp file, so the parser input is unchanged). That argument was correct **for
the stdout mechanism** but missed a second-order effect: the edit also rewrote
the prose around the invocation. Operator asked to "just prove it works" → gated
haiku/low faithfulness sweeps on the fixed harness.

## What the sweeps showed

| Arm | Wording | Harness | Result |
|---|---|---|---|
| eslint sweep | ported | fixed | **5/5 PASS** |
| ruff sweep (n=5) | ported | fixed | 3/5 — trials 2,4 leaked an out-of-scope `notebook.ipynb` finding |
| ruff isolation (n=5) | **pre-port** | fixed | **5/5 PASS** |
| ruff power arm A (n=20) | ported | fixed | aborted at trial-011 (exit 5); trials 1–10 = 9 canonical + 1 leak (trial-7); trial-11 leaked AND crashed the parser |
| ruff reprobe (06-02, historical) | pre-port | pre-fix | 20/20 PASS |

**The fixture is an out-of-scope trap:** `tests/fixtures/static-analysis/ruff/`
ships both `bad.py` (in scope: changed-lines `bad.py:1`) and `notebook.ipynb`
(on disk, NOT in the diff). `notebook.ipynb` has its own F401. A correct trial
must scan only the changed file (or drop the notebook finding per §5). The
canonical baseline has exactly one finding (`bad.py:1`).

## Root cause (systematic-debugging Phase 1–3)

The `--stdout` edit replaced the terse `Check $CLAUDE_TEMP_DIR is present …` line
with a 4-sentence temp-dir-contract paragraph, pushing the changed-files framing
down the "Tool invocation" section. Trace evidence: leaking trials narrated
*"run Ruff on the changed Python files (bad.py and notebook.ipynb)"* and ran
`ruff check … bad.py notebook.ipynb`, treating both as in scope; clean trials ran
`ruff check … bad.py` only. The pre-port wording went straight to
`<changed-py-files>`, implicitly anchoring scope; the longer paragraph diluted it.

**Honest statistics:** the clean same-harness comparison (ported 4/16 leaks vs
pre-port 0/5) is Fisher p≈0.53 — *not* significant in isolation; n=5/16 is
underpowered, and the 0/20 history ran on the pre-`830905b` harness so pooling
confounds wording with harness. The signal was *suggestive*, backed by a concrete
mechanism + traces, not a p<0.05 proof. A clean n=20 ported arm was impractical
because the crash variant (below) aborts the run.

## The crash path (separate harness-robustness gap)

One leaking variant wrote the finding line as `notebook.ipynb:1 (cell 1)`. The
harness §7 parser (`tests/ab/lib/agent_capture.sh`) feeds the line value to jq as
a numeric; `1 (cell 1)` is not a valid numeric literal → jq aborts → the whole
run exits 5. So the notebook-leak has two faces: faithfulness divergence (plain
`:1`) and a run-killing parser crash (`:1 (cell 1)`). The parser's intolerance of
a non-numeric line is a latent robustness gap independent of the port — logged
for a future fix (it would have bitten any agent that emitted a `(cell N)`
suffix).

## The fix (`508c904`)

Lead the "Tool invocation" section with a **Scope first** anchor in both
ruff-reviewer.md and eslint-reviewer.md: invoke the linter on ONLY the changed
files, never scan the working tree, drop any out-of-scope finding per §5. Keeps
the `--stdout` streaming. **Re-test: hardened ruff is 5/5 canonical** — all five
trials ran `ruff check … bad.py` only, no notebook scan, hash `7b003236…`.

**Caveat on the 5/5:** with a ~25% baseline leak rate, a clean 5/5 has ~24%
chance even unfixed — so 5/5 is *consistent with fixed* and corroborated by the
"no notebook scan" traces, but is not a p<0.05 proof on its own. eslint's fixture
has no out-of-scope sibling, so its anchor is defence-in-depth (untested against
the trap, but correct for real monorepo diffs).

## Lesson

A prose edit "around" a tool invocation is NOT behaviourally inert just because
the *command bytes* are unchanged. Re-ordering/lengthening guidance shifts a
small model's attention. Offline byte-equivalence proves the mechanism, not the
behaviour — gated validation is what caught this.
