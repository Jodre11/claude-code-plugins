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


# --- composition ------------------------------------------------------------

def depth_bracket(trials, params, ceiling_output=None):
    """Panel per-turn output-token bracket: floor from on-disk opus turns,
    ceiling from a harvested deep synth turn (if given) else a fallback
    multiple of the floor."""
    opus_outputs = [t["usage"]["output"] for t in trials
                    if t["model"].startswith("claude-opus-4-8")]
    floor = max(opus_outputs) if opus_outputs else 0.0
    if ceiling_output is None:
        ceiling_output = floor * params["ceiling_fallback_multiple"]
    return {"floor": float(floor), "ceiling": float(ceiling_output)}


def panel_input_cost(n, prefix_tokens, suffix_tokens, price_row, cache_mode):
    """Input-side USD for N panelists sharing a prefix.

    shared-warm: prefix cached once (creation) then read (N-1) times, plus N
    small suffixes at full input price.
    no-share:    every panelist pays full input price for prefix + suffix.
    """
    if cache_mode == "no-share":
        return n * (prefix_tokens + suffix_tokens) * price_row["input"]
    if cache_mode == "shared-warm":
        creation = prefix_tokens * price_row["cache_creation"]
        reads = (n - 1) * prefix_tokens * price_row["cache_read"]
        suffixes = n * suffix_tokens * price_row["input"]
        return creation + reads + suffixes
    raise ValueError(f"unknown cache_mode: {cache_mode}")


def compose_arm(arm_name, params, prices, diff_tokens, depth_output,
                cache_mode, per_turn_costs):
    """Per-arm total tokens + USD for a given diff size, depth, cache mode.

    Stage 1 is common to all arms and costed from a representative real
    Stage-1 turn (per_turn_costs['stage1']['total']) x the Stage-1 turn count.
    """
    tc = params["turn_counts"]
    stage1_turns = tc["stage1_core_sonnet"] + tc["stage1_conditional"]
    stage1_usd = stage1_turns * per_turn_costs["stage1"]["total"]

    if arm_name == "old":
        cross_usd = tc["cross_sonnet"] * per_turn_costs["stage1"]["total"]
        synth_usd = price_turn(
            {"input": diff_tokens, "output": depth_output,
             "cache_read": 0, "cache_creation": 0},
            prices["claude-opus-4-8"])["total"]
        middle_usd = cross_usd + synth_usd
        # Resample is a probabilistic addend: with probability p_gate_fires the
        # boundary gate fires and re-runs Stage-1 + cross + synth once more.
        p = params["resample"]["p_gate_fires"]
        middle_usd += p * (stage1_usd + cross_usd + synth_usd)
    elif arm_name.startswith("panel-"):
        n = int(arm_name.split("-")[1])
        prefix = diff_tokens + params["concern_brief_tokens"]
        panel_input = panel_input_cost(n, prefix, suffix_tokens=0,
                                       price_row=prices["claude-opus-4-8"],
                                       cache_mode=cache_mode)
        panel_output = n * depth_output * prices["claude-opus-4-8"]["output"]
        writer_usd = price_turn(
            {"input": diff_tokens, "output": 3000, "cache_read": 0, "cache_creation": 0},
            prices["claude-sonnet-4-6"])["total"]
        middle_usd = panel_input + panel_output + writer_usd
    else:
        raise ValueError(f"unknown arm: {arm_name}")

    return {"usd": stage1_usd + middle_usd,
            "stage1_usd": stage1_usd,
            "middle_usd": middle_usd}
