I'll review the changed lines in `lib/http_client.py`.
I've reviewed lines 23-34 of `lib/http_client.py`.

## Correctness Review Findings

0 findings.

The `fetch_user_profile` change is sound on correctness grounds:

- **Error path is observable** — the `except` block logs a `warning` with the `user_id` and exception before returning `None`, so a failed request leaves a trace rather than failing silently.
- **Docstring matches behaviour** — "Returns the profile dict, or None if the request fails" is accurate against the implementation.
- **Exception scope is safe** — catching `Exception` (not `BaseException`) leaves `KeyboardInterrupt`/`SystemExit` propagating correctly.
- No off-by-one, null dereference, resource leak (the `with` closes the response), or boundary issue on the changed lines.