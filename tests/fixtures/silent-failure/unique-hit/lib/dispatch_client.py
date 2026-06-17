"""Dispatch-queue client helpers for the review-harness scratch tooling.

Thin wrappers around urllib.request used only by the silent-failure
A/B trial corpus.
"""

import json
import time
import urllib.request


BASE_URL = "https://api.example.invalid"
MAX_ATTEMPTS = 3
POLL_INTERVAL_SECONDS = 2


def enqueue_job(payload: dict) -> str:
    """Submit *payload* to the dispatch queue and return the new job id."""
    url = f"{BASE_URL}/jobs"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())["job_id"]


def await_dispatch(job_id: str) -> dict | None:
    """Poll the dispatch queue for *job_id* until it reports a terminal state.

    Returns the completed job record, or None if the job has not settled.
    """
    url = f"{BASE_URL}/jobs/{job_id}"
    for _ in range(MAX_ATTEMPTS):
        with urllib.request.urlopen(url, timeout=5) as resp:
            record = json.loads(resp.read())
        if record["state"] == "done":
            return record
        time.sleep(POLL_INTERVAL_SECONDS)
    return None
