# Housekeeper-reviewer Haiku/low A/B result (vertical slice 1)

**Date:** 2026-06-05
**Status:** EQUIVALENT (clean — both arms 20/20 single-hash, zero divergence)
**Spec:** ../specs/2026-06-05-housekeeper-specialist-design.md
**Plan:** ../plans/2026-06-05-housekeeper-specialist.md
**Tuning framework:** ../specs/2026-05-29-static-specialist-tuning-sweep.md
**Precedent (trivy, equivalent after fix):** ./2026-06-03-trivy-haiku-low-result.md
**Precedent (jbinspect, equivalent):** ./2026-06-04-jbinspect-haiku-low-result.md (see memory)
**Baseline (sonnet) run dir:** `tests/ab/runs/20260605T105259Z-housekeeper-baseline/` (gitignored)
**Probe (haiku/low) run dir:** `tests/ab/runs/20260605T105305Z-housekeeper-haiku-low/` (gitignored)
**Sweep SHA:** `846b8be` (cache refreshed to this commit before the sweep — see "Cache-staleness incident")

## Headline

Housekeeper is the most multi-step static specialist (resolve diff → write two
temp files → run the engine → render N findings), so it was the most haiku-risky
yet. It nonetheless returned a **perfectly clean EQUIVALENT on the first
fix-validated sweep**: Sonnet/default and Haiku/low each landed **20/20 on the
identical canonical hash**, with no within-arm non-determinism, no skips, and no
fabrications. The shipped `model: haiku` + `effort: low` tier is validated; the
sonnet fallback is not needed.

## Sweep configuration

- Codepath: per-agent harness, `--stream-json`.
- Specialist: `housekeeper-reviewer`. Fixture: `housekeeper-smoke-stale-deps` —
  three deterministic Suggestion findings on a synthetic repo: a stale
  `runs-on: ubuntu-22.04` (line 5) and `uses: actions/checkout@v3` (line 7) in
  `.github/workflows/ci.yml`, plus a stale `react ^18.2.0` (line 4) in
  `package.json`.
- Engine: `bin/housekeeper-freshness` (stdlib Python). Source classes exercised:
  `runner` (engine-internal `LATEST_RUNNERS` table, no network), `github-actions`
  and `npm` (live registry fetches — the A/B harness scrubs subprocess env, so
  `HOUSEKEEPER_REGISTRY_FIXTURES` is NOT injected and the engine hits the real
  npm + GitHub APIs; see "Live-registry note").
- Arms: Sonnet/default (`housekeeper-baseline.yaml`) and Haiku/low
  (`housekeeper-haiku-low.yaml`), n=20 each.
- Apparatus: the engine ships in the plugin `bin/` (on PATH) — NO `setup:`
  provisioning block, no install race (like trivy/jbinspect). The fixture repo is
  copied per-trial into a hermetic, non-git working dir.

## Canonical hash (the 3-tuple set)

Canonical hash `a7ab17fce010e2343880022e7e180f5036f02930a041370cef4dcebeae27fb5a`,
the parsed tuple set:

```json
[{"file":".github/workflows/ci.yml","line":5,"rule_id":"housekeeper/runner","severity":"Suggestion","confidence":100},
 {"file":".github/workflows/ci.yml","line":7,"rule_id":"housekeeper/github-actions","severity":"Suggestion","confidence":100},
 {"file":"package.json","line":4,"rule_id":"housekeeper/npm","severity":"Suggestion","confidence":100}]
```

The hash keys only on `file/line/rule_id/severity/confidence` — the version text
in the rendered Description (e.g. "latest GA is v6.0.3") is intentionally NOT
hashed, so the per-trial hash is **drift-proof**: the sweep stays stable as new
upstream releases ship. (At sweep time the live values were checkout `v6.0.3`,
react `19.2.7`; these will move, the hash will not.)

The hash matches the Task-14 gated re-capture baseline exactly — confirmed at
n=20 on both arms, not carried from a single trial.

## Hash distribution

| Arm | canonical `a7ab17fc…` | other | skipped/INCONCLUSIVE | NORMAL rate |
|---|---|---|---|---|
| **Sonnet/default** | **20 / 20** | 0 | 0 | **100 %** |
| **Haiku/low** | **20 / 20** | 0 | 0 | **100 %** |

Every trial in both arms: `findings_count == 3`, canonical hash,
`first_finding_rule == housekeeper/runner`, `exit_code 0`, `inconclusive false`,
`timed_out false`. No divergence to characterise — the haiku arm is as
deterministic as the sonnet arm. This is the first static-specialist sweep in the
programme to come back clean on the first fix-validated pass with zero tail.

## Cost delta

