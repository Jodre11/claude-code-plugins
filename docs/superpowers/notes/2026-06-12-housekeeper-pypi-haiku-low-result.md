# Housekeeper-reviewer PyPI Haiku/low A/B result (vertical slice 4)

**Date:** 2026-06-12 (sweep executed; slice planned/built same day)
**Status:** EQUIVALENT (clean — single-arm 20/20 single-hash, zero divergence)
**Design:** ../specs/2026-06-12-housekeeper-pypi-slice-design.md
**Plan:** ../plans/2026-06-12-housekeeper-pypi-slice.md
**Tuning framework:** ../specs/2026-05-29-static-specialist-tuning-sweep.md
**Slice-3 result (precedent, equivalent):** ./2026-06-12-housekeeper-docker-haiku-low-result.md
**Probe (haiku/low) run dir:** `tests/ab/runs/20260612T103926Z-housekeeper-pypi-haiku-low/` (gitignored)
**Sweep SHA:** `570710c` (cache refreshed via `/plugins update` + `/reload-plugins` before the sweep — pre-flight clean, no cache-staleness incident this slice)

## Headline

The PyPI source class returned a **perfectly clean EQUIVALENT on the first
sweep**: Haiku/low landed **20/20 on the identical canonical hash**
(`63c72cb5…`), with no within-arm non-determinism, no skips, no fabrications, no
timeouts. The faithfulness check passed 20/20 against the recorded oracle. The
shipped `model: haiku` + `effort: low` tier is validated for the PyPI source
class; the sonnet fallback is not needed.

## Single-arm rationale (design §9.4)

Like slice 3, this slice ran a **single-arm** haiku/low 20/20 sweep. The
chassis-equivalence question is settled — slices 1–3 all returned EQUIVALENT
20/20, and the PyPI renderer is a thin §7 projection over the same agent prompt.
The single-arm sweep therefore guards **apparatus determinism** (empty-stdout,
format drift, temp-dir self-abort, install race, fixture round-trip), not the
model tier. Sonnet remains the documented fallback only if a tail appeared — it
did not.

## Sweep configuration

- Codepath: per-agent harness, `--faithfulness-check --stream-json`.
- Specialist: `housekeeper-reviewer`. Corpus: `housekeeper-pypi-stale-deps` — a
  synthetic `pyproject.toml` pulled into scope **via Anchor scope** by a
  `.py`-only changeset (`pkg/app/module.py:1`), with NO manifest in the diff. Two
  deterministic Suggestion findings: `requests==2.20.0` stale (untouched line →
  nearest-in-major `2.31.0`) and `urllib3==2.0.0` stale-and-yanked (yanked health
  rider; "Truncated response bodies when streaming a large compressed body").
- Engine: `bin/housekeeper-freshness` (stdlib Python; PyPI parsing needs
  `tomllib`, 3.11+). PyPI source class exercised: PyPI JSON API
  `https://pypi.org/pypi/<project>/json` fetch (live — the A/B harness scrubs
  subprocess env, so `HOUSEKEEPER_REGISTRY_FIXTURES` is NOT injected and the
  engine hits real pypi.org; see "Live-registry note").
- Arm: Haiku/low (`housekeeper-pypi-haiku-low.yaml`), n=20. No sonnet baseline.
- Apparatus: the engine ships in the plugin `bin/` (on PATH) — NO `setup:`
  provisioning block, no install race. The fixture repo is copied per-trial into
  a hermetic, non-git working dir; the agent's `Changed lines:`-block fallback
  supplies the file list.

## Canonical hash (the 2-tuple set)

Canonical hash `63c72cb57d68d22462bc74cfef47e1fcd1f525198ad9de948a4860ada5fb642c`,
the parsed tuple set:

```json
[{"file":"pkg/app/pyproject.toml","line":5,"rule_id":"housekeeper/pypi","severity":"Suggestion","confidence":100},{"file":"pkg/app/pyproject.toml","line":6,"rule_id":"housekeeper/pypi","severity":"Suggestion","confidence":100}]
```

Both findings cite `pkg/app/pyproject.toml` even though only `pkg/app/module.py`
changed — Anchor scope pulls the `pyproject.toml` in because it is the
nearest-ancestor manifest of the changed `.py`. The hash keys only on
`file/line/rule_id/severity/confidence`; the version text in the rendered
Description ("latest GA is 2.31.0" / "2.2.1") and the Suggested-fix targets
(nearest-in-major, since both manifest lines are untouched) are intentionally NOT
hashed, so the per-trial hash is **drift-proof**. The `urllib3` finding exercises
the yanked health rider: stale AND yanked, so it renders the upgrade fix form
with the appended "Marked yanked in the registry: …" clause.

## Hash distribution

| Arm | canonical `63c72cb5…` | other | skipped/INCONCLUSIVE | NORMAL rate |
|---|---|---|---|---|
| **Haiku/low** | **20 / 20** | 0 | 0 | **100 %** |

