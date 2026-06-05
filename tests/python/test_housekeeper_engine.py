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
        self.assertEqual(deps["react"], ("^18.2.0", 3))
        self.assertEqual(deps["left-pad"], ("1.3.0", 4))

    def test_npm_root_finds_nearest_package_json(self):
        files = ["web/app/src/index.ts", "api/server.py"]
        roots = self.m.npm_scope_roots(files, {"web/app/package.json", "api/package.json"})
        # The .ts pulls in web/app (nearest ancestor with a package.json).
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


if __name__ == "__main__":
    unittest.main()
