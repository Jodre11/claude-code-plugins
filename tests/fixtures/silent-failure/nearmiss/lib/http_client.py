"""HTTP client helpers for the review-harness scratch tooling.

Thin wrappers around urllib.request used only by the silent-failure
A/B trial corpus.
"""

import json
import logging
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = "https://api.example.invalid"


def get_user(user_id: int) -> dict | None:
    """Return user record for *user_id*, or None when the user is not found."""
    url = f"{BASE_URL}/users/{user_id}"
    with urllib.request.urlopen(url, timeout=5) as resp:
        return json.loads(resp.read())


def fetch_user_profile(user_id: int) -> dict | None:
    """Fetch the extended profile for *user_id* from the profile endpoint.

    Returns the profile dict, or None if the request fails.
    """
    url = f"{BASE_URL}/profiles/{user_id}"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return json.loads(resp.read())
    except Exception as exc:
        logger.warning("fetch_user_profile(%s) failed: %s", user_id, exc)
        return None
