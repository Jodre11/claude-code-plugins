## Severity Definitions

Use these definitions when assigning severity to findings. They are listed from most to least severe. When in doubt, choose the lower severity — over-classification wastes the author's time; under-classification is caught by the synthesiser.

### Critical

The defect will cause **data loss, a security breach, or a production outage** if the code ships as written. The failure is near-certain, not speculative.

Litmus test: would you page someone at 2am to prevent this from merging?

Examples: SQL injection, unhandled null on a code path exercised every request, credentials committed to source control, infinite loop in a request handler.

### Important

The defect will cause **observable incorrect behaviour, a runtime error, or silently wrong results** in a reachable code path. A user, downstream system, or operator would notice the defect during normal use — not only under contrived or theoretical conditions.

Litmus test: if this ships, will someone file a bug?

Examples: wrong boolean condition that inverts a filter, unclosed resource in a long-lived process, missing error propagation that swallows failures the caller needs, race condition on shared state in a concurrent code path.

**Not Important** (downgrade to Suggestion): documentation wording, naming improvements, defensive hardening against unreachable conditions, stylistic consistency, cross-reference maintenance, missing comments, redundant-but-harmless code.

### Suggestion

Everything that does not meet the Important bar. Suggestions improve quality, readability, maintainability, or convention adherence but the code functions correctly without the fix.

First-pass reviews should be thorough with Suggestions — flag everything worth improving. Re-reviews (reviewing code that was already reviewed and revised) should only raise new Suggestions on code changed since the last review, not on code the author already saw and chose not to change.

Examples: better variable names, simplified control flow, missed utility reuse, documentation gaps, style inconsistencies, performance improvements in cold paths.
