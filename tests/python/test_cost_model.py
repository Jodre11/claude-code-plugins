import json
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
            {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}, self.prices["claude-sonnet-4-6"]),
            "usage": {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}}
        a3 = cost_model.compose_arm("panel-3", self.params, self.prices, diff_tokens=20000,
                                    depth_output=5000, cache_mode="no-share", per_turn_costs=per_turn)
        a5 = cost_model.compose_arm("panel-5", self.params, self.prices, diff_tokens=20000,
                                    depth_output=5000, cache_mode="no-share", per_turn_costs=per_turn)
        self.assertGreater(a5["usd"], a3["usd"])

    def test_old_arm_includes_probabilistic_resample(self):
        per_turn = {"stage1": cost_model.price_turn(
            {"input": 10, "output": 10, "cache_read": 0, "cache_creation": 0},
            self.prices["claude-sonnet-4-6"]),
            "usage": {"input": 10, "output": 10, "cache_read": 0, "cache_creation": 0}}
        p0 = {**self.params, "resample": {**self.params["resample"], "p_gate_fires": 0.0}}
        p1 = {**self.params, "resample": {**self.params["resample"], "p_gate_fires": 1.0}}
        a0 = cost_model.compose_arm("old", p0, self.prices, 20000, 5000, "no-share", per_turn)
        a1 = cost_model.compose_arm("old", p1, self.prices, 20000, 5000, "no-share", per_turn)
        self.assertGreater(a1["usd"], a0["usd"])  # p=1 dearer than p=0

    def test_compose_arm_returns_token_split(self):
        per_turn = {"stage1": cost_model.price_turn(
            {"input": 5, "output": 5, "cache_read": 0, "cache_creation": 0}, self.prices["claude-sonnet-4-6"]),
            "usage": {"input": 5, "output": 5, "cache_read": 0, "cache_creation": 0}}
        a3 = cost_model.compose_arm("panel-3", self.params, self.prices, 20000, 5000,
                                    "no-share", per_turn)
        for ch in ("input", "output", "cache_read", "cache_creation"):
            self.assertIn(ch, a3["tokens"])
        a5 = cost_model.compose_arm("panel-5", self.params, self.prices, 20000, 5000,
                                    "no-share", per_turn)
        self.assertGreater(a5["tokens"]["output"], a3["tokens"]["output"])


class WallClockAndVerdictTest(unittest.TestCase):
    def setUp(self):
        self.params = json.loads(PARAMS_PATH.read_text(encoding="utf-8"))
        self.secs = {"cross": 30.0, "opus_per_1k_output": 12.0, "writer": 20.0}

    def test_old_wall_clock_includes_serial_cross_and_synth(self):
        # p_gate=0 -> no resample: cross(30) + synth(4*12=48) = 78
        w0 = cost_model.wall_clock("old", self.params, depth_output=4000,
                                   per_turn_secs=self.secs, p_gate=0.0)
        self.assertAlmostEqual(w0, 78.0)
        # p_gate=1 -> gate always re-fires: 78 * 2 = 156
        w1 = cost_model.wall_clock("old", self.params, depth_output=4000,
                                   per_turn_secs=self.secs, p_gate=1.0)
        self.assertAlmostEqual(w1, 156.0)

    def test_panel_wall_clock_is_parallel_then_writer(self):
        w = cost_model.wall_clock("panel-3", self.params, depth_output=4000, per_turn_secs=self.secs)
        # parallel panel (one turn: 4*12=48) + writer (20) = 68; N does not add serial time
        self.assertAlmostEqual(w, 48.0 + 20.0)

    def test_panel_wall_clock_ignores_n(self):
        w3 = cost_model.wall_clock("panel-3", self.params, 4000, self.secs)
        w5 = cost_model.wall_clock("panel-5", self.params, 4000, self.secs)
        self.assertAlmostEqual(w3, w5)  # parallel: 5 panelists no slower than 3

    def test_classify_kill_when_dearer_on_both(self):
        self.assertEqual(cost_model.classify(200, 100, old_usd=100, old_wall_s=80), "KILL")

    def test_classify_survive_when_cheaper_on_wall_clock(self):
        # dearer tokens, but faster wall-clock -> not dominated -> SURVIVE
        self.assertEqual(cost_model.classify(200, 60, old_usd=100, old_wall_s=80), "SURVIVE")

    def test_wall_clock_unknown_arm_raises(self):
        with self.assertRaises(ValueError):
            cost_model.wall_clock("legacy", self.params, 4000, self.secs)

    def test_classify_survive_when_cheaper_but_slower(self):
        # cheaper tokens, slower wall-clock -> not dominated -> SURVIVE
        self.assertEqual(cost_model.classify(50, 100, old_usd=100, old_wall_s=80), "SURVIVE")


