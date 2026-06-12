import importlib.machinery
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
ENGINE = REPO / "plugins/code-review-suite/bin/housekeeper-freshness"


def load_engine():
    loader = importlib.machinery.SourceFileLoader("housekeeper_freshness", str(ENGINE))
    spec = importlib.util.spec_from_loader("housekeeper_freshness", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class ChassisTest(unittest.TestCase):
    def test_empty_inputs_emit_empty_array(self):
        with tempfile.TemporaryDirectory() as d:
            files = pathlib.Path(d) / "files.txt"
            lines = pathlib.Path(d) / "lines.txt"
            files.write_text("")
            lines.write_text("Changed lines:\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE),
                 "--root", d,
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines)],
                capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(out.stdout), [])


class VersionCoreTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_parse_version_strips_v_prefix(self):
        self.assertEqual(self.m.parse_version("v4.2.1"), (4, 2, 1, 0))
        self.assertEqual(self.m.parse_version("4.2.1"), (4, 2, 1, 0))
        self.assertEqual(self.m.parse_version("v4"), (4, 0, 0, 0))
        self.assertEqual(self.m.parse_version("4.2"), (4, 2, 0, 0))

    def test_parse_version_drops_prerelease_and_build(self):
        self.assertEqual(self.m.parse_version("1.2.3-rc.1"), (1, 2, 3, 0))
        self.assertEqual(self.m.parse_version("1.2.3+build.5"), (1, 2, 3, 0))

    def test_parse_version_four_part_nuget(self):
        # NuGet 4-part versions; revision defaults to 0 for shorter inputs.
        self.assertEqual(self.m.parse_version("1.2.3.4"), (1, 2, 3, 4))
        self.assertEqual(self.m.parse_version("13.0.3.0"), (13, 0, 3, 0))
        # Backward-compat: 3-part inputs compare identically to slice 1.
        self.assertEqual(self.m.parse_version("18.2.0"), (18, 2, 0, 0))

    def test_four_part_comparison_orders_revision(self):
        self.assertEqual(self.m.compare_versions("1.2.3.4", "1.2.3.5"), -1)
        self.assertEqual(self.m.compare_versions("1.2.3.4", "1.2.3.4"), 0)
        self.assertEqual(self.m.compare_versions("1.2.4.0", "1.2.3.9"), 1)
        # A 3-part version equals its 4-part .0 form (revision defaults to 0).
        self.assertEqual(self.m.compare_versions("1.2.3", "1.2.3.0"), 0)

    def test_parse_version_invalid_returns_none(self):
        self.assertIsNone(self.m.parse_version("latest"))
        self.assertIsNone(self.m.parse_version(""))

    def test_compare_versions_orders_numerically_not_lexically(self):
        # 1.10.0 > 1.9.0 is the classic lexical trap.
        self.assertEqual(self.m.compare_versions("1.10.0", "1.9.0"), 1)
        self.assertEqual(self.m.compare_versions("1.9.0", "1.10.0"), -1)
        self.assertEqual(self.m.compare_versions("4.2.1", "4.2.1"), 0)

    def test_is_ga_rejects_prerelease(self):
        self.assertTrue(self.m.is_ga("1.2.3"))
        self.assertTrue(self.m.is_ga("v4"))
        self.assertFalse(self.m.is_ga("1.2.3-rc.1"))
        self.assertFalse(self.m.is_ga("2.0.0-beta"))
        self.assertFalse(self.m.is_ga("1.0.0-0"))

    def test_latest_ga_picks_highest_non_prerelease(self):
        versions = ["1.0.0", "1.2.0", "2.0.0-rc.1", "1.9.0", "1.10.0"]
        self.assertEqual(self.m.latest_ga(versions), "1.10.0")

    def test_nearest_in_major_within_current_major(self):
        versions = ["17.0.0", "18.1.0", "18.2.0", "18.3.1", "19.0.0"]
        self.assertEqual(self.m.nearest_in_major("18.0.0", versions), "18.3.1")
        # No higher in-major version -> returns the current.
        self.assertEqual(self.m.nearest_in_major("19.0.0", versions), "19.0.0")

    def test_strip_constraint_extracts_pinned_version(self):
        self.assertEqual(self.m.strip_constraint("^18.2.0"), "18.2.0")
        self.assertEqual(self.m.strip_constraint("~1.4.3"), "1.4.3")
        self.assertEqual(self.m.strip_constraint(">=2.0.0"), "2.0.0")
        self.assertEqual(self.m.strip_constraint("18.2.0"), "18.2.0")
        self.assertIsNone(self.m.strip_constraint("*"))
        self.assertIsNone(self.m.strip_constraint("latest"))
        self.assertIsNone(self.m.strip_constraint("github:foo/bar"))


# A registration index with an inlined page (no external @id fetch needed).
REG_INLINE = {
    "count": 1,
    "items": [
        {
            "@id": "https://example/page1",
            "count": 2,
            "items": [
                {"catalogEntry": {"version": "1.0.0", "licenseExpression": "MIT",
                                  "listed": True}},
                {"catalogEntry": {"version": "2.0.0", "licenseExpression": "Apache-2.0",
                                  "listed": True,
                                  "deprecation": {"message": "Use Foo.Bar instead",
                                                  "reasons": ["Legacy"]}}},
            ],
        }
    ],
}

# A registration index with an EXTERNAL page (no inline "items" -> needs a
# follow-up fetch to the page @id).
REG_EXTERNAL_INDEX = {
    "count": 1,
    "items": [{"@id": "https://example/pageA", "count": 1}],
}
REG_EXTERNAL_PAGE = {
    "items": [
        {"catalogEntry": {"version": "3.1.4", "licenseExpression": "MIT",
                          "listed": False}},
    ],
}


class RegistrationTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_registration_inline_page_extracts_per_version_map(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg._get_json = lambda url: REG_INLINE
        out = reg.registration("Foo.Bar")
        self.assertEqual(out["1.0.0"]["licence"], "MIT")
        self.assertEqual(out["2.0.0"]["licence"], "Apache-2.0")
        self.assertEqual(out["2.0.0"]["deprecation"]["message"], "Use Foo.Bar instead")
        self.assertTrue(out["1.0.0"]["listed"])

    def test_registration_external_page_is_fetched(self):
        reg = self.m.Registry(fixtures_dir=None)
        calls = []

        def fake_get(url):
            calls.append(url)
            return REG_EXTERNAL_INDEX if url.endswith("index.json") else REG_EXTERNAL_PAGE

        reg._get_json = fake_get
        out = reg.registration("Some.Pkg")
        # The index URL plus the external page @id were both fetched.
        self.assertEqual(len(calls), 2)
        self.assertIn("https://example/pageA", calls)
        self.assertEqual(out["3.1.4"]["licence"], "MIT")
        self.assertFalse(out["3.1.4"]["listed"])

    def test_registration_miss_returns_none(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg._get_json = lambda url: None
        self.assertIsNone(reg.registration("Nope"))

    def test_registration_fixture_override_reads_decompressed_json(self):
        with tempfile.TemporaryDirectory() as d:
            regdir = pathlib.Path(d) / "nuget-registration"
            regdir.mkdir()
            (regdir / "foo.bar.json").write_text(json.dumps(REG_INLINE))
            reg = self.m.Registry(fixtures_dir=d)
            out = reg.registration("Foo.Bar")  # slug lowercases the name
            self.assertEqual(out["2.0.0"]["licence"], "Apache-2.0")
            self.assertEqual(out["2.0.0"]["deprecation"]["reasons"], ["Legacy"])


class GitHubActionsTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_find_action_uses_extracts_tag_pins(self):
        text = (
            "jobs:\n"
            "  build:\n"
            "    steps:\n"
            "      - uses: actions/checkout@v3\n"
            "      - uses: actions/setup-node@v4.0.1\n"
        )
        uses = self.m.find_action_uses(text)
        self.assertIn(("actions/checkout", "v3", 4), uses)
        self.assertIn(("actions/setup-node", "v4.0.1", 5), uses)

    def test_find_action_uses_reads_sha_pin_version_comment(self):
        text = "      - uses: actions/checkout@abc123def  # v3.6.0\n"
        uses = self.m.find_action_uses(text)
        self.assertEqual(uses, [("actions/checkout", "v3.6.0", 1)])

    def test_find_action_uses_skips_sha_pin_without_comment(self):
        text = "      - uses: actions/checkout@abc123def456\n"
        # No trustworthy current version -> not collected.
        self.assertEqual(self.m.find_action_uses(text), [])

    def test_find_action_uses_skips_local_and_docker(self):
        text = (
            "      - uses: ./.github/actions/local\n"
            "      - uses: docker://alpine:3.18\n"
        )
        self.assertEqual(self.m.find_action_uses(text), [])

    def test_actions_finding_flags_stale_major(self):
        # checkout@v3, latest release tag_name v4.2.1 -> stale, target v4.
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: {"tag_name": "v4.2.1"}
        findings = self.m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: actions/checkout@v3\n"},
            {".github/workflows/ci.yml": {1}},
            reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["source"], "github-actions")
        self.assertEqual(f["item"], "actions/checkout")
        self.assertEqual(f["current"], "v3")
        self.assertEqual(f["latest_ga"], "v4.2.1")
        self.assertEqual(f["target"], "v4")

    def test_actions_finding_silent_when_current(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: {"tag_name": "v3.6.0"}
        findings = self.m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: actions/checkout@v3\n"},
            {".github/workflows/ci.yml": {1}},
            reg)
        self.assertEqual(findings, [])

    def test_find_action_uses_keeps_tag_pin_with_freetext_comment(self):
        text = "      - uses: actions/checkout@v3 # node setup\n"
        uses = self.m.find_action_uses(text)
        self.assertIn(("actions/checkout", "v3", 1), uses)

    def test_actions_nested_action_uses_owner_repo_for_api(self):
        reg = self.m.Registry(fixtures_dir=None)
        calls = []
        def rec(source, item, url):
            calls.append(url)
            return {"tag_name": "v3.0.0"}
        reg.fetch = rec
        findings = self.m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: github/codeql-action/analyze@v2\n"},
            {".github/workflows/ci.yml": {1}},
            reg)
        self.assertEqual(calls, ["https://api.github.com/repos/github/codeql-action/releases/latest"])
        self.assertEqual(findings[0]["item"], "github/codeql-action/analyze")
        self.assertEqual(findings[0]["target"], "v3")

    def test_actions_finding_silent_on_fetch_miss(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: None
        findings = self.m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: actions/checkout@v3\n"},
            {".github/workflows/ci.yml": {1}},
            reg)
        self.assertEqual(findings, [])


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_find_runner_labels(self):
        text = (
            "jobs:\n"
            "  a:\n"
            "    runs-on: ubuntu-22.04\n"
            "  b:\n"
            "    runs-on: windows-2022\n"
        )
        labels = self.m.find_runner_labels(text)
        self.assertIn(("ubuntu", "22.04", 3), labels)
        self.assertIn(("windows", "2022", 5), labels)

    def test_runner_flags_stale_known_family(self):
        findings = self.m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "    runs-on: ubuntu-22.04\n"},
            {".github/workflows/ci.yml": {1}})
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["source"], "runner")
        self.assertEqual(f["item"], "ubuntu")
        self.assertEqual(f["current"], "ubuntu-22.04")
        self.assertEqual(f["latest_ga"], "ubuntu-24.04")

    def test_runner_silent_when_latest(self):
        findings = self.m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "    runs-on: ubuntu-24.04\n"},
            {".github/workflows/ci.yml": {1}})
        self.assertEqual(findings, [])

    def test_runner_flags_label_with_trailing_comment_and_quotes(self):
        text = (
            "    runs-on: ubuntu-22.04 # pinned, see RUNNER.md\n"
            "    runs-on: 'windows-2022'\n"
        )
        findings = self.m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": text},
            {".github/workflows/ci.yml": {1, 2}})
        items = sorted((f["item"], f["current"], f["latest_ga"]) for f in findings)
        self.assertEqual(items, [
            ("ubuntu", "ubuntu-22.04", "ubuntu-24.04"),
            ("windows", "windows-2022", "windows-2025"),
        ])

    def test_runner_skips_unknown_and_latest_labels(self):
        text = (
            "    runs-on: ubuntu-latest\n"
            "    runs-on: self-hosted\n"
            "    runs-on: my-custom-runner\n"
        )
        findings = self.m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": text},
            {".github/workflows/ci.yml": {1, 2, 3}})
        self.assertEqual(findings, [])


class NuGetParseTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_strip_constraint_concrete_three_and_four_part(self):
        self.assertEqual(self.m.nuget_strip_constraint("1.2.3"), "1.2.3")
        self.assertEqual(self.m.nuget_strip_constraint("1.2.3.4"), "1.2.3.4")
        self.assertEqual(self.m.nuget_strip_constraint("13.0.3"), "13.0.3")

    def test_strip_constraint_rejects_untrustworthy_forms(self):
        self.assertIsNone(self.m.nuget_strip_constraint("$(SerilogVersion)"))
        self.assertIsNone(self.m.nuget_strip_constraint("[1.0,2.0)"))
        self.assertIsNone(self.m.nuget_strip_constraint("(,2.0]"))
        self.assertIsNone(self.m.nuget_strip_constraint("1.*"))
        self.assertIsNone(self.m.nuget_strip_constraint("1.2.*"))
        self.assertIsNone(self.m.nuget_strip_constraint(""))

    def test_parse_csproj_inline_version(self):
        text = (
            '<Project Sdk="Microsoft.NET.Sdk">\n'
            '  <ItemGroup>\n'
            '    <PackageReference Include="Serilog" Version="2.10.0" />\n'
            '  </ItemGroup>\n'
            '</Project>\n'
        )
        refs = self.m.parse_csproj(text)
        self.assertEqual(refs["Serilog"], ("2.10.0", 3))

    def test_parse_csproj_version_override_wins(self):
        text = (
            '    <PackageReference Include="Newtonsoft.Json" VersionOverride="12.0.1" />\n'
        )
        refs = self.m.parse_csproj(text)
        self.assertEqual(refs["Newtonsoft.Json"], ("12.0.1", 1))

    def test_parse_csproj_versionless_records_none_for_cpm(self):
        text = (
            '    <PackageReference Include="Serilog" />\n'
        )
        refs = self.m.parse_csproj(text)
        self.assertEqual(refs["Serilog"], (None, 1))

    def test_parse_csproj_child_element_version(self):
        text = (
            '    <PackageReference Include="AutoMapper">\n'
            '      <Version>11.0.1</Version>\n'
            '    </PackageReference>\n'
        )
        refs = self.m.parse_csproj(text)
        # The acted-on line is the <Version> literal, not the opening tag.
        self.assertEqual(refs["AutoMapper"], ("11.0.1", 2))

    def test_parse_csproj_multiline_ref_closing_without_version_is_versionless(self):
        # A multi-line PackageReference that closes without a <Version> child
        # is version-less (CPM-resolved); the recorded line is the opening tag.
        text = (
            '    <PackageReference Include="Serilog">\n'
            '      <PrivateAssets>all</PrivateAssets>\n'
            '    </PackageReference>\n'
        )
        refs = self.m.parse_csproj(text)
        self.assertEqual(refs["Serilog"], (None, 1))

    def test_parse_csproj_trailing_pending_ref_flushes_as_versionless(self):
        # A PackageReference whose opening tag is the last line (no close, no
        # child <Version>) is flushed at EOF as version-less.
        text = '    <PackageReference Include="AutoMapper">\n'
        refs = self.m.parse_csproj(text)
        self.assertEqual(refs["AutoMapper"], (None, 1))

    def test_parse_packages_props_central_and_global(self):
        text = (
            '<Project>\n'
            '  <ItemGroup>\n'
            '    <PackageVersion Include="Serilog" Version="3.1.1" />\n'
            '    <PackageReference Include="Microsoft.SourceLink.GitHub" Version="1.1.1" />\n'
            '  </ItemGroup>\n'
            '</Project>\n'
        )
        central, glob = self.m.parse_packages_props(text)
        self.assertEqual(central["Serilog"], ("3.1.1", 3))
        self.assertEqual(glob["Microsoft.SourceLink.GitHub"], ("1.1.1", 4))


class NuGetScopeTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_nearest_ancestor_csproj_is_the_gate(self):
        changed = ["src/Api/Controllers/Home.cs"]
        csprojs = {"src/Api/Api.csproj", "src/Worker/Worker.csproj"}
        props = set()
        in_csproj, in_props = self.m.nuget_scope_roots(changed, csprojs, props)
        self.assertEqual(in_csproj, {"src/Api/Api.csproj"})
        self.assertEqual(in_props, set())

    def test_non_csharp_file_does_not_pull_in_csproj(self):
        changed = ["src/Api/notes.txt"]
        csprojs = {"src/Api/Api.csproj"}
        in_csproj, _ = self.m.nuget_scope_roots(changed, csprojs, set())
        self.assertEqual(in_csproj, set())

    def test_changed_csproj_is_its_own_scope(self):
        changed = ["src/Api/Api.csproj"]
        csprojs = {"src/Api/Api.csproj"}
        in_csproj, _ = self.m.nuget_scope_roots(changed, csprojs, set())
        self.assertEqual(in_csproj, {"src/Api/Api.csproj"})

    def test_governing_props_walk_up(self):
        # A root Directory.Packages.props and a src-level Directory.Build.props
        # both govern an in-scope csproj deeper in the tree.
        changed = ["src/Api/Controllers/Home.cs"]
        csprojs = {"src/Api/Api.csproj"}
        props = {"Directory.Packages.props", "src/Directory.Build.props",
                 "other/Unrelated.props"}
        in_csproj, in_props = self.m.nuget_scope_roots(changed, csprojs, props)
        self.assertEqual(in_csproj, {"src/Api/Api.csproj"})
        self.assertEqual(in_props, {"Directory.Packages.props", "src/Directory.Build.props"})

    def test_sibling_subtree_props_not_in_scope(self):
        changed = ["src/Api/Home.cs"]
        csprojs = {"src/Api/Api.csproj"}
        props = {"src/Worker/Worker.props"}
        _, in_props = self.m.nuget_scope_roots(changed, csprojs, props)
        self.assertEqual(in_props, set())

    def test_prefix_collision_does_not_cross_sibling_dirs(self):
        # src/Api must NOT be treated as an ancestor of src/ApiTests (the
        # '+ "/"' guard in _dir_is_ancestor_or_same). A changed file under
        # src/ApiTests resolves to ApiTests.csproj, never Api.csproj.
        changed = ["src/ApiTests/UnitTest.cs"]
        csprojs = {"src/Api/Api.csproj", "src/ApiTests/ApiTests.csproj"}
        in_csproj, _ = self.m.nuget_scope_roots(changed, csprojs, set())
        self.assertEqual(in_csproj, {"src/ApiTests/ApiTests.csproj"})


