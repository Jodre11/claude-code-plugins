import json
import pathlib
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "ab" / "lib"))

import ranking_packet  # noqa: E402


class NormaliseTest(unittest.TestCase):
    def test_rules_applied(self):
        rules = [{"pattern": r"(?i)\bpanelists?\b", "replace": "reviewers"}]
        out = ranking_packet.normalise_arm_tells("The panelists agreed.", rules)
        self.assertNotIn("panelist", out.lower())
        self.assertIn("reviewers", out)

    def test_empty_rules_is_identity(self):
        self.assertEqual(ranking_packet.normalise_arm_tells("x", []), "x")


class SealAssignmentTest(unittest.TestCase):
    def test_deterministic_given_seed(self):
        a = ranking_packet.seal_assignment(["pr-1", "pr-2"], seed=42)
        b = ranking_packet.seal_assignment(["pr-1", "pr-2"], seed=42)
        self.assertEqual(a, b)

    def test_each_pr_maps_both_arms_to_distinct_labels(self):
        m = ranking_packet.seal_assignment(["pr-1"], seed=7)
        self.assertEqual(sorted(m["pr-1"].values()), ["A", "B"])
        self.assertEqual(sorted(m["pr-1"].keys()), ["classic", "panel"])


class BlindingInvariantTest(unittest.TestCase):
    def _scaffold(self, root):
        for arm in ("classic", "panel"):
            td = root / "pr-1" / arm / "trial-001"
            td.mkdir(parents=True)
            (td / "verdict.txt").write_text("REQUEST_CHANGES\n", encoding="utf-8")
            body = "## Review\nThe panelists reached consensus.\n"
            (td / "durable-log.md").write_text("<!-- plugin_sha: x | ts: y -->\n" + body, encoding="utf-8")
            (td / "durable-log.jsonl").write_text(
                json.dumps({"type": "meta", "orchestration_mode": arm}) + "\n", encoding="utf-8")
        (root / "criteria.md").write_text("catches real bugs > low FP\n", encoding="utf-8")

    def test_packet_has_no_orchestration_mode_leak(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            self._scaffold(root)
            rules = [{"pattern": r"(?i)\bpanelists?\b", "replace": "reviewers"}]
            rules_path = root / "arm_tells.json"
            rules_path.write_text(json.dumps(rules), encoding="utf-8")
            ranking_packet.build_packets(str(root), seed=1, rules_path=str(rules_path),
                                         criteria_present=True)
            for label in ("A", "B"):
                txt = (root / "packets" / "pr-1" / f"{label}.md").read_text(encoding="utf-8")
                self.assertNotIn("orchestration_mode", txt)
                self.assertNotIn("classic", txt.lower())
                self.assertNotIn("panelist", txt.lower())

    def test_build_refuses_without_criteria(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            self._scaffold(root)
            (root / "criteria.md").unlink()
            rules_path = root / "arm_tells.json"
            rules_path.write_text("[]", encoding="utf-8")
            with self.assertRaises(Exception):
                ranking_packet.build_packets(str(root), seed=1, rules_path=str(rules_path),
                                             criteria_present=False)
