# Code-review orchestrator → Workflow migration — design

> **Status:** Design doc. Promotes the direction-setting
> [`2026-06-11-orchestrator-as-workflow-direction.md`](2026-06-11-orchestrator-as-workflow-direction.md)
> to a design + (next) plan. The Phase 3 static-specialist tuning sweep is
> complete (all 5 static specialists flipped to haiku + effort:low; housekeeper
> subagent Bash-failure fix validated 2026-06-13), so this work is **unblocked**.
>
> **Scope owner:** maintainer. **Date:** 2026-06-13.

---

## 1. Problem & motivation

The code-review suite's orchestration is a **markdown procedure**
(`includes/review-pipeline.md`, ~1185 lines, inlined verbatim into both
`commands/pre-review.md` and `skills/review-gh-pr/SKILL.md`). A main-loop LLM
interprets it: dispatch 8 core + up to 6 conditional specialists → collect →
cross-review → opus synthesis → post. Two recurring failure classes follow from
"orchestrator is an agent following prose":

1. **Specialist dropping.** The model has historically dispatched a subset of
   specialists and fabricated justification (commit `eb0bbda`, 2026-05). The
   pipeline fights this with a `MANDATORY DISPATCH CONSTRAINT` block, an explicit
   per-agent dispatch enumeration, a post-dispatch self-check (Step 4.3), and the
   deliberate inlining hack (an agent reliably skips file-path references,
   rationalising it "knows" the content — PR #10 incident, 2026-05-05).
2. **Idle-time drift.** On a live `review-gh-pr` run (PR #77, 2026-06-11) the
   orchestrator re-read every changed file during background waits and
   re-derived the reconciliation table — acting as a reviewer when its role is
   deterministic execution, violating the authority model in
   [`2026-05-14-verdict-rubric-and-orchestrator-scope-design.md`](2026-05-14-verdict-rubric-and-orchestrator-scope-design.md).
   Unexamined drift, not deliberate override — exactly the class structure
   prevents.

Separately, the **A/B test harness** (`tests/ab/lib/agent_capture.sh`) is the
*only* mechanical markdown→data parser of finding **content** in the system. It
is a per-static-specialist state machine (ruff / eslint / trivy / jbinspect /
housekeeper) and has been the entire source of the §7 / worked-example /
tokeniser / zero-tuple fragility this programme repeatedly patched. The
production path has no equivalent content parser — the opus synthesiser reads
specialist markdown *as prose*.

**Primary goal (ranked #1 by the maintainer): deterministic orchestration.**
A `parallel([...specialists])` in a script dispatches every specialist *by
construction* — no agent exists to drop one or improvise during idle time. This
also lets us retire the inlining hack and return to a single referenced core.

**Secondary goal (the memory's "real prize"): retire the A/B markdown parser**
via schema-validated specialist output.

These two changes are **complementary** under the deterministic-orchestration
lens: a uniform finding schema makes the collect → cross-review → synthesise
hand-offs structured-data passing instead of string concatenation, which *is*
part of the determinism story.

---

## 2. Decisions (locked during brainstorming)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Approach A — core-only deterministic Workflow.** Host keeps the interactive + git/gh envelope; the Workflow owns dispatch → cross-review → synthesis. | The "dropped specialists / idle drift" failure lives exactly in the orchestration phase; making *that* deterministic retires the #1 goal. Interactive stdin + git/gh + posting cannot run in a headless JS sandbox, so they must stay in the host. |
| D2 | **Schema all specialists** (8 core + UI + 5 static + synthesiser), not static-only. | Under the determinism goal, uniform structured findings make every hand-off data-passing. Static-only would suffice to kill the parser, but schema-everything is complementary, not wasteful, here. |
| D3 | **Synthesiser keeps prose judgement in a structured envelope.** `report` / comment bodies remain free-text markdown fields; the schema structures only the envelope (verdict enum, tiers, rendered comments). | The synthesiser still runs the §10 confidence-dissent arithmetic, reclassifies severity, tiers by judgement. Schema is a wrapper, not a flattening. |
| D4 | **Sealed bundle contract** (from the direction spec). `review-core` renders comment bodies **and applies the Class D confidence filter in code**, returning `{verdict, bodyText, comments:[{path,line,side,body}]}`. Callers can only *post* it, never reshape. | Directly closes the PR #77 dilution surface: a caller that can re-render or re-filter has leaked the boundary. |
| D5 | **Decomposition: `review-core` + interactive path now; `review-auto` later.** | Builds the deterministic core + the human-gated path this migration needs. `review-auto` (headless) is deferred to the PR-CI automation item it unblocks — don't build the headless wrapper until that work starts. |
| D6 | **Interactive path is the existing markdown host/main-loop, not a background workflow.** It calls `workflow('review-core')`, receives the bundle, runs the human gate, then posts deterministically. | Workflows run in the background and cannot do a mid-run `AskUserQuestion` (direction-spec open-question 4). The gate must live in the main-loop relay. |
| D7 | **Parallel-run then retire**, across 5 staged phases. Nothing irreversible until the new path has a track record. | Both scoping memories flag the `agent()` schema API as undocumented / server-gated — assume it can break in a CLI release. |
| D8 | **Finding schema lives in the plugin** (`plugins/code-review-suite/includes/finding-schema.json`); the Workflow script references it; the harness reads the same file. | Co-located with the agents that must honour it; respects the plugin-subtree copy rule. |
| D9 | **Harness schema mechanism deferred to a Phase 0 spike.** | The Workflow enforces schema via the `agent()` `schema` param, but the harness launches `command claude -p` directly (no `agent()` wrapper). Whether a CLI structured-output flag exists is unverified — Phase 0 decides. |
| D10 | **Parallel-run comparison is manual / ad hoc**, recorded in a handover memory. | Matches how the Phase 3 tuning sweeps were assessed; the maintainer reviews PRs continuously, so side-by-side is organic. A structured parity harness is heavier than the win warrants. |
| D11 | **Decided failure modes** (from the direction spec): human gate is *before* posting; human walk-away → **cancel** (not submit-as-proposed); auto-mode posting failure → fail loud. | Unattended silence must not ship a `REQUEST_CHANGES`. (Auto-mode is deferred per D5 but the contract is recorded.) |

---

## 3. Architecture — the seam

```
┌─ INTERACTIVE HOST (markdown, main-loop model — stdin, git/gh) ────────┐
│  Phase 0    intent ledger (incl. 0.4 interactive paste)               │
│  Phase 0.55 local branch freshness   ┐                                │
│  Phase 0.6  CI status gate           │ git/gh + may halt              │
│  Phase 0.7  trivial-mode (incl. 0.7.8 y/N + 0.7.9 gh post)            │
│  Step 1-2   base / diff / CHANGED_LINES / detection flags  (git)      │
│  Step 3     route: lightweight vs full                                │
│        │                                                               │
│        ▼  resolves $AGENT_PROMPT + flags + temp dir, then:            │
│   ┌── workflow('review-core', args) ── DETERMINISTIC CORE ─────────┐  │
│   │  phase 'dispatch'  parallel() over a FIXED specialist list;    │  │
│   │                    each agent() carries FINDINGS schema        │  │
│   │  phase 'cross'     parallel() cross-review (schema'd opinions); │  │
│   │                    static-analysis findings passed as data,    │  │
│   │                    excluded from receiving cross-review        │  │
│   │  phase 'synth'     agent(opus, SYNTH schema) → verdict + tiers │  │
│   │                    + prose report                              │  │
│   │  code              render comment bodies; apply Class D filter │  │
│   │  RETURNS sealed bundle:                                         │  │
│   │    { verdict, bodyText, comments:[{path,line,side,body}] }     │  │
│   └────────────────────────────────────────────────────────────────┘ │
│        │                                                               │
│        ▼                                                               │
│  Step 7   render bodyText; PR-mode: y/N gate → deterministic gh post   │
│           (walk-away → cancel; verdict-level override only)            │
└───────────────────────────────────────────────────────────────────────┘
```

**Why the seam sits here.** Everything *above* the core needs interactive stdin
(0.4 paste, 0.7.8 confirm), runs `git`/`gh` (freshness, CI gate, diff, posting),
or both — none possible in a headless JS sandbox. Everything *inside* is pure
orchestration: the phase where the failures live. The host stays markdown
(it must, to read stdin and shell out) but shrinks to an envelope.

**Lightweight path** (Step 3) calls the same `review-core` with a single-element
specialist list (`code-analysis`) and no cross/synth phases — **one** core code
path, not two.

**Sealed-bundle boundary.** The core has *no posting code and no human-relay
code*, so it physically cannot reshape or drop findings on its own initiative.
The Class D confidence filter and comment rendering happen **inside** the core,
in code — the host receives something it can only post.

---

## 4. Components

| # | Unit | Path | Does | Interface |
|---|---|---|---|---|
| 1 | **Workflow script** | `plugins/code-review-suite/workflows/review-core.mjs` (placement pending plugin-subtree import check — see §8 risks) | Deterministic core: `parallel()` fan-out, `parallel()` cross-review, `agent()` synthesis, in-code Class D filter + comment rendering | `args` in (see below); returns sealed bundle |
| 2 | **Finding schema** | `plugins/code-review-suite/includes/finding-schema.json` | Single source of truth: one-finding schema `{file,line,rule_id?,severity,confidence,description,suggested_fix,reference?}`; synth-envelope schema `{verdict,rubricRowApplied,tiers,bodyText,comments[]}` | Imported by the script; read by the harness validator |
| 3 | **Interactive host** | `commands/pre-review.md`, `skills/review-gh-pr/SKILL.md` | Phases 0–3 unchanged; Steps 4–6 replaced by `workflow('review-core')`; Step 7 consumes the bundle (no markdown regex) | Behind a parallel-run flag (§5) |
| 4 | **Agent definitions** | `agents/*.md` | Output contract: "emit this markdown shape" → "populate these structured fields". §7 worked-example content migrates into field descriptions. Synthesiser keeps rubric / §10 prose, emits structured envelope | Consumed by `agent()` via `subagent_type` |
| 5 | **Harness validator** | `tests/ab/lib/agent_capture.sh` | Markdown→tuple state machine **deleted**; replaced by JSON-envelope validate + normalise + hash. Corpus `expected/findings.json` fixtures unchanged | Per Phase 0 spike result (D9) |

**`review-core` `args` (everything the host resolves in Phases 0–3):**
```
{ agentPrompt, flags:{csharp,ui,js,py,iac,housekeeping,securitySensitive},
  route:'lightweight'|'full', selfReReview, reviewMode:'pr'|'local',
  base, headSha, emptyTreeMode, pathScope, tempDir }
```
The core does **no** git/gh and reads no interactive input.

---

## 5. Staging (parallel-run then retire)

Five phases, each an independently shippable PR (repo PR-per-slice rhythm,
branch protection active → open PRs, don't admin-bypass).

**Phase 0 — Spikes (no production change).** Record results in the plan /
a handover memory. Two probes:
- *`agent()` schema spike* — a throwaway Workflow calling one specialist with a
  trivial schema, confirming the `schema` param validates + retries on the
  maintainer's Bedrock CLI build.
- *CLI structured-output spike* — probe whether `claude -p` exposes a
  schema / JSON-output flag (the harness already uses `--output-format
  stream-json`). Resolves D9.
- **Gate:** if the `agent()` schema param is broken on this build, the migration
  **pauses here** — cheap to discover before any production change.

**Phase 1 — Schema + agent bodies (no orchestration change).** Add
`finding-schema.json`; rewrite static agent bodies (then LLM ones) to describe
structured fields. Old markdown pipeline still runs; agents emit prose report
*and* structured output where asked. **Gate:** existing A/B harness shows
static-specialist *findings* unchanged pre/post body-rewrite (reuses the n=20
sweep capability). This de-risks the memory's open question — *does forcing
schema output change live behaviour?* — before any orchestration move.

**Phase 2 — `review-core` Workflow, behind a flag.** Add `review-core.mjs`.
Host gains a branch: a `--workflow` arg / `.claude/code-review.toml` key routes
Steps 4–6 through the Workflow; default still runs today's inline dispatch. Both
paths live; retire nothing. **Gate:** Workflow path produces a well-formed sealed
bundle on a real diff.

**Phase 3 — Parallel run.** Run both paths on the same real PRs for a few weeks
(organic — the maintainer reviews continuously). Compare manually: finding
parity, verdict agreement, cost ratio, wall-clock. Record in a handover memory.

**Phase 4 — Retire.** Once the Workflow path has a track record: make it the
default, delete the inline Step 4–6 markdown, **gut `agent_capture.sh`'s parser**
(harness adopts schema validation per the Phase 0 spike), retire the dead flag,
**retire the inlining hack** (return to a single referenced core — now safe
because the orchestrator is a script).

Ordering: the *primary win* (deterministic dispatch) lands in Phase 2 but is only
trusted after Phase 3; the *parser death* completes in Phase 4. Nothing
irreversible until the new path is proven.

---

## 6. Data flow — what changes at each hand-off

| Hand-off | Today | After |
|---|---|---|
| specialist → orchestrator | markdown report, truncated to 4000 chars | schema'd `findings[]` object |
| orchestrator → cross-review | string concat + heading-strip | structured findings filtered by domain in JS |
| synthesiser → host | markdown the host regex-scans (`Verdict:`, count) | sealed bundle fields `{verdict, bodyText, comments[]}` |
| harness → A/B compare | markdown→tuple parser → hash | validate JSON envelope → hash |

The synthesiser still receives specialist findings + cross opinions and writes
the prose review, runs §10 dissent arithmetic, tiers by judgement. The schema
structures the *envelope*; reasoning stays prose (D3).

---

## 7. Testing & verification

- **Structural suite (`tests/run.sh`):** add checks that `finding-schema.json`
  is valid JSON Schema, every static agent body references it, and the Workflow
  `meta` block is well-formed. Existing sync-note / cross-ref checks extend to
  the new include.
- **A/B harness (`tests/ab/`):** stays the static-specialist ground-truth rig.
  Phase 1 reuses it as-is (markdown parser still live, proving findings
  unchanged). Phase 4 swaps its parser for schema validation per the Phase 0
  spike. Corpus `expected/findings.json` fixtures are the invariant across both.
- **Per-phase gates** (see §5) are the verification spine: P0 spikes gate the
  whole migration; P1 gate = A/B parity; P2 gate = well-formed bundle; P4 gate =
  P3 manual track record.
- **No new test framework** — everything rides the two existing rigs.

---

## 8. Risks & open items

- **R1 — undocumented `agent()` schema API.** Server-gated; can break in a CLI
  release. Mitigated by D7 (parallel run) + the P0 gate. If it breaks
  post-landing, the host's parallel-run flag is the rollback (flip default back
  to inline markdown) until Phase 4 deletes that path — so **keep the inline
  path until Phase 4 confirms stability**, even though it's flag-disabled in
  Phase 2–3.
- **R2 — Workflow script import from plugin subtree.** Whether a `.mjs` under
  `plugins/code-review-suite/workflows/` can `import` the schema JSON (and
  whether the workflow runner resolves it under the plugin cache copy) is
  unverified. Settle script + schema co-location in the plan; fall back to
  inlining the schema object into the script if import fails. (Does **not**
  change D8's "schema is canonical in the plugin" — only how the script obtains
  it.)
- **R3 — "must satisfy both consumers."** The schema change must work for the
  Workflow `agent()` call *and* the harness's direct `claude -p` launch. D9 +
  the P0 CLI spike resolve the harness side; P1's A/B parity gate proves the
  agent-body rewrite didn't shift live behaviour.
- **R4 — sealed-bundle Class D filter moves into code.** Today the Class D
  confidence filter is applied by the synthesiser/orchestrator in prose. Moving
  it into the core's JS must reproduce the existing semantics exactly; the plan
  must pin the current filter definition (cross-ref the 2026-05-14 rubric spec)
  before porting.
- **R5 — `review-auto` deferred (D5).** The headless wrapper is the building
  block for the deferred required-PR-check item. Not built here; its failure-mode
  contract (D11) is recorded so the later drop-in is constrained. Do **not** start
  PR-CI automation as part of this migration.

---

## 9. Out of scope

- `review-auto` headless wrapper and required-PR-check CI automation (deferred;
  unblocked *by* this migration, not part of it).
- Re-tuning model/effort tiers (Phase 3 sweep is complete).
- Any change to specialist analysis logic or the verdict rubric semantics — this
  migration changes the *enforcement mechanism* and *output format*, not *what*
  the reviewers decide.

---

## 10. Relationship to prior specs

- **Promotes**
  [`2026-06-11-orchestrator-as-workflow-direction.md`](2026-06-11-orchestrator-as-workflow-direction.md)
  to a design. Adopts its sealed-bundle contract (D4), wrapper decomposition
  (D5, partially — `review-auto` deferred), human-gate-in-wrapper conclusion
  (D6), and decided failure modes (D11).
- **Extends**
  [`2026-05-14-verdict-rubric-and-orchestrator-scope-design.md`](2026-05-14-verdict-rubric-and-orchestrator-scope-design.md):
  unchanged authority model (synthesiser is sole verdict authority); this changes
  *how* the orchestrator's "may not dilute" half is enforced (prose-constrained
  agent → structure-constrained script).
- **Builds on** the A/B harness
  ([`2026-05-21-ab-test-harness-design.md`](2026-05-21-ab-test-harness-design.md))
  and the completed static-specialist tuning sweep
  ([`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md)).
