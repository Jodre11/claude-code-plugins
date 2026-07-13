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


def _write_trial_harvested(arm_dir, n, verdict, tiers):
    """Write a trial in the real HARVESTED schema: verdict.txt (authoritative, written by
    orchestration_harvest_journal) + durable-log.jsonl carrying the synthesiser Workflow
    result record. `tiers` maps a tier name (consensus/synthesiser/contested/dismissed) to
    its raw finding dicts (file/line/severity/confidence/description/suggested_fix — no tier
    or domain field, exactly as the live journal emits)."""
    td = arm_dir / f"trial-{n:03d}"
    td.mkdir(parents=True)
    (td / "verdict.txt").write_text(verdict + "\n", encoding="utf-8")
    lines = [
        json.dumps({"type": "result", "result": {"findings": [], "status": "ok"}}),
        json.dumps({"type": "result", "result": {
            "verdict": verdict,
            "rubricRowApplied": 3,
            "rubricReason": "whatever",
            "bodyText": "## Report\n",
            "tiers": {**{k: [] for k in ("consensus", "synthesiser", "contested", "dismissed")}, **tiers},
        }}),
    ]
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


class HarvestedSchemaTest(unittest.TestCase):
    """load_arm must read the live harvested schema: verdict from verdict.txt and findings
    from the synthesiser Workflow result record's tiers.*, NOT the obsolete
    type:finding / type:meta records (which the current harvest no longer emits)."""

    def _raw(self, file="a.cs", line=10, sev="Important", conf=72):
        return {"file": file, "line": line, "severity": sev, "confidence": conf,
                "description": "d", "suggested_fix": "f"}

    def test_verdict_read_from_verdict_txt(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            _write_trial_harvested(arm, 1, "REQUEST_CHANGES", {"consensus": [self._raw()]})
            runs = differential.load_arm(arm)
            self.assertEqual(runs[0]["verdict"], "REQUEST_CHANGES")

    def test_findings_extracted_from_all_tiers(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            _write_trial_harvested(arm, 1, "REQUEST_CHANGES", {
                "consensus": [self._raw(file="a.cs", line=10)],
                "synthesiser": [self._raw(file="b.cs", line=20)],
            })
            runs = differential.load_arm(arm)
            self.assertEqual(len(runs[0]["findings"]), 2)

    def test_tier_synthesised_from_tier_list_name(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            _write_trial_harvested(arm, 1, "REQUEST_CHANGES", {
                "consensus": [self._raw(file="a.cs", line=10)],
                "dismissed": [self._raw(file="b.cs", line=20)],
            })
            runs = differential.load_arm(arm)
            tiers = {f["tier"] for f in runs[0]["findings"]}
            self.assertEqual(tiers, {"consensus", "dismissed"})

    def test_high_value_survives_extraction(self):
        # A consensus finding is high-value regardless of confidence — proves the tier
        # tag is wired through to high_value().
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            _write_trial_harvested(arm, 1, "REQUEST_CHANGES",
                                   {"consensus": [self._raw(conf=10)]})
            runs = differential.load_arm(arm)
            self.assertTrue(differential.high_value(runs[0]["findings"][0]))

    def test_positional_match_on_extracted_findings(self):
        # Findings carry no domain field; extraction defaults it uniformly so
        # findings_match degrades to file + line-proximity (the honest positional match).
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            _write_trial_harvested(arm, 1, "REQUEST_CHANGES",
                                   {"consensus": [self._raw(file="a.cs", line=10)]})
            _write_trial_harvested(arm, 2, "REQUEST_CHANGES",
                                   {"consensus": [self._raw(file="a.cs", line=12)]})
            runs = differential.load_arm(arm)
            self.assertTrue(differential.findings_match(
                runs[0]["findings"][0], runs[1]["findings"][0]))


def _write_trial_panel(arm_dir, n, verdict, panelist_raised):
    """Write a trial in the PANEL harvested schema. Unlike classic, panel computes the
    verdict + tiers in JS (applyRubric / mapSpreadToTierConfidence) and never journals
    them. What IS journaled: a Stage-1 specialist result ({findings,status}), one
    {votes,raised} result PER panelist, and a final writer result carrying ONLY bodyText
    (no verdict, no tiers). `panelist_raised` is a list of per-panelist raised[] lists
    (each finding: file/line/severity/confidence/description/suggested_fix — no tier,
    no domain, exactly as PANEL_SCHEMA's FINDING_SHAPE emits)."""
    td = arm_dir / f"trial-{n:03d}"
    td.mkdir(parents=True)
    (td / "verdict.txt").write_text(verdict + "\n", encoding="utf-8")
    lines = [json.dumps({"type": "result", "result": {"findings": [], "status": "ok"}})]
    for raised in panelist_raised:
        lines.append(json.dumps({"type": "result", "result": {"votes": [], "raised": raised}}))
    lines.append(json.dumps({"type": "result", "result": {"bodyText": "## Verdict: " + verdict + "\n"}}))
    (td / "durable-log.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return td


class PanelSchemaTest(unittest.TestCase):
    """load_arm must also read the PANEL harvested schema: the writer's bodyText record
    carries no tiers, so findings come from the panelists' raised[] records instead.
    The classic tiers path must keep working unchanged (branch on which keys present)."""

    def _raw(self, file="a.cs", line=10, sev="Important", conf=72):
        return {"file": file, "line": line, "severity": sev, "confidence": conf,
                "description": "d", "suggested_fix": "f"}

    def test_panel_findings_read_from_raised(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "panel"
            _write_trial_panel(arm, 1, "REQUEST_CHANGES",
                               [[self._raw(file="a.cs", line=10)]])
            runs = differential.load_arm(arm)
            self.assertEqual(len(runs[0]["findings"]), 1)
            self.assertEqual(runs[0]["findings"][0]["file"], "a.cs")

    def test_panel_raised_aggregated_across_panelists(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "panel"
            _write_trial_panel(arm, 1, "REQUEST_CHANGES", [
                [self._raw(file="a.cs", line=10)],
                [self._raw(file="b.cs", line=20)],
            ])
            runs = differential.load_arm(arm)
            files = sorted(f["file"] for f in runs[0]["findings"])
            self.assertEqual(files, ["a.cs", "b.cs"])

    def test_panel_raised_finding_carries_uniform_domain_for_positional_match(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "panel"
            _write_trial_panel(arm, 1, "REQUEST_CHANGES",
                               [[self._raw(file="a.cs", line=10)]])
            _write_trial_panel(arm, 2, "REQUEST_CHANGES",
                               [[self._raw(file="a.cs", line=12)]])
            runs = differential.load_arm(arm)
            self.assertTrue(differential.findings_match(
                runs[0]["findings"][0], runs[1]["findings"][0]))

    def test_panel_high_confidence_raised_is_high_value(self):
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "panel"
            _write_trial_panel(arm, 1, "REQUEST_CHANGES",
                               [[self._raw(conf=90)]])
            runs = differential.load_arm(arm)
            self.assertTrue(differential.high_value(runs[0]["findings"][0]))

    def test_classic_tiers_path_unaffected_by_panel_branch(self):
        # Regression: a classic trial (synth record WITH tiers) must still read from
        # tiers, never from raised — the panel branch must not steal it.
        with tempfile.TemporaryDirectory() as d:
            arm = pathlib.Path(d) / "classic"
            _write_trial_harvested(arm, 1, "REQUEST_CHANGES",
                                   {"consensus": [self._raw(file="c.cs", line=30)]})
            runs = differential.load_arm(arm)
            self.assertEqual(len(runs[0]["findings"]), 1)
            self.assertEqual(runs[0]["findings"][0]["tier"], "consensus")


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