Per-trial cost columns from the stream `result` envelope.

| Arm | n | mean cost/trial* | mean turns | mean out tok | mean cache-read tok | mean wall |
|---|---|---|---|---|---|---|
| Sonnet/default | 20 | **$0.13507** | 9.70 | 1,556 | 235,891 | 33 s |
| Haiku/low | 20 | **$0.05683** | 9.90 | 1,893 | 210,546 | 27 s |

**Cost ratio Sonnet ÷ Haiku = 2.38×.**

> **\* List-price caveat (load-bearing).** The CC stream's `total_cost_usd` is
> computed at **Anthropic list prices, not Bedrock**. Treat the absolute dollars
> as indicative of the **ratio**, not the actual Bedrock bill. The 2.38× ratio is
> the reportable figure; it sits in family with trivy 2.34×, eslint 2.17×, ruff
> ~2.2× — the price-tier saving is stable across all five static specialists.

Consistent with the programme finding: cost is dominated by turns × cached
context, not output tokens. Haiku's mean output (1,893) is *higher* than Sonnet's
(1,556), yet it costs 2.38× less — the lever is the price tier, not verbosity.
Turn counts are near-identical (9.70 vs 9.90), confirming Haiku follows the same
multi-step procedure (tool checks → temp-file writes → engine run → render)
without extra flailing.

## Live-registry note

Unlike the unittest `EndToEndTest` (which injects `HOUSEKEEPER_REGISTRY_FIXTURES`
via `subprocess.run(env=)` and is deterministic against recorded JSON), the A/B
harness scrubs the subagent's environment (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`),
so the dispatched engine ran in **live** mode against the real npm + GitHub APIs.
The sweep was still 20/20 stable because (a) the fixture's pins are
unambiguously stale (v3 ≪ latest-major, ubuntu-22.04 < 24.04 via the engine's
internal table, react 18.2.0 < 19.x), and (b) the findings hash drops the version
text. The `registry_fixtures:` key in the corpus `source.yaml` is therefore an
inert forward-marker, documented as such. Engine determinism *under fixtures* is
independently guaranteed by the unittest suite.

## Cache-staleness incident (process learning)

The first gated capture returned `[]` (zero findings) — NOT an agent, engine,
parser, or worked-example defect. Root cause: the A/B harness dispatches the agent
**body** from the working tree, but the engine binary resolves on PATH from the
**plugin cache**, which was pinned to commit `235a1e48` — the Task-1 stubbed
chassis whose `collect_findings` returns `[]` unconditionally. `/plugins update` +
`/reload-plugins` refreshed the cache to `846b8be25c9d` (full engine, all three
`collect_*` wired), after which the re-capture produced the clean 3-finding set.
Lesson (reinforces [[project_plugin_cache_staleness]] /
[[feedback_plugins_update_after_push]]): when an A/B specialist depends on a `bin/`
tool changed mid-session, refresh the plugin cache before capture — the working
tree drives the agent prose, the cache drives the executable.

## General correctness fix shipped during Task 14

The first capture also exposed a real gap: the housekeeper agent built its
changed-file list with `git diff --name-only`, which yields nothing in the
harness's non-git copied sandbox → empty list → engine `[]`. Fix (`846b8be`): the
agent now falls back to deriving the changed-file list from the `Changed lines:`
block (always present in the prompt) when `git diff` returns nothing. This is a
**general correctness improvement** — it helps any non-git or empty-base review
sandbox, sonnet and haiku alike — not fixture-chasing. It is the housekeeper's
only departure from the other static specialists' file-list resolution, made
necessary because it is the only one that feeds the engine a file written to disk.

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

The agent already ships `model: haiku` + `effort: low` (the user's up-front call,
recorded against the suite's sonnet-then-flip discipline). On a clean EQUIVALENT,
**no frontmatter change is needed — this result VALIDATES the shipped tier.** The
sonnet fallback (the documented mitigation had equivalence failed) is not invoked.

This closes vertical slice 1 of the housekeeper specialist. Follow-on plans add
further source classes (NuGet/PyPI/crates/Go/RubyGems/Docker base images,
framework/SDK/runtime versions) on the same chassis; each adds a parser + fixtures
+ a cookbook row and is independently testable. The maintenance-health axis
(archived/deprecated/abandoned deps) was surfaced in a parallel design session and
recorded as an own-or-defer line in the design spec's Open items (default: defer).

## Cross-references

- Tuning framework: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- trivy precedent (equivalent after fix): ./2026-06-03-trivy-haiku-low-result.md
- Plugin-cache staleness: memory `project_plugin_cache_staleness.md`,
  `feedback_plugins_update_after_push.md`
