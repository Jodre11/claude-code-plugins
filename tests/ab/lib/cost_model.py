#!/usr/bin/env python3
"""cost_model — predict per-arm cost for the panel-review redesign.

Pure-stdlib analysis tool. Reads A/B harness per-turn usage from
tests/ab/runs/**/trial-*/stream.jsonl (real data, gitignored, local-only)
and an externalised JSON parameter block, and classifies each candidate
arm KILL / SURVIVE against the ranked cost bar. Emits a comparison table;
touches no review path. See
docs/superpowers/specs/2026-07-08-panel-review-cost-model-design.md.
"""
import argparse
import glob
import json
import os
import sys


# --- parsing ----------------------------------------------------------------

def resolve_model(records):
    """Return the plain model token from the first assistant record.

    Uses message.model (scanner-safe), never the ARN. Fail-fast: a trial
    with no resolvable model is an error, not a silent default.
    """
    for rec in records:
        if rec.get("type") == "assistant":
            model = rec.get("message", {}).get("model")
            if model:
                return model
    raise ValueError("no assistant record with message.model found")


def parse_trial(stream_text):
    """Parse one trial's stream.jsonl text into a normalised usage dict."""
    records = [json.loads(ln) for ln in stream_text.splitlines() if ln.strip()]
    result = next((r for r in records if r.get("type") == "result"), None)
    if result is None:
        raise ValueError("no result record in trial")
    u = result["usage"]
    model_usage = result.get("modelUsage", {})
    recorded = None
    if model_usage:
        recorded = next(iter(model_usage.values())).get("costUSD")
    if recorded is None:
        recorded = result.get("total_cost_usd")
    return {
        "model": resolve_model(records),
        "usage": {
            "input": u["input_tokens"],
            "output": u["output_tokens"],
            "cache_read": u["cache_read_input_tokens"],
            "cache_creation": u["cache_creation_input_tokens"],
        },
        "duration_ms": result["duration_ms"],
        "num_turns": result["num_turns"],
        "recorded_cost_usd": recorded,
    }


def load_runs(runs_dir):
    """Walk runs_dir for **/stream.jsonl; return parsed trials."""
    trials = []
    pattern = os.path.join(runs_dir, "**", "stream.jsonl")
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
            if text.strip():
                trials.append(parse_trial(text))
        except (ValueError, KeyError, json.JSONDecodeError):
            continue
    return trials


# --- pricing ----------------------------------------------------------------

def price_turn(usage, price_row):
    """USD cost of one turn: element-wise token count x per-token price."""
    channels = ("input", "output", "cache_read", "cache_creation")
    out = {c: usage[c] * price_row[c] for c in channels}
    out["total"] = sum(out[c] for c in channels)
    return out


def cross_check(trial, price_row, rel_tol=0.05):
    """Recompute a trial's cost from tokens x price; compare to recorded USD.

    The recorded modelUsage.costUSD is Bedrock-priced, so this is an
    INDEPENDENT validation of the price row — provided the price row is
    sourced independently (from the claude-api skill), never back-filled
    from the recorded cost. A rel_err above rel_tol means the price row is
    wrong or stale (e.g. a list-rate change, or a cache-TTL band mismatch
    if a 5m-TTL trial appears — see the Task 1 cache-TTL guard).
    """
    recomputed = price_turn(trial["usage"], price_row)["total"]
    recorded = trial["recorded_cost_usd"]
    if not recorded:
        return {"recomputed": recomputed, "recorded": recorded, "rel_err": float("inf"), "ok": False}
    rel_err = abs(recomputed - recorded) / recorded
    return {"recomputed": recomputed, "recorded": recorded, "rel_err": rel_err, "ok": rel_err <= rel_tol}
