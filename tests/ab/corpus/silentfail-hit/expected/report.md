I'll review the changed lines in the HTTP client helper. Let me read the file.
## Correctness Review Findings

### Finding — Silent failure path swallows all errors without any signal
- **File:** lib/http_client.py:30
- **Confidence:** 90
- **Severity:** Important
- **Description:** The `except Exception:` block on line 30 catches every error — network failures, timeouts, HTTP errors, and `json.loads` decode errors — and collapses them all to `return None` (line 31) with no logging, no metric, and no re-raise. A future debugger has no observable signal to distinguish a genuine "profile not found" from a connection timeout, a DNS failure, or a malformed JSON body. The blanket `except Exception` also masks programming errors (e.g. a `TypeError` from a bad call) that should surface. This is the classic silent-failure path: the request can fail in many distinct ways and the caller sees an indistinguishable `None` for all of them.
- **Suggested fix:** Emit an observable signal before returning the fallback, and narrow the caught type. For example:
  ```python
  import logging
  logger = logging.getLogger(__name__)
  ...
  except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
      logger.warning("fetch_user_profile failed for user_id=%s: %s", user_id, exc)
      return None
  ```
  This preserves the `None` fallback contract while leaving a trace, and lets unexpected exception types propagate instead of being silently swallowed.

### Finding — Docstring/return-contract inconsistency with the sibling `get_user`
- **File:** lib/http_client.py:24
- **Confidence:** 55
- **Severity:** Suggestion
- **Description:** The docstring (lines 22–25) states `None` means "the request fails", but the `-> dict | None` signature and the surrounding convention in `get_user` (line 15) use `None` to mean "not found". Here `None` conflates two semantically different outcomes — "profile genuinely absent (404)" and "request errored". A caller cannot tell which occurred, which is a latent correctness hazard for any logic that branches on a missing profile (e.g. retry vs. treat-as-empty). Note `get_user` does *not* handle a 404 at all (`urlopen` raises `HTTPError` on 4xx), so the two functions also disagree on how "not found" is surfaced.
- **Suggested fix:** Decide on one contract. If `None` should mean "not found", catch `HTTPError` with `.code == 404` specifically and return `None` only for that, letting other errors propagate (and aligning `get_user` similarly). Otherwise update the docstring to state that errors are swallowed and the caller cannot distinguish failure modes.