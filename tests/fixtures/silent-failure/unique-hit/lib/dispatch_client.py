"""Rate-limit resolution helpers for the review-harness scratch tooling.

Thin wrappers around urllib.request used only by the silent-failure
A/B trial corpus.
"""

import json
import urllib.request


BASE_URL = "https://api.example.invalid"
DEFAULT_RATE_LIMIT = 100


def resolve_tenant_rate_limit(tenant_id: str) -> int:
    """Return the configured requests-per-minute for *tenant_id*."""
    url = f"{BASE_URL}/tenants/{tenant_id}/limits"
    with urllib.request.urlopen(url, timeout=5) as resp:
        record = json.loads(resp.read())
    limit = record.get("rate_limit")
    if limit is None:
        return DEFAULT_RATE_LIMIT
    return limit
