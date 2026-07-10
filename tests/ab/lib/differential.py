#!/usr/bin/env python3
"""differential — mechanical differential for the panel-vs-classic orchestration A/B.

Pure-stdlib. Reads the harvested durable-log JSONL + per-trial verdict.txt under a
run dir and computes verdict agreement (within-arm noise floor + cross-arm) and the
finding-set delta (matched by file/line-proximity/domain, NEVER description). Emits
the honesty flags the decision rule needs (contradiction, noise-dominated). Never
calls an LLM — the quality sign is the human ranking, not this tool.
"""
import argparse
import glob
import json
import os

_VERDICT_ORDER = ("APPROVE", "REQUEST_CHANGES", "INCONCLUSIVE")


def _read_jsonl(path):
    out = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln:
                out.append(json.loads(ln))
    return out


def load_arm(arm_dir):
    """One entry per trial-*/ under arm_dir: {verdict, findings, meta}."""
    runs = []
    for trial in sorted(glob.glob(os.path.join(arm_dir, "trial-*"))):
        verdict = "INCONCLUSIVE"
        vpath = os.path.join(trial, "verdict.txt")
        if os.path.isfile(vpath):
            with open(vpath, encoding="utf-8") as fh:
                verdict = fh.read().strip() or "INCONCLUSIVE"
        findings, meta = [], {}
        jpath = os.path.join(trial, "durable-log.jsonl")
        if os.path.isfile(jpath):
            for rec in _read_jsonl(jpath):
                if rec.get("type") == "finding":
                    findings.append(rec)
                elif rec.get("type") == "meta":
                    meta = rec
        runs.append({"verdict": verdict, "findings": findings, "meta": meta})
    return runs


def verdict_distribution(runs):
    dist = {}
    for r in runs:
        dist[r["verdict"]] = dist.get(r["verdict"], 0) + 1
    return dist


def modal_verdict(runs):
    dist = verdict_distribution(runs)
    if not dist:
        return "INCONCLUSIVE"
    best = max(dist.values())
    for v in _VERDICT_ORDER:            # deterministic tie-break by canonical order
        if dist.get(v, 0) == best:
            return v
    return max(dist, key=dist.get)      # non-canonical verdicts fall through


def within_arm_stability(runs):
    if not runs:
        return 0.0
    modal = modal_verdict(runs)
    return sum(1 for r in runs if r["verdict"] == modal) / len(runs)


def cross_arm_agreement(runs_a, runs_b):
    modal_match = modal_verdict(runs_a) == modal_verdict(runs_b)
    if not runs_a or not runs_b:
        return {"modal_match": modal_match, "pairwise_rate": 0.0}
    agree = sum(1 for a in runs_a for b in runs_b if a["verdict"] == b["verdict"])
    return {"modal_match": modal_match, "pairwise_rate": agree / (len(runs_a) * len(runs_b))}
