I'll review the changed lines in the dispatch client for correctness.
## Correctness Review Findings

### Finding — Silent fallback to default rate limit emits no signal
- **File:** lib/dispatch_client.py:21
- **Confidence:** 75
- **Severity:** Important
- **Description:** When the config API response omits the `rate_limit` key, `record.get("rate_limit")` returns `None` and the function silently substitutes `DEFAULT_RATE_LIMIT` (100) with nothing logged or otherwise observable. This is a fallback path that returns a default without signalling. A misconfigured tenant — or a config-API schema change that drops/renames the field — would be indistinguishable from a tenant genuinely configured at 100 rpm. A future debugger investigating "why is this tenant throttled at 100?" has no trace to tell whether 100 was the resolved value or a silent fallback. The intent is to return the *tenant-specific* limit; quietly masking the absence of that value undermines the goal.
- **Suggested fix:** Emit an observable signal before returning the default, e.g. `logging.getLogger(__name__).warning("rate_limit missing for tenant %s; falling back to default %d", tenant_id, DEFAULT_RATE_LIMIT)` immediately before `return DEFAULT_RATE_LIMIT`.

### Finding — Resolved limit returned without type/sanity validation
- **File:** lib/dispatch_client.py:23
- **Confidence:** 40
- **Severity:** Suggestion
- **Description:** `limit` is returned directly from the parsed JSON whenever it is non-`None`. The signature promises `-> int`, but the value is whatever the API serialised — a JSON float, string, or negative/zero number would pass straight through, violating the declared contract and potentially feeding an invalid limit to callers. Only the missing-key case is guarded.
- **Suggested fix:** Coerce/validate, e.g. `return int(limit)` with a guard rejecting non-positive values, or narrow the check to confirm `isinstance(limit, int)` before returning and otherwise fall back (with a signal, per the finding above).
