#!/usr/bin/env python3
"""ranking_packet — blinded side-by-side ranking packets for the orchestration A/B.

Pure-stdlib. Presents bodyText ONLY (never the JSONL meta), normalises arm tells
against rules in tests/ab/lib/arm_tells.json — these rules SHOULD BE derived from a
real live capture (Task 6 Step 1); the shipped file contains ILLUSTRATIVE PLACEHOLDERS
that MUST be regenerated from a live capture before any real ranking run, and seals a
per-PR arm→label(A/B) randomisation from a recorded seed. Refuses to build without a
pre-registration criteria file present — blinding without a timestamped honesty
anchor is worthless. NEVER calls an LLM.
"""
import argparse
import glob
import json
import os
import random
import re


def normalise_arm_tells(body_text, rules):
    out = body_text
    for rule in rules:
        out = re.sub(rule["pattern"], rule["replace"], out)
    return out


def _strip_provenance(md_text):
    lines = md_text.split("\n")
    if lines and lines[0].startswith("<!-- plugin_sha:"):
        lines = lines[1:]
    return "\n".join(lines).strip()


def _arm_runs(arm_dir):
    runs = []
    for trial in sorted(glob.glob(os.path.join(arm_dir, "trial-*"))):
        v = "INCONCLUSIVE"
        vp = os.path.join(trial, "verdict.txt")
        if os.path.isfile(vp):
            with open(vp, encoding="utf-8") as fh:
                v = fh.read().strip() or "INCONCLUSIVE"
        body = ""
        mp = os.path.join(trial, "durable-log.md")
        if os.path.isfile(mp):
            with open(mp, encoding="utf-8") as fh:
                body = _strip_provenance(fh.read())
        runs.append({"verdict": v, "body": body})
    return runs


_ORDER = ("APPROVE", "REQUEST_CHANGES", "INCONCLUSIVE")


def _modal(runs):
    dist = {}
    for r in runs:
        dist[r["verdict"]] = dist.get(r["verdict"], 0) + 1
    if not dist:
        return "INCONCLUSIVE"
    best = max(dist.values())
    for v in _ORDER:
        if dist.get(v, 0) == best:
            return v
    return max(dist, key=dist.get)


def modal_run_body(arm_dir):
    runs = _arm_runs(arm_dir)
    if not runs:
        return ""
    modal = _modal(runs)
    for r in runs:                    # first run matching the modal verdict
        if r["verdict"] == modal:
            return r["body"]
    return runs[0]["body"]


def seal_assignment(pr_slugs, seed):
    rng = random.Random(seed)
    out = {}
    for slug in pr_slugs:
        if rng.random() < 0.5:
            out[slug] = {"classic": "A", "panel": "B"}
        else:
            out[slug] = {"classic": "B", "panel": "A"}
    return out


def build_packets(run_dir, seed, rules_path, criteria_present):
    if not criteria_present and not os.path.isfile(os.path.join(run_dir, "criteria.md")):
        raise RuntimeError("refusing to build packets: pre-registration criteria.md absent")
    with open(rules_path, encoding="utf-8") as fh:
        rules = json.loads(fh.read())

    pr_slugs = sorted(
        e for e in os.listdir(run_dir)
        if os.path.isdir(os.path.join(run_dir, e, "classic"))
        and os.path.isdir(os.path.join(run_dir, e, "panel"))
    )
    assignment = seal_assignment(pr_slugs, seed)
    packets_dir = os.path.join(run_dir, "packets")
    os.makedirs(packets_dir, exist_ok=True)
    with open(os.path.join(packets_dir, "seed.json"), "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"seed": seed, "assignment": assignment}, indent=2) + "\n")

    for slug in pr_slugs:
        pr_out = os.path.join(packets_dir, slug)
        os.makedirs(pr_out, exist_ok=True)
        for arm, label in assignment[slug].items():
            body = modal_run_body(os.path.join(run_dir, slug, arm))
            with open(os.path.join(pr_out, f"{label}.md"), "w", encoding="utf-8") as fh:
                fh.write(normalise_arm_tells(body, rules) + "\n")


def main(argv=None):
    p = argparse.ArgumentParser(prog="ranking_packet")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--seed", type=int, required=True)
    p.add_argument("--rules", default=os.path.join(os.path.dirname(__file__), "arm_tells.json"))
    args = p.parse_args(argv)
    build_packets(args.run_dir, args.seed, args.rules, criteria_present=False)
    print(f"packets written under {os.path.join(args.run_dir, 'packets')}")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
