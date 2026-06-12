# Housekeeper-reviewer Docker Haiku/low A/B result (vertical slice 3)

**Date:** 2026-06-12 (sweep executed; slice planned/built 2026-06-11)
**Status:** EQUIVALENT (clean — single-arm 20/20 single-hash, zero divergence)
**Design:** ../specs/2026-06-11-housekeeper-docker-slice-design.md
**Plan:** ../plans/2026-06-11-housekeeper-docker-slice.md
**Tuning framework:** ../specs/2026-05-29-static-specialist-tuning-sweep.md
**Slice-2 result (precedent, equivalent):** ./2026-06-05-housekeeper-nuget-haiku-low-result.md
**Probe (haiku/low) run dir:** `tests/ab/runs/20260612T070532Z-housekeeper-docker-haiku-low/` (gitignored)
**Sweep SHA:** `a981b0a` (cache refreshed via `/plugins update` + `/reload-plugins` before the sweep — pre-flight clean, no cache-staleness incident this slice)

## Headline

The Docker base-image source class returned a **perfectly clean EQUIVALENT on the
first sweep**: Haiku/low landed **20/20 on the identical canonical hash**
(`ec6b1016…`), with no within-arm non-determinism, no skips, no fabrications, no
timeouts. The faithfulness check passed 20/20 against the recorded oracle. The
shipped `model: haiku` + `effort: low` tier is validated for the docker source
class; the sonnet fallback is not needed.

## Single-arm rationale (design §9)

Unlike slices 1–2 (two-arm sonnet-vs-haiku), this slice ran a **single-arm**
haiku/low 20/20 sweep. The chassis-equivalence question is settled — slices 1 and
2 both returned EQUIVALENT 20/20, and the docker renderer is a thin §7 projection
over the same agent prompt. The single-arm sweep therefore guards **apparatus
determinism** (empty-stdout, format drift, temp-dir self-abort, install race),
not the model tier. Sonnet remains the documented fallback only if a tail
appeared — it did not.

## Sweep configuration

- Codepath: per-agent harness, `--faithfulness-check --stream-json`.
- Specialist: `housekeeper-reviewer`. Corpus: `housekeeper-docker-stale-base` — a
  synthetic Dockerfile (`FROM node:18.20.0-alpine`) pulled into scope **via Anchor
  A** by a `.cs`-only changeset (`src/Api/Program.cs:1`), with NO Dockerfile in
  the diff. One deterministic Suggestion finding.
- Engine: `bin/housekeeper-freshness` (stdlib Python). Docker source class
  exercised: OCI Distribution v2 `tags/list` fetch (live — the A/B harness scrubs
  subprocess env, so `HOUSEKEEPER_REGISTRY_FIXTURES` is NOT injected and the
  engine hits the real registry; see "Live-registry note").
- Arm: Haiku/low (`housekeeper-docker-haiku-low.yaml`), n=20. No sonnet baseline.
- Apparatus: the engine ships in the plugin `bin/` (on PATH) — NO `setup:`
  provisioning block, no install race. The fixture repo is copied per-trial into a
  hermetic, non-git working dir; the agent's `Changed lines:`-block fallback
  supplies the file list.

## Canonical hash (the 1-tuple set)

Canonical hash `ec6b1016e8830eb29233585116e5faacb187f42376be10c0f99ec48d9d3997ab`,
the parsed tuple set:

```json
[{"file":"src/Api/Dockerfile","line":1,"rule_id":"housekeeper/docker","severity":"Suggestion","confidence":100}]
```

