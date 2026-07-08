# Panel-Review Cost-Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone, stdlib-only Python cost model that predicts per-arm (`old` / `panel-3` / `panel-5`) token spend, wall-clock, and USD for the proposed `review-gh-pr` panel redesign from data already on disk, and classifies each arm **kill** or **survive-to-A/B** — with zero new review tokens, before any pipeline build.

**Architecture:** A pure-stdlib engine `tests/ab/lib/cost_model.py` (importable functions + a `main()` CLI), mirroring the existing `tests/ab/lib/ab_stats.py` + `tests/python/test_ab_stats.py` split. It reads per-turn `usage` from the A/B harness `tests/ab/runs/**/trial-*/stream.jsonl` records (real data, local-only — `tests/ab/runs/` is gitignored), prices each turn against an externalised JSON parameter block, composes per-arm totals across a diff-size sweep × a reasoning-depth bracket × a cache-sharing bracket, and self-validates by recomputing recorded Bedrock cost. CI-gated unit tests run against small committed, ARN-redacted fixtures under `tests/fixtures/cost-model/`. The deliverables are the engine plus a findings write-up; **nothing in the review path changes.**

**Tech Stack:** Python 3.11+ (stdlib only — `json`, `argparse`, `pathlib`, `os`, `sys`, `math`, `glob`; **no** third-party packages, matching `ab_stats.py` and `bin/housekeeper-freshness`). Bash test bridge (`tests/lib/test_*.sh` → `tests/run.sh`). Tests use `unittest.TestCase` (the only Python style CI collects — see Global Constraints).

## Global Constraints

Every task's requirements implicitly include this section. Values copied verbatim from the spec and the verified repo state.