Every trial: `findings_count == 2`, canonical hash,
`first_finding_rule == housekeeper/pypi`, `exit_code 0`, `inconclusive false`,
`timed_out false`. No divergence to characterise — the haiku arm is fully
deterministic. Like slices 1–3, clean on the first pass with zero tail.

## Cost

Per-trial figures from the stream `result` envelope's `total_cost_usd`.

| Arm | n | mean cost/trial* | total cost* | mean out tok | mean wall |
|---|---|---|---|---|---|
| Haiku/low | 20 | **$0.0810** | $1.6200 | 2,124 | 30 s |

> **\* List-price caveat (load-bearing).** The CC stream's `total_cost_usd` is
> computed at **Anthropic list prices, not Bedrock**. Treat the absolute dollars
> as indicative only. No sonnet arm was run this slice, so no fresh cost ratio is
> computed; the established family (slice-1 housekeeper 2.38×, slice-2 NuGet
> 2.06×, trivy 2.34×, eslint 2.17×, jbinspect 1.89×) is unchanged. The per-trial
> haiku cost ($0.0810) sits in family with slices 2–3 ($0.0724 / $0.0798).

## Live-registry note

The A/B harness scrubs the subagent's environment
(`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`), so the dispatched engine ran in **live**
mode against real pypi.org — `HOUSEKEEPER_REGISTRY_FIXTURES` is an inert
forward-marker in the corpus `source.yaml`. Engine determinism *under fixtures*
is independently guaranteed by the unittest `PyPIOnDiskFixtureTest`. The corpus
pins are genuinely behind/yanked live: `requests==2.20.0` is many minors behind
(live latest GA 2.34.2 at sweep time), and `urllib3==2.0.0` is **genuinely
yanked** on live pypi.org (reason: truncated response bodies). Because the
RECORDED FIXTURE is the oracle, the sweep is deterministic regardless of live
drift — but the live-honesty discipline (slice-2 `WindowsAzure.Storage` lesson)
is preserved so a future live run stays consistent with the recorded findings.

> **Live-drift correction this slice.** The plan/spec originally specified
> `urllib3==2.0.6` (yanked for CVE-2023-45803). The Task-14 live spot-check found
> 2.0.6 had been **un-yanked** on pypi.org since the spec was written. Swapped the
> corpus pin to `urllib3==2.0.0` (genuinely yanked) and updated the fixture
> pyproject, registry JSON, expected findings, source.yaml intent ledger, and the
> agent worked-example block in lockstep (`570710c`). This is exactly the
> "re-verify the live spot-check before sweeping; if a pin is no longer
> behind/yanked, update the corpus + expected files in lockstep" contingency the
> handover anticipated.

## Pre-flight (clean this slice)

Plugin-cache pre-flight was honoured: `/plugins update` + `/reload-plugins`
refreshed the cache before the sweep. The corpus `index.yaml` row was added as an
explicit plan step this slice (Task 13) — the slice-3 near-miss (corpus shipped
without its index row) did not recur. Reinforces
[[project_plugin_cache_staleness]] / [[feedback_plugins_update_after_push]].

## Verdict (framework verbatim)

- **EQUIVALENT** — Haiku matches the canonical hash within noise (clean,
  single-hash arm).
- **INCONCLUSIVE (decision-4)** — mixed within-arm hashes default to inconclusive
  regardless of rate.
- **WORSE** — >25 % NORMAL-rate drop.

**EQUIVALENT (clean).** Haiku/low produced 20/20 identical canonical hash, no
within-arm non-determinism, no skips, no fabrications, faithfulness-check 20/20
against the oracle. Clears the EQUIVALENT bar with zero movement against the 25 %
guard and no tail to characterise.

## Production-flip decision

The agent already ships `model: haiku` + `effort: low` (validated for slices 1–3;
the tier is shared across all source classes). On a clean EQUIVALENT, **no
frontmatter change is needed — this result VALIDATES the shipped tier for the new
PyPI source class.** The sonnet fallback is not invoked.

This closes vertical slice 4 of the housekeeper specialist (PyPI). Follow-on:
**Go modules** next (the user's stated order) on the same chassis — its own
brainstorm → spec → plan → implement cycle (parse `go.mod`; proxy
`https://proxy.golang.org/<module>/@v/list`; Go's `vN+` major-suffix import-path
convention is the analogue of the Docker variant wrinkle). Licence-diff remains a
deferred cross-source follow-on (design §5.5); `setup.cfg`/`setup.py`/`Pipfile`
and `-r` nested-include resolution remain out (design §12).

## Cross-references

- Slice-3 result (precedent): ./2026-06-12-housekeeper-docker-haiku-low-result.md
- Slice-2 result: ./2026-06-05-housekeeper-nuget-haiku-low-result.md
- Slice-1 result: ./2026-06-05-housekeeper-haiku-low-result.md
- Tuning framework: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Plugin-cache staleness: memory `project_plugin_cache_staleness.md`,
  `feedback_plugins_update_after_push.md`
- Diff-is-selector principle: memory
  `feedback_housekeeper_diff_is_selector_not_filter.md`
