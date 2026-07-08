import json
import os
import pathlib
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "ab" / "lib"))

FIXTURES = REPO / "tests" / "fixtures" / "cost-model"
PARAMS_PATH = REPO / "tests" / "ab" / "lib" / "cost_model_params.json"

import cost_model  # noqa: E402


class FixtureIntegrityTest(unittest.TestCase):
    def test_params_json_loads_and_has_price_rows(self):
        params = json.loads(PARAMS_PATH.read_text(encoding="utf-8"))
        for model in ("claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"):
            row = params["prices"][model]
            for k in ("input", "output", "cache_read", "cache_creation"):
                self.assertIsInstance(row[k], (int, float))

    def test_fixtures_are_valid_jsonl_with_a_result_record(self):
        for name in ("opus-reuse", "sonnet-housekeeper"):
            text = (FIXTURES / name / "stream.jsonl").read_text(encoding="utf-8")
            recs = [json.loads(ln) for ln in text.splitlines() if ln.strip()]
            self.assertTrue(any(r.get("type") == "result" for r in recs))
            self.assertTrue(any(r.get("type") == "assistant" for r in recs))

    def test_fixtures_contain_no_real_arn(self):
        # Scanner-safety guard: committed fixtures must not carry real ARNs.
        for name in ("opus-reuse", "sonnet-housekeeper"):
            text = (FIXTURES / name / "stream.jsonl").read_text(encoding="utf-8")
            self.assertNotIn("application-inference-profile/", text)


class ParseTrialTest(unittest.TestCase):
    def _text(self, name):
        return (FIXTURES / name / "stream.jsonl").read_text(encoding="utf-8")

    def test_resolve_model_reads_plain_message_model(self):
        recs = [json.loads(ln) for ln in self._text("opus-reuse").splitlines() if ln.strip()]
        self.assertEqual(cost_model.resolve_model(recs), "claude-opus-4-8")

    def test_resolve_model_raises_when_absent(self):
        with self.assertRaises(ValueError):
            cost_model.resolve_model([{"type": "result", "usage": {}}])

    def test_parse_trial_extracts_usage_and_model(self):
        t = cost_model.parse_trial(self._text("opus-reuse"))
        self.assertEqual(t["model"], "claude-opus-4-8")
        self.assertEqual(t["usage"]["input"], 12)
        self.assertEqual(t["usage"]["output"], 1700)
        self.assertEqual(t["usage"]["cache_read"], 271407)
        self.assertEqual(t["usage"]["cache_creation"], 19227)
        self.assertEqual(t["num_turns"], 6)
        self.assertEqual(t["duration_ms"], 29000)
        self.assertAlmostEqual(t["recorded_cost_usd"], 0.37053349999999996)

    def test_load_runs_reads_fixture_dir(self):
        trials = cost_model.load_runs(str(FIXTURES))
        models = sorted(t["model"] for t in trials)
        self.assertEqual(models, ["claude-opus-4-8", "claude-sonnet-4-6"])


class PriceEngineTest(unittest.TestCase):
    def test_price_turn_sums_per_channel(self):
        usage = {"input": 100, "output": 10, "cache_read": 1000, "cache_creation": 50}
        row = {"input": 0.00001, "output": 0.0001, "cache_read": 0.000001, "cache_creation": 0.00002}
        out = cost_model.price_turn(usage, row)
        # 100*1e-5 + 10*1e-4 + 1000*1e-6 + 50*2e-5 = 0.001 + 0.001 + 0.001 + 0.001
        self.assertAlmostEqual(out["total"], 0.004)
        self.assertAlmostEqual(out["cache_read"], 0.001)

    def test_cross_check_flags_agreement(self):
        # Contrived exact prices so recomputed == recorded.
        trial = {"usage": {"input": 0, "output": 100, "cache_read": 0, "cache_creation": 0},
                 "recorded_cost_usd": 0.01, "model": "x"}
        row = {"input": 0, "output": 0.0001, "cache_read": 0, "cache_creation": 0}
        res = cost_model.cross_check(trial, row)
        self.assertTrue(res["ok"])
        self.assertAlmostEqual(res["rel_err"], 0.0)

    def test_cross_check_flags_disagreement(self):
        trial = {"usage": {"input": 0, "output": 100, "cache_read": 0, "cache_creation": 0},
                 "recorded_cost_usd": 0.01, "model": "x"}
        row = {"input": 0, "output": 0.0005, "cache_read": 0, "cache_creation": 0}  # 5x off
        res = cost_model.cross_check(trial, row)
        self.assertFalse(res["ok"])


class CrossCheckOnFixturesTest(unittest.TestCase):
    def setUp(self):
        self.params = json.loads(PARAMS_PATH.read_text(encoding="utf-8"))

    def _trial(self, name):
        return cost_model.parse_trial(
            (FIXTURES / name / "stream.jsonl").read_text(encoding="utf-8"))

    def test_opus_price_row_reproduces_recorded_cost(self):
        t = self._trial("opus-reuse")
        res = cost_model.cross_check(t, self.params["prices"][t["model"]])
        self.assertTrue(res["ok"],
                        f"opus rel_err {res['rel_err']:.3f}; recomputed "
                        f"{res['recomputed']:.5f} vs recorded {res['recorded']:.5f}")

    def test_sonnet_price_row_reproduces_recorded_cost(self):
        t = self._trial("sonnet-housekeeper")
        res = cost_model.cross_check(t, self.params["prices"][t["model"]])
        self.assertTrue(res["ok"],
                        f"sonnet rel_err {res['rel_err']:.3f}; recomputed "
                        f"{res['recomputed']:.5f} vs recorded {res['recorded']:.5f}")
