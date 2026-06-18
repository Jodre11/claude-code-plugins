## Verdict Rubric

<!-- CANONICAL SOURCE — do not delete.
This file is the single source of truth for the PR review verdict rubric, the
orchestrator's posting policy, and the body construction rules. Its content is
inlined verbatim into both consumer files:
  - agents/review-synthesiser.md
  - skills/review-gh-pr/SKILL.md (Step 6)

WHY INLINED: same rationale as review-pipeline.md and ci-status-gate.md — agents
skip file-path references and must see the rule in context. The synthesiser
applies the rubric to compute the verdict; Step 6 of SKILL.md (the orchestrator)
applies the posting policy and body construction transforms.

MAINTENANCE: Edit this file first, then propagate to both consumers. The test
suite verifies the inlined copies match this canonical source. Heading levels
are relative — H2 here renders as H2 in consumers; do not change without
auditing both. -->

### Verdict rubric (PR mode only, first match wins)

| # | Condition | Verdict |
|---|---|---|
| 1 | Intent-ledger states a `goal` AND any consensus finding indicates the goal is not achieved | `REQUEST_CHANGES` |
| 2 | Any consensus **Critical** finding (at any confidence) | `REQUEST_CHANGES` |
| 3 | Any consensus **Important** finding with confidence ≥ 70 | `REQUEST_CHANGES` |
| 4 | Otherwise | `APPROVE` |

The synthesiser produces only `APPROVE` or `REQUEST_CHANGES`. `COMMENT` is
never a synthesiser output, and the orchestrator never auto-downgrades a synth
verdict to `COMMENT`. The only route to a `COMMENT` verdict is an explicit user
override at the Class A confirmation prompt.

By construction under `APPROVE`:
- Either no `goal` was stated in the intent ledger, or no consensus finding
  indicates the goal is not achieved (row 1 did not fire).
- No Critical findings exist (row 2 caught them).
- Important findings only exist below confidence 70 (row 3 caught the rest).
- Suggestions exist at any confidence.

In `local` (pre-review) mode the rubric does not apply: pre-review produces no
verdict — the human reader decides what (if anything) to act on. The synthesiser
emits no `Verdict:` line in local mode.

### Posting policy (orchestrator, mechanical)

The orchestrator filters which consensus findings get posted to GitHub based on
the synthesiser's verdict. The filter is deterministic — same input, same
output, no model judgement. It does not constitute "altering findings" because
the synthesiser's sealed report (severity, confidence, body, fix text) is
unchanged; only which subset gets posted is decided.

| Verdict path | Filter |
|---|---|
| `REQUEST_CHANGES` | Post **every** consensus finding. No filter. The implementer needs the full picture; an under-powered orchestrator must not dilute what a max-effort synthesiser produced. Verbose by design. |
| `APPROVE` | Post consensus findings with **confidence ≥ 75**. Sub-threshold findings remain visible in the synthesiser's stdout report but are not posted to GitHub. |

The 75 threshold is intentionally above the rubric's 70 cutoff for Important
findings. Below 70: don't block. Above 75: surface under APPROVE. The 70-75
band is judged not-confident-enough to distract an author who is already
getting an APPROVE.

### Body construction (orchestrator)

The GitHub top-level review body posts the synthesiser's body verbatim except
for three deterministic transformations:

- References to filtered-out findings (those dropped by the Posting policy
  above) are elided. The synthesiser tags every consensus finding with a stable
  `[#N]` token (see Synthesiser contract below); the orchestrator strips body
  paragraphs and bullets that contain `[#N]` tokens for filtered findings.
- `## Cost` section stripped — instrumentation, not author-facing. Stays in
  stdout for the implementer.
- `## Dismissed` section stripped — false-positives, noise for the author.
  Stays in stdout for the implementer.

### Synthesiser contract

For the orchestrator's filtering to be mechanical, the synthesiser MUST produce
a body where every consensus finding is tagged with a stable `[#N]` token in
its section header, and EVERY reference to that finding elsewhere in the body
(Synthesiser Assessment, Summary, cross-references) carries the same `[#N]`
token. The orchestrator filters by stripping paragraphs and bullets that
contain a filtered-out finding's `[#N]` token via deterministic string
operations — no prose parsing.

<!-- TEST SYNC ANCHOR: the literal "operations — no prose parsing." (start of the
final line of the Synthesiser contract section above) is used as a `sed` end-anchor
in `tests/lib/test_sync_notes.sh::test_sync_verdict_rubric_inline_matches_canonical`
to extract the inlined block from consumer files. Do NOT rephrase the final sentence
without updating the test's sed pattern in lockstep — a partial-phrase rephrase
would silently truncate the extracted body, and the diff-based comparison would
either pass vacuously or fail with an obscure "extracted body was empty" error.

This comment is intentionally placed AFTER the end-anchor line so it sits outside
the extraction window — adding it inside would invalidate the sync test. -->

