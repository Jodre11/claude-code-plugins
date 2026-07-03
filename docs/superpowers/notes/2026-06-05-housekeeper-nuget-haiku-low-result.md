# Housekeeper-reviewer NuGet Haiku/low A/B result (vertical slice 2)

**Date:** 2026-06-11 (sweep executed; slice planned/built 2026-06-05)
**Status:** EQUIVALENT (clean — both arms 20/20 single-hash, zero divergence)
**Spec:** ../specs/2026-06-05-housekeeper-slice2-nuget-design.md
**Plan:** ../plans/2026-06-05-housekeeper-slice2-nuget.md
**Tuning framework:** ../specs/2026-05-29-static-specialist-tuning-sweep.md
**Slice-1 result (precedent, equivalent):** ./2026-06-05-housekeeper-haiku-low-result.md
**Baseline (sonnet) run dir:** `tests/ab/runs/20260611T115220Z-housekeeper-nuget-baseline/` (gitignored)
**Probe (haiku/low) run dir:** `tests/ab/runs/20260611T115223Z-housekeeper-nuget-haiku-low/` (gitignored)
**Gated single capture run dir:** `tests/ab/runs/20260611T113102Z-housekeeper-nuget-baseline/` (gitignored)
**Sweep SHA:** `ca815a4` (cache refreshed to this commit via `/plugins update` + `/reload-plugins` before the capture — pre-flight clean, no cache-staleness incident this slice)

## Headline

NuGet is the most parse-heavy housekeeper source class (CPM indirection through
`Directory.Packages.props`, version-less `<PackageReference>` resolution, props
walk-up, plus a registration-API licence/health lookup). It nonetheless returned
a **perfectly clean EQUIVALENT on the first sweep**: Sonnet/default and Haiku/low
each landed **20/20 on the identical canonical hash** (`be7dbfd8…`), with no
within-arm non-determinism, no skips, and no fabrications. The shipped
`model: haiku` + `effort: low` tier is validated for NuGet too; the sonnet
fallback is not needed. This closes the Phase-3 tier story: all four static
source classes plus the two new axes (NuGet + maintenance-health) run on
haiku/low.

## Sweep configuration

- Codepath: per-agent harness, `--stream-json`.
- Specialist: `housekeeper-reviewer`. Corpus: `housekeeper-nuget-stale-deps` — a
  synthetic CPM solution (`Directory.Packages.props` central versions; two
  version-less `<PackageReference>`s in `src/Api/Api.csproj` resolving through
  CPM; a benign `Directory.Build.props` proving the walk-up scans it without
  finding a stale global dep). Two deterministic Suggestion findings.
- Engine: `bin/housekeeper-freshness` (stdlib Python). NuGet source class
  exercised: flat-container freshness fetch + registration-API licence/health
  fetch (both live — the A/B harness scrubs subprocess env, so
  `HOUSEKEEPER_REGISTRY_FIXTURES` is NOT injected and the engine hits real
  nuget.org; see "Live-registry note").
- Arms: Sonnet/default (`housekeeper-nuget-baseline.yaml`) and Haiku/low
  (`housekeeper-nuget-haiku-low.yaml`), n=20 each.
- Apparatus: the engine ships in the plugin `bin/` (on PATH) — NO `setup:`
  provisioning block, no install race (like trivy/jbinspect/slice-1). The fixture
  repo is copied per-trial into a hermetic, non-git working dir; the agent's
  `Changed lines:`-block fallback (shipped slice 1) supplies the file list.

## Canonical hash (the 2-tuple set)

Canonical hash `be7dbfd8f04b449eb106b26c502e6c37a3be8b93b45204b44654cbf6549cca23`,
the parsed tuple set:

```json
[{"file":"Directory.Packages.props","line":3,"rule_id":"housekeeper/nuget","severity":"Suggestion","confidence":100},
 {"file":"Directory.Packages.props","line":4,"rule_id":"housekeeper/nuget","severity":"Suggestion","confidence":100}]
```

Both findings cite `Directory.Packages.props` (not `Api.csproj`) because the
version-less csproj refs resolve through the CPM central versions, where the
literal versions actually live. Line 3 = Serilog (freshness); line 4 =
WindowsAzure.Storage (pure-health, deprecated). The hash keys only on
`file/line/rule_id/severity/confidence` — the version text in the rendered
Description (e.g. "latest GA is 4.3.1") is intentionally NOT hashed, so the
per-trial hash is **drift-proof**. The hash matches the gated single-capture
baseline exactly — confirmed at n=20 on both arms, not carried from one trial.

## Hash distribution

| Arm | canonical `be7dbfd8…` | other | skipped/INCONCLUSIVE | NORMAL rate |
|---|---|---|---|---|
| **Sonnet/default** | **20 / 20** | 0 | 0 | **100 %** |
| **Haiku/low** | **20 / 20** | 0 | 0 | **100 %** |

Every trial in both arms: `findings_count == 2`, canonical hash,
`first_finding_rule == housekeeper/nuget`, `exit_code 0`, `inconclusive false`,
`timed_out false`. No divergence to characterise — the haiku arm is as
deterministic as the sonnet arm. Like slice 1, this came back clean on the first
pass with zero tail, despite NuGet being the most parse-heavy source.

## Cost delta

Per-trial figures from the stream `result` envelope's `total_cost_usd`.

