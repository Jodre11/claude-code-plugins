# Panel Severity + Tractability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the opt-in panel reviewer block PR #98's reachable authZ gap by re-anchoring severity to impact-if-manifested and adding a tractability axis that routes/prunes suggestions below the verdict line.

**Architecture:** The panel path (`orchestrationMode==='panel'`) runs `panelVote` → `panelWrite` → `tallyVotes` → `mapSpreadToTierConfidence` → `applyRubric` → a deterministic writer → `finalizeBundle`. This plan (a) re-anchors the severity definition in the concern brief, (b) adds a `tractability` vote field, (c) replaces the realness→confidence ratchet *arithmetic* with severity-majority verdicting + agreement-based discrete confidence, (d) adds tractability routing (fix-now / optional / drop-open-ended) that operates entirely below the verdict line, and (e) enforces an inline-vs-PR-body-vs-drop surfacing contract. The classic (`crossAndSynth`) path is left byte-for-byte unchanged — every panel-specific behaviour is gated on `envelope.panel === true`, and shared helpers only gain fallbacks, never rewrites.

**Tech Stack:** Node ESM workflow script (`review-core.mjs`, run inside the Workflow sandbox via `new Function`), Bash + `jq` structural/behavioural tests (`tests/lib/test_*.sh`, run by `tests/run.sh`), JSON Schema for agent I/O.

## Global Constraints

- Plugin `plugin.json` files omit `version` — do not add one.
- Shell scripts: 4-space indentation. Markdown/JSON: 2-space. All text files: LF line endings, final newline.
- Bash tool rules (CLAUDE.md): no `&&`/`||`/`;` compounds, no command substitution `$(...)`, no subshells, no pipes/redirection except `2>&1`. One simple command per Bash call. (These apply to *how you drive the shell during implementation*, not to committed test-file contents, which already use pipes.)
- Test entry point is `bash tests/run.sh` — every `test_*` function in `tests/lib/*.sh` is auto-discovered.
- review-core.mjs runs in a sandbox that evals the stripped source: **no `import()`, no `$ref`, no `export function`**. Helpers are file-local consts/functions; tests exercise them only through the returned bundle (`_pan_run_core`), never by direct call.
- The A/B experiment / blind-ranking is CLOSED. **Model-as-judge is a permanent ban.** PR #98 runs are smoke sanity checks only, not a powered comparison.
- Work lands on branch `feat/panel-severity-tractability` (already created); open a PR, do not push to `main` (main is protected).

---

## File Structure

- `plugins/code-review-suite/includes/panel-concern-brief.md` — panelist prompt. Re-anchor severity; add the tractability axis definition; instruct panelists to supply both axes on raised findings too. (Task 1)
- `plugins/code-review-suite/workflows/review-core.mjs` — all verdict/routing/surfacing logic. Sections touched: `PANEL_SCHEMA` (~L105), `tallyVotes` (~L629), `mapSpreadToTierConfidence` (~L676), `applyRubric` (~L729), `finalizeBundle` (~L476), `isPosted` (~L817), `isVerdictRelevant` (~L833), `renderCommentBody` (~L845), `buildLogPayload` (~L975), `panelWrite` (~L779). (Tasks 2–6)
- `tests/lib/test_panel_review.sh` — the panel behavioural suite. Existing ratchet-model tests are rewritten to the majority model; new tractability/surfacing tests added. (Tasks 2–6)
- `tests/lib/test_workflow_migration.sh` — schema-parity test; confirm it stays green (Task 2 must not drift `SPECIALIST/SYNTH/CROSS_SCHEMA`).

---

## Design decisions locked here (spec open questions resolved)

1. **Confidence representation.** Panel findings carry a discrete `confidence_flag ∈ {high, medium, low}` derived from panelist *agreement* on the severity axis (`high` = unanimous across all `s` survivors, `medium` = strict majority `> s/2`, `low` = severity scatter / cautious-resolved). The old numeric field `confidence` is **retained** and set from a fixed map (`high→90, medium→75, low→50`) *only* so the classic path, the durable-log numeric column, and `tests/ab/lib/differential.py` keep working without a cross-path rewrite. Rubric and routing consume the *flag*, never the number. Because exactly three values are ever produced, no false precision is introduced. This honours the spec's "discrete flag, no interpolation" while keeping blast radius on the panel path only.
2. **`blocks_goal` and `is_real` stay** (spec flags both as removal *candidates*). Keeping them preserves the existing row-1 and dismissed-tier tests and lets the A/B confirm removal later. `is_real` still gates: majority-not-real → `dismissed`; not-real panelists abstain from the severity/tractability tallies (an opinion on a false positive is incoherent). Severity/tractability majority is computed over **real votes only**.
3. **Static findings** (`STATIC` domains) keep tool-locked severity, `confidence_flag = high`, and default `tractability = Mechanical` (not voted) — their fixes are mechanical by nature (bump the version, fix the lint). They are never dismissed.
4. **Drop telemetry.** Dropped open-ended suggestions are excluded from the posted report but recorded in the `dismissed` tier with `dropped: true`, so the durable log still shows what was pruned.
5. **Panel gating.** `panelWrite` stamps `envelope.panel = true`. Every panel-specific branch in shared helpers (`finalizeBundle`, `isPosted`) keys on the per-finding `posting` field or this flag; classic findings never carry `posting`, so classic behaviour is unchanged.

---

### Task 1: Concern brief — impact severity + tractability axis

**Files:**
- Modify: `plugins/code-review-suite/includes/panel-concern-brief.md`
- Test: `tests/lib/test_panel_review.sh` (add structural assertions)

**Interfaces:**
- Consumes: nothing (prose prompt).
- Produces: the runtime instruction that panelists emit `severity` (impact-based) and `tractability` (`Mechanical`/`Bounded`/`Open-ended`) on every vote and every raised finding. Task 2's `PANEL_SCHEMA` must match the enum names used here.

- [ ] **Step 1: Write the failing structural test**

Add to `tests/lib/test_panel_review.sh`:

```bash
# The concern brief must define severity by impact-if-manifested and must define
# the three tractability tiers by name, so panelists elicit the new axes.
test_panel_brief_defines_impact_severity_and_tractability() {
    local brief
    brief="$REPO_ROOT/plugins/code-review-suite/includes/panel-concern-brief.md"
    assert_matches "impact" "$(cat "$brief")" "brief anchors severity to impact"
    assert_matches "Tractability" "$(cat "$brief")" "brief names the Tractability axis"
    assert_matches "Mechanical" "$(cat "$brief")" "brief defines Mechanical tier"
    assert_matches "Bounded" "$(cat "$brief")" "brief defines Bounded tier"
    assert_matches "Open-ended" "$(cat "$brief")" "brief defines Open-ended tier"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 "panel brief defines"`
