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


class CompositionTest(unittest.TestCase):
    def setUp(self):
        self.params = json.loads(PARAMS_PATH.read_text(encoding="utf-8"))
        self.prices = self.params["prices"]

    def test_depth_bracket_floor_from_opus_trials(self):
        trials = [
            {"model": "claude-opus-4-8", "usage": {"output": 1700}},
            {"model": "claude-opus-4-8", "usage": {"output": 2500}},
            {"model": "claude-sonnet-4-6", "usage": {"output": 9000}},
        ]
        br = cost_model.depth_bracket(trials, self.params)
        self.assertEqual(br["floor"], 2500)  # max opus output, sonnet ignored
        self.assertEqual(br["ceiling"], 2500 * self.params["ceiling_fallback_multiple"])

    def test_depth_bracket_uses_explicit_ceiling(self):
        trials = [{"model": "claude-opus-4-8", "usage": {"output": 2000}}]
        br = cost_model.depth_bracket(trials, self.params, ceiling_output=20000)
        self.assertEqual(br["ceiling"], 20000)

    def test_no_share_costs_n_times_full_input(self):
        row = {"input": 0.00001, "output": 0, "cache_read": 0, "cache_creation": 0}
        no_share = cost_model.panel_input_cost(3, prefix_tokens=1000, suffix_tokens=0,
                                               price_row=row, cache_mode="no-share")
        # 3 panelists x 1000 full-price input tokens
        self.assertAlmostEqual(no_share, 3 * 1000 * 0.00001)

    def test_shared_warm_is_cheaper_than_no_share(self):
        row = {"input": 0.00001, "output": 0, "cache_read": 0.000001, "cache_creation": 0.0000125}
        shared = cost_model.panel_input_cost(3, 1000, 0, row, "shared-warm")
        no_share = cost_model.panel_input_cost(3, 1000, 0, row, "no-share")
        self.assertLess(shared, no_share)

    def test_compose_arm_panel3_scales_with_n(self):
        # With trivial Stage-1 costs, panel-5 must exceed panel-3.
        per_turn = {"stage1": cost_model.price_turn(
            {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}, self.prices["claude-sonnet-4-6"])}
        a3 = cost_model.compose_arm("panel-3", self.params, self.prices, diff_tokens=20000,
                                    depth_output=5000, cache_mode="no-share", per_turn_costs=per_turn)
        a5 = cost_model.compose_arm("panel-5", self.params, self.prices, diff_tokens=20000,
                                    depth_output=5000, cache_mode="no-share", per_turn_costs=per_turn)
        self.assertGreater(a5["usd"], a3["usd"])

    def test_old_arm_includes_probabilistic_resample(self):
        per_turn = {"stage1": cost_model.price_turn(
            {"input": 10, "output": 10, "cache_read": 0, "cache_creation": 0},
            self.prices["claude-sonnet-4-6"])}
        p0 = {**self.params, "resample": {**self.params["resample"], "p_gate_fires": 0.0}}
        p1 = {**self.params, "resample": {**self.params["resample"], "p_gate_fires": 1.0}}
        a0 = cost_model.compose_arm("old", p0, self.prices, 20000, 5000, "no-share", per_turn)
        a1 = cost_model.compose_arm("old", p1, self.prices, 20000, 5000, "no-share", per_turn)
        self.assertGreater(a1["usd"], a0["usd"])  # p=1 dearer than p=0