The finding cites `src/Api/Dockerfile:1` even though only `src/Api/Program.cs`
changed — Anchor A pulls the Dockerfile in because its directory is the resolved
.NET unit's directory (`src/Api/Api.csproj`). The hash keys only on
`file/line/rule_id/severity/confidence`; the version text in the rendered
Description ("latest GA is 22.3.0") and the Suggested-fix target ("Upgrade node to
18.20.4" — nearest-in-major, since the Dockerfile line is untouched) are
intentionally NOT hashed, so the per-trial hash is **drift-proof**.

## Hash distribution

| Arm | canonical `ec6b1016…` | other | skipped/INCONCLUSIVE | NORMAL rate |
|---|---|---|---|---|
| **Haiku/low** | **20 / 20** | 0 | 0 | **100 %** |

Every trial: `findings_count == 1`, canonical hash,
`first_finding_rule == housekeeper/docker`, `exit_code 0`, `inconclusive false`,
`timed_out false`. No divergence to characterise — the haiku arm is fully
deterministic. Like slices 1–2, clean on the first pass with zero tail.

## Cost

Per-trial figures from the stream `result` envelope's `total_cost_usd`.

| Arm | n | mean cost/trial* | total cost* | mean out tok | mean wall |
|---|---|---|---|---|---|
| Haiku/low | 20 | **$0.0798** | $1.5965 | 2,058 | 33 s |

> **\* List-price caveat (load-bearing).** The CC stream's `total_cost_usd` is
> computed at **Anthropic list prices, not Bedrock**. Treat the absolute dollars
> as indicative only. No sonnet arm was run this slice, so no fresh cost ratio is
> computed; the established family (slice-1 housekeeper 2.38×, slice-2 NuGet
> 2.06×, trivy 2.34×, eslint 2.17×, jbinspect 1.89×) is unchanged. The per-trial
> haiku cost ($0.0798) sits in family with the slice-2 haiku arm ($0.07244).

## Live-registry note

The A/B harness scrubs the subagent's environment
(`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`), so the dispatched engine ran in **live**
mode against the real registry — `HOUSEKEEPER_REGISTRY_FIXTURES` is an inert
forward-marker in the corpus `source.yaml`. Engine determinism *under fixtures* is
independently guaranteed by the unittest `DockerEndToEndTest`. The corpus base
image (`node:18.20.0-alpine`) is genuinely stale live (Node 18 is several majors
behind), so the live `tags/list` reliably yields a higher GA in the alpine
lineage — keeping the live finding consistent with the recorded oracle. This is
the live-honesty discipline from slice 2's `WindowsAzure.Storage` lesson applied
pre-emptively.

## Pre-flight (clean this slice)

Plugin-cache pre-flight was honoured: `/plugins update` + `/reload-plugins`
refreshed the cache before the sweep. Separately, a gap was caught and fixed
before the sweep could run — the slice-3 corpus directory shipped WITHOUT its
`tests/ab/corpus/index.yaml` entry, and the per-agent harness gates `fixture_load`
on the index (no glob discovery), so the sweep would have failed preflight.
Registered the corpus (`a981b0a`) before launching. Reinforces
[[project_plugin_cache_staleness]] / [[feedback_plugins_update_after_push]] and
adds a new lesson: **a new A/B corpus needs an index.yaml row, not just a corpus
directory** — the plan omitted this step.

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

The agent already ships `model: haiku` + `effort: low` (validated for slices 1–2;
the tier is shared across all source classes). On a clean EQUIVALENT, **no
frontmatter change is needed — this result VALIDATES the shipped tier for the new
docker source class.** The sonnet fallback is not invoked.

This closes vertical slice 3 of the housekeeper specialist (Docker base-image
tags). Follow-on slices add further ecosystems (PyPI next, then Go modules — the
user's stated order) on the same chassis; each adds a parser + scope-suffix set +
cookbook row + recorded-registry fixtures + a single-arm haiku sweep, extending
the engine scope set AND the Step 2.6 trigger prose in lockstep. ECR Public,
docker-compose, `Containerfile`, and the docker maintenance-health axis remain
deferred (design §10).

## Cross-references

- Slice-2 result (precedent): ./2026-06-05-housekeeper-nuget-haiku-low-result.md
- Slice-1 result: ./2026-06-05-housekeeper-haiku-low-result.md
- Tuning framework: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Plugin-cache staleness: memory `project_plugin_cache_staleness.md`,
  `feedback_plugins_update_after_push.md`