Expected: FAIL — "Tractability" / "Mechanical" not present in the current brief.

- [ ] **Step 3: Edit the concern brief**

In `plugins/code-review-suite/includes/panel-concern-brief.md`, replace the second sentence of the opening paragraph (the `is_real` / `severity` instruction) with the impact-anchored severity definition and a tractability instruction. The paragraph beginning "For each Stage-1 finding, emit two INDEPENDENT judgements…" becomes:

```markdown
For each Stage-1 finding, emit INDEPENDENT judgements and do no arithmetic:
`is_real` (is this a true issue or a false positive? — purely epistemic), `severity`, and
`tractability`. Do not fuse them; do not compute thresholds or tiers — the rubric combines
your opinions mechanically.

**Severity — rate the impact if this issue manifested as a problem, not how much you
personally care:**

- **Critical** — takes down the whole system, or a large enough part that core
  functionality cannot be delivered.
- **Important** — some functionality would actually go wrong or not work; if the issue
  manifested, a real feature breaks. A reachable gap that lets the wrong thing happen
  (e.g. an unauthorised principal acting on a finance endpoint) is Important even if it
  was a declared non-goal — the impact is real regardless of intent.
- **Suggestion** — what we have works; this is a better way, nicer, or a non-blocking
  improvement (not a correctness or accessibility problem).

**Tractability — how well-understood and contained is the fix?** One fused ordinal;
uncertainty *is* the dominant source of risk.

- **Mechanical** — the remedy is obvious and local; you could name the diff now; negligible
  chance of collateral damage.
- **Bounded** — understood but non-trivial: touches something load-bearing or needs care,
  but the shape of the fix is clear.
- **Open-ended** — the remedy is uncertain, **or** fixing it risks deviating from intent or
  introducing a new class of bug. Needs investigation before anyone touches it.

Provide `severity` and `tractability` for **every** finding you vote on, and for every
net-new finding you raise yourself. A genuine but low-stakes finding is
`is_real: true, severity: Suggestion`.
```

Leave the "Scrutinise, across all concern domains" list and the closing "Vote independently" paragraph intact, but in the closing paragraph update the sentence that currently reads "Answer the two questions separately" to "Answer each question separately" (there are now three).

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -A1 "panel brief defines"`
Expected: PASS (5 assertions).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/includes/panel-concern-brief.md tests/lib/test_panel_review.sh
git commit -m "feat(panel): re-anchor severity to impact + add tractability axis to concern brief"
```

---

