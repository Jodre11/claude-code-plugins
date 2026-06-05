# Analysis — review dimensions through the agent-maintained-code lens

> **Status:** RESOLVED. This began as a moderate-effort thinking snapshot and was
> revisited at high effort on 2026-06-05, grounded in the actual agent definitions
> (`plugins/code-review-suite/agents/*-reviewer.md`) rather than a digest. All five
> open threads are now resolved into concrete keep / retune / add / drop
> recommendations, each routed to an implementation path (see "Resolved threads →
> routing"). The user confirmed each decision-fork. No code was changed in the
> analysis session — this doc is the seed for two downstream artifacts: one
> `writing-plans` implementation plan (four edit-existing changes) and one fresh
> brainstorming cycle (the test-quality specialist).

## Why this exists

The `code-review-suite` has ~13 specialist reviewers. The question driving this
analysis: **when code is maintained by agents rather than read by humans, which review
dimensions still matter, which weaken, and what are we failing to cover?** The original
pass was deliberately provisional on several verdicts (especially DRY); the high-effort
revisit was tasked with pushing past those and not treating any as fixed. It did — in
two places the original *verdict* held but its *rationale* did not survive scrutiny, and
the deepest finding (the severity model itself encodes a classical-SE ontology) was not
visible in the original pass at all.

## What each specialist actually reviews (grounded in the agent definitions)

Read from `plugins/code-review-suite/agents/*.md` Focus Areas:

- **correctness** — logic errors, off-by-one, null/undef deref, races/TOCTOU, resource
  leaks, error-handling gaps, boundary conditions, type mismatches, bad/deprecated API
  usage, async pitfalls, **hallucinated APIs / wrong signatures / wrong versions**,
  **comment-truth verification**.
- **efficiency** — redundant compute, repeated I/O, N+1, wasted allocations, missed
  concurrency, hot-path bloat, no-op state updates, TOCTOU, unbounded structures/leaks,
  overly-broad reads/watches.
- **security** — injection, authz bypass, secrets, unsafe deserialisation, OWASP, crypto
  misuse, path traversal, SSRF, dep CVEs (#6a), pinning hygiene (#6b), freshness (#7 —
  being retired to housekeeper), sensitive-data exposure, RCE.
- **style** — readability, unnecessary complexity, dead code, naming clarity, function
  length, in-diff duplication.
- **consistency** — CLAUDE.md / editorconfig / lint-config / CONTRIBUTING violations,
  naming, architectural-pattern conformance, **generic-textbook-vs-codebase convention**.
- **reuse** — missed reuse of existing cross-file utilities/helpers (cross-file DRY).
- **alignment** — intent drift, goal under-delivery, goal contradiction, non-goal
  violation, out-of-scope changes, PR-body quality (reasons from an intent ledger).
- **archaeology** — deletion of load-bearing code (magic numbers, sleeps, retries, guard
  clauses, workarounds) that exists for a non-obvious historical reason.
- **ui** — semantic HTML, ARIA/accessibility, keyboard nav, responsive, touch targets,
  motion.
- **eslint / ruff / trivy / jbinspect** — language linters + IaC misconfig (wrappers).

## Classical vs agentic-native classification

**Classical SE** (predate LLMs; the concern is identical regardless of who wrote the
code): correctness (mostly), efficiency (all), security (all), style sub-checks
(readability/naming/length/complexity/dead-code), reuse/DRY, consistency/conventions,
UI/accessibility, all four linters, archaeology.

**Agentic-native** (exist *because* an LLM wrote the code):
- correctness › **hallucinated APIs / wrong signatures / wrong versions** — pure model
  failure mode.
- correctness › **comment-truth** — agents over-generate confident docstrings that lie.
- **alignment (entire reviewer)** — "did it build the thing asked, or something
  adjacent?" is *the* agentic problem.
- consistency › **generic-textbook-vs-codebase** — flags the default patterns LLMs reach
  for over the local idiom.

**Headline:** the suite is ~80% classical, under-invested in agentic-native dimensions.
Only alignment + the two correctness sub-checks + one consistency sub-check are
genuinely agent-native. The resolution below corrects this on two axes: it *retargets*
existing classical reviewers (style, reuse) toward agent-relevant criteria, *adds* the
single biggest missing agent-native dimension (test-quality), and — most consequentially
— *fixes the severity model* so agent-native concerns can carry weight at all (Thread 5).

## Which dimensions survive the agent-maintained lens?

Lens: *who consumes this property, and does that consumer still exist?*

- **Matter MORE** (consumer = running program / attacker, author-agnostic): correctness,
  security, efficiency, hallucination/comment-truth. Agents introduce subtle defects at
  scale → arguably *higher* weight.
- **Matter MOST** (the property humans were silently providing, now must be explicit):
  alignment (agents wander from intent) and archaeology (agents confidently delete
  "redundant-looking" code they have no lived memory of).
- **Fully relevant** (end-user-facing): UI/accessibility. Don't conflate "humans don't
  read the *code*" with "humans don't *use the product*."
- **Weaken / retarget** (consumer was human comprehension): style readability/naming/
  length, and the team-familiarity slice of consistency. They don't vanish — the
  criterion shifts from "readable to a tired human" to "cheap and safe for an agent to
  reason over and edit correctly" (less misreading, fewer wrong edits). Drop cosmetic,
  keep and sharpen the reasoning-economy core. See Thread 2.

---

# Resolved threads

The five threads below were the open questions for the high-effort revisit. Each is now
resolved with a concrete recommendation. The decision-forks (1, 3, 4, 5) were put to the
user and confirmed; Thread 2 is a low-risk reframe of an existing specialist.

## Thread 1 — reuse-reviewer: KEEP, bifurcate by triviality (~80-20)

The original pass landed 65-35 "keep but reframe" on a discoverability + context-cost
argument. The revisit **strengthens the verdict but replaces the rationale** — both of
the original's load-bearing reasons partly self-undermine.

**Where the original rationale leaked:**

- *Discoverability-via-grep.* The snapshot argued the dangerous duplicates are
  "semantically equivalent but textually different — exactly what grep misses." But
  reuse-reviewer's own process (`reuse-reviewer.md:84-94`) is glob/keyword/grep-based. It
  shares the blindness it is meant to cure: it is strongest at catching textually-*similar*
  duplicates — precisely the ones a maintaining agent could also grep-and-fix cheaply —
  and weakest on the textually-divergent ones that are actually dangerous.
- *Context-economy (N× tokens).* A codebase-health argument, not a per-finding
  reviewable-defect argument; it only bites when all N copies are loaded into context
  together, which is rare.

**The rationale that survives the agent lens (re-anchor onto these):**

1. **Correctness blast-radius.** A bug in non-trivial duplicated logic must be fixed N
   times, and each fix is an independent chance to err. This survives because it is a
   *correctness* property, author-agnostic — not a human-memory one.
2. **Agent cold-start amnesia — this inverts the "automation kills DRY" worry.** Textbook
   DRY says "someone forgets site 5"; automation does kill *that*. But a human maintainer
   accumulates a latent mental map ("we already have a `formatCurrency`"), whereas an
   agent starts every session with zero persistent codebase memory — it knows only what
   it greps or what is in context. "Reimplemented the canonical thing because I didn't
   know it existed" is therefore *categorically worse* for agents than humans. The
   reuse-reviewer is the backstop for the agent's missing mental model.

**Retune (concrete):**

- **Drop trivial duplication** — a 3-line helper duplicated twice has low blast radius,
  and consolidating it risks the wrong abstraction (Metz: "duplication is far cheaper
  than the wrong abstraction"). Stop flagging it.
- **Keep and sharpen** — reimplementation of *non-trivial canonical/tested logic*, or of
  a *dependency's existing feature*. This is *strengthened* under agents (cold-start
  amnesia + the correctness gap between fresh code and battle-tested code), not weakened.
- **Swap the rationale prose** in `reuse-reviewer.md:67-68` from "maintenance burden …
  the duplicate diverges silently" to blast-radius + cold-start amnesia.

The honest drop-case (reuse findings are always non-blocking Suggestions at a premium
dispatch cost) was weighed and rejected: the cold-start-amnesia argument makes the
reviewer *more* load-bearing under agents, not less.

## Thread 2 — style-reviewer: RETARGET to agent-reasoning-economy

Criterion shifts from "readable to a tired human" to "cheap and safe for an agent to
reason over and edit correctly." Per focus area (`style-reviewer.md:72-77`):

| Focus area | Resolution under the agent lens |
|---|---|
| **Misleading names** | **Up-weight hard.** The single strongest agent-native style concern. An agent trusts a name as a context-saving prior *to avoid reading the body*; a lying name (`validate` that mutates, `get` that writes) actively induces wrong reasoning. Worse for agents than for humans, who are more likely to read the body anyway. |
| **Implicit behaviour / action-at-a-distance** | **Up-weight.** Agents lack the lived context to know about hidden side-effects or distant coupling. |
| Clever / dense code | Keep — high misread risk. |
| Dead / commented-out code | Keep; **up-weight commented-out** code — pure context pollution, plus an ambiguous intent signal an agent may wrongly treat as meaningful. |
| Deep nesting / branching | Keep — misread → wrong edit. |
| Ambiguous names (`data`, `tmp`) | Keep, but below *misleading* in priority — a vague name costs a read; a misleading name causes a wrong edit. |
| **Function/method length** | **Retarget — this partially INVERTS.** The human "extract small functions" guideline can *hurt* an agent: chasing 6 helpers across 4 files costs more context than reading one linear, well-named 80-line function. Drop the raw line-count heuristic; retarget to length × branching/state complexity (cyclomatic load, not line count). |
| In-diff trivial duplication | **Down-weight** — even safer than cross-file duplication, since all copies are visible in a single diff. |

**Drops:** raw line-count thresholds; "add intermediate variables for readability"
pressure; verbosity-for-skimming naming preferences.

This is a Focus-Areas rewrite of an existing specialist (`style-reviewer.md` intro line
65, Focus Areas 72-77, Rules 116-120) — not a new dispatch. Low risk.

## Thread 3 — test-quality: NEW standalone, sharply-scoped specialist

The original pass flagged a counter explicitly: is this a CI-gate concern rather than a
diff-review concern? The revisit resolves the split cleanly:

- **Coverage (did the lines execute) = CI-gate, NOT a reviewer.** An LLM estimating "is
  this tested" is strictly worse than `coverage.py` / `dotnet test --collect`. The
  counter is *correct here* — do **not** build a coverage-estimator.
- **Assertion quality + test-intent alignment + smells = diff-review, and uncovered.** A
  test that calls the function and asserts nothing yields 100% coverage and zero
  verification — coverage tools are blind to it; correctness-reviewer is *told to ignore
  tests* (`correctness-reviewer.md:134`); alignment does not assess test adequacy.

Under the agent thesis this is **the** hazard, and the single most on-thesis gap in the
suite: **the test suite is the executable spec a future agent regresses against.** A
false-green suite means the next agent breaks behaviour, the tests stay green, and the
break ships. No existing reviewer and no static tool catches this.

**Shape:** judgement-based specialist (sonnet; **not** a static §10 tool specialist).
Mandate:

- Assertion quality — does the test assert *behaviour*, or merely execute the code?
- Test-intent alignment — does the test verify what the change's `goal` claims? This
  needs the intent ledger, like `alignment-reviewer` (see `includes/intent-ledger.md`).
- A short high-value smell list: no-assert, tautological/self-referential, asserts on the
  mock rather than behaviour, over-mocking that voids the test's value.

**Scope guards (hard):** only test files in the diff; never re-review production code;
never estimate coverage; non-blocking unless a smell rises to agent-hazard Important
(Thread 5).

**Routing:** a NEW specialist earns its own brainstorming → design-doc → spec cycle
(housekeeper precedent — `2026-06-05-housekeeper-specialist-design.md`). This doc records
the resolved shape to seed that cycle; the specialist is not built from the analysis
plan directly.

## Thread 4 — observability: DISTRIBUTE into correctness (no new dispatch)

On its face this has the same thesis-strength as test-quality: a debugging agent's only
window into a running system is the telemetry, so under-instrumented code is a blind spot
for every future debugger. But there is a structural asymmetry the original pass treated
as co-equal and should not have:

**Test-quality has both artifacts in the diff (the test and the code it tests).
Telemetry-adequacy needs out-of-diff operational context** — what dashboards exist, what
is logged upstream, what the runbook needs. A diff-scoped reviewer is well-positioned for
the former and poorly positioned for the latter. After correctness (swallowed
exceptions), efficiency (hot-loop logging) and consistency (wrong logging framework)
each take their slice, the *unique residue* is narrow: "this new error/retry/fallback/
external-call path emits nothing, so a future debugger is blind here."

**Resolution:** extend correctness-reviewer's "Error handling gaps — swallowed
exceptions" (`correctness-reviewer.md:77`) to **silent failure paths**:
caught-not-logged / retried-without-trace / fallback-without-signal. One bullet edit, no
new specialist. A unify-with-test-quality option (one "agent-maintainability" reviewer)
was considered and rejected: the two have different diff-signal density and different
scopes, and bundling them would dilute the test-quality mandate.

## Thread 5 — severity model: ADD an "agent-hazard" basis at the Important tier

**This is the deepest finding and the real re-weighting lever** — not per-finding
severity bumps. It was not visible in the original pass.

Operationally, "weight" in this suite means "can a finding reach Important/Critical and
thus block." The verdict rubric (`includes/verdict-rubric.md`, rows 1-3) only fires
`REQUEST_CHANGES` on goal-not-achieved, a consensus Critical, or a consensus Important at
confidence ≥70. Suggestions never block. And every severity bar in
`severity-definitions.md` is **runtime-defect-shaped**: Critical = "data loss, security
breach, or production outage"; Important = "observable incorrect behaviour … in a
reachable code path." That is the classical-SE ontology crystallised.

Under this model, agentic-native concerns *structurally cannot* block except by
manifesting as a runtime defect — and the suite has been **bolting on exceptions to
compensate**, which is the tell:

- **Alignment** ("built the wrong thing") does not fit the defect bars → so a **special
  rubric row 1** (`verdict-rubric.md`) was added to let goal-not-achieved block.
- **Comment-truth** (a lying docstring causes no runtime defect) → so
  `correctness-reviewer.md:88-92` carries a **special clause** to let it reach Important.
- A proposed **no-assert test** (no defect *today*) → under the current model is a
  Suggestion *forever*, can never block, despite being the false-green spec future agents
  regress against.

**Fix:** amend the Important tier in `severity-definitions.md` to add an agent-hazard
basis:

> A change that will predictably cause a *future* maintainer (human or agent) to
> introduce a defect — a lying comment or name, a false-green test, a silently-deleted
> workaround, an unmaintainable indirection — meets the Important bar even when it
> produces no incorrect behaviour today.

This **dissolves the existing bolt-ons into one principle**: comment-truth and
alignment's row-1 become *instances* of agent-hazard, not special cases. And it gives
test-quality (Thread 3) and the distributed observability checks (Thread 4) a severity
home, so they can carry weight rather than being permanent non-blocking Suggestions.

**Inflation guardrails:**

- Critical bar is **untouched** — stays outage / breach / data-loss. Agent-hazard reaches
  Important only, never Critical.
- Requires a *concrete misleading mechanism*, not a vague "could confuse." The finding
  must name what future-defect it induces and how.
- The existing "Not Important" downgrade list stays — naming improvements that do not
  *mislead* remain Suggestions; defensive hardening against unreachable conditions stays
  a Suggestion.
- The verdict rubric's ≥70-confidence block gate still applies.

**Behavioural consequence (stated explicitly, not buried):** once agent-hazard findings
can be Important, rubric row 3 (Important ≥70 → `REQUEST_CHANGES`) means a high-confidence
lying-comment or false-green test *can block a PR*. That is the intended re-weighting
toward agentic-native dimensions — but it is a real change to what blocks, so it is
called out here for the implementation plan to weigh.

**Ripple:** `review-synthesiser.md` Severity Reclassification gains the agent-hazard
basis as a legitimate upgrade ground; the comment-truth special clause can be simplified
to cite the new basis; verdict-rubric row 1 *may* be reframed as an instance of
agent-hazard or kept as an explicit fast-path (implementation-plan call).

---

## Resolved threads → routing

The five resolutions seed **two** downstream artifacts:

| Thread | Recommendation | Implementation route |
|---|---|---|
| 5 severity-model + ripple | Add agent-hazard basis at Important | Edit existing — sequence **FIRST** (1/2/3 depend on the basis existing) |
| 1 reuse retune | Keep, bifurcate by triviality; re-anchor rationale | Edit existing — shared implementation plan |
| 2 style retarget | Reframe Focus Areas to reasoning-economy | Edit existing — shared implementation plan |
| 4 observability | Extend correctness to silent failure paths | Edit existing — shared implementation plan |
| 3 test-quality | New sharply-scoped specialist (assertion quality + intent-alignment + smells; NOT coverage) | NEW specialist — own brainstorming → design-doc → spec cycle |

- **One `writing-plans` implementation plan** covers the four edit-existing changes
  (severity-model first, since threads 1/2/3 reference the new agent-hazard basis).
- **One fresh brainstorming cycle** designs the test-quality specialist (housekeeper
  precedent: a new specialist gets its own spec → plan → implementation).

## Gaps — still uncovered, NOT acted on this session

Ranked under the agent-maintained thesis. Threads 3 (test-quality) and 4 (observability)
are resolved above and removed from this list. The remainder are recorded, not actioned:

1. **Rollout / migration / data safety** — schema migrations, breaking wire/API changes,
   reversibility. Correctness touches API *signatures*; alignment asks for a rollback
   plan in the *body*; nothing assesses whether the migration is actually safe/reversible.
2. **Cost / spend** — efficiency is latency/throughput-shaped; nothing flags "adds a
   per-request LLM call" or unbounded fan-out cost.
3. **Supply-chain beyond CVE** — licence compatibility, abandoned/unmaintained deps.
   **RESOLVED elsewhere** — folded into the housekeeper specialist (licence-change
   detection in scope; dependency maintenance-health added as an own-or-defer line). See
   `2026-06-05-housekeeper-specialist-design.md` and memory
   `project_housekeeper_maintenance_health_axis`. **Do not re-litigate.**
4. **Product-side LLM concerns** — if the reviewed codebase contains prompts/tool-defs/
   agent code: prompt-injection surface, eval coverage, prompt regressions. Meta-gap
   given what this suite reviews.
5. **Doc/contract drift** — comment-truth is in-file only; README/OpenAPI/external-doc
   drift uncovered. i18n (hardcoded user-facing strings) has no owner.

These remain future candidates. None were promoted to action this session to keep the
scope at four edit-existing changes + one new specialist.

## Pointers for a cold start

- Reviewer definitions: `plugins/code-review-suite/agents/*-reviewer.md` (shared
  cross-review preamble + per-reviewer `## Focus Areas`).
- Severity model: `plugins/code-review-suite/includes/severity-definitions.md` (Thread 5
  amends this).
- Verdict rubric: `plugins/code-review-suite/includes/verdict-rubric.md` (the block gate
  the severity weight feeds into).
- Intent ledger (alignment + the proposed test-quality reviewer consume it):
  `plugins/code-review-suite/includes/intent-ledger.md`.
- Static-specialist apparatus (test-quality is judgement-based, NOT this — but the
  contrast matters): `includes/static-analysis-context.md`.
- Housekeeper design (the supply-chain gap already in motion):
  `docs/superpowers/specs/2026-06-05-housekeeper-specialist-design.md`.
- Backlog memory: `project_code_review_suite_backlog`.