| Arm | n | mean cost/trial* | mean turns | mean out tok | mean cache-read tok | mean wall |
|---|---|---|---|---|---|---|
| Sonnet/default | 20 | **$0.14941** | 7.90 | 1,360 | 199,807 | 30 s |
| Haiku/low | 20 | **$0.07244** | 10.05 | 1,895 | 207,883 | 27 s |

**Cost ratio Sonnet ÷ Haiku = 2.06×** (stream `total_cost_usd`); a hand-rolled
token×list-price recompute gave 2.18×. Both sit in the established family.

> **\* List-price caveat (load-bearing).** The CC stream's `total_cost_usd` is
> computed at **Anthropic list prices, not Bedrock**. Treat the absolute dollars
> as indicative of the **ratio**, not the actual Bedrock bill. The ~2.0–2.2×
> ratio is the reportable figure; it sits in family with slice-1 housekeeper
> 2.38×, trivy 2.34×, eslint 2.17×, jbinspect 1.89×, ruff ~2.2× — the price-tier
> saving is stable across every static specialist and now both new NuGet axes.

Consistent with the programme finding: cost is dominated by turns × cached
context, not output tokens. Haiku's mean output (1,895) is *higher* than Sonnet's
(1,360) and it took more turns (10.05 vs 7.90), yet it still costs ~2× less — the
lever is the price tier, not verbosity. Both arms follow the same multi-step
procedure (tool checks → temp-file writes → engine run → render) without
flailing.

## Live-registry note + live-deprecation decision (the slice-2 execution risk)

The A/B harness scrubs the subagent's environment
(`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`), so the dispatched engine ran in **live**
mode against real nuget.org — `HOUSEKEEPER_REGISTRY_FIXTURES` is an inert
forward-marker in the corpus `source.yaml`. Engine determinism *under fixtures*
is independently guaranteed by the unittest `NuGetEndToEndTest`.

The freshness finding (Serilog 2.10.0) is unambiguously stale live (latest GA was
4.3.1 at sweep time). The **maintenance-health finding was the genuine live
risk**: the corpus originally used `Newtonsoft.Json 13.0.3` as the
current-but-deprecated case, but nuget.org does NOT mark Newtonsoft.Json
deprecated, so the live sweep would not have produced that health finding —
diverging from the fixture and risking a false INCONCLUSIVE. **Decision (operator-
gated):** before the capture, the corpus health slot was swapped to
`WindowsAzure.Storage 9.3.3`, verified against the live registration API as
genuinely deprecated (`listed: true`, deprecation message "obsolete as of
3/31/2023 … upgrade to Azure.Storage.Common", reasons `["Legacy"]`) and abandoned
(so 9.3.3 stays latest → a stable pure-health case, current==latest==target). The
gated single capture confirmed the live engine emits both findings (the health
finding appeared with the full live deprecation message), so the 2×20 sweep ran
against a corpus with **no fixture/live divergence**. The fixture-recorded
registries (under `tests/fixtures/static-analysis/housekeeper-nuget/registry/`)
were updated to WindowsAzure.Storage in lockstep so the engine unit tests stay
internally consistent; they remain inert in the live sweep.

The agent worked example (`housekeeper-reviewer.md`) kept its Newtonsoft.Json
pure-health illustration — it teaches the package-agnostic render *shape*, not the
live registry state, so it needed no change.

## Pre-flight (carried, clean this slice)

Plugin-cache pre-flight was honoured: `/plugins update` + `/reload-plugins`
refreshed the cache to `ca815a4` before the capture, and the cached engine was
verified to contain the NuGet code. No cache-staleness incident this slice
(contrast slice 1, which cost a capture). Reinforces
[[project_plugin_cache_staleness]] / [[feedback_plugins_update_after_push]].

## Verdict (framework verbatim)

- **EQUIVALENT** — Haiku matches the canonical hash within noise (clean,
  single-hash arm).
- **INCONCLUSIVE (decision-4)** — mixed within-arm hashes default to inconclusive
  regardless of rate.
- **WORSE** — >25 % NORMAL-rate drop.

**EQUIVALENT (clean).** Haiku/low matches the Sonnet/default baseline exactly —
20/20 identical canonical hash on both arms, no within-arm non-determinism, no
skips, no fabrications. Clears the EQUIVALENT bar with zero movement against the
25 % guard and no tail to characterise.

## Production-flip decision

The agent already ships `model: haiku` + `effort: low` (validated for the three
slice-1 source classes; the tier covers ALL four source classes since slice 1).
On a clean EQUIVALENT, **no frontmatter change is needed — this result VALIDATES
the shipped tier for the new NuGet source class and the maintenance-health axis.**
The sonnet fallback is not invoked. Because the tier is shared across all four
source classes, a hypothetical revert would have hit npm/Actions/runner too — but
no revert is warranted.

This closes vertical slice 2 of the housekeeper specialist (NuGet +
maintenance-health + the slice-1 npm/runner hardening). Follow-on slices add
further ecosystems (PyPI, crates.io, Go modules, RubyGems, Docker base-image tags,
framework/SDK versions) on the same chassis; each adds a parser + fixtures + a
cookbook row and is independently testable. Fuzzy maintenance-health (last-publish
age, single-maintainer) stays deferred — it breaks determinism.

## Cross-references

- Slice-1 result (precedent): ./2026-06-05-housekeeper-haiku-low-result.md
- Tuning framework: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Plugin-cache staleness: memory `project_plugin_cache_staleness.md`,
  `feedback_plugins_update_after_push.md`