### Task 2: PANEL_SCHEMA — tractability on votes and raised findings

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs:105-131` (`PANEL_SCHEMA`)
- Test: `tests/lib/test_panel_review.sh`

**Interfaces:**
- Consumes: the enum names from Task 1 (`Mechanical`/`Bounded`/`Open-ended`).
- Produces: `PANEL_SCHEMA.votes.items` requires `tractability`; a new panel-local `RAISED_SHAPE` (= `FINDING_SHAPE` + a required `tractability`) used by `PANEL_SCHEMA.raised.items`. `tallyVotes` (Task 3) reads `v.tractability`; `clusterRaised`/routing (Task 5) reads `r.tractability`.

**Why a panel-local `RAISED_SHAPE`, not extending `FINDING_SHAPE`:** the shared `FINDING_SHAPE` is parity-checked against `finding-schema.json` by `test_inlined_schema_matches_canonical` (only `SPECIALIST/SYNTH/CROSS_SCHEMA` are compared). `PANEL_SCHEMA` is *not* in that parity set, so a panel-local raised shape adds `tractability` without touching the canonical schema or breaking parity.

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_panel_review.sh` a schema-extract test (mirrors the parity test's prefix-eval trick):

```bash
# PANEL_SCHEMA.votes require tractability; PANEL_SCHEMA.raised items carry tractability.
test_panel_schema_has_tractability() {
    local wf result
    wf="$(_pan_cr_dir)/workflows/review-core.mjs"
    result=$(WF="$wf" node -e '
        const fs = require("fs");
        const wf = fs.readFileSync(process.env.WF, "utf8");
        const cut = wf.indexOf("const resolvedArgs");
        const prefix = wf.slice(0, cut).replace(/^export\s+const\s+meta/m, "const meta");
        const { PANEL_SCHEMA } = new Function(prefix + "\nreturn { PANEL_SCHEMA };")();
        const vote = PANEL_SCHEMA.properties.votes.items;
        const raised = PANEL_SCHEMA.properties.raised.items;
        const voteOk = vote.required.includes("tractability")
            && vote.properties.tractability.enum.join(",") === "Mechanical,Bounded,Open-ended";
        const raisedOk = !!raised.properties.tractability
            && raised.properties.tractability.enum.join(",") === "Mechanical,Bounded,Open-ended";
        console.log(voteOk && raisedOk ? "OK" : "MISMATCH vote=" + voteOk + " raised=" + raisedOk);
    ' 2>&1)
    assert_equals "OK" "$result" "PANEL_SCHEMA votes + raised carry the tractability enum"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A1 "panel schema has tractability"`
Expected: FAIL — `tractability` absent (prints `MISMATCH vote=false raised=false`).

- [ ] **Step 3: Add tractability to `PANEL_SCHEMA`**

In `review-core.mjs`, add `tractability` to the vote items' `required` and `properties`, and introduce `RAISED_SHAPE`. Replace the `PANEL_SCHEMA` block (L105–131) with:

```javascript
// RAISED_SHAPE — a panel-raised finding is a FINDING_SHAPE plus a required tractability
// (the raiser's own fix-risk read). Panel-local: PANEL_SCHEMA is NOT in the finding-schema
// parity set, so this does not touch the canonical schema.
const RAISED_SHAPE = {
    type: 'object',
    additionalProperties: false,
    required: [...FINDING_SHAPE.required, 'tractability'],
    properties: {
        ...FINDING_SHAPE.properties,
        tractability: { enum: ['Mechanical', 'Bounded', 'Open-ended'], description: "The raiser's fix-risk read: Mechanical (obvious local diff), Bounded (understood but non-trivial), Open-ended (uncertain or risks deviating from intent)." },
    },
}

const PANEL_SCHEMA = {
    type: 'object',
    additionalProperties: false,
    required: ['votes', 'raised'],
    properties: {
        votes: {
            type: 'array',
            items: {
                type: 'object',
                additionalProperties: false,
                required: ['finding_id', 'is_real', 'severity', 'tractability', 'blocks_goal', 'rationale'],
                properties: {
                    finding_id: { type: 'integer', minimum: 0, description: 'Index into the flattened Stage-1 finding list.' },
                    is_real: { type: 'boolean', description: 'True issue vs false positive — purely epistemic, independent of importance.' },
                    severity: { enum: ['Critical', 'Important', 'Suggestion'], description: 'Impact if the issue manifested. Ignored for static-analysis findings (severity is locked).' },
                    tractability: { enum: ['Mechanical', 'Bounded', 'Open-ended'], description: 'How well-understood and contained the fix is. Mechanical=obvious local diff; Bounded=non-trivial but clear; Open-ended=uncertain or risks deviating from intent.' },
                    blocks_goal: { type: 'boolean', description: 'True iff this finding shows the stated goal is not achieved. Always false when no goal is in scope.' },
                    rationale: { type: 'string' },
                },
            },
        },
        raised: {
            type: 'array',
            items: RAISED_SHAPE,
            description: 'Net-new cross-cutting findings this panelist surfaced. Provenance (panel) is stamped by review-core.',
        },
    },
}
```

- [ ] **Step 4: Run the schema test + the parity test to verify both pass**

Run: `bash tests/run.sh 2>&1 | grep -A1 "panel schema has tractability"`
Expected: PASS.

Run: `bash tests/run.sh 2>&1 | grep -A1 "inlined schema parity"`
Expected: PASS (unchanged — canonical schema untouched).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_panel_review.sh
git commit -m "feat(panel): add tractability field to PANEL_SCHEMA votes and raised findings"
```

---

### Task 3: Verdict engine — severity-majority + agreement confidence, drop the ratchet arithmetic

**Files:**
- Modify: `review-core.mjs` — `tallyVotes` (~L629), `mapSpreadToTierConfidence` (~L676), `applyRubric` (~L729), `panelWrite` (~L779, stamp `envelope.panel`).
- Test: `tests/lib/test_panel_review.sh` — rewrite the ratchet-model tests to the majority model.

**Interfaces:**
- Consumes: `tally.sevVotes` / `tally.tractVotes` (real-vote arrays), `s` (survivor count), `STATIC`.
- Produces: each voted finding stamped `{ ...rest, severity, tractability, confidence_flag, confidence, blocks_goal, judgement_call? }` and placed in a tier. Task 4 reads `severity`+`tractability`+`confidence_flag` to route; Task 6 reads `confidence_flag` for the log.

**New tally + majority model (replaces the realness→confidence ratchet arithmetic):**
- Severity majority is over **real votes only**. `majorityOf(values, s)` → `{ value, agreement }` where `agreement='high'` iff one value has all `s` survivors, `'medium'` iff `> s/2`, else `value=null` (scatter).
- Tractability uses `resolveTractability(values, s)`: majority when there is one; on scatter, resolve to the **most cautious** value present (`Open-ended > Bounded > Mechanical`) with `agreement='low'`.
- Tiering: majority-not-real → `dismissed`; static → locked-severity blocking rule; non-static blocking (majority Critical/Important) → `consensus`; severity scatter → `contested` with `judgement_call: true`; majority Suggestion → `contested` (routing/posting set in Task 4). Raised clusters unchanged for now (Task 5 re-routes them).

- [ ] **Step 1: Rewrite the affected existing tests to the majority model**

In `tests/lib/test_panel_review.sh`, add `tractability` to every vote fixture (append `,"tractability":"Bounded"` to each vote object; static/mechanical cases use `"Mechanical"`), and change the expectations that the ratchet arithmetic drove. Replace these three tests wholesale:

```bash
# Mixed severity with NO majority (1 Important / 1 Suggestion real, 1 not-real):
# severity votes among real = [Important, Suggestion] → no majority → SCATTER →
# judgement call (contested, non-blocking) → APPROVE. (Old ratchet rounded to Important+RC.)
test_panel_mixed_severity_scatter_is_judgement_call() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"maybe","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "severity scatter does not block → APPROVE"
    assert_equals "contested" "$(echo "$out" | jq -r '.log.findings[0].tier')" "severity scatter → contested judgement-call bin"
    assert_equals "true" "$(echo "$out" | jq -r '.log.findings[0].judgement_call')" "scatter finding flagged judgement_call"
}

# 1 real Critical / 2 not-real: majority-not-real fires FIRST → dismissed → APPROVE.
# (Old ratchet kept conf=78 ≥ 70 and blocked; the new model never reaches severity for a
# majority-not-real finding.)
test_panel_lone_real_critical_majority_notreal_dismissed() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Critical","confidence":100,"description":"false alarm","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "majority not-real → dismissed → APPROVE"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority not-real → dismissed"
}

