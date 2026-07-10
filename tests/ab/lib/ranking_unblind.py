#!/usr/bin/env python3
"""ranking_unblind — join blind rankings to arm labels + the mechanical differential,
then apply the pre-registered decision rule. Pure-stdlib. NEVER calls an LLM. The
maintainer override of the 2/3 threshold, if used, must be logged by the caller
against this on-record value (the "keep me honest" contract).
"""
import argparse
import json
import os


def unblind(rankings, assignment):
    out = {}
    for slug, rk in rankings.items():
        amap = assignment[slug]                       # {"classic":"A","panel":"B"}
        label_to_arm = {v: k for k, v in amap.items()}
        winner = rk["winner"]
        winner_arm = "tie" if winner == "tie" else label_to_arm[winner]
        out[slug] = {"winner_arm": winner_arm, "reason": rk.get("reason", "")}
    return out


def _is_material(pr_diff):
    d = pr_diff["finding_delta"]
    if d["dropped"] or d["added"] or d["tier_moved"]:
        return True
    return pr_diff["classic_modal_verdict"] != pr_diff["panel_modal_verdict"]


def material_prs(differential):
    return [slug for slug, d in sorted(differential["prs"].items()) if _is_material(d)]


def apply_decision_rule(unblinded, differential, cost_non_worse=None):
    material = material_prs(differential)
    # Rule 1: panel wins-or-ties >= 2/3 of material PRs.
    wins_ties = sum(1 for slug in material
                    if unblinded.get(slug, {}).get("winner_arm") in ("panel", "tie"))
    rule1 = (wins_ties >= (2 / 3) * len(material)) if material else False

    # Rule 2: no PR where panel dropped a high-value finding AND ranking did not prefer panel.
    contradictions = []
    for slug, d in differential["prs"].items():
        dropped = bool(d["finding_delta"]["dropped"])
        preferred_panel = unblinded.get(slug, {}).get("winner_arm") == "panel"
        contradiction = dropped and not preferred_panel
        d["contradiction"] = contradiction
        if contradiction:
            contradictions.append(slug)
    rule2 = len(contradictions) == 0

    rule3 = "pending" if cost_non_worse is None else bool(cost_non_worse)
    flip = bool(rule1 and rule2 and rule3 is True)
    return {
        "rule1_ranking": rule1,
        "rule2_no_regression": rule2,
        "rule3_cost": rule3,
        "flip": flip,
        "contradictions": contradictions,
        "detail": {"material_prs": material, "material_wins_ties": wins_ties},
    }


def main(argv=None):
    p = argparse.ArgumentParser(prog="ranking_unblind")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--cost-non-worse", choices=["true", "false"], default=None)
    args = p.parse_args(argv)

    rd = args.run_dir
    with open(os.path.join(rd, "packets", "seed.json"), encoding="utf-8") as fh:
        assignment = json.loads(fh.read())["assignment"]
    with open(os.path.join(rd, "differential.json"), encoding="utf-8") as fh:
        differential = json.loads(fh.read())
    with open(os.path.join(rd, "rankings.json"), encoding="utf-8") as fh:
        rankings = json.loads(fh.read())

    cost = None if args.cost_non_worse is None else (args.cost_non_worse == "true")
    unbl = unblind(rankings, assignment)
    res = apply_decision_rule(unbl, differential, cost_non_worse=cost)
    out = {"unblinded": unbl, "decision": res}
    with open(os.path.join(rd, "unblinded.json"), "w", encoding="utf-8") as fh:
        fh.write(json.dumps(out, indent=2) + "\n")
    print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
