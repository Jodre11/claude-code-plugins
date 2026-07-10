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


def findings_match(f1, f2, line_proximity=5):
    """Match by (file, domain, line-proximity). NEVER by description text."""
    if f1.get("file", "") != f2.get("file", ""):
        return False
    if f1.get("domain", "") != f2.get("domain", ""):
        return False
    return abs((f1.get("line") or 0) - (f2.get("line") or 0)) <= line_proximity


def high_value(finding):
    return finding.get("tier") == "consensus" or (finding.get("confidence") or 0) >= 80


def _dedupe_arm_findings(runs):
    """Collapse each arm's per-run findings into unique positional findings."""
    uniq = []
    for r in runs:
        for f in r["findings"]:
            if not any(findings_match(f, u) for u in uniq):
                uniq.append(f)
    return uniq


def modal_presence(runs, finding):
    if not runs:
        return False
    hits = sum(1 for r in runs if any(findings_match(finding, f) for f in r["findings"]))
    return hits * 2 >= len(runs)          # >= half the runs


def _conf_band(f):
    c = f.get("confidence") or 0
    return "high" if c >= 80 else ("mid" if c >= 50 else "low")


def finding_delta(runs_a, runs_b):
    """Classic(A) → panel(B) delta. dropped = high-value modally-present in A, not B."""
    a_uniq = _dedupe_arm_findings(runs_a)
    b_uniq = _dedupe_arm_findings(runs_b)
    retained, dropped, tier_moved = [], [], []
    for fa in a_uniq:
        if not modal_presence(runs_a, fa):
            continue
        match = next((fb for fb in b_uniq if findings_match(fa, fb) and modal_presence(runs_b, fb)), None)
        if match is None:
            if high_value(fa):
                dropped.append(fa)
        else:
            retained.append(fa)
            if (fa.get("tier"), _conf_band(fa)) != (match.get("tier"), _conf_band(match)):
                tier_moved.append({"classic": fa, "panel": match})
    added = []
    for fb in b_uniq:
        if not modal_presence(runs_b, fb):
            continue
        if not any(findings_match(fb, fa) and modal_presence(runs_a, fa) for fa in a_uniq):
            added.append(fb)
    return {"retained": retained, "dropped": dropped, "added": added, "tier_moved": tier_moved}


def per_pr_differential(pr_dir):
    classic = load_arm(os.path.join(pr_dir, "classic"))
    panel = load_arm(os.path.join(pr_dir, "panel"))
    agreement = cross_arm_agreement(classic, panel)
    stab = min(within_arm_stability(classic), within_arm_stability(panel))
    delta = finding_delta(classic, panel)
    return {
        "classic_modal_verdict": modal_verdict(classic),
        "panel_modal_verdict": modal_verdict(panel),
        "within_arm_stability": stab,
        "cross_arm_agreement": agreement,
        "finding_delta": delta,
        "noise_dominated": stab < agreement["pairwise_rate"],
        "contradiction": None,          # filled by ranking_unblind once rankings exist
    }


def build_differential(run_dir):
    prs = {}
    for entry in sorted(os.listdir(run_dir)):
        pr_dir = os.path.join(run_dir, entry)
        if os.path.isdir(os.path.join(pr_dir, "classic")) and os.path.isdir(os.path.join(pr_dir, "panel")):
            prs[entry] = per_pr_differential(pr_dir)
    return {"prs": prs}


def main(argv=None):
    p = argparse.ArgumentParser(prog="differential")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--out", default=None)
    args = p.parse_args(argv)
    rep = build_differential(args.run_dir)
    text = json.dumps(rep, indent=2)
    print(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
