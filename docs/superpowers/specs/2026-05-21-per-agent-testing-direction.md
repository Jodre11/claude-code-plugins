# Per-agent A/B testing — direction for Phase 2

> **Status:** Direction-setting spec. Not a plan. Promote to a design
> doc + plan when the team commits to the work.
>
> **Surfaced by:** Phase 1 ultrathink experiment, 2026-05-21. The
> end-to-end suite trial cost (~3 hours of wall-clock + ~5M tokens for
> 6 trials) and signal-to-noise ratio (verdict flips on identical
> input) made it clear that whole-suite A/B is the wrong shape for
> agent-level tuning.

## The problem with end-to-end A/B

The Phase 1 harness measures the suite as a black box. To answer "should
the synthesiser use opus or sonnet?" requires a full trial: 8 specialists
+ 8 cross-reviewers + synthesiser + orchestrator. That trial pays for:

- ~800K tokens of Bedrock cost.
- 17-25 minutes of wall-clock.
- 16 layers of upstream stochasticity that the synthesiser-tuning
  question doesn't care about.
- One data point.

Three trials per arm produces a sample size too small to call any
delta meaningful (Phase 1's 11.7% wall-clock arm-mean delta is buried
in 35% intra-arm spread). To get statistical confidence at the
end-to-end level you'd need n≥10 per arm and probably n≥30. That's
hours of wall-clock and millions of tokens per agent-tuning question.

## The problem with naïvely-scaled per-agent testing

A naïve per-agent harness would invent synthetic specialist outputs,
feed them to the synthesiser, and tune. Risk: the synthesiser tunes
to the synthetic distribution, not the real one. Production behaviour
diverges from test behaviour.

## The solution

Use **real captured artefacts** as fixed inputs:

1. **End-to-end harness collects fixtures.** Every Phase 1 trial that
   ran end-to-end leaves a `CLAUDE_TEMP_DIR` with real
   `all-findings.md` and `all-cross-opinions.md` files. The harness
   should preserve these alongside the per-trial artefacts in
   `tests/ab/runs/<run>/trial-NNN/inputs/` so they survive past OS
   cleanup of `/tmp`.
2. **Per-agent harness consumes fixtures.** A new sub-harness mode
   (`tests/ab/run.sh --agent <name> --fixture <path>`) launches just
   one agent against fixed inputs, captures just that agent's output,
   measures just that agent's metrics.
3. **Layered tuning.** Tune specialists first against fixed diffs.
   Once specialists are stable, freeze them and tune cross-reviewers
   against fixed specialist findings. Once cross-reviewers are stable,
   freeze them and tune the synthesiser against fixed
   findings + opinions.

## What the harness already provides

Per-agent mode is mostly a config-schema change plus a
"feed inputs from file" wrapper around existing primitives:

- `lib/mutate.sh` already knows how to rewrite agent frontmatter
  (`mutate_set_agent_model`).
- `lib/launch.sh` already knows how to dispatch a `claude -p` session
  with a custom prompt.
- `lib/capture.sh` already knows how to extract structured artefacts
  from stdout.
- `lib/config.sh`'s schema already supports per-agent `model:` and
  `ultrathink:` fields.

What's missing:

- **Fixture preservation.** Phase 1 leaves
  `all-findings.md` / `all-cross-opinions.md` in `/tmp/claude-<uuid>/`,
  which OS reboots clean up. Phase 2 should copy them into the trial
  output directory.
- **Per-agent dispatch wrapper.** A new helper that constructs the
  agent's input prompt from a fixture file and invokes the agent in
  isolation rather than going through the orchestrator.
- **Agent-isolated launch.** Currently `launch.sh` invokes
  `claude -p /review-gh-pr <url>` which runs the whole orchestrator.
  Per-agent mode needs to invoke a single agent's prompt directly,
  bypassing the orchestrator and the upstream pipeline.
- **Output schema.** The synthesiser's output is structured (verdict,
  rubric row, findings); other agents' outputs are findings lists with
  confidence scores. Per-agent capture needs an agent-specific parser.

## Open design questions

1. **How does a per-agent dispatch get the agent's full system prompt?**
   The agent files in `plugins/code-review-suite/agents/*.md` contain
   YAML frontmatter + body. The orchestrator currently dispatches them
   via `Agent({subagent_type: ...})`. A direct `claude -p` invocation
   needs to either reconstruct the prompt or use an MCP/tool dispatch
   path that respects the same agent definition.
2. **Should we test agents individually or in pairs?** Specialists vs
   cross-reviewers is a natural split, but cross-reviewers depend on
   specialist output shape; if we tune specialists in isolation, we
   may produce outputs the cross-reviewers don't handle well.
3. **What's the corpus shape?** Phase 1 hard-codes one corpus PR. Phase
   2 should support multiple PRs with a corpus YAML
   (already deferred from Phase 1). For per-agent mode, the corpus is
   per-agent fixtures (real captured outputs), not PR URLs.
4. **How do we handle fixture decay?** Real captured outputs reflect a
   specific commit of the upstream agents. When upstream agents change,
   the fixtures may not match the new agents' output distribution. Need
   a refresh-fixtures workflow.

## What "per-agent harness" specifically means

Concrete operations the new harness mode would support:

- `--agent review-synthesiser --fixture-dir <path>`: run just the
  synthesiser on a captured (findings, opinions) pair.
- `--agent <specialist> --diff <patch>`: run just one specialist on a
  fixed diff.
- `--corpus <yaml>`: replace Phase 1's hard-coded PR URL with a list of
  fixture-paths.
- Multi-trial sweep without revert overhead: fixed inputs mean no
  in-tree mutation is needed for testing-purpose model swaps; just
  pass a different `--model` per trial.

## Cross-references

- Phase 1 harness spec:
  [`2026-05-21-ab-test-harness-design.md`](2026-05-21-ab-test-harness-design.md)
- Phase 1 conclusion (motivation for the pivot):
  `${CLAUDE_TEMP_DIR}/ultrathink-experiment-conclusion.md`
- Verdict-stability follow-up (a question per-agent testing should
  answer cheaply):
  [`2026-05-21-rubric-row-stability-followup.md`](2026-05-21-rubric-row-stability-followup.md)
- Empty-stdout anomaly (per-agent testing would NOT catch this — it's
  an orchestrator concern, retains a role for end-to-end smoke):
  [`2026-05-21-orchestrator-empty-stdout-anomaly.md`](2026-05-21-orchestrator-empty-stdout-anomaly.md)