- **Stdlib only.** No `pip`, no third-party imports. The engine and tests import only the Python standard library. (Matches `tests/ab/lib/ab_stats.py`.)
- **Python 3.11+** — permitted (the housekeeper engine already requires `tomllib`, 3.11+).
- **Python indentation = 4 spaces.** JSON & Markdown = 2 spaces. All files LF line endings, final newline. (`.editorconfig` / `.gitattributes`.)
- **Tests MUST be `unittest.TestCase` subclasses**, not bare `def test_` functions. CI runs `tests/run.sh` → `tests/lib/test_housekeeper_engine.sh` → `python3 -m unittest discover -s tests/python`, which collects **only** `TestCase` classes. Bare pytest-style functions (as in `test_ab_stats.py`) are silently **not** run in CI. Do not copy that style.
- **Scanner-safe commits.** A pre-commit hook + gitleaks scan staged changes. These patterns are **forbidden in any committed file**: the literal string `application-inference-profile/` followed by 10–16 `[a-z0-9]` chars (a real Bedrock ARN fragment); and `arn:aws...:<12 digits>` (account ID in an ARN). Committed fixtures and params **must not contain real ARNs**. Resolve model identity from the plain `message.model` token (e.g. `claude-opus-4-8`) instead. When you must mention an ARN in prose/commits, elide the prefix (write `…/5kqc3rwmz09k`, never `application-inference-profile/<id>`).
- **`tests/ab/runs/` is gitignored** (`.gitignore:36`). Real run data lives there locally and is **absent in CI**. The engine reads it at runtime; tests never depend on it — they use committed fixtures under `tests/fixtures/cost-model/`.
- **Bash tool rules (hook-enforced):** one simple command per call — no `&&`, `;`, `|`, `$(...)`, or redirection (except `2>&1`). Prefer Read/Edit/Write over `cat`/`sed`/`awk`/`echo`. Only carve-out is the `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC.
- **Plugins repo = PR workflow.** `main` is branch-protected. Work lands on `design/panel-review-cost-model`; integration is via PR, not direct push. Run `tests/run.sh` (must be green) before every commit that touches Python or test files.
- **No `version` field** in any `plugin.json` (not touched here, but standing).
- **Verdict vocabulary is fixed:** an arm is **KILL** iff it is dearer than `old` on **both** tokens and wall-clock (dominated); otherwise **SURVIVE-to-A/B**. A cost model never emits "go" (quality/simplicity are not cost-observable).

## Reference: the real data shape (verified on disk)

One trial's `stream.jsonl` is newline-delimited JSON. Two record types matter:

- `{"type":"assistant","message":{"model":"claude-opus-4-8", …}}` — carries the **plain model name** (scanner-safe). Present in every trial with ≥1 turn.
- `{"type":"result", …}` — the **per-turn aggregate**, exactly one per trial. Verified fields:
  ```
  duration_ms, duration_api_ms, num_turns, total_cost_usd,
  usage: { input_tokens, output_tokens,
           cache_creation_input_tokens, cache_read_input_tokens },
  modelUsage: { "<arn>": { inputTokens, outputTokens, cacheReadInputTokens,
                           cacheCreationInputTokens, costUSD, contextWindow } }
  ```
  `modelUsage` has exactly one entry for these single-model turns; its `costUSD` is **Bedrock-priced** (the cross-check ground truth). Read it as `next(iter(modelUsage.values()))["costUSD"]` — do **not** key on the ARN.

Verified representative turns (used to build fixtures):

| Trait | reuse (opus) trial-001 | housekeeper (sonnet) trial-015 |
|---|---|---|
| `message.model` | `claude-opus-4-8` | `claude-sonnet-4-6` |
| `usage.input_tokens` | 12 | 13 |
| `usage.output_tokens` | 1700 | 3003 |
| `usage.cache_creation_input_tokens` | 19227 | 12831 |
| `usage.cache_read_input_tokens` | 271407 | 373295 |
| `total_cost_usd` | 0.37053349999999996 | 0.2340585 |
| `duration_ms` | 29000 | 63455 |
| `num_turns` | 6 | 11 |
| `contextWindow` | 1000000 | 200000 |

Note the opus turns are **reuse-specialist-shaped on a small fixture diff** — shallow (≈1.7k output). They ground the opus *price row* and a depth *floor*; the panel-depth *ceiling* comes from a deep opus-max synth turn harvested from a transcript (Task 7, best-effort).

---

### Task 1: Parameter block + scanner-safe fixtures

**Files:**
- Create: `tests/ab/lib/cost_model_params.json`
- Create: `tests/fixtures/cost-model/opus-reuse/stream.jsonl`
- Create: `tests/fixtures/cost-model/sonnet-housekeeper/stream.jsonl`
- Create: `tests/python/test_cost_model.py`

**Interfaces:**
- Consumes: nothing (foundation task).
- Produces: the params JSON schema and two fixture trials consumed by every later task; the test module later tasks extend.

- [ ] **Step 1: Write the params JSON**

Prices are **illustrative placeholders** — Task 3 replaces them with real Bedrock rates from the `claude-api` skill and the cross-check validates them. Structure is final; values are not. Per-token USD (i.e. per-1M-token rate ÷ 1e6).

Create `tests/ab/lib/cost_model_params.json`:

```json
{
  "_note": "Per-token USD prices. Populate `prices` from the claude-api skill's Bedrock rates in Task 3; the cross-check validates them. Model keys are plain model tokens (scanner-safe), never ARNs.",
  "prices": {
    "claude-opus-4-8": {
      "input": 0.000015,
      "output": 0.000075,
      "cache_read": 0.0000015,
      "cache_creation": 0.00001875
    },
    "claude-sonnet-4-6": {
      "input": 0.000003,
      "output": 0.000015,
      "cache_read": 0.0000003,
      "cache_creation": 0.00000375
    },
    "claude-haiku-4-5": {
      "input": 0.0000008,
      "output": 0.000004,
      "cache_read": 0.00000008,
      "cache_creation": 0.000001
    }
  },
  "turn_counts": {
    "stage1_core_sonnet": 8,
    "stage1_conditional": 4,
    "cross_sonnet": 8
  },
  "resample": {
    "p_gate_fires": 0.25,
    "bracket": [0.0, 1.0]
  },
  "panel_n": [3, 5],
  "cache_sharing_modes": ["shared-warm", "no-share"],
  "concern_brief_tokens": 2000,
  "ceiling_fallback_multiple": 4.0,
  "diff_sizes": {
    "small": 4000,
    "median": 20000,
    "large": 80000
  }
}
```

- [ ] **Step 2: Write the opus fixture trial**

Create `tests/fixtures/cost-model/opus-reuse/stream.jsonl` (2 JSONL lines; `modelUsage` keyed by the **plain model name**, not an ARN — scanner-safe and the engine reads the value, not the key). `costUSD` is the real recorded value:

```
{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","content":[{"type":"text","text":"synthetic reuse finding"}]}}
{"type":"result","subtype":"success","is_error":false,"duration_ms":29000,"duration_api_ms":27624,"num_turns":6,"result":"synthetic","total_cost_usd":0.37053349999999996,"usage":{"input_tokens":12,"cache_creation_input_tokens":19227,"cache_read_input_tokens":271407,"output_tokens":1700},"modelUsage":{"claude-opus-4-8":{"inputTokens":12,"outputTokens":1700,"cacheReadInputTokens":271407,"cacheCreationInputTokens":19227,"costUSD":0.37053349999999996,"contextWindow":1000000,"maxOutputTokens":64000}}}
```

- [ ] **Step 3: Write the sonnet fixture trial**

Create `tests/fixtures/cost-model/sonnet-housekeeper/stream.jsonl`:

```
{"type":"assistant","message":{"model":"claude-sonnet-4-6","role":"assistant","content":[{"type":"text","text":"synthetic housekeeper finding"}]}}
{"type":"result","subtype":"success","is_error":false,"duration_ms":63455,"duration_api_ms":61624,"num_turns":11,"result":"synthetic","total_cost_usd":0.2340585,"usage":{"input_tokens":13,"cache_creation_input_tokens":12831,"cache_read_input_tokens":373295,"output_tokens":3003},"modelUsage":{"claude-sonnet-4-6":{"inputTokens":13,"outputTokens":3003,"cacheReadInputTokens":373295,"cacheCreationInputTokens":12831,"costUSD":0.2340585,"contextWindow":200000,"maxOutputTokens":32000}}}
```

- [ ] **Step 4: Write the failing test — fixtures parse as JSONL, params load, no ARNs**

Create `tests/python/test_cost_model.py`:

```python
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
```

- [ ] **Step 5: Run the test to verify it passes (fixtures + params exist and are well-formed)**

Run: `python3 -m unittest tests.python.test_cost_model.FixtureIntegrityTest -v`
(from repo root). Expected: 3 tests PASS. If `ModuleNotFoundError`, run from the repo root so `tests.python...` resolves.

- [ ] **Step 6: Verify the CI bridge discovers the new module**

Run: `python3 -m unittest discover -s tests/python -v`
Expected: the `FixtureIntegrityTest` cases appear in the output (proves CI's discovery path collects this file).

- [ ] **Step 7: Run the full structural suite**

Run: `tests/run.sh`
Expected: ends with `... passed`, exit 0 (the `housekeeper engine unittest` gate now also runs our tests).

- [ ] **Step 8: Commit**

```bash
git add tests/ab/lib/cost_model_params.json tests/fixtures/cost-model/opus-reuse/stream.jsonl tests/fixtures/cost-model/sonnet-housekeeper/stream.jsonl tests/python/test_cost_model.py
git commit -m "$(cat <<'EOF'
test(code-review): scaffold cost-model params + scanner-safe fixtures

Externalised parameter block (illustrative prices, real Bedrock rates land
in the cross-check task) plus two ARN-free fixture trials (opus reuse,
sonnet housekeeper) mirroring real stream.jsonl records. Tests use
unittest.TestCase so CI's `unittest discover` bridge collects them.
EOF
)"
```

---

### Task 2: Trial parser + model resolver

**Files:**
- Create: `tests/ab/lib/cost_model.py`
- Modify: `tests/python/test_cost_model.py`

**Interfaces:**
- Consumes: fixtures + params from Task 1.
- Produces:
  - `resolve_model(records: list) -> str` — the plain model token from the first `assistant` record's `message.model`; raises `ValueError` if none found (fail-fast, no silent default).
  - `parse_trial(stream_text: str) -> dict` — returns `{"model": str, "usage": {"input": int, "output": int, "cache_read": int, "cache_creation": int}, "duration_ms": int, "num_turns": int, "recorded_cost_usd": float}`.
  - `load_runs(runs_dir: str) -> list` — walks `runs_dir` for `**/trial-*/stream.jsonl`, returns a list of `parse_trial` dicts (skips unreadable/empty files).

- [ ] **Step 1: Write the failing test**

Add to `tests/python/test_cost_model.py`:

```python
import cost_model  # noqa: E402  (import after sys.path insert above)


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
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest tests.python.test_cost_model.ParseTrialTest -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'cost_model'`.

- [ ] **Step 3: Write the minimal implementation**

Create `tests/ab/lib/cost_model.py`:

```python
#!/usr/bin/env python3
"""cost_model — predict per-arm cost for the panel-review redesign.

Pure-stdlib analysis tool. Reads A/B harness per-turn usage from
tests/ab/runs/**/trial-*/stream.jsonl (real data, gitignored, local-only)
and an externalised JSON parameter block, and classifies each candidate
arm KILL / SURVIVE against the ranked cost bar. Emits a comparison table;
touches no review path. See
docs/superpowers/specs/2026-07-08-panel-review-cost-model-design.md.
"""
import argparse
import glob
import json
import os
import sys