# 2/1 majority Important (one dissent on is_real) STILL BLOCKS — difficulty/doubt never
# excuses a real defect. confidence_flag=medium, but a medium majority Important blocks.
test_panel_two_one_majority_important_blocks() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"solid bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "2/1 majority Important blocks (no confidence gate)"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "2/1 majority Important → consensus"
    assert_equals "medium" "$(echo "$out" | jq -r '.log.findings[0].confidence_flag')" "2/1 majority → medium confidence flag"
}
```

Then update the fixtures (append tractability to each vote) of the tests that keep their verdicts: `test_panel_unanimous_real_important_is_rc` (→ add `confidence_flag=high` assertion), `test_panel_split_majority_real_suggestion_approves`, `test_panel_row1_fires_on_goal_block`, `test_panel_row1_finding_is_verdict_relevant`, `test_panel_approve_flags_nothing_verdict_relevant`, `test_panel_row1_inert_without_goal`, `test_panel_below_quorum_degrades`, `test_panel_exact_quorum_proceeds`, `test_panel_row1_needs_consensus_majority`, `test_panel_log_carries_cogs_and_meta`.

**Delete** the ratchet-arithmetic tests whose premise no longer exists: `test_panel_mixed_severity_rounds_to_important_blocks` (replaced above), `test_panel_critical_survives_two_dissents` (replaced above), `test_panel_n5_bare_majority_is_contested` (rename/rewrite: N=5 3-real-Important-of-5 → consensus, RC — no ratchet), `test_panel_trackA_severity_upgrade_blocks` (now: unanimous Important majority blocks — keep, drop the "effLevel" reasoning), `test_panel_trackA_realness_drops_below_gate` → `test_panel_trackA_majority_notreal_dismissed` (unanimous not-real → dismissed, no numeric threshold), `test_panel_trackA_single_dissent_still_blocks` (folds into `test_panel_two_one_majority_important_blocks`), `test_panel_trackA_nonreal_abstains_from_severity` (keep — abstention semantics survive; drop effLevel math), `test_panel_n5_realness_scaling` (delete — pure ratchet math). Keep both Track B statics (E, F) — static locking survives; update their confidence assertions to `confidence_flag=high`.

- [ ] **Step 2: Run the suite to confirm the rewritten tests fail against the current ratchet code**

Run: `bash tests/run.sh 2>&1 | grep -E "scatter|two one majority|lone real critical"`
Expected: FAIL — current code still rounds/ratchets (e.g. mixed-scatter returns RC not APPROVE).

- [ ] **Step 3: Rewrite `tallyVotes`**

Replace `tallyVotes` (L629–645) with:

```javascript
// Aggregate the axes per Stage-1 finding across surviving panelists. Severity and
// tractability opinions are collected ONLY from is_real:true panelists (an opinion on a
// false positive is incoherent). Majority/scatter is computed downstream in
// mapSpreadToTierConfidence, which has the survivor count s.
function tallyVotes(panelists, flat) {
    return flat.map(f => {
        const tally = { is_real_true: 0, is_real_false: 0, blocks_goal: 0, sevVotes: [], tractVotes: [] }
        for (const p of panelists) {
            const v = (p.votes ?? []).find(x => x.finding_id === f.finding_id)
            if (!v) continue
            if (v.is_real) {
                tally.is_real_true++
                tally.sevVotes.push(v.severity)
                if (v.tractability) tally.tractVotes.push(v.tractability)
            } else {
                tally.is_real_false++
            }
            if (v.blocks_goal) tally.blocks_goal++
        }
        return { finding: f, tally }
    })
}
```

- [ ] **Step 4: Rewrite `mapSpreadToTierConfidence` (drop the ratchet, add majority + agreement flag)**

Replace `mapSpreadToTierConfidence` (L663–723) with:

```javascript
const TRACT_ORDER = { 'Mechanical': 1, 'Bounded': 2, 'Open-ended': 3 }
const FLAG_TO_NUM = { high: 90, medium: 75, low: 50 }

// Severity majority over the real votes. agreement: 'high' iff one value has ALL s
// survivors, 'medium' iff a strict majority (> s/2), else scatter (value null).
function majorityOf(values, s) {
    const counts = {}
    for (const v of values) counts[v] = (counts[v] ?? 0) + 1
    let best = null, bestC = 0
    for (const [k, c] of Object.entries(counts)) if (c > bestC) { best = k; bestC = c }
    if (bestC === s) return { value: best, agreement: 'high' }
    if (bestC > s / 2) return { value: best, agreement: 'medium' }
    return { value: null, agreement: null }
}

// Tractability resolution: majority when one exists; on scatter, resolve to the MOST
// cautious value present (disagreement = fix not understood → lean less-tractable).
function resolveTractability(values, s) {
    const m = majorityOf(values, s)
    if (m.value) return { value: m.value, agreement: m.agreement }
    let worst = 'Mechanical'
    for (const v of values) if ((TRACT_ORDER[v] ?? 0) > TRACT_ORDER[worst]) worst = v
    return { value: worst, agreement: 'low' }
}

// Map vote spread + raise corroboration onto the four-tier envelope. Emits ALL four keys;
// `synthesiser` is always [] in panel mode. Confidence is now the discrete agreement flag
// (severity axis); the numeric `confidence` is a back-compat shim (FLAG_TO_NUM) for the log
// and classic-shared helpers. Routing/posting fields are added in Task 4.
//
// Non-static: majority-not-real → dismissed; else severity majority governs — Critical/
//   Important → consensus (blocking); Suggestion → contested (routing set later);
//   scatter → contested + judgement_call.
// Static (STATIC.has(domain)): severity locked, confidence_flag high, tractability Mechanical;
//   blocks iff locked-sev >= Important → consensus; else contested (NEVER dismissed).
function mapSpreadToTierConfidence(voteTallies, raisedClusters, s) {
    const tiers = { consensus: [], synthesiser: [], contested: [], dismissed: [] }
    const SEV_TO_LEVEL = { Suggestion: 1, Important: 2, Critical: 3 }
    const blocksGoal = t => t.blocks_goal > s / 2
    for (const { finding, tally } of voteTallies) {
        const { finding_id, ...rest } = finding
        const isStatic = STATIC.has(finding.domain)
        let tier, confidence_flag, severity, tractability, judgement_call = false

        if (isStatic) {
            severity = finding.severity           // locked
            confidence_flag = 'high'
            tractability = 'Mechanical'
            tier = SEV_TO_LEVEL[severity] >= 2 ? 'consensus' : 'contested'
        } else if (tally.is_real_false > tally.is_real_true) {
            severity = finding.severity
            confidence_flag = 'low'
            tractability = resolveTractability(tally.tractVotes, s).value
            tier = 'dismissed'
        } else {
            const sevM = majorityOf(tally.sevVotes, s)
            tractability = resolveTractability(tally.tractVotes, s).value
            if (!sevM.value) {                    // severity scatter → judgement call
                severity = finding.severity
                confidence_flag = 'low'
                judgement_call = true
                tier = 'contested'
            } else {
                severity = sevM.value
                confidence_flag = sevM.agreement
                tier = SEV_TO_LEVEL[severity] >= 2 ? 'consensus' : 'contested'
            }
        }
        tiers[tier].push({
            ...rest, severity, tractability, confidence_flag,
            confidence: FLAG_TO_NUM[confidence_flag],
            blocks_goal: blocksGoal(tally),
            ...(judgement_call ? { judgement_call: true } : {}),
        })
    }
    for (const c of raisedClusters) {
        let tier, confidence_flag
        if (c.corroboration >= Math.ceil((2 * s) / 3)) { tier = 'consensus'; confidence_flag = 'high' }
        else if (c.corroboration > 1) { tier = 'contested'; confidence_flag = 'medium' }
        else { tier = 'contested'; confidence_flag = 'low' }
        tiers[tier].push({ ...c.rep, domain: 'panel', confidence_flag, confidence: FLAG_TO_NUM[confidence_flag] })
    }
    return tiers
}
```

- [ ] **Step 5: Rewrite `applyRubric` (severity-majority verdict, no numeric confidence gate)**

Replace `applyRubric` (L729–742) with:

```javascript
// Verdict rubric, first match wins. Row 1 (goal) scans consensus ∪ contested for blocks_goal
// (hasGoal-gated). Rows 2/3 scan consensus only. Row 3 has NO confidence gate: a majority
// Important (which is the only way a non-static Important reaches consensus) blocks — a
// 2/1 majority still blocks, because difficulty/doubt must never excuse a real defect.
function applyRubric(tiers, hasGoal) {
    const consensus = tiers.consensus ?? []
    const contested = tiers.contested ?? []
    if (hasGoal && [...consensus, ...contested].some(f => f.blocks_goal)) {
        return { verdict: 'REQUEST_CHANGES', rubricRowApplied: 1, rubricReason: 'goal not achieved (panel majority)' }
    }
    if (consensus.some(f => f.severity === 'Critical')) {
        return { verdict: 'REQUEST_CHANGES', rubricRowApplied: 2, rubricReason: 'consensus Critical' }
    }
    if (consensus.some(f => f.severity === 'Important')) {
        return { verdict: 'REQUEST_CHANGES', rubricRowApplied: 3, rubricReason: 'consensus Important (majority)' }
    }
    return { verdict: 'APPROVE', rubricRowApplied: 4, rubricReason: 'no blocking findings' }
}
```

- [ ] **Step 6: Stamp `envelope.panel = true` in `panelWrite`**

In `panelWrite` (L806), change the envelope construction:

```javascript
    const envelope = { verdict, rubricRowApplied, rubricReason, tiers, bodyText, panel: true }