NUGET_FLAT = {"versions": ["2.10.0", "3.0.0", "3.1.1", "4.0.0"]}


def _reg_map(**versions):
    # Helper: build a registration map; each kwarg is version="MIT" or a dict.
    out = {}
    for v, meta in versions.items():
        v = v.replace("_", ".")
        out[v] = meta if isinstance(meta, dict) else {"licence": meta, "deprecation": None, "listed": True}
    return out


class NuGetCollectTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def _reg(self, flat, registration):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda source, item, url: flat
        reg.registration = lambda item: registration
        return reg

    def test_inline_version_stale_touched_targets_latest(self):
        reg = self._reg(NUGET_FLAT, _reg_map(**{"2_10_0": "MIT", "4_0_0": "MIT"}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["source"], "nuget")
        self.assertEqual(f["item"], "Serilog")
        self.assertEqual(f["current"], "2.10.0")
        self.assertEqual(f["latest_ga"], "4.0.0")
        self.assertEqual(f["target"], "4.0.0")
        self.assertEqual(f["file"], "Api.csproj")
        self.assertEqual(f["line"], 1)
        self.assertIsNone(f["health"])

    def test_untouched_line_targets_nearest_in_major(self):
        reg = self._reg(NUGET_FLAT, _reg_map(**{"3_0_0": "MIT", "3_1_1": "MIT"}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="3.0.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": set()}, reg)
        self.assertEqual(findings[0]["target"], "3.1.1")  # nearest in major 3

    def test_cpm_resolution_points_file_line_at_props(self):
        reg = self._reg(NUGET_FLAT, _reg_map(**{"3_1_1": "MIT", "4_0_0": "MIT"}))
        csproj = {"src/Api/Api.csproj": '    <PackageReference Include="Serilog" />\n'}
        props = {"Directory.Packages.props":
                 '    <PackageVersion Include="Serilog" Version="3.1.1" />\n'}
        findings = self.m.collect_nuget(csproj, props, {"Directory.Packages.props": {1}}, reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["current"], "3.1.1")
        self.assertEqual(f["file"], "Directory.Packages.props")  # literal lives in props
        self.assertEqual(f["line"], 1)
        self.assertEqual(f["target"], "4.0.0")

    def test_version_override_wins_over_cpm(self):
        reg = self._reg(NUGET_FLAT, _reg_map(**{"3_0_0": "MIT", "4_0_0": "MIT"}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" VersionOverride="3.0.0" />\n'}
        props = {"Directory.Packages.props":
                 '    <PackageVersion Include="Serilog" Version="3.1.1" />\n'}
        findings = self.m.collect_nuget(csproj, props, {"Api.csproj": {1}}, reg)
        self.assertEqual(findings[0]["current"], "3.0.0")
        self.assertEqual(findings[0]["file"], "Api.csproj")  # override literal in csproj

    def test_property_ref_and_range_yield_no_finding(self):
        reg = self._reg(NUGET_FLAT, None)
        csproj = {"Api.csproj":
                  '    <PackageReference Include="A" Version="$(AVersion)" />\n'
                  '    <PackageReference Include="B" Version="[1.0,2.0)" />\n'}
        self.assertEqual(self.m.collect_nuget(csproj, {}, {"Api.csproj": {1, 2}}, reg), [])

    def test_versionless_with_no_cpm_match_is_skipped(self):
        reg = self._reg(NUGET_FLAT, None)
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" />\n'}
        self.assertEqual(self.m.collect_nuget(csproj, {}, {"Api.csproj": set()}, reg), [])

    def test_flat_container_miss_suppresses(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: None
        reg.registration = lambda item: None
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        self.assertEqual(self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg), [])

    def test_registration_miss_keeps_freshness_finding_with_null_metadata(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NUGET_FLAT
        reg.registration = lambda item: None
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(len(findings), 1)
        self.assertIsNone(findings[0]["licence_current"])
        self.assertIsNone(findings[0]["health"])

    def test_licence_diff_against_target(self):
        reg = self._reg(
            NUGET_FLAT,
            _reg_map(**{"2_10_0": {"licence": "MIT", "deprecation": None, "listed": True},
                        "4_0_0": {"licence": "BSL-1.1", "deprecation": None, "listed": True}}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(findings[0]["licence_current"], "MIT")
        self.assertEqual(findings[0]["licence_latest"], "BSL-1.1")

    def test_deprecated_but_current_emits_pure_health(self):
        # Package is at the latest GA but the registry marks it deprecated.
        flat = {"versions": ["4.0.0"]}
        reg = self._reg(
            flat,
            _reg_map(**{"4_0_0": {"licence": "MIT", "listed": True,
                                  "deprecation": {"message": "Use Foo.Bar instead",
                                                  "reasons": ["Legacy"]}}}))
        csproj = {"Api.csproj": '    <PackageReference Include="Foo" Version="4.0.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["current"], "4.0.0")
        self.assertEqual(f["target"], "4.0.0")  # nothing newer; pure-health
        self.assertEqual(f["health"], {"state": "deprecated", "detail": "Use Foo.Bar instead"})

    def test_unlisted_current_emits_pure_health(self):
        flat = {"versions": ["4.0.0"]}
        reg = self._reg(flat, _reg_map(**{"4_0_0": {"licence": "MIT", "listed": False,
                                                    "deprecation": None}}))
        csproj = {"Api.csproj": '    <PackageReference Include="Foo" Version="4.0.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": {1}}, reg)
        self.assertEqual(findings[0]["health"]["state"], "unlisted")

    def test_duplicate_cpm_resolution_dedupes(self):
        # Two csprojs both reference Serilog version-lessly -> one CPM literal,
        # one finding (deduped by file/line/item).
        reg = self._reg(NUGET_FLAT, _reg_map(**{"3_1_1": "MIT", "4_0_0": "MIT"}))
        csproj = {
            "src/A/A.csproj": '    <PackageReference Include="Serilog" />\n',
            "src/B/B.csproj": '    <PackageReference Include="Serilog" />\n',
        }
        props = {"Directory.Packages.props":
                 '    <PackageVersion Include="Serilog" Version="3.1.1" />\n'}
        findings = self.m.collect_nuget(csproj, props, {"Directory.Packages.props": {1}}, reg)
        self.assertEqual(len(findings), 1)

    def test_cpm_touched_signal_or_accumulates_across_csprojs(self):
        # Two csprojs version-lessly reference the same CPM central. Only the
        # FIRST-sorting csproj's reference line is touched. The touched signal
        # must OR-accumulate to the shared props candidate, so the finding
        # targets latest GA across a major boundary regardless of sibling order.
        flat = {"versions": ["2.10.0", "4.0.0"]}  # major 2 has nothing newer
        reg = self._reg(flat, _reg_map(**{"2_10_0": "MIT", "4_0_0": "MIT"}))
        csproj = {
            "src/A/A.csproj": '    <PackageReference Include="Serilog" />\n',
            "src/B/B.csproj": '    <PackageReference Include="Serilog" />\n',
        }
        props = {"Directory.Packages.props":
                 '    <PackageVersion Include="Serilog" Version="2.10.0" />\n'}
        # A's reference line (src/A/A.csproj:1) is touched; B's is not; the props
        # literal line is NOT touched. Under last-write-wins (B overwrites A),
        # touched would be lost and the cross-major bump suppressed.
        changed = {"src/A/A.csproj": {1}}
        findings = self.m.collect_nuget(csproj, props, changed, reg)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["current"], "2.10.0")
        self.assertEqual(findings[0]["target"], "4.0.0")  # latest GA, not suppressed

    def test_props_global_package_reference_is_a_candidate(self):
        # A global <PackageReference Version> declared in a props file (e.g.
        # Directory.Build.props) is an upgrade candidate in its own right.
        reg = self._reg(NUGET_FLAT, _reg_map(**{"2_10_0": "MIT", "4_0_0": "MIT"}))
        props = {"Directory.Build.props":
                 '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        findings = self.m.collect_nuget({}, props, {"Directory.Build.props": {1}}, reg)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["item"], "Serilog")
        self.assertEqual(findings[0]["file"], "Directory.Build.props")
        self.assertEqual(findings[0]["target"], "4.0.0")

    def test_untouched_in_major_exhausted_is_not_stale(self):
        # current 2.10.0 with nothing newer in major 2; a higher major exists.
        # Untouched line -> nearest_in_major stays at current -> not stale ->
        # no finding (and no health here).
        flat = {"versions": ["2.10.0", "4.0.0"]}
        reg = self._reg(flat, _reg_map(**{"2_10_0": "MIT"}))
        csproj = {"Api.csproj": '    <PackageReference Include="Serilog" Version="2.10.0" />\n'}
        findings = self.m.collect_nuget(csproj, {}, {"Api.csproj": set()}, reg)
        self.assertEqual(findings, [])


class NuGetEndToEndTest(unittest.TestCase):
    def test_cli_against_inline_fixtures_incl_health(self):
        # A self-contained tree: CPM central versions, a global props dep, and a
        # deprecated-current package. Recorded flat-container + registration.
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d) / "repo"
            (root / "src/Api").mkdir(parents=True)
            (root / "src/Api/Api.csproj").write_text(
                '<Project Sdk="Microsoft.NET.Sdk">\n'
                '  <ItemGroup>\n'
                '    <PackageReference Include="Serilog" />\n'
                '    <PackageReference Include="Foo.Legacy" Version="4.0.0" />\n'
                '  </ItemGroup>\n'
                '</Project>\n')
            (root / "Directory.Packages.props").write_text(
                '<Project>\n'
                '  <ItemGroup>\n'
                '    <PackageVersion Include="Serilog" Version="2.10.0" />\n'
                '  </ItemGroup>\n'
                '</Project>\n')
            fx = pathlib.Path(d) / "fx"
            (fx / "nuget").mkdir(parents=True)
            (fx / "nuget-registration").mkdir(parents=True)
            (fx / "nuget" / "serilog.json").write_text(json.dumps({"versions": ["2.10.0", "3.1.1", "4.0.0"]}))
            (fx / "nuget" / "foo.legacy.json").write_text(json.dumps({"versions": ["4.0.0"]}))
            (fx / "nuget-registration" / "serilog.json").write_text(json.dumps({
                "items": [{"items": [
                    {"catalogEntry": {"version": "2.10.0", "licenseExpression": "Apache-2.0", "listed": True}},
                    {"catalogEntry": {"version": "4.0.0", "licenseExpression": "Apache-2.0", "listed": True}},
                ]}]}))
            (fx / "nuget-registration" / "foo.legacy.json").write_text(json.dumps({
                "items": [{"items": [
                    {"catalogEntry": {"version": "4.0.0", "licenseExpression": "MIT", "listed": True,
                                      "deprecation": {"message": "Abandoned; use Foo.Bar", "reasons": ["Legacy"]}}},
                ]}]}))
            files = pathlib.Path(d) / "files.txt"
            lines = pathlib.Path(d) / "lines.txt"
            files.write_text("src/Api/Api.csproj\n")
            lines.write_text("Changed lines:\n  src/Api/Api.csproj: 3,4\n")
            env = dict(os.environ, HOUSEKEEPER_REGISTRY_FIXTURES=str(fx))
            out = subprocess.run(
                [sys.executable, str(ENGINE), "--root", str(root),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines)],
                capture_output=True, text=True, check=True, env=env)
            tuples = json.loads(out.stdout)
            by_item = {t["item"]: t for t in tuples}
            # Serilog: version-less csproj ref -> CPM 2.10.0 in props -> stale (4.0.0).
            self.assertEqual(by_item["Serilog"]["current"], "2.10.0")
            self.assertEqual(by_item["Serilog"]["latest_ga"], "4.0.0")
            self.assertEqual(by_item["Serilog"]["file"], "Directory.Packages.props")
            # Foo.Legacy: current AND latest, but registry-deprecated -> pure-health.
            self.assertEqual(by_item["Foo.Legacy"]["health"]["state"], "deprecated")
            self.assertEqual(by_item["Foo.Legacy"]["target"], "4.0.0")


NPM_DOC = {
    "dist-tags": {"latest": "19.0.0"},
    "versions": {
        "18.0.0": {"license": "MIT"},
        "18.2.0": {"license": "MIT"},
        "18.3.1": {"license": "MIT"},
        "19.0.0": {"license": "MIT"},
    },
}


class NpmTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_parse_package_json_deps_with_lines(self):
        text = (
            '{\n'
            '  "dependencies": {\n'
            '    "react": "^18.2.0",\n'
            '    "left-pad": "1.3.0"\n'
            '  }\n'
            '}\n'
        )
        deps = self.m.parse_package_json(text)
        self.assertEqual(deps[("dependencies", "react")], ("^18.2.0", 3))
        self.assertEqual(deps[("dependencies", "left-pad")], ("1.3.0", 4))

    def test_parse_package_json_keeps_multi_section_deps(self):
        text = (
            '{\n'
            '  "dependencies": {\n'
            '    "react": "^18.2.0"\n'
            '  },\n'
            '  "peerDependencies": {\n'
            '    "react": "^18.0.0"\n'
            '  }\n'
            '}\n'
        )
        deps = self.m.parse_package_json(text)
        # Two distinct (section, name) entries, both for react, on their own lines.
        self.assertEqual(
            sorted((k[0], k[1], v[0], v[1]) for k, v in deps.items()),
            [("dependencies", "react", "^18.2.0", 3),
             ("peerDependencies", "react", "^18.0.0", 6)])

    def test_collect_npm_emits_both_sections(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NPM_DOC
        text = ('{\n  "dependencies": {\n    "react": "^18.2.0"\n  },\n'
                '  "peerDependencies": {\n    "react": "^18.0.0"\n  }\n}\n')
        findings = self.m.collect_npm({"package.json": text}, {"package.json": {3, 6}}, reg)
        self.assertEqual(len(findings), 2)
        self.assertEqual(sorted(f["line"] for f in findings), [3, 6])

    def test_npm_root_finds_nearest_package_json(self):
        files = ["web/app/src/index.ts", "api/server.py"]
        roots = self.m.npm_scope_roots(files, {"web/app/package.json", "api/package.json"})
        # The .ts pulls in web/app (nearest ancestor with a package.json).
        self.assertEqual(roots, {"web/app/package.json"})

    def test_stray_json_does_not_pull_in_package_json(self):
        roots = self.m.npm_scope_roots(["web/app/data.json"], {"web/app/package.json"})
        self.assertEqual(roots, set())

    def test_tsconfig_still_pulls_in_package_json(self):
        roots = self.m.npm_scope_roots(["web/app/tsconfig.json"], {"web/app/package.json"})
        self.assertEqual(roots, {"web/app/package.json"})

    def test_npm_finding_touched_line_targets_latest_ga(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NPM_DOC
        text = '{\n  "dependencies": {\n    "react": "^18.2.0"\n  }\n}\n'
        findings = self.m.collect_npm(
            {"package.json": text},
            {"package.json": {3}},  # react's line IS changed -> full bump
            reg)
        self.assertEqual(len(findings), 1)
        f = findings[0]
        self.assertEqual(f["source"], "npm")
        self.assertEqual(f["item"], "react")
        self.assertEqual(f["current"], "18.2.0")
        self.assertEqual(f["latest_ga"], "19.0.0")
        self.assertEqual(f["target"], "19.0.0")
        self.assertEqual(f["line"], 3)

    def test_npm_finding_untouched_line_targets_nearest_in_major(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NPM_DOC
        text = '{\n  "dependencies": {\n    "react": "^18.2.0"\n  }\n}\n'
        findings = self.m.collect_npm(
            {"package.json": text},
            {"package.json": set()},  # in-scope solution but line not touched
            reg)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["target"], "18.3.1")  # nearest in major 18

    def test_npm_licence_change_recorded(self):
        doc = {
            "dist-tags": {"latest": "2.0.0"},
            "versions": {"1.0.0": {"license": "MIT"}, "2.0.0": {"license": "BSL-1.1"}},
        }
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: doc
        text = '{\n  "dependencies": {\n    "foo": "1.0.0"\n  }\n}\n'
        findings = self.m.collect_npm({"package.json": text}, {"package.json": {3}}, reg)
        self.assertEqual(findings[0]["licence_current"], "MIT")
        self.assertEqual(findings[0]["licence_latest"], "BSL-1.1")

    def test_npm_silent_on_fetch_miss_and_non_registry_specs(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: None
        text = '{\n  "dependencies": {\n    "react": "^18.2.0",\n    "x": "github:a/b"\n  }\n}\n'
        self.assertEqual(self.m.collect_npm({"package.json": text}, {"package.json": {3, 4}}, reg), [])

    def test_npm_licence_diff_uses_target_not_latest(self):
        doc = {
            "dist-tags": {"latest": "19.0.0"},
            "versions": {
                "18.2.0": {"license": "MIT"},
                "18.3.1": {"license": "MIT"},
                "19.0.0": {"license": "BSL-1.1"},
            },
        }
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: doc
        text = '{\n  "dependencies": {\n    "react": "^18.2.0"\n  }\n}\n'
        findings = self.m.collect_npm({"package.json": text}, {"package.json": set()}, reg)
        self.assertEqual(findings[0]["target"], "18.3.1")
        self.assertEqual(findings[0]["licence_current"], "MIT")
        self.assertEqual(findings[0]["licence_latest"], "MIT")  # target 18.3.1 is MIT, not the 19.0.0 BSL flip

    def test_npm_deprecated_current_emits_pure_health(self):
        doc = {
            "dist-tags": {"latest": "4.0.0"},
            "versions": {"4.0.0": {"license": "MIT", "deprecated": "no longer maintained"}},
        }
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: doc
        text = '{\n  "dependencies": {\n    "left-pad": "4.0.0"\n  }\n}\n'
        findings = self.m.collect_npm({"package.json": text}, {"package.json": {3}}, reg)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["health"], {"state": "deprecated", "detail": "no longer maintained"})
        self.assertEqual(findings[0]["target"], "4.0.0")  # current; pure-health

    def test_npm_stale_finding_has_null_health(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.fetch = lambda *a, **k: NPM_DOC
        text = '{\n  "dependencies": {\n    "react": "^18.2.0"\n  }\n}\n'
        findings = self.m.collect_npm({"package.json": text}, {"package.json": {3}}, reg)
        self.assertIsNone(findings[0]["health"])


class EndToEndTest(unittest.TestCase):
    def test_cli_against_recorded_fixtures(self):
        # The engine emits stable tuples when pointed at recorded fixtures.
        repo = REPO  # the real fixture lives under tests/fixtures (Task 13)
        fixtures = repo / "tests/fixtures/static-analysis/housekeeper"
        if not fixtures.exists():
            self.skipTest("Task 13 fixture not yet created")
        with tempfile.TemporaryDirectory() as d:
            files = pathlib.Path(d) / "files.txt"
            lines = pathlib.Path(d) / "lines.txt"
            files.write_text(".github/workflows/ci.yml\npackage.json\n")
            lines.write_text("Changed lines:\n  .github/workflows/ci.yml: 12,15\n  package.json: 4\n")
            env = dict(os.environ,
                       HOUSEKEEPER_REGISTRY_FIXTURES=str(fixtures / "registry"))
            out = subprocess.run(
                [sys.executable, str(ENGINE), "--root", str(fixtures),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines)],
                capture_output=True, text=True, check=True, env=env)
            tuples = json.loads(out.stdout)
            sources = sorted(t["source"] for t in tuples)
            self.assertEqual(sources, ["github-actions", "npm", "runner"])


class HashStabilityTest(unittest.TestCase):
    def test_existing_collectors_carry_null_health(self):
        m = load_engine()
        # github-actions
        ga_reg = m.Registry(fixtures_dir=None)
        ga_reg.fetch = lambda *a, **k: {"tag_name": "v4.2.1"}
        ga = m.collect_github_actions(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "      - uses: actions/checkout@v3\n"},
            {".github/workflows/ci.yml": {1}}, ga_reg)
        self.assertIn("health", ga[0])
        self.assertIsNone(ga[0]["health"])
        # runner
        run = m.collect_runners(
            [".github/workflows/ci.yml"],
            {".github/workflows/ci.yml": "    runs-on: ubuntu-22.04\n"},
            {".github/workflows/ci.yml": {1}})
        self.assertIsNone(run[0]["health"])


class DockerParseTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_pinned_semver_no_variant(self):
        out = self.m.parse_dockerfile("FROM node:20.11.1\n")
        self.assertEqual(out, [("node", "20.11.1", "", 1)])

    def test_pinned_semver_with_variant(self):
        out = self.m.parse_dockerfile("FROM python:3.12.1-bookworm\n")
        self.assertEqual(out, [("python", "3.12.1", "bookworm", 1)])

    def test_versioned_variant_kept_whole(self):
        out = self.m.parse_dockerfile("FROM node:20.11.1-alpine3.19\n")
        self.assertEqual(out, [("node", "20.11.1", "alpine3.19", 1)])

    def test_explicit_host_and_repo_path(self):
        out = self.m.parse_dockerfile(
            "FROM mcr.microsoft.com/dotnet/aspnet:8.0.1\n")
        self.assertEqual(
            out, [("mcr.microsoft.com/dotnet/aspnet", "8.0.1", "", 1)])

    def test_as_alias_recorded_and_stage_ref_skipped(self):
        text = "FROM node:20.11.1 AS build\nFROM build\n"
        out = self.m.parse_dockerfile(text)
        self.assertEqual(out, [("node", "20.11.1", "", 1)])

    def test_platform_flag_stripped(self):
        out = self.m.parse_dockerfile(
            "FROM --platform=linux/amd64 node:20.11.1\n")
        self.assertEqual(out, [("node", "20.11.1", "", 1)])

    def test_case_insensitive_keywords(self):
        out = self.m.parse_dockerfile("from node:20.11.1 as Build\n")
        self.assertEqual(out, [("node", "20.11.1", "", 1)])

    def test_skips_latest_no_tag_partial_digest_scratch_var(self):
        text = (
            "FROM node\n"              # no tag
            "FROM node:latest\n"       # latest
            "FROM node:20\n"           # floating major
            "FROM node:20.11\n"        # partial (not M.N.P)
            "FROM node@sha256:abc123\n"  # digest
            "FROM scratch\n"           # scratch
            "FROM node:${TAG}\n"       # interpolated braces
            "FROM node:$TAG\n"         # interpolated bare
        )
        self.assertEqual(self.m.parse_dockerfile(text), [])

    def test_line_numbers_are_one_based_and_correct(self):
        text = "# comment\nFROM node:20.11.1\nRUN true\nFROM python:3.12.1\n"
        out = self.m.parse_dockerfile(text)
        self.assertEqual(out, [("node", "20.11.1", "", 2),
                               ("python", "3.12.1", "", 4)])

    def test_tag_plus_digest_acts_on_the_tag(self):
        out = self.m.parse_dockerfile("FROM node:20.11.1@sha256:abc123\n")
        self.assertEqual(out, [("node", "20.11.1", "", 1)])


class DockerTagsTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_parse_ref_bare_name_is_docker_library(self):
        host, repo = self.m._docker_parse_ref("node")
        self.assertEqual((host, repo), ("registry-1.docker.io", "library/node"))

    def test_parse_ref_org_image_is_docker_hub(self):
        host, repo = self.m._docker_parse_ref("grafana/grafana")
        self.assertEqual((host, repo),
                         ("registry-1.docker.io", "grafana/grafana"))

    def test_parse_ref_explicit_host_used_verbatim(self):
        host, repo = self.m._docker_parse_ref("ghcr.io/org/img")
        self.assertEqual((host, repo), ("ghcr.io", "org/img"))

    def test_parse_ref_mcr_multi_segment_repo(self):
        host, repo = self.m._docker_parse_ref("mcr.microsoft.com/dotnet/aspnet")
        self.assertEqual((host, repo),
                         ("mcr.microsoft.com", "dotnet/aspnet"))

    def test_parse_ref_ecr_returns_none(self):
        self.assertIsNone(
            self.m._docker_parse_ref("123.dkr.ecr.eu-west-1.amazonaws.com/svc"))

    def test_parse_challenge_extracts_realm_service_scope(self):
        hdr = ('Bearer realm="https://auth.docker.io/token",'
               'service="registry.docker.io",scope="repository:library/node:pull"')
        realm, params = self.m._docker_parse_challenge(hdr)
        self.assertEqual(realm, "https://auth.docker.io/token")
        self.assertEqual(params["service"], "registry.docker.io")
        self.assertEqual(params["scope"], "repository:library/node:pull")

    def test_docker_tags_fixture_override_reads_tag_list(self):
        with tempfile.TemporaryDirectory() as d:
            fx = pathlib.Path(d) / "docker"
            fx.mkdir()
            (fx / "library__node.json").write_text(
                '{"tags": ["20.11.1", "22.2.0", "22.2.0-alpine"]}')
            reg = self.m.Registry(fixtures_dir=d)
            self.assertEqual(reg.docker_tags("node"),
                             ["20.11.1", "22.2.0", "22.2.0-alpine"])

    def test_docker_tags_fixture_miss_returns_none(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "docker").mkdir()
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIsNone(reg.docker_tags("node"))

    def test_docker_tags_ecr_returns_none_even_with_fixtures(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "docker").mkdir()
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIsNone(
                reg.docker_tags("123.dkr.ecr.eu-west-1.amazonaws.com/svc"))


class DockerScopeTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_is_dockerfile_basename_variants(self):
        self.assertTrue(self.m._is_dockerfile("Dockerfile"))
        self.assertTrue(self.m._is_dockerfile("src/Api/Dockerfile"))
        self.assertTrue(self.m._is_dockerfile("Dockerfile.prod"))
        self.assertTrue(self.m._is_dockerfile("build/api.dockerfile"))
        self.assertFalse(self.m._is_dockerfile("src/Api/Program.cs"))
        self.assertFalse(self.m._is_dockerfile("notes/Dockerfile.md"))

    def test_directly_changed_dockerfile_in_scope(self):
        roots = self.m.docker_scope_roots(
            ["src/Api/Dockerfile"], {"src/Api/Dockerfile"},
            nuget_csprojs=set(), npm_roots=set())
        self.assertEqual(roots, {"src/Api/Dockerfile"})

    def test_source_change_pulls_in_same_dir_dockerfile(self):
        roots = self.m.docker_scope_roots(
            ["src/Api/Program.cs"], {"src/Api/Dockerfile"},
            nuget_csprojs={"src/Api/Api.csproj"}, npm_roots=set())
        self.assertEqual(roots, {"src/Api/Dockerfile"})

    def test_root_dockerfile_in_scope_for_nested_unit(self):
        roots = self.m.docker_scope_roots(
            ["src/Api/Program.cs"], {"Dockerfile"},
            nuget_csprojs={"src/Api/Api.csproj"}, npm_roots=set())
        self.assertEqual(roots, {"Dockerfile"})

    def test_dockerfile_deeper_than_unit_not_pulled_by_source(self):
        # Dockerfile below the unit dir is NOT an ancestor of the unit, so a
        # source change to the unit does not pull it in.
        roots = self.m.docker_scope_roots(
            ["src/Api/Program.cs"], {"src/Api/sub/Dockerfile"},
            nuget_csprojs={"src/Api/Api.csproj"}, npm_roots=set())
        self.assertEqual(roots, set())

    def test_sibling_unit_dockerfile_not_in_scope(self):
        roots = self.m.docker_scope_roots(
            ["src/Api/Program.cs"], {"src/Worker/Dockerfile"},
            nuget_csprojs={"src/Api/Api.csproj"}, npm_roots=set())
        self.assertEqual(roots, set())

    def test_npm_unit_pulls_in_dockerfile(self):
        roots = self.m.docker_scope_roots(
            ["web/src/index.ts"], {"web/Dockerfile"},
            nuget_csprojs=set(), npm_roots={"web/package.json"})
        self.assertEqual(roots, {"web/Dockerfile"})


class DockerCollectTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def _reg(self, tags):
        reg = self.m.Registry(fixtures_dir=None)
        reg.docker_tags = lambda ref: tags
        return reg

    def test_touched_line_targets_latest_ga_in_variant(self):
        reg = self._reg(["20.11.1", "22.2.0", "22.3.0"])
        text = {"Dockerfile": "FROM node:20.11.1\n"}
        out = self.m.collect_docker(text, {"Dockerfile": {1}}, reg)
        self.assertEqual(len(out), 1)
        f = out[0]
        self.assertEqual((f["source"], f["item"], f["current"],
                          f["latest_ga"], f["target"], f["file"], f["line"]),
                         ("docker", "node", "20.11.1", "22.3.0", "22.3.0",
                          "Dockerfile", 1))
        self.assertIsNone(f["health"])

    def test_untouched_line_targets_nearest_in_major(self):
        reg = self._reg(["20.11.1", "20.12.0", "22.3.0"])
        text = {"Dockerfile": "FROM node:20.11.1\n"}
        out = self.m.collect_docker(text, {}, reg)  # untouched
        self.assertEqual(out[0]["target"], "20.12.0")
        self.assertEqual(out[0]["latest_ga"], "22.3.0")

    def test_variant_isolation_only_same_variant_tags_considered(self):
        # An -alpine pin must not see plain tags, and vice versa.
        reg = self._reg(["20.11.1", "22.3.0", "20.11.1-alpine", "22.3.0-alpine"])
        text = {"Dockerfile": "FROM node:20.11.1-alpine\n"}
        out = self.m.collect_docker(text, {"Dockerfile": {1}}, reg)
        self.assertEqual(out[0]["current"], "20.11.1")
        self.assertEqual(out[0]["target"], "22.3.0")  # the alpine 22.3.0 core

    def test_not_stale_emits_nothing(self):
        reg = self._reg(["20.11.1", "20.10.0"])
        text = {"Dockerfile": "FROM node:20.11.1\n"}
        self.assertEqual(self.m.collect_docker(text, {"Dockerfile": {1}}, reg), [])

    def test_no_tags_in_variant_lineage_emits_nothing(self):
        reg = self._reg(["20.11.1-bullseye", "22.0.0-bullseye"])
        text = {"Dockerfile": "FROM node:20.11.1-alpine\n"}
        self.assertEqual(self.m.collect_docker(text, {"Dockerfile": {1}}, reg), [])

    def test_registry_miss_emits_nothing(self):
        reg = self._reg(None)
        text = {"Dockerfile": "FROM node:20.11.1\n"}
        self.assertEqual(self.m.collect_docker(text, {"Dockerfile": {1}}, reg), [])

    def test_multiple_from_lines_and_multiple_dockerfiles(self):
        reg = self.m.Registry(fixtures_dir=None)
        reg.docker_tags = lambda ref: {
            "node": ["18.20.0", "18.20.4", "22.3.0"],
            "python": ["3.11.0", "3.12.1", "3.12.5"],
        }.get(ref)
        text = {
            "api/Dockerfile": "FROM node:18.20.0 AS build\nFROM python:3.11.0\n",
            "web/Dockerfile": "FROM node:18.20.0\n",
        }
        changed = {"api/Dockerfile": {2}, "web/Dockerfile": {1}}
        out = self.m.collect_docker(text, changed, reg)
        keyed = {(f["file"], f["line"]): f for f in out}
        # api/Dockerfile node line (untouched line 1) -> nearest-in-major 18.20.4
        self.assertEqual(keyed[("api/Dockerfile", 1)]["item"], "node")
        self.assertEqual(keyed[("api/Dockerfile", 1)]["target"], "18.20.4")
        # api/Dockerfile python line (touched line 2) -> latest GA 3.12.5
        self.assertEqual(keyed[("api/Dockerfile", 2)]["item"], "python")
        self.assertEqual(keyed[("api/Dockerfile", 2)]["target"], "3.12.5")
        # web/Dockerfile node line (touched line 1) -> latest GA 22.3.0
        self.assertEqual(keyed[("web/Dockerfile", 1)]["target"], "22.3.0")
        self.assertEqual(len(out), 3)


class DockerEndToEndTest(unittest.TestCase):
    """Drives the engine as a subprocess against an on-disk fixture tree with a
    recorded docker fixture, proving collect_findings wires docker in and that
    a SOURCE-only changeset pulls in its unit's Dockerfile (Anchor A)."""
    def setUp(self):
        self.m = load_engine()

    def _tree(self, d):
        root = pathlib.Path(d)
        (root / "src/Api").mkdir(parents=True)
        (root / "src/Api/Api.csproj").write_text(
            '<Project Sdk="Microsoft.NET.Sdk"></Project>\n')
        (root / "src/Api/Program.cs").write_text("class P {}\n")
        (root / "src/Api/Dockerfile").write_text("FROM node:18.20.0\n")
        fx = root / "registry/docker"
        fx.mkdir(parents=True)
        (fx / "library__node.json").write_text(
            '{"tags": ["18.20.0", "20.11.1", "22.3.0"]}')
        return root

    def test_directly_changed_dockerfile_targets_latest(self):
        with tempfile.TemporaryDirectory() as d:
            root = self._tree(d)
            files = root / "files.txt"
            lines = root / "lines.txt"
            files.write_text("src/Api/Dockerfile\n")  # directly changed
            lines.write_text("Changed lines:\n  src/Api/Dockerfile: 1\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE),
                 "--root", str(root),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines),
                 "--registry-fixtures", str(root / "registry")],
                capture_output=True, text=True, check=True)
            data = json.loads(out.stdout)
            docker = [f for f in data if f["source"] == "docker"]
            self.assertEqual(len(docker), 1)
            self.assertEqual(docker[0]["item"], "node")
            self.assertEqual(docker[0]["current"], "18.20.0")
            self.assertEqual(docker[0]["latest_ga"], "22.3.0")
            self.assertEqual(docker[0]["target"], "22.3.0")  # touched -> latest

    def test_source_only_untouched_targets_nearest_in_major(self):
        with tempfile.TemporaryDirectory() as d:
            root = self._tree(d)
            # Overwrite the fixture to include a higher 18.x so an untouched
            # in-major bump is available and the Anchor-A pull-in is observable.
            (root / "registry/docker/library__node.json").write_text(
                '{"tags": ["18.20.0", "18.20.4", "20.11.1", "22.3.0"]}')
            files = root / "files.txt"
            lines = root / "lines.txt"
            files.write_text("src/Api/Program.cs\n")  # source only, no Dockerfile
            lines.write_text("Changed lines:\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE),
                 "--root", str(root),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines),
                 "--registry-fixtures", str(root / "registry")],
                capture_output=True, text=True, check=True)
            docker = [f for f in json.loads(out.stdout) if f["source"] == "docker"]
            self.assertEqual(len(docker), 1)
            self.assertEqual(docker[0]["target"], "18.20.4")  # nearest in-major
            self.assertEqual(docker[0]["latest_ga"], "22.3.0")


class PyPIVersionCoreTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_is_ga_rejects_pep440_prereleases(self):
        self.assertTrue(self.m.pypi_is_ga("1.2.3"))
        self.assertTrue(self.m.pypi_is_ga("2.0.0"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3rc1"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3a1"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3b2"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3.dev0"))
        self.assertFalse(self.m.pypi_is_ga("1.2.3rc1.dev0"))

    def test_post_release_is_ga_and_newer(self):
        self.assertTrue(self.m.pypi_is_ga("1.2.3.post1"))
        self.assertEqual(self.m.pypi_compare("1.2.3.post1", "1.2.3"), 1)
        self.assertEqual(self.m.pypi_compare("1.2.3", "1.2.3.post1"), -1)

    def test_prerelease_sorts_below_final(self):
        self.assertEqual(self.m.pypi_compare("1.2.3rc1", "1.2.3"), -1)
        self.assertEqual(self.m.pypi_compare("1.2.3a1", "1.2.3b1"), -1)
        self.assertEqual(self.m.pypi_compare("1.2.3.dev0", "1.2.3a1"), -1)

    def test_epoch_sorts_above(self):
        self.assertEqual(self.m.pypi_compare("1!1.0", "2.0"), 1)

    def test_local_version_stripped_for_ordering(self):
        self.assertEqual(self.m.pypi_compare("1.2.3+ubuntu1", "1.2.3"), 0)
        self.assertTrue(self.m.pypi_is_ga("1.2.3+ubuntu1"))

    def test_trailing_zero_release_equal(self):
        self.assertEqual(self.m.pypi_compare("1.0", "1.0.0"), 0)
        self.assertEqual(self.m.pypi_compare("1.2.0", "1.2"), 0)

    def test_compare_orders_numerically(self):
        self.assertEqual(self.m.pypi_compare("1.10.0", "1.9.0"), 1)
        self.assertEqual(self.m.pypi_compare("2.0.0", "10.0.0"), -1)

    def test_unparsable_returns_none_or_zero(self):
        self.assertIsNone(self.m.pypi_version_key("not-a-version"))
        self.assertFalse(self.m.pypi_is_ga("garbage"))
        self.assertEqual(self.m.pypi_compare("garbage", "1.0.0"), 0)

    def test_latest_ga_skips_prereleases(self):
        versions = ["1.0.0", "2.0.0rc1", "1.9.0", "1.10.0", "2.0.0.dev1"]
        self.assertEqual(self.m.pypi_latest_ga(versions), "1.10.0")

    def test_nearest_in_major(self):
        versions = ["2.20.0", "2.28.1", "2.31.0", "3.0.0"]
        self.assertEqual(self.m.pypi_nearest_in_major("2.20.0", versions), "2.31.0")
        self.assertEqual(self.m.pypi_nearest_in_major("3.0.0", versions), "3.0.0")


class PyPIConstraintTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_strip_acts_on_single_anchor_floors(self):
        self.assertEqual(self.m.pypi_strip_constraint("==1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("===1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("~=1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint(">=1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("^1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("~1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("1.2.3"), "1.2.3")
        self.assertEqual(self.m.pypi_strip_constraint("==2.0.0rc1"), "2.0.0rc1")

    def test_strip_skips_untrustworthy_forms(self):
        self.assertIsNone(self.m.pypi_strip_constraint("==1.2.*"))
        self.assertIsNone(self.m.pypi_strip_constraint("1.*"))
        self.assertIsNone(self.m.pypi_strip_constraint(">=1.2,<2"))
        self.assertIsNone(self.m.pypi_strip_constraint("!=1.2.3"))
        self.assertIsNone(self.m.pypi_strip_constraint("<2.0"))
        self.assertIsNone(self.m.pypi_strip_constraint(">1.2"))
        self.assertIsNone(self.m.pypi_strip_constraint("<=1.0"))
        self.assertIsNone(self.m.pypi_strip_constraint(""))
        self.assertIsNone(self.m.pypi_strip_constraint("git+https://x/y.git"))

    def test_pep508_splits_name_and_spec(self):
        self.assertEqual(self.m._pypi_pep508_name_spec("requests>=2.0"),
                         ("requests", ">=2.0"))
        self.assertEqual(self.m._pypi_pep508_name_spec("requests==2.28.1"),
                         ("requests", "==2.28.1"))

    def test_pep508_strips_extras_and_markers(self):
        self.assertEqual(
            self.m._pypi_pep508_name_spec('requests[security]>=2.0 ; python_version < "3.11"'),
            ("requests", ">=2.0"))
        self.assertEqual(self.m._pypi_pep508_name_spec("flask[async]==2.0.0"),
                         ("flask", "==2.0.0"))

    def test_pep508_url_reference_returns_none(self):
        self.assertIsNone(self.m._pypi_pep508_name_spec("foo @ git+https://x/y.git"))
        self.assertIsNone(self.m._pypi_pep508_name_spec(""))
        self.assertIsNone(self.m._pypi_pep508_name_spec("# a comment"))

    def test_pep508_bare_name_no_spec(self):
        self.assertEqual(self.m._pypi_pep508_name_spec("requests"), ("requests", ""))


class PyPIRequirementsParseTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_parses_pinned_and_floored_lines(self):
        text = (
            "requests==2.28.1\n"
            "flask>=2.0\n"
            "django~=4.1.0\n"
        )
        out = self.m.parse_requirements(text)
        self.assertIn(("requests", "==2.28.1", 1), out)
        self.assertIn(("flask", ">=2.0", 2), out)
        self.assertIn(("django", "~=4.1.0", 3), out)

    def test_skips_comments_blanks_options_and_includes(self):
        text = (
            "# a comment\n"
            "\n"
            "-r base.txt\n"
            "-c constraints.txt\n"
            "-e .\n"
            "--index-url https://example/simple\n"
            "requests==2.28.1\n"
        )
        out = self.m.parse_requirements(text)
        self.assertEqual(out, [("requests", "==2.28.1", 7)])

    def test_strips_inline_comment_and_extras_and_marker(self):
        text = 'requests[security]==2.28.1  # pinned ; keep\n'
        out = self.m.parse_requirements(text)
        self.assertEqual(out, [("requests", "==2.28.1", 1)])

    def test_skips_url_and_vcs_entries(self):
        text = (
            "foo @ git+https://x/y.git\n"
            "https://example/pkg.whl\n"
        )
        self.assertEqual(self.m.parse_requirements(text), [])


class PyPIProjectParseTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_pep621_dependencies_and_optional(self):
        text = (
            "[project]\n"
            'name = "x"\n'
            "dependencies = [\n"
            '  "requests>=2.0",\n'
            '  "flask==2.0.0",\n'
            "]\n"
            "[project.optional-dependencies]\n"
            'dev = ["pytest==7.0.0"]\n'
        )
        out = self.m.parse_pyproject(text)
        names = {n: s for n, s, _ in out}
        self.assertEqual(names["requests"], ">=2.0")
        self.assertEqual(names["flask"], "==2.0.0")
        self.assertEqual(names["pytest"], "==7.0.0")

    def test_poetry_tables_and_python_skipped(self):
        text = (
            "[tool.poetry.dependencies]\n"
            'python = "^3.11"\n'
            'requests = "^2.28.0"\n'
            'flask = {version = "2.0.0", optional = true}\n'
            "[tool.poetry.group.dev.dependencies]\n"
            'pytest = "~7.0"\n'
        )
        out = self.m.parse_pyproject(text)
        names = {n: s for n, s, _ in out}
        self.assertNotIn("python", names)
        self.assertEqual(names["requests"], "^2.28.0")
        self.assertEqual(names["flask"], "2.0.0")
        self.assertEqual(names["pytest"], "~7.0")

    def test_line_numbers_point_at_declaration(self):
        text = (
            "[project]\n"
            "dependencies = [\n"
            '  "requests>=2.0",\n'
            "]\n"
        )
        out = self.m.parse_pyproject(text)
        self.assertEqual(out, [("requests", ">=2.0", 3)])

    def test_empty_or_no_deps_returns_empty(self):
        self.assertEqual(self.m.parse_pyproject('[project]\nname = "x"\n'), [])

    def test_non_string_pep621_dep_is_skipped_not_raised(self):
        text = (
            "[project]\n"
            "dependencies = [\n"
            '  "requests>=2.0",\n'
            "  123,\n"
            "]\n"
        )
        out = self.m.parse_pyproject(text)
        self.assertEqual(out, [("requests", ">=2.0", 3)])

    def test_string_valued_optional_group_does_not_explode(self):
        text = (
            "[project]\n"
            'name = "x"\n'
            "[project.optional-dependencies]\n"
            'dev = "pytest"\n'
        )
        self.assertEqual(self.m.parse_pyproject(text), [])


class PyPIRegistryTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_normalize_pep503(self):
        self.assertEqual(self.m._pypi_normalize("Flask-SQLAlchemy"), "flask-sqlalchemy")
        self.assertEqual(self.m._pypi_normalize("zope.interface"), "zope-interface")
        self.assertEqual(self.m._pypi_normalize("ruamel_yaml"), "ruamel-yaml")

    def test_fixture_override_reads_releases(self):
        with tempfile.TemporaryDirectory() as d:
            fx = pathlib.Path(d) / "pypi"
            fx.mkdir()
            (fx / "requests.json").write_text(json.dumps({
                "info": {"version": "2.31.0"},
                "releases": {"2.28.1": [{"yanked": False}],
                             "2.31.0": [{"yanked": False}]},
            }))
            reg = self.m.Registry(fixtures_dir=d)
            rel = reg.pypi_releases("requests")
            self.assertIn("2.31.0", rel)
            self.assertEqual(rel["2.28.1"], [{"yanked": False}])

    def test_fixture_override_normalizes_slug(self):
        with tempfile.TemporaryDirectory() as d:
            fx = pathlib.Path(d) / "pypi"
            fx.mkdir()
            (fx / "flask-sqlalchemy.json").write_text(json.dumps({
                "releases": {"3.0.0": [{"yanked": False}]}}))
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIn("3.0.0", reg.pypi_releases("Flask-SQLAlchemy"))

    def test_fixture_miss_returns_none(self):
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "pypi").mkdir()
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIsNone(reg.pypi_releases("nope"))

    def test_fixture_without_releases_key_returns_none(self):
        with tempfile.TemporaryDirectory() as d:
            fx = pathlib.Path(d) / "pypi"
            fx.mkdir()
            (fx / "requests.json").write_text(json.dumps({"info": {"version": "2.31.0"}}))
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIsNone(reg.pypi_releases("requests"))

    def test_malformed_fixture_returns_none(self):
        with tempfile.TemporaryDirectory() as d:
            fx = pathlib.Path(d) / "pypi"
            fx.mkdir()
            (fx / "requests.json").write_text("{not json")
            reg = self.m.Registry(fixtures_dir=d)
            self.assertIsNone(reg.pypi_releases("requests"))


PYPI_REL = {
    "2.20.0": [{"yanked": False}],
    "2.28.1": [{"yanked": False}],
    "2.31.0": [{"yanked": False}],
    "3.0.0": [{"yanked": False}],
    "2.99.0": [{"yanked": True, "yanked_reason": "broken wheel"}],
}


class PyPICollectTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def _reg(self, releases):
        reg = self.m.Registry(fixtures_dir=None)
        reg.pypi_releases = lambda project: releases
        return reg

    def test_touched_line_targets_latest_ga(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(len(out), 1)
        f = out[0]
        self.assertEqual((f["source"], f["item"], f["current"], f["latest_ga"],
                          f["target"], f["file"], f["line"]),
                         ("pypi", "requests", "2.20.0", "3.0.0", "3.0.0",
                          "requirements.txt", 1))
        self.assertIsNone(f["health"])
        self.assertIsNone(f["licence_current"])

    def test_untouched_line_targets_nearest_in_major(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": set()}, reg)
        self.assertEqual(out[0]["target"], "2.31.0")  # nearest in major 2
        self.assertEqual(out[0]["latest_ga"], "3.0.0")

    def test_yanked_release_excluded_from_target(self):
        # latest non-yanked GA is 3.0.0; 2.99.0 (yanked) must not be the target.
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(out[0]["latest_ga"], "3.0.0")
        self.assertEqual(out[0]["target"], "3.0.0")

    def test_yanked_current_emits_health_rider(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.99.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(len(out), 1)
        f = out[0]
        self.assertEqual(f["health"], {"state": "yanked", "detail": "broken wheel"})
        self.assertEqual(f["current"], "2.99.0")
        self.assertEqual(f["target"], "3.0.0")  # stale AND yanked -> upgrade target

    def test_current_latest_but_yanked_is_pure_health(self):
        rel = {"3.0.0": [{"yanked": True, "yanked_reason": "security"}]}
        reg = self._reg(rel)
        # 3.0.0 is the only release and it is yanked -> no GA latest -> skip.
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==3.0.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(out, [])

    def test_pure_health_when_current_is_latest_ga_but_yanked(self):
        rel = {"2.0.0": [{"yanked": False}],
               "3.0.0": [{"yanked": True, "yanked_reason": "bad"}]}
        # current 3.0.0 is yanked (health) but the latest NON-yanked GA is 2.0.0,
        # which is not newer -> not stale -> pure-health, target == current.
        reg = self._reg(rel)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==3.0.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["health"]["state"], "yanked")
        self.assertEqual(out[0]["target"], "3.0.0")

    def test_not_stale_emits_nothing(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==3.0.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(out, [])

    def test_registry_miss_emits_nothing(self):
        reg = self._reg(None)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(out, [])

    def test_range_and_url_specs_skipped(self):
        reg = self._reg(PYPI_REL)
        text = "requests>=2.0,<3\nfoo @ git+https://x/y.git\n"
        out = self.m.collect_pypi({}, {"requirements.txt": text},
                                  {"requirements.txt": {1, 2}}, reg)
        self.assertEqual(out, [])

    def test_pyproject_source_routed_through_collector(self):
        reg = self._reg(PYPI_REL)
        text = ('[project]\ndependencies = [\n  "requests==2.20.0",\n]\n')
        out = self.m.collect_pypi({"pyproject.toml": text}, {},
                                  {"pyproject.toml": {3}}, reg)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["item"], "requests")
        self.assertEqual(out[0]["file"], "pyproject.toml")
        self.assertEqual(out[0]["line"], 3)

    def test_empty_records_release_treated_as_non_yanked(self):
        rel = {"2.20.0": [{"yanked": False}], "2.31.0": []}
        reg = self._reg(rel)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["latest_ga"], "2.31.0")  # empty-records 2.31.0 still eligible
        self.assertEqual(out[0]["target"], "2.31.0")

    def test_current_absent_from_map_keeps_health_none(self):
        # current pin not present as a release key -> no health claim, but stale.
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.10.0\n"},
            {"requirements.txt": {1}}, reg)
        self.assertEqual(len(out), 1)
        self.assertIsNone(out[0]["health"])
        self.assertEqual(out[0]["current"], "2.10.0")
        self.assertEqual(out[0]["target"], "3.0.0")

    def test_same_dep_two_manifests_emits_two(self):
        reg = self._reg(PYPI_REL)
        out = self.m.collect_pypi(
            {}, {"requirements.txt": "requests==2.20.0\n",
                 "requirements-dev.txt": "requests==2.20.0\n"},
            {"requirements.txt": {1}, "requirements-dev.txt": {1}}, reg)
        self.assertEqual(len(out), 2)
        self.assertEqual({f["file"] for f in out},
                         {"requirements.txt", "requirements-dev.txt"})


class PyPIScopeTest(unittest.TestCase):
    def setUp(self):
        self.m = load_engine()

    def test_py_pulls_in_nearest_pyproject(self):
        pj, rq = self.m.pypi_scope_roots(
            ["pkg/app/module.py"],
            {"pyproject.toml", "pkg/app/pyproject.toml"}, set())
        self.assertEqual(pj, {"pkg/app/pyproject.toml"})
        self.assertEqual(rq, set())

    def test_pyi_stub_pulls_in_pyproject(self):
        pj, _ = self.m.pypi_scope_roots(
            ["pkg/types.pyi"], {"pkg/pyproject.toml"}, set())
        self.assertEqual(pj, {"pkg/pyproject.toml"})

    def test_directly_changed_pyproject_in_scope(self):
        pj, _ = self.m.pypi_scope_roots(
            ["pyproject.toml"], {"pyproject.toml"}, set())
        self.assertEqual(pj, {"pyproject.toml"})

    def test_directly_changed_requirements_in_scope(self):
        _, rq = self.m.pypi_scope_roots(
            ["requirements.txt"], set(), {"requirements.txt"})
        self.assertEqual(rq, {"requirements.txt"})
        _, rq2 = self.m.pypi_scope_roots(
            ["requirements-dev.txt"], set(), {"requirements-dev.txt"})
        self.assertEqual(rq2, {"requirements-dev.txt"})

    def test_source_with_no_pyproject_falls_back_to_requirements(self):
        pj, rq = self.m.pypi_scope_roots(
            ["svc/handler.py"], set(), {"svc/requirements.txt"})
        self.assertEqual(pj, set())
        self.assertEqual(rq, {"svc/requirements.txt"})

    def test_pyproject_wins_over_requirements_when_both_present(self):
        pj, rq = self.m.pypi_scope_roots(
            ["svc/handler.py"],
            {"svc/pyproject.toml"}, {"svc/requirements.txt"})
        self.assertEqual(pj, {"svc/pyproject.toml"})
        self.assertEqual(rq, set())

    def test_non_python_file_pulls_nothing(self):
        pj, rq = self.m.pypi_scope_roots(
            ["svc/README.md"], {"svc/pyproject.toml"}, {"svc/requirements.txt"})
        self.assertEqual((pj, rq), (set(), set()))

    def test_prefix_collision_does_not_cross_sibling_dirs(self):
        pj, _ = self.m.pypi_scope_roots(
            ["src/AppTests/test_x.py"],
            {"src/App/pyproject.toml", "src/AppTests/pyproject.toml"}, set())
        self.assertEqual(pj, {"src/AppTests/pyproject.toml"})

    def test_root_level_py_pulls_in_root_pyproject(self):
        # The empty-string-root branch of _nearest_ancestor / ancestor check.
        pj, rq = self.m.pypi_scope_roots(
            ["module.py"], {"pyproject.toml"}, set())
        self.assertEqual(pj, {"pyproject.toml"})
        self.assertEqual(rq, set())

    def test_two_py_files_pull_distinct_pyprojects(self):
        pj, _ = self.m.pypi_scope_roots(
            ["a/x.py", "b/y.py"],
            {"a/pyproject.toml", "b/pyproject.toml"}, set())
        self.assertEqual(pj, {"a/pyproject.toml", "b/pyproject.toml"})

    def test_pyproject_wins_by_precedence_not_depth(self):
        # pyproject is SHALLOWER than the requirements file; precedence (not
        # depth) must still pick the pyproject for the .py pull-in.
        pj, rq = self.m.pypi_scope_roots(
            ["a/b/handler.py"],
            {"a/pyproject.toml"}, {"a/b/requirements.txt"})
        self.assertEqual(pj, {"a/pyproject.toml"})
        self.assertEqual(rq, set())


class PyPIWiringTest(unittest.TestCase):
    """Drives the engine as a subprocess against an on-disk tree with a recorded
    pypi fixture, proving collect_findings wires pypi in and that a SOURCE-only
    change pulls in its unit's pyproject.toml."""
    def _tree(self, d, requirements=False):
        root = pathlib.Path(d)
        (root / "pkg/app").mkdir(parents=True)
        (root / "pkg/app/module.py").write_text("x = 1\n")
        if requirements:
            (root / "pkg/app/requirements.txt").write_text("requests==2.20.0\n")
        else:
            (root / "pkg/app/pyproject.toml").write_text(
                '[project]\nname = "app"\ndependencies = [\n  "requests==2.20.0",\n]\n')
        fx = root / "registry/pypi"
        fx.mkdir(parents=True)
        (fx / "requests.json").write_text(json.dumps({
            "info": {"version": "2.31.0"},
            "releases": {"2.20.0": [{"yanked": False}],
                         "2.28.1": [{"yanked": False}],
                         "2.31.0": [{"yanked": False}]}}))
        return root

    def _run(self, root, changed):
        with tempfile.TemporaryDirectory() as t:
            files = pathlib.Path(t) / "files.txt"
            lines = pathlib.Path(t) / "lines.txt"
            files.write_text("".join(c + "\n" for c in changed))
            lines.write_text("Changed lines:\n")
            out = subprocess.run(
                [sys.executable, str(ENGINE), "--root", str(root),
                 "--changed-files-from", str(files),
                 "--changed-lines-from", str(lines),
                 "--registry-fixtures", str(root / "registry")],
                capture_output=True, text=True, check=True)
            return [f for f in json.loads(out.stdout) if f["source"] == "pypi"]

    def test_source_only_change_pulls_in_pyproject(self):
        with tempfile.TemporaryDirectory() as d:
            root = self._tree(d)
            pypi = self._run(root, ["pkg/app/module.py"])
            self.assertEqual(len(pypi), 1)
            self.assertEqual(pypi[0]["item"], "requests")
            self.assertEqual(pypi[0]["current"], "2.20.0")
            self.assertEqual(pypi[0]["latest_ga"], "2.31.0")
            self.assertEqual(pypi[0]["target"], "2.31.0")  # untouched -> nearest in major 2

    def test_source_only_change_pulls_in_requirements(self):
        with tempfile.TemporaryDirectory() as d:
            root = self._tree(d, requirements=True)
            pypi = self._run(root, ["pkg/app/module.py"])
            self.assertEqual(len(pypi), 1)
            self.assertEqual(pypi[0]["file"], "pkg/app/requirements.txt")
            self.assertEqual(pypi[0]["item"], "requests")


if __name__ == "__main__":
    unittest.main()
