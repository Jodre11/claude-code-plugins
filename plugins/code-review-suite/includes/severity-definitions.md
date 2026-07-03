## Severity Definitions

Use these definitions when assigning severity to findings. They are listed from most to least severe. When in doubt, choose the lower severity — over-classification wastes the author's time; under-classification is caught by the synthesiser.

### Critical

The defect will cause **data loss, a security breach, or a production outage** if the code ships as written. The failure is near-certain, not speculative.

Litmus test: would you page someone at 2am to prevent this from merging?

Examples: SQL injection, unhandled null on a code path exercised every request, credentials committed to source control, infinite loop in a request handler.

### Important

The defect will cause **observable incorrect behaviour, a runtime error, or silently wrong results** in a reachable code path. A user, downstream system, or operator would notice the defect during normal use — not only under contrived or theoretical conditions.

Litmus test: if this ships, will someone file a bug?

Examples: wrong boolean condition that inverts a filter, unclosed resource in a long-lived process, missing error propagation that swallows failures the caller needs, race condition on shared state in a concurrent code path, N+1 query pattern in a production request handler, exact duplicate of an actively-maintained utility that will predictably diverge.

**Agent-hazard basis** (no runtime defect required). A change ALSO meets the Important bar when it will *predictably cause a future maintainer — human or agent — to introduce a defect*, even though it produces no incorrect behaviour today: a lying comment or misleading name, a false-green or tautological test, a silently-deleted workaround, an unmaintainable indirection. Rationale: an agent starts each session with no persistent memory of the codebase, so a misleading artefact is more dangerous than it is for a human who might recall the real story — it actively induces a wrong edit rather than merely costing a read.

Agent-hazard guardrails (these prevent severity inflation — apply them strictly):
- The finding MUST name a *concrete misleading mechanism* and the *specific future defect it induces*. A vague "could confuse someone" does NOT clear the bar.
- This basis reaches **Important only, never Critical**. The Critical bar above is untouched — it stays outage / breach / data-loss.
- The verdict rubric's confidence ≥ 70 gate still applies (`includes/verdict-rubric.md` row 3): a low-confidence agent-hazard finding does not block.

**Not Important** (downgrade to Suggestion): documentation wording, naming improvements *that do not mislead*, defensive hardening against unreachable conditions, stylistic consistency, cross-reference maintenance, missing comments, redundant-but-harmless code. A naming or comment issue clears the Important bar ONLY via the agent-hazard basis above — that is, only when it *actively misleads*, never when it is merely absent, vague, or imperfect.

### Suggestion

Everything that does not meet the Important bar. Suggestions improve quality, readability, maintainability, or convention adherence but the code functions correctly without the fix.

First-pass reviews should be thorough with Suggestions — flag everything worth improving. Re-reviews (reviewing code that was already reviewed and revised) should only raise new Suggestions on code changed since the last review, not on code the author already saw and chose not to change.

Examples: better variable names, simplified control flow, missed utility reuse, documentation gaps, style inconsistencies, performance improvements in cold paths.