```

- [ ] **Step 7: Run the full panel suite to verify it passes**

Run: `bash tests/run.sh 2>&1 | grep -E "FAIL|panel"`
Expected: all panel tests PASS; no FAIL lines. If `isVerdictRelevant` (still reading numeric `>=70`) mis-flags, note it — Task 6 migrates it; for now `confidence` numeric is still populated (75/90/50) so `>=70` holds for high/medium, which matches the majority-blocks intent.

- [ ] **Step 8: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_panel_review.sh
git commit -m "feat(panel): severity-majority verdict + agreement confidence, drop ratchet arithmetic"
```

---

### Task 4: Tractability routing + surfacing contract (inline / body / drop)

**Files:**
- Modify: `review-core.mjs` — `mapSpreadToTierConfidence` (stamp `posting`/`recommendation`/`annotation`), `finalizeBundle` (~L499–512, panel-branch comment/body sets), `isPosted` (~L817, respect `posting`).
- Test: `tests/lib/test_panel_review.sh`.

**Interfaces:**
- Consumes: each finding's `severity`, `tractability`, `judgement_call` from Task 3.
- Produces: each panel finding stamped `posting ∈ {inline, body, drop}`, `recommendation ∈ {fix-now, follow-up, null}`, optional `annotation`. `finalizeBundle` builds `commentSet` (`posting==='inline'`) and `bodySet` (`inline`|`body`); dropped findings appear only in the `dismissed` log tier with `dropped: true`.

**Routing rules (below the verdict line):**
| Case | posting | recommendation | tier |
|---|---|---|---|
| Blocking (consensus Critical/Important), tract Mechanical/Bounded | inline | fix-now | consensus |
| Blocking, tract Open-ended | inline | fix-now + `annotation` "open-ended remedy — do not dispatch a fix-agent; needs a designed change" | consensus |
| Suggestion + Mechanical | inline | fix-now | contested |
| Suggestion + Bounded | body | follow-up | contested |
| Suggestion + Open-ended | drop (`dropped:true`) | null | dismissed |
| Judgement call (severity scatter) | body | null | contested |
| Dismissed (majority not-real) | drop | null | dismissed |

- [ ] **Step 1: Write the failing tests**

```bash
# Suggestion + Mechanical → fix-now, posted inline as one comment.
test_panel_suggestion_mechanical_is_fix_now_inline() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"tidy this","suggested_fix":"rename"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "Suggestion never blocks → APPROVE"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "Suggestion+Mechanical posts inline (fix-now)"
    assert_equals "fix-now" "$(echo "$out" | jq -r '.log.findings[0].recommendation')" "Suggestion+Mechanical → fix-now"
}

# Suggestion + Open-ended → DROPPED: no comment, recorded in dismissed with dropped:true.
test_panel_suggestion_openended_is_dropped() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"big refactor idea","suggested_fix":"rethink module"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "open-ended suggestion posts nothing"
    assert_equals "true" "$(echo "$out" | jq -r '.log.findings[0].dropped')" "open-ended suggestion recorded dropped in log"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "dropped suggestion sits in dismissed tier"
}

# Suggestion + Bounded → body only (follow-up), no inline comment.
test_panel_suggestion_bounded_is_body_only() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"worth a follow-up","suggested_fix":"later"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "bounded suggestion is not an inline comment"
    assert_equals "follow-up" "$(echo "$out" | jq -r '.log.findings[0].recommendation')" "bounded suggestion → follow-up"
}

# Open-ended BLOCKER: still blocks (RC), posts inline, carries the do-not-dispatch annotation.
test_panel_openended_blocker_annotated_still_blocks() {
    local specs pans out
    specs='{"security":[{"file":"api.cs","line":12,"severity":"Important","confidence":88,"description":"missing role gate","suggested_fix":"add policy"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "open-ended Important still blocks"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "blocker posts inline"
    assert_matches "do not dispatch" "$(echo "$out" | jq -r '.log.findings[0].annotation')" "open-ended blocker carries the do-not-dispatch annotation"
}

# Judgement call (severity scatter) → PR-body only, no inline comment.
test_panel_judgement_call_is_body_only() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"contested stakes","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "judgement call does not block"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "judgement call is not an inline comment"
    assert_equals "true" "$(echo "$out" | jq -r '.log.findings[0].judgement_call')" "scatter finding flagged judgement_call"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run.sh 2>&1 | grep -E "fix now inline|is dropped|body only|blocker annotated|judgement call"`
Expected: FAIL — no routing fields yet; open-ended suggestions currently sit in contested and are not dropped.

