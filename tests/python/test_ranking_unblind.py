import pathlib
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "ab" / "lib"))

import ranking_unblind  # noqa: E402


def _diff(dropped=0, added=0, verdict_differ=False):
    return {
        "classic_modal_verdict": "REQUEST_CHANGES",
        "panel_modal_verdict": "APPROVE" if verdict_differ else "REQUEST_CHANGES",
        "finding_delta": {"dropped": [{"x": 1}] * dropped, "added": [{"y": 1}] * added,
                          "retained": [], "tier_moved": []},
        "noise_dominated": False, "contradiction": None,
    }


class UnblindTest(unittest.TestCase):
    def test_unblind_maps_labels_back_to_arms(self):
        assignment = {"pr-1": {"classic": "A", "panel": "B"}}
        rankings = {"pr-1": {"winner": "B", "reason": "clearer"}}
        out = ranking_unblind.unblind(rankings, assignment)
        self.assertEqual(out["pr-1"]["winner_arm"], "panel")


class MaterialTest(unittest.TestCase):
    def test_near_identical_pr_is_immaterial(self):
        diff = {"prs": {"pr-1": _diff(), "pr-2": _diff(dropped=1)}}
        self.assertEqual(ranking_unblind.material_prs(diff), ["pr-2"])


class DecisionRuleTest(unittest.TestCase):
    def test_flip_when_panel_wins_material_and_no_regression(self):
        diff = {"prs": {"pr-1": _diff(added=1), "pr-2": _diff(added=1), "pr-3": _diff(added=1)}}
        assignment = {p: {"classic": "A", "panel": "B"} for p in ("pr-1", "pr-2", "pr-3")}
        rankings = {p: {"winner": "B", "reason": "r"} for p in ("pr-1", "pr-2", "pr-3")}
        unbl = ranking_unblind.unblind(rankings, assignment)
        res = ranking_unblind.apply_decision_rule(unbl, diff, cost_non_worse=True)
        self.assertTrue(res["rule1_ranking"])
        self.assertTrue(res["rule2_no_regression"])
        self.assertTrue(res["flip"])

    def test_no_flip_when_panel_drops_finding_and_ranking_did_not_prefer_it(self):
        diff = {"prs": {"pr-1": _diff(dropped=1)}}
        assignment = {"pr-1": {"classic": "A", "panel": "B"}}
        rankings = {"pr-1": {"winner": "A", "reason": "classic caught more"}}  # preferred classic
        unbl = ranking_unblind.unblind(rankings, assignment)
        res = ranking_unblind.apply_decision_rule(unbl, diff, cost_non_worse=True)
        self.assertFalse(res["rule2_no_regression"])
        self.assertFalse(res["flip"])
        self.assertEqual(len(res["contradictions"]), 1)

    def test_cost_pending_blocks_flip(self):
        diff = {"prs": {"pr-1": _diff(added=1)}}
        assignment = {"pr-1": {"classic": "A", "panel": "B"}}
        rankings = {"pr-1": {"winner": "B", "reason": "r"}}
        unbl = ranking_unblind.unblind(rankings, assignment)
        res = ranking_unblind.apply_decision_rule(unbl, diff, cost_non_worse=None)
        self.assertEqual(res["rule3_cost"], "pending")
        self.assertFalse(res["flip"])
