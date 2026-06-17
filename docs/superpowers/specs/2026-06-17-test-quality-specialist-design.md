# Design — test-quality specialist (Thread 3 of review-dimensions)

> **Status:** APPROVED (brainstorming complete, 2026-06-17). Seeds a `writing-plans`
> implementation plan. This is the final open thread of the agentic-review-dimensions
> programme; the other four threads (severity agent-hazard basis #52; reuse/style/
> correctness retargets #53) are shipped and merged. Source analysis:
> `docs/superpowers/specs/2026-06-05-review-dimensions-agentic-analysis.md` (Thread 3).

## 1. Why this specialist exists

When a future agent modifies code, the test suite is the executable spec it regresses
against. A test that asserts nothing, whose name lies about what it checks, or that
mocks the very thing under test gives that future agent **false confidence** — it breaks
behaviour, the tests stay green, and the break ships. This is the single most on-thesis
agent-hazard in the suite, and **no existing reviewer owns it**:

- `correctness-reviewer` is explicitly told to ignore tests (`correctness-reviewer.md:142`).
- Coverage tools are blind to a test that executes code but asserts nothing.
- `alignment-reviewer` assesses intent drift, not test adequacy.

The 2026-06-05 analysis resolved this as a NEW, sharply-scoped, judgement-based reviewer.

## 2. Architecture & scope

A new **judgement-based specialist**, `test-quality-reviewer`:

- **Model:** `sonnet` (matches the other judgement specialists — correctness/reuse/style).
- **Dispatch:** **conditional** — only when the diff touches test files (`$TESTS_DETECTED`).
- **Cross-review:** participates fully (NOT in the `STATIC` set) — both gives and receives.
- **Schema:** emits the standard finding schema; no new field.
- **Severity:** leans on the agent-hazard basis (`severity-definitions.md`, PR #52) for its
  Important-tier calls.

**Remit — three axes:**

1. **Assertion quality** — does each test assert the *behaviour* its name/intent claims,
   or merely execute the code?
2. **Test-intent alignment** — does the test verify what the change's `goal` claims?
   Consumes the intent ledger (`includes/intent-ledger.md`), like `alignment-reviewer`.
3. **A fixed four-smell list** (short and concrete — resist sprawl into generic lint):
   - **no-assert** — calls the function under test, asserts nothing.
   - **tautological / self-referential** — `assert x == x`, asserting a literal against
     itself.
   - **asserts-on-the-mock** — asserts a mock's own configured return value rather than
     the behaviour the mock was standing in for.
   - **over-mocking that voids the test** — mocks the very unit under test, so the test
     passes even when production would fail.

**Hard scope guards (load-bearing — do not violate):**

- **NEVER a coverage estimator.** No line-counting, no %, no "untested code" flags.
  Coverage stays a CI gate. An LLM estimating coverage is strictly worse than
  `coverage.py` / `dotnet test --collect`.
- **Test files in the diff ONLY.** Never re-reviews production code; never the whole
  suite. Detection fires on test-file paths in the diff (see §4.1).
- **Non-blocking unless agent-hazard.** A false-green test rises to **Important** via the
  agent-hazard basis (it predictably makes a future maintainer ship a defect). Everything
  else is a **Suggestion**. Cosmetic test issues must NOT be inflated.

## 3. The agent definition file

`plugins/code-review-suite/agents/test-quality-reviewer.md`, structured like the
judgement specialists (correctness/reuse/style):

**Frontmatter:** `name: test-quality-reviewer`, `model: sonnet`,
`tools: Read, Grep, Glob, Bash`, `background: true`, `description` for the registry.

**Body, in order:**

1. **Inlined CROSS-REVIEW MODE block** — copied byte-for-byte from a sibling (canonical
   source `includes/cross-review-mode.md`). The sync test (`tests/lib/test_sync_notes.sh`)
   enforces byte-equality — copy, never hand-edit.
2. **Intro line** — "You are a test-quality reviewer…" + the agent-thesis framing (the
   suite is the executable spec a future agent regresses against). Includes the
   "If your prompt does NOT contain `Mode: cross-review`, follow … `includes/specialist-context.md`"
   line that every judgement specialist carries.
3. **`## Focus Areas`** — the three axes (assertion quality, test-intent alignment,
   the fixed four-smell list), each with concrete examples. Cites the agent-hazard basis
   in `severity-definitions.md` explicitly — naming a false-green test as a textbook
   instance (mirrors `correctness-reviewer.md:93-95` for comment-truth) so the reviewer
   knows *why* a no-assert test reaches Important.
4. **`## Analysis Process`** — (a) identify changed test files; (b) for each test, read
   what it *claims* (name + intent-ledger goal) vs what it *asserts*; (c) apply the smell
   list; (d) decide severity via the agent-hazard basis.
5. **`## Output Format`** — `## Test Quality Review Findings` block, standard finding
   fields (map to `includes/finding-schema.json#/$defs/finding`), `0 findings.` sentinel.
6. **`## Rules`** — inlined CHANGED_LINES OUTPUT FILTER block (canonical, byte-equal);
   plus scope-guard rules: never estimate coverage, never review production code, test
   files in diff only, don't inflate cosmetic test issues.

## 4. Integration points

Verified against `main` @ `42c5d6f`. The suite has two dispatch paths — the default
Workflow core AND the inline `$USE_WORKFLOW == false` fallback — so several edits land in
both. RE-VERIFY line numbers at implementation time.

### 4.1 Detection flag

`includes/review-pipeline.md` Step 2.6 (~line 691) and the mirror in
`skills/review-gh-pr/SKILL.md` (~line 799). Add a **Test detection** rule setting
`$TESTS_DETECTED = true` on a **generous matcher** — naming conventions OR test-dir
segments:

- **Naming:** `test_*.py` / `*_test.py`; `*.test.*` / `*.spec.*` for JS/TS extensions;
  `*Test.cs` / `*Tests.cs`; `*_test.go`; `*_spec.rb` / `*_test.rb`.
- **Dir segment:** any path segment equal to `test`, `tests`, `spec`, `specs`, or
  `__tests__`.

Rationale for generous: over-dispatch is harmless — the reviewer's scope guards absorb a
non-test file (e.g. a fixture under `tests/`) by simply finding nothing. Missing a real
test file is the worse failure.

### 4.2 Flags plumbing

`skills/review-gh-pr/SKILL.md` (~line 910, the `flags:` object) and the same object in
`includes/review-pipeline.md` (~line 804). Add `tests: $TESTS_DETECTED`.

### 4.3 Workflow core

`workflows/review-core.mjs` (~line 150). Add `['test-quality', flags.tests]` to the
`CONDITIONAL` array. **Not** in `CORE`; **not** in the `STATIC` set (~line 181) — so it
automatically lands in `crossDomains` (~line 182) and both gives and receives
cross-review. Dispatch resolves `code-review-suite:test-quality-reviewer`, matching the
file name.

### 4.4 Inline fallback dispatch

`skills/review-gh-pr/SKILL.md` (~line 1087, after the housekeeper block). Add an
`If $TESTS_DETECTED, also dispatch: test-quality-reviewer` block. Update:

- the batching-fallback enumeration (Batch 2 conditionals: 6 → 7; polyglot fallback note);
- `$SPECIALIST_COUNT` accounting (~line 1109: 9–15 with conditionals);
- the verify-completeness mandatory set (~line 1116: add `test-quality-reviewer` if
  `$TESTS_DETECTED`).

### 4.5 Cross-review peer-block gating

`skills/review-gh-pr/SKILL.md` (~line 1213). test-quality is a **judgement** specialist
(not static), so it is in the normal cross-review set — but because it is **conditional**,
its `### test-quality-reviewer findings` block must be **omitted when `$TESTS_DETECTED`
is false**. Add it to the conditional-omission list, NOT the always-on static list.

### 4.6 Finding schema — no change

Judgement specialists already emit the standard shape (`SPECIALIST_SCHEMA` in
review-core.mjs, `finding-schema.json`); test-quality findings need no new field.
Confirmed.

## 5. Structural tests & README

- **`tests/run.sh` + `tests/lib/`** — register the new agent in any "all agents have X"
  structural checks; add a sync-note check for its inlined canonical blocks
  (CROSS-REVIEW MODE + CHANGED_LINES); add corpus/index gating for its ablation fixtures.
  Run `tests/run.sh` and fix whatever the new agent trips. Baseline before this work:
  448 passed, 1 skipped, 0 failed.
- **`plugins/code-review-suite/README.md`** — add `test-quality-reviewer` to the agent
  table (and the marketplace agent list if one exists), per the plugin-authoring
  conventions in CLAUDE.md.

## 6. Validation

Mirrors the #53 apparatus exactly (`tests/ab/run-specialist-ablation.sh`,
`tests/ab/lib/specialist_score.sh`, `tests/ab/lib/ab_stats.py`) — shipped, reused as-is.

**Per-agent config:** `tests/ab/configs/per-agent/test-quality-baseline.yaml`
(opus / effort `default` — the ablation arm pins opus regardless of the sonnet production
model, matching the reuse/style/correctness baselines).

**Two matched fixtures, gated in `tests/ab/corpus/index.yaml`:**

- **`test-quality-hit`** — a changed test file with a real false-green defect the reviewer
  SHOULD flag at Important. Candidate: a test named `test_rejects_invalid_email` that
  mocks the validator and then asserts the mock's own configured return — so it passes
  even if real validation is broken. `expect_arm_b: Important` (false-green = agent-hazard).
- **`test-quality-nearmiss`** — a changed test that is genuinely fine (or has a trivial
  cosmetic issue the reviewer must NOT inflate). `expect_arm_b: ABSENT` (inflation guard).

**Method — B + A (chosen 2026-06-17):**

- **B — behavioural gate (single-arm capture):** run test-quality on each fixture; hit
  must fire Important, near-miss must stay ABSENT. Bar: Fisher p < 0.05 hit-vs-nearmiss,
  near-miss inflation ~0. This is the bar #52/#53 cleared mechanically.
- **A — unique-fire proof:** one contrast on the hit showing the *rest of the suite*
  (correctness/style/reuse/alignment) stays silent on the same fixture while test-quality
  fires — proving the coverage is unique (the whole justification for a new specialist).

**Three fixture-design lessons carried in from #53 (all bit on the earlier threads):**

1. **No breadcrumbs.** Fixture context files (READMEs, docstrings, intent ledgers) name
   only the corpus, never the defect/mechanism in the reviewer's own vocabulary.
2. **No overlap defects.** The planted defect must be one ONLY the test-quality lens
   catches. The mock-asserts-its-own-return defect qualifies: correctness ignores tests,
   style/reuse won't see the false-green. This is also what makes the Arm-A unique-fire
   clean.
3. **Plant-line drift.** Do a capture trial FIRST, see where the reviewer cites, then set
   `planted.line` to the cited line. Score at the cited line.

**Cost-tuning (haiku/low):** deferred. Judgement specialists run sonnet in production; a
cheaper-model sweep is a separate exercise, only if asked.

**Approval gate:** live ablations cost opus tokens and need a valid AWS SSO token → gated
on user approval (the #53 precedent). The offline work (agent def, fixtures, wiring,
structural tests) needs no approval and lands first.

## 7. Sequencing & PR shape

- `main` is protected + shared — start a **new feature branch**, ship as a PR, never
  direct-push. Ask before opening the PR and before merging.
- The agent-hazard severity basis (PR #52) this reviewer depends on is already merged, so
  there is no cross-PR dependency to sequence.
- This is a single focused feature PR (new specialist + wiring + tests + fixtures). The
  three #53 deferred follow-ups (correctness unique-fire fixture; plant-line corrections;
  reuse de-escalate-vs-suppress prose) are independent small PRs — do NOT bundle them
  here.

## 8. Naming decision (resolved)

Domain: **`test-quality`** → file `test-quality-reviewer.md`, dispatch string
`code-review-suite:test-quality-reviewer`, flag `flags.tests` / `$TESTS_DETECTED`,
output block `## Test Quality Review Findings`. Chosen over `tests` (too generic, reads
as "run tests") and `test-reviewer` (reads as "a reviewer that is a test").