- [ ] **Step 3: Add routing fields in `mapSpreadToTierConfidence`**

Add a routing helper above `mapSpreadToTierConfidence` and apply it when pushing each finding. Insert:

```javascript
// Route a resolved finding below the verdict line. Returns { posting, recommendation,
// annotation?, tierOverride? }. Blockers always post inline (fix-now) and gain a
// do-not-dispatch annotation when Open-ended. Suggestions route by tractability:
// Mechanical→inline fix-now, Bounded→body follow-up, Open-ended→drop (dismissed).
function routeFinding({ severity, tractability, judgement_call, blocking }) {
    if (blocking) {
        const annotation = tractability === 'Open-ended'
            ? 'open-ended remedy — do not dispatch a fix-agent; needs a designed change'
            : undefined
        return { posting: 'inline', recommendation: 'fix-now', ...(annotation ? { annotation } : {}) }
    }
    if (judgement_call) return { posting: 'body', recommendation: null }
    if (severity === 'Suggestion') {
        if (tractability === 'Mechanical') return { posting: 'inline', recommendation: 'fix-now' }
        if (tractability === 'Bounded') return { posting: 'body', recommendation: 'follow-up' }
        return { posting: 'drop', recommendation: null, dropped: true, tierOverride: 'dismissed' }
    }
    return { posting: 'body', recommendation: null }   // safety net (non-blocking, non-suggestion)
}
```

Then in `mapSpreadToTierConfidence`, at the point where each voted finding is pushed, compute `blocking` and merge the route. Replace the `tiers[tier].push({ ...rest, ... })` block with:

```javascript
        const blocking = tier === 'consensus'
        const route = routeFinding({ severity, tractability, judgement_call, blocking })
        const destTier = route.tierOverride ?? tier
        tiers[destTier].push({
            ...rest, severity, tractability, confidence_flag,
            confidence: FLAG_TO_NUM[confidence_flag],
            blocks_goal: blocksGoal(tally),
            posting: route.posting,
            recommendation: route.recommendation,
            ...(route.annotation ? { annotation: route.annotation } : {}),
            ...(route.dropped ? { dropped: true } : {}),
            ...(judgement_call ? { judgement_call: true } : {}),
        })
```

(Dismissed findings from the majority-not-real branch: give them `posting: 'drop', recommendation: null` too — set those two fields on that branch's push so the shape is uniform. Since dismissed is never posted, this is cosmetic but keeps the log consistent.)

Raised clusters: after computing `confidence_flag`, add `posting`/`recommendation` — a consensus raised finding is `posting:'inline', recommendation:'fix-now'`; a contested raised finding is `posting:'body', recommendation:'follow-up'`. (Task 5 refines raised routing to use raiser-supplied tractability.)

- [ ] **Step 4: Teach `finalizeBundle` + `isPosted` the panel surfacing contract**

In `isPosted` (L817), respect an explicit `posting` field:

```javascript
function isPosted(finding, verdict) {
    if (finding.posting) return finding.posting === 'inline'   // panel: explicit routing
    if (verdict === 'REQUEST_CHANGES') return true
    return (finding.confidence ?? 0) >= POST_THRESHOLD
}
```

In `finalizeBundle`, the PR-mode branch (L499–512): build `commentSet` (inline only) and `bodySet` (inline + body), and include the contested tier for the panel. Replace L500–509 with:

```javascript
    const verdict = envelope.verdict
    const consensus = envelope.tiers.consensus ?? []
    const contested = envelope.tiers.contested ?? []
    const synthFindings = envelope.tiers.synthesiser ?? []

    // Panel: contested carries fix-now/optional/judgement-call findings routed via `posting`.
    // Classic: contested is never posted, so only consensus + synth are candidates.
    const candidates = envelope.panel
        ? [...consensus, ...contested, ...synthFindings]
        : [...consensus, ...synthFindings]
    const commentSet = candidates.filter(f => isPosted(f, verdict))
    const bodySet = envelope.panel
        ? candidates.filter(f => f.posting === 'inline' || f.posting === 'body')
        : commentSet
    const suppressedCount = candidates.length - bodySet.length

    const comments = renderComments(commentSet)
    const bodyText = buildBody(envelope, bodySet, suppressedCount)
    const logPayload = buildLogPayload(envelope, phaseLog)

    return { verdict, bodyText, comments, log: logPayload }
```

- [ ] **Step 5: Run the routing tests + confirm classic path unaffected**

Run: `bash tests/run.sh 2>&1 | grep -E "fix now inline|is dropped|body only|blocker annotated|judgement call|absent mode|lightweight"`
Expected: all PASS. `test_absent_mode_takes_classic_path` still PASS (no `envelope.panel`, classic candidate set unchanged).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_panel_review.sh
git commit -m "feat(panel): tractability routing + inline/body/drop surfacing contract"
```

---

### Task 5: Raised findings routed on raiser-supplied axes

**Files:**
- Modify: `review-core.mjs` — `clusterRaised` (~L651, carry `tractability`), the raised-cluster loop in `mapSpreadToTierConfidence`.
- Test: `tests/lib/test_panel_review.sh`.

**Interfaces:**
- Consumes: `RAISED_SHAPE.tractability` (Task 2), `routeFinding` (Task 4).
- Produces: raised findings routed through the same table on their raiser-supplied `severity` + `tractability` (a raised Suggestion+Open-ended is dropped; a corroborated raised Important blocks + posts inline).

**Why raised is special:** raised findings are single-panelist (clustered by corroboration), not majority-voted — so they route on the *representative raiser's* axes, not a majority. Verdict still flows through the rubric: a raised finding placed in `consensus` with `severity==='Important'` blocks via row 3.

- [ ] **Step 1: Write the failing tests**

```bash
# A raised Suggestion + Open-ended is DROPPED even when corroborated by 2 panelists.
test_panel_raised_suggestion_openended_dropped() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"n.cs","line":20,"severity":"Suggestion","tractability":"Open-ended","confidence":40,"description":"open refactor","suggested_fix":"rethink"}]},{"votes":[],"raised":[{"file":"n.cs","line":22,"severity":"Suggestion","tractability":"Open-ended","confidence":90,"description":"open refactor","suggested_fix":"rethink"}]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "raised open-ended suggestion is not posted"
    assert_equals "true" "$(echo "$out" | jq -r '[.log.findings[] | select(.domain=="panel")][0].dropped')" "raised open-ended suggestion marked dropped"
}

