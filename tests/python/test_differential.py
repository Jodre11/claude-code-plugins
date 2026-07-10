import json
import pathlib
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "ab" / "lib"))

import differential  # noqa: E402


def _write_trial(arm_dir, n, verdict, findings, meta=None):
    td = arm_dir / f"trial-{n:03d}"
    td.mkdir(parents=True)
    (td / "verdict.txt").write_text(verdict + "\n", encoding="utf-8")
    lines = [json.dumps({**(meta or {}), "type": "meta"})]
    lines += [json.dumps({**f, "type": "finding"}) for f in findings]
    (td / "durable-log.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return td


class VerdictAgreementTest(unittest.TestCase):
    def test_within_arm_stability_all_agree(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            for i in range(1, 4):
                _write_trial(arm, i, "REQUEST_CHANGES", [])
            runs = differential.load_arm(arm)
            self.assertEqual(differential.modal_verdict(runs), "REQUEST_CHANGES")
            self.assertEqual(differential.within_arm_stability(runs), 1.0)

    def test_within_arm_stability_split(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            _write_trial(arm, 1, "APPROVE", [])
            _write_trial(arm, 2, "REQUEST_CHANGES", [])
            _write_trial(arm, 3, "REQUEST_CHANGES", [])
            runs = differential.load_arm(arm)
            self.assertEqual(differential.modal_verdict(runs), "REQUEST_CHANGES")
            self.assertAlmostEqual(differential.within_arm_stability(runs), 2 / 3)

    def test_cross_arm_pairwise_rate(self):
        with tempfile.TemporaryDirectory() as d:
            a = pathlib.Path(d) / "classic"
            b = pathlib.Path(d) / "panel"
            for i in range(1, 3):
                _write_trial(a, i, "REQUEST_CHANGES", [])
            _write_trial(b, 1, "REQUEST_CHANGES", [])
            _write_trial(b, 2, "APPROVE", [])
            ra, rb = differential.load_arm(a), differential.load_arm(b)
            agg = differential.cross_arm_agreement(ra, rb)
            self.assertFalse(agg["modal_match"])  # classic RC vs panel modal APPROVE/RC tie→first
            self.assertAlmostEqual(agg["pairwise_rate"], 0.5)  # 2 of 4 pairs agree