class ReportTest(unittest.TestCase):
    def setUp(self):
        self.params = json.loads(PARAMS_PATH.read_text(encoding="utf-8"))
        self.trials = cost_model.load_runs(str(FIXTURES))

    def test_build_report_covers_all_arms_and_diff_sizes(self):
        rep = cost_model.build_report(self.trials, self.params)
        self.assertEqual(set(rep["diff_sizes"]), {"small", "median", "large"})
        for band in rep["rows"]:
            self.assertIn(band["arm"], {"old", "panel-3", "panel-5"})
            self.assertIn(band["verdict"], {"KILL", "SURVIVE"})

    def test_report_has_cross_check_per_model(self):
        rep = cost_model.build_report(self.trials, self.params)
        models = {c["model"] for c in rep["cross_check"]}
        self.assertIn("claude-opus-4-8", models)
        self.assertIn("claude-sonnet-4-6", models)

    def test_sensitivity_flags_verdict_flip(self):
        rep = cost_model.build_report(self.trials, self.params)
        # sensitivity["fragile_arms"] lists arms whose verdict is not constant
        # across depth x cache brackets; type must be a list.
        self.assertIsInstance(rep["sensitivity"]["fragile_arms"], list)

    def test_main_runs_on_fixtures(self):
        rc = cost_model.main(["--params", str(PARAMS_PATH), "--runs", str(FIXTURES)])
        self.assertEqual(rc, 0)

    def test_main_returns_1_when_no_trials(self):
        rc = cost_model.main(["--params", str(PARAMS_PATH), "--runs", str(REPO / "tests" / "fixtures" / "cost-model-empty-does-not-exist")])
        self.assertEqual(rc, 1)

    def test_report_sweeps_resample_points(self):
        rep = cost_model.build_report(self.trials, self.params)
        self.assertEqual(rep["resample_points"], [0.0, 0.25, 1.0])
        ps = {r["resample_p"] for r in rep["rows"]}
        self.assertEqual(ps, {0.0, 0.25, 1.0})
        # Fixture data has a shallow depth bracket (floor=1700, ceiling=6800 via fallback),
        # so panel-5 at large/no-share is dearer AND slower at p=0 — a genuine KILL, which
        # positively demonstrates the verdict axis can reach KILL (not just SURVIVE). Real
        # runs (floor=2786, ceiling=25956) produce no fragile arms — see findings doc.
        self.assertEqual(rep["sensitivity"]["fragile_arms"], ["panel-5"])

    def test_main_json_output_is_serialisable(self):
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cost_model.main(["--params", str(PARAMS_PATH), "--runs", str(FIXTURES), "--json"])
        self.assertEqual(rc, 0)
        parsed = json.loads(buf.getvalue())
        self.assertIn("rows", parsed)
        self.assertIn("cross_check", parsed)


class SynthHarvestTest(unittest.TestCase):
    def test_finds_deepest_opus_turn_from_streaming_chunks(self):
        # Real transcripts have NO result record; usage is at message.usage,
        # repeated per streaming chunk. Take the max output_tokens.
        text = "\n".join([
            json.dumps({"type": "assistant", "message": {"model": "claude-opus-4-8",
                "usage": {"input_tokens": 2, "output_tokens": 9603,
                          "cache_read_input_tokens": 74158, "cache_creation_input_tokens": 2830}}}),
            json.dumps({"type": "assistant", "message": {"model": "claude-opus-4-8",
                "usage": {"input_tokens": 2, "output_tokens": 25956,
                          "cache_read_input_tokens": 76988, "cache_creation_input_tokens": 561}}}),
            json.dumps({"type": "user", "message": {"role": "user"}}),
        ])
        turn = cost_model.find_old_path_synth_turn(text)
        self.assertIsNotNone(turn)
        self.assertEqual(turn["model"], "claude-opus-4-8")
        self.assertEqual(turn["usage"]["output"], 25956)   # max chunk, not first
        self.assertEqual(turn["usage"]["cache_read"], 76988)

    def test_ignores_non_opus_assistant_records(self):
        text = "\n".join([
            json.dumps({"type": "assistant", "message": {"model": "claude-sonnet-4-6",
                "usage": {"input_tokens": 5, "output_tokens": 40000,
                          "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}}),
        ])
        self.assertIsNone(cost_model.find_old_path_synth_turn(text))

    def test_returns_none_without_any_usage(self):
        text = json.dumps({"type": "assistant", "message": {"model": "claude-opus-4-8"}})
        self.assertIsNone(cost_model.find_old_path_synth_turn(text))