# A raised Important corroborated by 2 of 3 → consensus → RC, posted inline.
test_panel_raised_important_blocks() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"n.cs","line":20,"severity":"Important","tractability":"Bounded","confidence":40,"description":"missing null check","suggested_fix":"guard"}]},{"votes":[],"raised":[{"file":"n.cs","line":22,"severity":"Important","tractability":"Bounded","confidence":90,"description":"missing null check","suggested_fix":"guard"}]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "corroborated raised Important → RC"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "corroborated raised Important posts inline"
}
```

Update the existing raised tests (`test_panel_raised_majority_is_consensus`, `test_panel_solo_raise_is_low_contested`, `test_panel_distant_raises_do_not_merge`) to add `"tractability":"Bounded"` to each raised fixture, and change the confidence assertion in `test_panel_raised_majority_is_consensus` from numeric `80` to `confidence_flag == "high"` (numeric 90 mapped; assert the flag instead), and `test_panel_solo_raise_is_low_contested` from `40` to `confidence_flag == "low"`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.sh 2>&1 | grep -E "raised suggestion openended|raised important blocks"`
Expected: FAIL — raised routing not yet applied; open-ended raised not dropped.

- [ ] **Step 3: Carry tractability through `clusterRaised`**

`clusterRaised` already spreads `c.rep` (which includes `tractability` now that `RAISED_SHAPE` carries it) — no change needed to the cluster mechanics. Confirm by reading `clusterRaised` (L651): `rep` is the first raise, spread verbatim. So `c.rep.tractability` is available. No edit.

- [ ] **Step 4: Route raised clusters in `mapSpreadToTierConfidence`**

Replace the raised-cluster loop with severity+tractability routing:

```javascript
    for (const c of raisedClusters) {
        let baseTier, confidence_flag
        if (c.corroboration >= Math.ceil((2 * s) / 3)) { baseTier = 'consensus'; confidence_flag = 'high' }
        else if (c.corroboration > 1) { baseTier = 'contested'; confidence_flag = 'medium' }
        else { baseTier = 'contested'; confidence_flag = 'low' }
        const severity = c.rep.severity
        const tractability = c.rep.tractability ?? 'Bounded'
        const blocking = baseTier === 'consensus' && (severity === 'Critical' || severity === 'Important')
        const route = routeFinding({ severity, tractability, judgement_call: false, blocking })
        const destTier = route.tierOverride ?? baseTier
        const { finding_id, ...rep } = c.rep
        tiers[destTier].push({
            ...rep, domain: 'panel', confidence_flag,
            confidence: FLAG_TO_NUM[confidence_flag],
            posting: route.posting,
            recommendation: route.recommendation,
            ...(route.annotation ? { annotation: route.annotation } : {}),
            ...(route.dropped ? { dropped: true } : {}),
        })
    }
```

(Note: a corroborated-but-`Suggestion` raised finding is not `blocking`, so it routes through the Suggestion arm — Mechanical→inline, Bounded→body, Open-ended→drop — exactly like a voted Suggestion. A corroborated Critical/Important raised finding blocks.)

- [ ] **Step 5: Run all raised tests**

Run: `bash tests/run.sh 2>&1 | grep -E "raised|solo raise|distant"`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_panel_review.sh
git commit -m "feat(panel): route raised findings on raiser-supplied severity + tractability"
```

---

### Task 6: Migrate numeric-confidence consumers + log fields

**Files:**
- Modify: `review-core.mjs` — `isVerdictRelevant` (~L833), `renderCommentBody` (~L845), `buildLogPayload` (~L975).
- Test: `tests/lib/test_panel_review.sh`.

**Interfaces:**
- Consumes: `confidence_flag`, `tractability`, `recommendation`, `annotation`, `judgement_call`, `dropped` on panel findings.
- Produces: the durable log records `confidence_flag`, `tractability`, `recommendation`, `dropped`; `renderCommentBody` prints the discrete flag (and the annotation/recommendation) for panel findings; `isVerdictRelevant` uses the majority-severity rule with no numeric gate.

- [ ] **Step 1: Write the failing tests**

```bash
# The durable log carries the new discrete/tractability columns for a panel finding.
test_panel_log_records_flag_and_tractability() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":100,"description":"bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "high" "$(echo "$out" | jq -r '.log.findings[0].confidence_flag')" "log records confidence_flag"
    assert_equals "Bounded" "$(echo "$out" | jq -r '.log.findings[0].tractability')" "log records tractability"
    assert_equals "fix-now" "$(echo "$out" | jq -r '.log.findings[0].recommendation')" "log records recommendation"
}

# An inline panel comment body renders the discrete flag, not a bare number, plus the fix-now
# recommendation.
test_panel_comment_body_shows_flag() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":100,"description":"bug","suggested_fix":"do x"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_matches "confidence high" "$(echo "$out" | jq -r '.comments[0].body')" "comment body renders discrete flag"
    assert_not_matches "confidence 90" "$(echo "$out" | jq -r '.comments[0].body')" "comment body does not print the shim number"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.sh 2>&1 | grep -E "log records flag|comment body shows"`
Expected: FAIL — log lacks `confidence_flag`/`tractability`; comment prints numeric confidence.

- [ ] **Step 3: `renderCommentBody` — print the flag + recommendation + annotation for panel findings**

Replace `renderCommentBody` (L845–850):

```javascript
function renderCommentBody(f) {
    const conf = f.confidence_flag ? `confidence ${f.confidence_flag}` : `confidence ${f.confidence}`
    let s = `**${f.severity}** (${conf})`
    if (f.recommendation) s += ` — ${f.recommendation === 'fix-now' ? 'fix in this PR' : 'raise as a follow-up'}`
    s += `\n\n${f.description}`
    if (f.annotation) s += `\n\n_${f.annotation}_`
    if (f.suggested_fix) s += `\n\n**Suggested fix:** ${f.suggested_fix}`
    if (f.reference) s += `\n\n${f.reference}`
    return s
}
```

- [ ] **Step 4: `buildLogPayload` — add the discrete + tractability columns**

In `buildLogPayload` (L982–993), extend the pushed record:

```javascript
      findings.push({
        tier,
        domain: f.domain || tier,
        severity: f.severity,
        confidence: f.confidence ?? 0,
        confidence_flag: f.confidence_flag ?? null,
        tractability: f.tractability ?? null,
        recommendation: f.recommendation ?? null,
        posting: f.posting ?? null,
        annotation: f.annotation ?? null,
        judgement_call: f.judgement_call ?? false,
        dropped: f.dropped ?? false,
        file: f.file || '',
        line: f.line ?? 0,
        description: f.description,
        suggested_fix: f.suggested_fix || '',
        verdict_relevant: isVerdictRelevant(f, tier, env.verdict, reason, i + 1, env.rubricRowApplied),
      })
