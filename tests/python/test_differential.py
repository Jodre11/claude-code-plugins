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


class FindingMatchTest(unittest.TestCase):
    def _f(self, file="a.py", line=10, domain="correctness", tier="consensus", conf=90):
        return {"file": file, "line": line, "domain": domain, "tier": tier,
                "confidence": conf, "severity": "Important", "description": "whatever"}

    def test_match_within_line_proximity(self):
        self.assertTrue(differential.findings_match(self._f(line=10), self._f(line=13)))
        self.assertFalse(differential.findings_match(self._f(line=10), self._f(line=20)))

    def test_match_requires_same_domain_and_file(self):
        self.assertFalse(differential.findings_match(self._f(domain="security"), self._f(domain="style")))
        self.assertFalse(differential.findings_match(self._f(file="a.py"), self._f(file="b.py")))

    def test_match_never_uses_description(self):
        a = self._f(); b = self._f()
        b["description"] = "totally different words"
        self.assertTrue(differential.findings_match(a, b))  # identical position/domain → match

    def test_high_value_is_consensus_or_conf_ge_80(self):
        self.assertTrue(differential.high_value(self._f(tier="dismissed", conf=85)))
        self.assertTrue(differential.high_value(self._f(tier="consensus", conf=10)))
        self.assertFalse(differential.high_value(self._f(tier="contested", conf=50)))


class FindingDeltaTest(unittest.TestCase):
    def _run(self, findings):
        return {"verdict": "REQUEST_CHANGES", "findings": findings, "meta": {}}

    def _f(self, **kw):
        base = {"file": "a.py", "line": 10, "domain": "correctness",
                "tier": "consensus", "confidence": 90, "severity": "Important"}
        base.update(kw)
        return base

    def test_dropped_high_value_finding_flagged(self):
        classic = [self._run([self._f()]), self._run([self._f()]), self._run([self._f()])]
        panel = [self._run([]), self._run([]), self._run([])]
        delta = differential.finding_delta(classic, panel)
        self.assertEqual(len(delta["dropped"]), 1)
        self.assertEqual(len(delta["retained"]), 0)

    def test_retained_finding_not_dropped(self):
        classic = [self._run([self._f()])] * 3
        panel = [self._run([self._f(line=12)])] * 3   # within proximity → retained
        delta = differential.finding_delta(classic, panel)
        self.assertEqual(len(delta["retained"]), 1)
        self.assertEqual(len(delta["dropped"]), 0)

    def test_added_finding_surfaced(self):
        classic = [self._run([])] * 3
        panel = [self._run([self._f(domain="security", file="x.py")])] * 3
        delta = differential.finding_delta(classic, panel)
        self.assertEqual(len(delta["added"]), 1)


class NoiseDominatedTest(unittest.TestCase):
    def test_noise_dominated_true_when_arms_indistinguishable(self):
        # classic and panel both always APPROVE → gap = 1.0-1.0 = 0.0 < 0.1 → True
        with tempfile.TemporaryDirectory() as d:
            pr = pathlib.Path(d) / "pr-x"
            for arm in ("classic", "panel"):
                _write_trial(pr / arm, 1, "APPROVE", [])
                _write_trial(pr / arm, 2, "APPROVE", [])
            out = differential.per_pr_differential(str(pr))
            self.assertIs(out["noise_dominated"], True)

    def test_noise_dominated_false_when_arms_clearly_differ(self):
        # classic always APPROVE, panel always REQUEST_CHANGES → gap = 1.0-0.0 = 1.0 ≥ 0.1 → False
        with tempfile.TemporaryDirectory() as d:
            pr = pathlib.Path(d) / "pr-y"
            for trial in (1, 2):
                _write_trial(pr / "classic", trial, "APPROVE", [])
                _write_trial(pr / "panel", trial, "REQUEST_CHANGES", [])
            out = differential.per_pr_differential(str(pr))
            self.assertIs(out["noise_dominated"], False)
