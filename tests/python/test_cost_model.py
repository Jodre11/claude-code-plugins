import json
import os
import pathlib
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "ab" / "lib"))

FIXTURES = REPO / "tests" / "fixtures" / "cost-model"
PARAMS_PATH = REPO / "tests" / "ab" / "lib" / "cost_model_params.json"


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