```

- [ ] **Step 5: `isVerdictRelevant` — majority-severity, no numeric gate**

Replace the consensus block in `isVerdictRelevant` (L836–840) — drop the `>= 70` on Important (a consensus Important is a majority and always blocks now):

```javascript
    if (tier === 'consensus') {
        if (finding.severity === 'Critical') return true
        if (finding.severity === 'Important') return true
        if (consensusIndexToken && rubricReason && rubricReason.includes(`[#${consensusIndexToken}]`)) return true
    }
```

Leave the row-1 (`blocks_goal`) branch above it unchanged.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh 2>&1 | grep -cE "^\s*(✓|PASS)"` then `bash tests/run.sh 2>&1 | grep -E "FAIL"`
Expected: no FAIL lines; the two new tests PASS and all Task 3–5 tests still PASS.

- [ ] **Step 7: Grep audit for stragglers**

Run: `grep -n "\.confidence \?? 0\|confidence >= 70\|confidence >= POST_THRESHOLD\|f.confidence" plugins/code-review-suite/workflows/review-core.mjs`
Expected: remaining numeric reads are only in the **classic path** (`boundaryGateFires`, `crossAndSynth` synth-emitted findings, the classic `isPosted` fallback) — none on the panel path. If a panel-reachable numeric read remains, migrate it to the flag. Record any classic-only reads left in place as intentional.

- [ ] **Step 8: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_panel_review.sh
git commit -m "feat(panel): surface discrete confidence flag + tractability in comments and log"
```

---

### Task 7: A/B smoke validation on PR #98

**Files:** none (operator-run validation, no code).

**Interfaces:**
- Consumes: the fully implemented panel path (Tasks 1–6).
- Produces: evidence that the panel now returns REQUEST_CHANGES on PR #98's authZ finding, the tautological test lands as a fix-now inline suggestion, and no open-ended suggestion is posted.

- [ ] **Step 1: Run the structural suite once green end-to-end**

Run: `bash tests/run.sh`
Expected: full pass, 0 failures. This is the gate before spending a live A/B run.

- [ ] **Step 2: Seed the pre-registered criteria and launch a single-arm panel run**

The orchestration run needs a pre-registered `criteria.md` at `$CLAUDE_TEMP_DIR/criteria.md` (reuse the pilot's verbatim from `tests/ab/runs/20260713T090815Z-orchestration-pilot/`). Pass `CLAUDE_TEMP_DIR` inline (it is not exported into Bash tool calls). Single-arm launch needs `--defer-gate`; PR #98 is large — use `--timeout-seconds 3600` (1800 times out pre-synth). Exact command form is in the session transcript / handover "Verify first".

- [ ] **Step 3: Confirm the expected outcomes from the durable log**

Read the run's `panel/trial-001/` durable log and confirm:
- Verdict is `REQUEST_CHANGES`.
- The missing-role-gate finding is `severity: Important`, `tier: consensus`, `posting: inline`, and carries the open-ended `annotation` ("do not dispatch a fix-agent").
- The tautological idempotence assertion is `Suggestion` + `Mechanical`, `recommendation: fix-now`, posted inline.
- No finding with `posting: drop` / `dropped: true` appears in `.comments`.

- [ ] **Step 4: Open the PR**

Write the PR body to `${CLAUDE_TEMP_DIR}/pr-body.md` (contextual summary first, then the technical change list, per CLAUDE.md), then:

```bash
gh pr create --title "Panel review: impact-based severity + tractability routing" --base main --head feat/panel-severity-tractability --body-file ${CLAUDE_TEMP_DIR}/pr-body.md
```

---

## Self-Review

**1. Spec coverage:**
- Root cause 1 (severity in a vacuum) → Task 1 (brief re-anchor) + Task 3 (severity-majority rubric). ✓
- Root cause 2 (no "real but don't fix here") → Task 4 (tractability routing) + Task 2 (schema). ✓
- Axis 1 severity re-anchor → Task 1 + Task 3. ✓
- Static carve-out → Task 3 (Track B branch, tractability=Mechanical). ✓
- Axis 2 tractability → Task 2 (schema) + Task 3 (tally) + Task 4 (routing). ✓
- Verdict rubric (majority Critical/Important → RC; severity scatter → judgement bin; Suggestion never blocks) → Task 3. ✓
- Tractability prune/route table (fix-now/optional/drop) → Task 4. ✓
- Open-ended blocker annotation → Task 4. ✓
- Confidence = agreement, asymmetric scatter (severity→judgement bin, tractability→cautious) → Task 3 (`majorityOf`/`resolveTractability`). ✓
- Confidence only de-escalates; 2/1 majority still blocks → Task 3 (`test_panel_two_one_majority_important_blocks`, no numeric gate in `applyRubric`). ✓
- Surfacing contract (inline/body/drop) → Task 4 (`finalizeBundle`, `isPosted`). ✓
- Raised findings on raiser axes → Task 5. ✓
- Cruft removal (ratchet arithmetic) → Task 3 (`mapSpreadToTierConfidence` rewrite deletes `ceil(31/s)`/`ceil(50/s)`). ✓ (`is_real`/`blocks_goal` retained as removal candidates per Design Decision 2.)
- Numeric-consumer migration → Task 6. ✓
- Validation A/B → Task 7. ✓

**2. Placeholder scan:** No TBD/"handle appropriately"/"similar to Task N" — every code step shows full code; every test shows full fixtures. ✓

**3. Type consistency:** `confidence_flag` (`high`/`medium`/`low`), `tractability` (`Mechanical`/`Bounded`/`Open-ended`), `posting` (`inline`/`body`/`drop`), `recommendation` (`fix-now`/`follow-up`/`null`) are used identically across Tasks 3–6. `majorityOf`/`resolveTractability`/`routeFinding`/`FLAG_TO_NUM`/`TRACT_ORDER` are defined in Task 3–4 before use. `envelope.panel` set in Task 3, read in Task 4. `RAISED_SHAPE` defined in Task 2, used by `PANEL_SCHEMA` there. ✓