# --- parsing ----------------------------------------------------------------

def resolve_model(records):
    """Return the plain model token from the first assistant record.

    Uses message.model (scanner-safe), never the ARN. Fail-fast: a trial
    with no resolvable model is an error, not a silent default.
    """
    for rec in records:
        if rec.get("type") == "assistant":
            model = rec.get("message", {}).get("model")
            if model:
                return model
    raise ValueError("no assistant record with message.model found")


def parse_trial(stream_text):
    """Parse one trial's stream.jsonl text into a normalised usage dict."""
    records = [json.loads(ln) for ln in stream_text.splitlines() if ln.strip()]
    result = next((r for r in records if r.get("type") == "result"), None)
    if result is None:
        raise ValueError("no result record in trial")
    u = result["usage"]
    model_usage = result.get("modelUsage", {})
    recorded = None
    if model_usage:
        recorded = next(iter(model_usage.values())).get("costUSD")
    if recorded is None:
        recorded = result.get("total_cost_usd")
    return {
        "model": resolve_model(records),
        "usage": {
            "input": u["input_tokens"],
            "output": u["output_tokens"],
            "cache_read": u["cache_read_input_tokens"],
            "cache_creation": u["cache_creation_input_tokens"],
        },
        "duration_ms": result["duration_ms"],
        "num_turns": result["num_turns"],
        "recorded_cost_usd": recorded,
    }


def load_runs(runs_dir):
    """Walk runs_dir for **/trial-*/stream.jsonl; return parsed trials."""
    trials = []
    pattern = os.path.join(runs_dir, "**", "stream.jsonl")
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            text = open(path, encoding="utf-8").read()
            if text.strip():
                trials.append(parse_trial(text))
        except (ValueError, KeyError, json.JSONDecodeError):
            continue
    return trials
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest tests.python.test_cost_model.ParseTrialTest -v`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/cost_model.py tests/python/test_cost_model.py
git commit -m "$(cat <<'EOF'
feat(code-review): cost-model trial parser + model resolver

parse_trial/resolve_model/load_runs read normalised per-turn usage from
harness stream.jsonl, resolving model from the plain message.model token
(never the ARN). Fail-fast on unresolvable model.
EOF
)"
```

---

### Task 3: Price engine + Bedrock cross-check (self-validation)

**Files:**
- Modify: `tests/ab/lib/cost_model.py`
- Modify: `tests/ab/lib/cost_model_params.json` (replace illustrative prices with real Bedrock rates)
- Modify: `tests/python/test_cost_model.py`

**Interfaces:**
- Consumes: `parse_trial` (Task 2); the params `prices` block (Task 1).
- Produces:
  - `price_turn(usage: dict, price_row: dict) -> dict` — returns `{"input","output","cache_read","cache_creation","total"}` USD. `usage` keys are the normalised `parse_trial` keys; `price_row` keys are `input/output/cache_read/cache_creation` (per-token USD).
  - `cross_check(trial: dict, price_row: dict, rel_tol: float = 0.05) -> dict` — returns `{"recomputed": float, "recorded": float, "rel_err": float, "ok": bool}`.

- [ ] **Step 1: Write the failing test**

Add to `tests/python/test_cost_model.py`:

```python
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest tests.python.test_cost_model.PriceEngineTest -v`
Expected: FAIL — `AttributeError: module 'cost_model' has no attribute 'price_turn'`.

- [ ] **Step 3: Implement the price engine**

Append to `tests/ab/lib/cost_model.py`:

```python
# --- pricing ----------------------------------------------------------------

def price_turn(usage, price_row):
    """USD cost of one turn: element-wise token count x per-token price."""
    channels = ("input", "output", "cache_read", "cache_creation")
    out = {c: usage[c] * price_row[c] for c in channels}
    out["total"] = sum(out[c] for c in channels)
    return out


def cross_check(trial, price_row, rel_tol=0.05):
    """Recompute a trial's cost from tokens x price; compare to recorded USD.

    The recorded modelUsage.costUSD is Bedrock-priced, so this is an
    INDEPENDENT validation of the price row — provided the price row is
    sourced independently (from the claude-api skill), never back-filled
    from the recorded cost. A rel_err above rel_tol means the price row is
    wrong or stale (e.g. a 1M-context premium not modelled).
    """
    recomputed = price_turn(trial["usage"], price_row)["total"]
    recorded = trial["recorded_cost_usd"]
    if not recorded:
        return {"recomputed": recomputed, "recorded": recorded, "rel_err": float("inf"), "ok": False}
    rel_err = abs(recomputed - recorded) / recorded
    return {"recomputed": recomputed, "recorded": recorded, "rel_err": rel_err, "ok": rel_err <= rel_tol}
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest tests.python.test_cost_model.PriceEngineTest -v`
Expected: 3 tests PASS.

- [ ] **Step 5: Obtain real Bedrock prices and validate against recorded cost**

**Do not guess prices** (CLAUDE.md: "Don't guess"). Invoke the `claude-api` skill to read the current Bedrock per-1M-token rates for `claude-opus-4-8`, `claude-sonnet-4-6`, and `claude-haiku-4-5` (input / output / cache-read / cache-write). Convert to per-token (÷ 1e6) and write them into `tests/ab/lib/cost_model_params.json` `prices`, replacing the illustrative values from Task 1.

Then add a data-driven validation test that runs the cross-check on the real fixtures. Add to `tests/python/test_cost_model.py`:

```python
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
```

- [ ] **Step 6: Run the cross-check; if opus fails, investigate the 1M-context premium**

Run: `python3 -m unittest tests.python.test_cost_model.CrossCheckOnFixturesTest -v`
Expected: both PASS. If `test_opus_...` FAILS with recomputed materially below recorded, the opus turn was billed at the **1M-context premium** (fixture `contextWindow` is 1000000). Add a distinct price row `claude-opus-4-8-1m` in the params and a resolver rule keying on `contextWindow > 200000`; re-run until green. Record the outcome — it is a real finding for the write-up (opus panel prompts are large and may hit the premium). Do **not** back-fill the price to force a pass — the price must stay the independent claude-api value.

- [ ] **Step 7: Run the full suite and commit**

Run: `tests/run.sh` — expected green.

```bash
git add tests/ab/lib/cost_model.py tests/ab/lib/cost_model_params.json tests/python/test_cost_model.py
git commit -m "$(cat <<'EOF'
feat(code-review): cost-model price engine + Bedrock cross-check

price_turn composes per-channel token x price; cross_check recomputes a
turn's cost and compares to the recorded Bedrock costUSD as an independent
self-validation. Real Bedrock rates sourced from the claude-api skill;
validated against the on-disk opus and sonnet turns.
EOF
)"
```

---

### Task 4: Arm composition + cache-sharing model + depth bracket

**Files:**
- Modify: `tests/ab/lib/cost_model.py`
- Modify: `tests/python/test_cost_model.py`

**Interfaces:**
- Consumes: `price_turn` (Task 3); `load_runs` (Task 2); the params `turn_counts`, `panel_n`, `cache_sharing_modes`, `concern_brief_tokens`, `diff_sizes`, `ceiling_fallback_multiple`.
- Produces:
  - `depth_bracket(trials: list, params: dict, ceiling_output: float | None = None) -> dict` — returns `{"floor": float, "ceiling": float}` panel per-turn **output** tokens. Floor = max `output` among on-disk `claude-opus-4-8*` trials. Ceiling = `ceiling_output` if given (harvested synth turn, Task 7), else `floor * params["ceiling_fallback_multiple"]`.
  - `panel_input_cost(n: int, prefix_tokens: float, suffix_tokens: float, price_row: dict, cache_mode: str) -> float` — input-side USD for N panelists sharing a `prefix` (brief+diff+findings) with a per-panelist `suffix`. `cache_mode` ∈ `{"shared-warm","no-share"}`.
  - `compose_arm(arm_name: str, params: dict, prices: dict, diff_tokens: float, depth_output: float, cache_mode: str, per_turn_costs: dict) -> dict` — returns `{"tokens": {...}, "usd": float}`. `arm_name` ∈ `{"old","panel-3","panel-5"}`. `per_turn_costs` maps a role → a representative priced turn (from Stage-1 harness turns), letting Stage-1 (common to all arms) be costed from real data.

- [ ] **Step 1: Write the failing test**

Add to `tests/python/test_cost_model.py`:

```python
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest tests.python.test_cost_model.CompositionTest -v`
Expected: FAIL — `AttributeError: ... 'depth_bracket'`.

- [ ] **Step 3: Implement composition**

Append to `tests/ab/lib/cost_model.py`:

```python
# --- composition ------------------------------------------------------------

def depth_bracket(trials, params, ceiling_output=None):
    """Panel per-turn output-token bracket: floor from on-disk opus turns,
    ceiling from a harvested deep synth turn (if given) else a fallback
    multiple of the floor."""
    opus_outputs = [t["usage"]["output"] for t in trials
                    if t["model"].startswith("claude-opus-4-8")]
    floor = max(opus_outputs) if opus_outputs else 0.0
    if ceiling_output is None:
        ceiling_output = floor * params["ceiling_fallback_multiple"]
    return {"floor": float(floor), "ceiling": float(ceiling_output)}


def panel_input_cost(n, prefix_tokens, suffix_tokens, price_row, cache_mode):
    """Input-side USD for N panelists sharing a prefix.

    shared-warm: prefix cached once (creation) then read (N-1) times, plus N
    small suffixes at full input price.
    no-share:    every panelist pays full input price for prefix + suffix.
    """
    if cache_mode == "no-share":
        return n * (prefix_tokens + suffix_tokens) * price_row["input"]
    if cache_mode == "shared-warm":
        creation = prefix_tokens * price_row["cache_creation"]
        reads = (n - 1) * prefix_tokens * price_row["cache_read"]
        suffixes = n * suffix_tokens * price_row["input"]
        return creation + reads + suffixes
    raise ValueError(f"unknown cache_mode: {cache_mode}")


def compose_arm(arm_name, params, prices, diff_tokens, depth_output,
                cache_mode, per_turn_costs):
    """Per-arm total tokens + USD for a given diff size, depth, cache mode.

    Stage 1 is common to all arms and costed from a representative real
    Stage-1 turn (per_turn_costs['stage1']['total']) x the Stage-1 turn count.
    """
    tc = params["turn_counts"]
    stage1_turns = tc["stage1_core_sonnet"] + tc["stage1_conditional"]
    stage1_usd = stage1_turns * per_turn_costs["stage1"]["total"]

    if arm_name == "old":
        cross_usd = tc["cross_sonnet"] * per_turn_costs["stage1"]["total"]
        synth_usd = price_turn(
            {"input": diff_tokens, "output": depth_output,
             "cache_read": 0, "cache_creation": 0},
            prices["claude-opus-4-8"])["total"]
        middle_usd = cross_usd + synth_usd
        # Resample is a probabilistic addend: with probability p_gate_fires the
        # boundary gate fires and re-runs Stage-1 + cross + synth once more.
        p = params["resample"]["p_gate_fires"]
        middle_usd += p * (stage1_usd + cross_usd + synth_usd)
    elif arm_name.startswith("panel-"):
        n = int(arm_name.split("-")[1])
        prefix = diff_tokens + params["concern_brief_tokens"]
        panel_input = panel_input_cost(n, prefix, suffix_tokens=0,
                                       price_row=prices["claude-opus-4-8"],
                                       cache_mode=cache_mode)
        panel_output = n * depth_output * prices["claude-opus-4-8"]["output"]
        writer_usd = price_turn(
            {"input": diff_tokens, "output": 3000, "cache_read": 0, "cache_creation": 0},
            prices["claude-sonnet-4-6"])["total"]
        middle_usd = panel_input + panel_output + writer_usd
    else:
        raise ValueError(f"unknown arm: {arm_name}")

    return {"usd": stage1_usd + middle_usd,
            "stage1_usd": stage1_usd,
            "middle_usd": middle_usd}
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest tests.python.test_cost_model.CompositionTest -v`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/cost_model.py tests/python/test_cost_model.py
git commit -m "$(cat <<'EOF'
feat(code-review): cost-model arm composition, cache + depth brackets

compose_arm totals old/panel-N middle-stage USD over a Stage-1 baseline
costed from real turns. panel_input_cost brackets cross-panelist cache
sharing (shared-warm vs no-share); depth_bracket floors panel output at
on-disk opus turns and ceilings at a harvested synth turn or a fallback.
EOF
)"
```

---

### Task 5: Wall-clock model + kill/survive classifier

**Files:**
- Modify: `tests/ab/lib/cost_model.py`
- Modify: `tests/python/test_cost_model.py`

**Interfaces:**
- Consumes: params `turn_counts`; a representative Stage-1 turn duration.
- Produces:
  - `wall_clock(arm_name: str, params: dict, depth_output: float, per_turn_secs: dict) -> float` — predicted critical-path seconds. `per_turn_secs` maps `{"cross": float, "opus_per_1k_output": float, "writer": float}`. `old` = cross fan-out (serial after Stage 1) + serial opus synth long pole; panel = one parallel opus turn (depth-scaled) + short writer. Stage 1 is common → excluded from the delta (documented).
  - `classify(arm_total_usd: float, arm_wall_s: float, old_usd: float, old_wall_s: float) -> str` — `"KILL"` iff `arm_total_usd > old_usd` **and** `arm_wall_s > old_wall_s`; else `"SURVIVE"`.

- [ ] **Step 1: Write the failing test**

Add to `tests/python/test_cost_model.py`:

```python
class WallClockAndVerdictTest(unittest.TestCase):
    def setUp(self):
        self.params = json.loads(PARAMS_PATH.read_text(encoding="utf-8"))
        self.secs = {"cross": 30.0, "opus_per_1k_output": 12.0, "writer": 20.0}

    def test_old_wall_clock_includes_serial_cross_and_synth(self):
        w = cost_model.wall_clock("old", self.params, depth_output=4000, per_turn_secs=self.secs)
        # 8 cross serial-after-stage1 is modelled parallel (max), synth serial:
        # cross fan-out (30) + synth (4 * 12 = 48) = 78
        self.assertAlmostEqual(w, 30.0 + 48.0)

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
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest tests.python.test_cost_model.WallClockAndVerdictTest -v`
Expected: FAIL — `AttributeError: ... 'wall_clock'`.

- [ ] **Step 3: Implement wall-clock + classify**

Append to `tests/ab/lib/cost_model.py`:

```python
# --- wall clock + verdict ---------------------------------------------------

def wall_clock(arm_name, params, depth_output, per_turn_secs):
    """Predicted critical-path seconds for the middle stage (Stage 1 common,
    excluded). old = parallel cross fan-out THEN serial opus-max synth long
    pole. panel = one parallel opus turn (N panelists concurrent) THEN a short
    sonnet writer. The structural win is dropping the serial cross stage from
    ahead of a deep opus turn; per-turn opus depth may still be large."""
    opus_secs = (depth_output / 1000.0) * per_turn_secs["opus_per_1k_output"]
    if arm_name == "old":
        return per_turn_secs["cross"] + opus_secs
    if arm_name.startswith("panel-"):
        return opus_secs + per_turn_secs["writer"]
    raise ValueError(f"unknown arm: {arm_name}")


