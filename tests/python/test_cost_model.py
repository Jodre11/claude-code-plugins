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