def classify(arm_total_usd, arm_wall_s, old_usd, old_wall_s):
    """KILL iff dominated (dearer on BOTH tokens and wall-clock); else
    SURVIVE-to-A/B. A cost model never returns 'go'."""
    if arm_total_usd > old_usd and arm_wall_s > old_wall_s:
        return "KILL"
    return "SURVIVE"
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest tests.python.test_cost_model.WallClockAndVerdictTest -v`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/cost_model.py tests/python/test_cost_model.py
git commit -m "$(cat <<'EOF'
feat(code-review): cost-model wall-clock model + kill/survive classifier

wall_clock models the structural difference (old: serial cross fan-out then
opus-max synth long pole; panel: one parallel opus turn then short writer).
classify emits KILL only when an arm is dominated on both tokens and
wall-clock, else SURVIVE-to-A/B — never "go".
EOF
)"
```

---

### Task 6: CLI `main` — sweep, report, sensitivity

**Files:**
- Modify: `tests/ab/lib/cost_model.py`
- Modify: `tests/python/test_cost_model.py`

**Interfaces:**
- Consumes: every function above.
- Produces:
  - `build_report(trials: list, params: dict, ceiling_output=None) -> dict` — the full result: per (diff-size × depth-band × cache-mode) arm totals, deltas vs `old`, verdicts, plus a `cross_check` block per model and a `sensitivity` summary (does any arm's verdict flip across the brackets?). Pure given `trials` + `params`.
  - `main(argv=None) -> int` — CLI: `--params PATH --runs DIR [--out PATH] [--json]`; loads, builds the report, prints a human table (and JSON if `--json`). Returns 0.

- [ ] **Step 1: Write the failing test**

Add to `tests/python/test_cost_model.py`:

```python
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest tests.python.test_cost_model.ReportTest -v`
Expected: FAIL — `AttributeError: ... 'build_report'`.

- [ ] **Step 3: Implement the report builder + CLI**

Append to `tests/ab/lib/cost_model.py`:

```python
# --- report + CLI -----------------------------------------------------------

def _representative_stage1_turn(trials, prices):
    """Pick a real sonnet turn as the Stage-1 per-turn cost proxy."""
    sonnet = [t for t in trials if t["model"] == "claude-sonnet-4-6"]
    chosen = sonnet[0] if sonnet else trials[0]
    return {"stage1": price_turn(chosen["usage"], prices[chosen["model"]]),
            "duration_ms": chosen["duration_ms"]}


def build_report(trials, params, ceiling_output=None):
    prices = params["prices"]
    per_turn = _representative_stage1_turn(trials, prices)
    br = depth_bracket(trials, params, ceiling_output)
    depths = {"low": br["floor"],
              "med": (br["floor"] + br["ceiling"]) / 2.0,
              "high": br["ceiling"]}
    secs = {"cross": 30.0,
            "opus_per_1k_output": (per_turn["duration_ms"] / 1000.0) / 3.0,
            "writer": per_turn["duration_ms"] / 1000.0}
    arms = ["old", "panel-3", "panel-5"]

    rows = []
    verdicts_by_arm = {a: set() for a in arms}
    for size_name, diff_tokens in params["diff_sizes"].items():
        for depth_name, depth_out in depths.items():
            for cache in params["cache_sharing_modes"]:
                totals = {}
                walls = {}
                for arm in arms:
                    c = compose_arm(arm, params, prices, diff_tokens, depth_out, cache, per_turn)
                    totals[arm] = c["usd"]
                    walls[arm] = wall_clock(arm, params, depth_out, secs)
                for arm in arms:
                    verdict = classify(totals[arm], walls[arm], totals["old"], walls["old"])
                    verdicts_by_arm[arm].add(verdict)
                    rows.append({
                        "diff_size": size_name, "depth": depth_name, "cache": cache,
                        "arm": arm, "usd": totals[arm], "wall_s": walls[arm],
                        "delta_usd": totals[arm] - totals["old"],
                        "delta_wall_s": walls[arm] - walls["old"],
                        "verdict": verdict,
                    })

    cross = []
    for t in trials:
        cross.append({"model": t["model"], **cross_check(t, prices[t["model"]])})

    fragile = [a for a in arms if a != "old" and len(verdicts_by_arm[a]) > 1]
    return {
        "diff_sizes": params["diff_sizes"], "depth_bracket": br,
        "rows": rows, "cross_check": cross,
        "sensitivity": {"fragile_arms": fragile,
                        "verdicts_by_arm": {a: sorted(v) for a, v in verdicts_by_arm.items()}},
    }


def _print_report(rep):
    print("Panel-review cost model — per-arm comparison\n")
    print(f"depth bracket (panel output tokens): floor={rep['depth_bracket']['floor']:.0f} "
          f"ceiling={rep['depth_bracket']['ceiling']:.0f}\n")
    hdr = f"{'diff':<8}{'depth':<6}{'cache':<12}{'arm':<9}{'USD':>10}{'dUSD':>10}{'wall_s':>9}{'verdict':>10}"
    print(hdr)
    print("-" * len(hdr))
    for r in rep["rows"]:
        print(f"{r['diff_size']:<8}{r['depth']:<6}{r['cache']:<12}{r['arm']:<9}"
              f"{r['usd']:>10.4f}{r['delta_usd']:>10.4f}{r['wall_s']:>9.1f}{r['verdict']:>10}")
    print("\ncross-check (recomputed vs recorded Bedrock cost):")
    for c in rep["cross_check"]:
        flag = "ok" if c["ok"] else "MISMATCH"
        print(f"  {c['model']:<20} rel_err={c['rel_err']:.3f} [{flag}]")
    print(f"\nfragile arms (verdict flips across brackets): {rep['sensitivity']['fragile_arms']}")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="cost_model")
    parser.add_argument("--params", required=True)
    parser.add_argument("--runs", required=True)
    parser.add_argument("--out", default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    params = json.loads(open(args.params, encoding="utf-8").read())
    trials = load_runs(args.runs)
    if not trials:
        print(f"no trials found under {args.runs}", file=sys.stderr)
        return 1
    rep = build_report(trials, params)
    if args.json:
        text = json.dumps(rep, indent=2)
        print(text)
        if args.out:
            open(args.out, "w", encoding="utf-8").write(text + "\n")
    else:
        _print_report(rep)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest tests.python.test_cost_model.ReportTest -v`
Expected: 4 tests PASS.

- [ ] **Step 5: Smoke-run the CLI on fixtures**

Run: `python3 tests/ab/lib/cost_model.py --params tests/ab/lib/cost_model_params.json --runs tests/fixtures/cost-model`
Expected: prints the comparison table, a cross-check line per model marked `[ok]`, and a fragile-arms line. (Fixture-only Stage-1 proxy makes numbers illustrative; real numbers come in Task 7.)

- [ ] **Step 6: Run the full suite and commit**

Run: `tests/run.sh` — expected green.

```bash
git add tests/ab/lib/cost_model.py tests/python/test_cost_model.py
git commit -m "$(cat <<'EOF'
feat(code-review): cost-model CLI, sweep + sensitivity report

build_report sweeps diff-size x depth-band x cache-mode, emitting per-arm
USD/wall-clock/delta/verdict, a per-model Bedrock cross-check, and a
sensitivity summary flagging arms whose verdict flips across the brackets.
main() wires params + runs into a printed table (or --json).
EOF
)"
```

---

### Task 7: Run on real data, best-effort back-test, findings write-up

**Files:**
- Create: `docs/superpowers/analysis/2026-07-08-panel-review-cost-model-findings.md`
- Modify: `tests/ab/lib/cost_model.py` (add `find_old_path_synth_turn`)
- Modify: `tests/python/test_cost_model.py`
- Modify: `README.md` (add the analysis tool to the suite's row/notes if a tooling list exists; otherwise skip — verify first)

**Interfaces:**
- Consumes: everything above; real local data in `tests/ab/runs/` and session transcripts in `~/.claude/projects/`.
- Produces:
  - `find_old_path_synth_turn(transcript_text: str) -> dict | None` — scan one transcript's JSONL for the deepest opus turn (a `result`/assistant record with `model` starting `claude-opus-4-8` and the largest `output_tokens`); return a normalised usage dict or `None` if absent. Pure over the passed text.

- [ ] **Step 1: Write the failing test for the transcript scanner**

Add to `tests/python/test_cost_model.py`:

```python
class SynthHarvestTest(unittest.TestCase):
    def test_finds_deepest_opus_turn(self):
        text = "\n".join([
            json.dumps({"type": "assistant", "message": {"model": "claude-opus-4-8"}}),
            json.dumps({"type": "result", "usage": {
                "input_tokens": 5000, "output_tokens": 8000,
                "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50},
                "modelUsage": {"claude-opus-4-8": {"costUSD": 1.0}},
                "duration_ms": 120000, "num_turns": 1}),
        ])
        turn = cost_model.find_old_path_synth_turn(text)
        self.assertIsNotNone(turn)
        self.assertEqual(turn["usage"]["output"], 8000)

    def test_returns_none_without_opus(self):
        text = json.dumps({"type": "assistant", "message": {"model": "claude-sonnet-4-6"}})
        self.assertIsNone(cost_model.find_old_path_synth_turn(text))
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest tests.python.test_cost_model.SynthHarvestTest -v`
Expected: FAIL — `AttributeError: ... 'find_old_path_synth_turn'`.

- [ ] **Step 3: Implement the scanner (reuse `parse_trial`)**

Append to `tests/ab/lib/cost_model.py`:

```python
def find_old_path_synth_turn(transcript_text):
    """Return the deepest opus turn (max output tokens) in a transcript, or
    None. Used to set the panel-depth ceiling and the old-arm back-test."""
    try:
        turn = parse_trial(transcript_text)
    except (ValueError, KeyError, json.JSONDecodeError):
        return None
    if turn["model"].startswith("claude-opus-4-8"):
        return turn
    return None
```

(Note: the plan keeps this deliberately simple — one deep synth turn per transcript. If a transcript interleaves many turns, extend `parse_trial` to iterate all `result` records and pick the max-output opus one; only do so if Step 6 finds such a transcript.)

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest tests.python.test_cost_model.SynthHarvestTest -v`
Expected: 2 tests PASS.

- [ ] **Step 5: Run the model on the REAL harness data**

Run: `python3 tests/ab/lib/cost_model.py --params tests/ab/lib/cost_model_params.json --runs tests/ab/runs --json --out /tmp/claude-<session>/cost-report.json`
(substitute the real `CLAUDE_TEMP_DIR`). Expected: exit 0, a JSON report over the ~80 real trials (opus reuse + sonnet housekeeper). Note the per-model cross-check `rel_err` values — these are the headline self-validation result.

- [ ] **Step 6: Best-effort back-test — locate a real old-path run**

Search `~/.claude/projects/` for a session transcript containing a `review-gh-pr` end-to-end run with a deep opus synth turn. Use Grep for `claude-opus-4-8` in `*.jsonl` under likely project dirs, then feed the file text through `find_old_path_synth_turn`. If found: record the synth turn's `output_tokens` (the real depth **ceiling**) and re-run Step 5 passing it as `ceiling_output` (add a `--ceiling-output N` arg if convenient, or invoke `build_report` directly in a scratch script). If **not found**: this is the documented non-fatal precondition miss — the ceiling stays at the fallback multiple, and the missing whole-arm back-test is the primary residual risk. Either way, write the outcome into the findings.

- [ ] **Step 7: Write the findings document**

Create `docs/superpowers/analysis/2026-07-08-panel-review-cost-model-findings.md`. Fill every bracketed value from the Step 5/6 real output — no placeholders in the committed doc:

```markdown
# Panel-review cost model — findings

**Date:** 2026-07-08
**Inputs:** `tests/ab/lib/cost_model.py` over `tests/ab/runs/**` (N=<count> real
trials: <opus-count> opus reuse, <sonnet-count> sonnet housekeeper), params
`tests/ab/lib/cost_model_params.json` (Bedrock rates from the claude-api skill).
**Spec:** `docs/superpowers/specs/2026-07-08-panel-review-cost-model-design.md`.

## Self-validation (must pass before trusting the model)

| Model | recomputed vs recorded | rel_err | verdict |
|---|---|---|---|
| claude-opus-4-8 | <$x> vs <$y> | <e>% | <ok/mismatch + note on 1M premium if any> |
| claude-sonnet-4-6 | <$x> vs <$y> | <e>% | <ok/mismatch> |

Back-test (old-arm whole-run): <reproduced within X% of a real run at
`<transcript path>`  /  UNAVAILABLE — no old-path transcript found; residual
risk noted below>.

## Per-arm comparison (delta vs old)

<paste the table for the median diff size; note how it shifts small->large>

## Sensitivity

- Depth bracket used: floor=<f> (on-disk opus), ceiling=<c> (<harvested synth / fallback multiple>).
- Cache sharing: <how much the shared-warm vs no-share bracket moves the panel input cost>.
- Fragile arms (verdict flips across brackets): <list or "none">.

## Kill / survive

- `panel-3`: <KILL/SURVIVE> — <one-line reason>.
- `panel-5`: <KILL/SURVIVE> — <one-line reason>.

## Recommendation & residual risk

<Does >=1 panel arm survive? What must the later A/B measure to resolve depth
for real? State the back-test/precondition risk explicitly.>
```

- [ ] **Step 8: Update README if the suite lists tooling**

Read `plugins/code-review-suite/README.md`. If it has an analysis/tooling section, add a one-line entry for `tests/ab/lib/cost_model.py`. If it does not, skip (do not invent a section). Verify before editing.

- [ ] **Step 9: Run the full suite and commit**

Run: `tests/run.sh` — expected green.

```bash
git add tests/ab/lib/cost_model.py tests/python/test_cost_model.py docs/superpowers/analysis/2026-07-08-panel-review-cost-model-findings.md
git commit -m "$(cat <<'EOF'
feat(code-review): cost-model findings + best-effort old-path back-test

find_old_path_synth_turn harvests the deep opus synth turn from a session
transcript (panel-depth ceiling + old-arm back-test). Findings write-up
reports the real-data per-arm comparison, the Bedrock self-validation, the
sensitivity brackets, and the kill/survive call.
EOF
)"
```

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:

| Spec requirement | Task |
|---|---|
| Reads harness `stream.jsonl` usage | 2 |
| Externalised parameter block (no inlined constants) | 1 (schema), 3 (real prices) |
| Empirically-grounded opus + sonnet price; engine cross-check on both | 3 |
| ARN → model resolution from record fields (scanner-safe) | 2 (plain `message.model`) |
| Diff-size **sweep** (small/median/large) | 4 (compose), 6 (sweep loop) |
| Panel depth **bracket** (floor on-disk opus, ceiling synth) | 4 (`depth_bracket`), 7 (real ceiling) |
| Cross-panelist cache-sharing bracket | 4 (`panel_input_cost`) |
| Concern-brief as a ×N opus-input line item | 4 (`compose_arm` prefix += `concern_brief_tokens`) |
| Probabilistic resample (P(gate) / bracket) | 1 (param), 4 (composed into `old` + test) |
| Wall-clock structural model | 5 |
| KILL / SURVIVE decision semantics (never "go") | 5 (`classify`), Global Constraints |
| Sensitivity table (verdict flips across brackets) | 6 (`sensitivity`) |
| Back-test the `old` arm (best-effort, non-fatal precondition) | 7 |
| Two deliverables: script + findings write-up | 1–6 (script), 7 (findings) |

**Gap found & resolved inline:** the `resample` parameter was defined (Task 1) with no task *composing* it into the `old` arm total. Fixed directly in Task 4 — `compose_arm`'s `old` branch now adds `p_gate_fires * (stage1 + cross + synth)`, with `test_old_arm_includes_probabilistic_resample` in Task 4 Step 1. No interface change (`compose_arm` already receives `params`).

**2. Placeholder scan** — the only bracketed `<...>` values are in the Task 7 findings **template**, which is explicitly filled from real Step 5/6 output before committing (Task 7 Step 7 states "no placeholders in the committed doc"). The Task 1 params prices are labelled illustrative and are **replaced with validated real rates in Task 3** (cross-check gates them). No other placeholders.

**3. Type consistency** — checked across tasks:
- `parse_trial` returns `usage` with keys `input/output/cache_read/cache_creation`; `price_turn`, `cross_check`, `compose_arm`, `depth_bracket` all consume exactly those keys. ✓
- `price_row` keys `input/output/cache_read/cache_creation` consistent in params, `price_turn`, `panel_input_cost`. ✓
- `compose_arm` returns `{"usd", "stage1_usd", "middle_usd"}`; `build_report` reads `["usd"]`. ✓
- `wall_clock` / `classify` signatures match their call sites in `build_report`. ✓
- Arm names `"old"/"panel-3"/"panel-5"` consistent throughout. ✓
- `per_turn_costs["stage1"]["total"]` produced by `price_turn` (has `total`) and consumed in `compose_arm`. ✓

`build_report` sets `walls[arm] = wall_clock(arm, params, depth_out, secs)` directly (an earlier drafting no-op prefix was removed in Task 6 Step 3).
