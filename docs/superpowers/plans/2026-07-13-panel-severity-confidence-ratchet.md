# Panel Severity/Confidence Ratchet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the panel vote token into independent `is_real` + `severity` fields and combine them with a mechanical two-track ratchet, so the panel arm stops under-blocking (the 2026-07-13 pilot returned APPROVE where classic returned REQUEST_CHANGES on identical code).

**Architecture:** Three pure functions in `plugins/code-review-suite/workflows/review-core.mjs` change: `PANEL_SCHEMA` (the panelist output contract), `tallyVotes` (aggregation), and `mapSpreadToTierConfidence` (the ratchet + tier mapping). `applyRubric` is untouched — it keeps acting on the `consensus` tier, now populated by the ratchet instead of a near-impossible `real` supermajority. Track A (LLM findings) gets a symmetric severity notch + realness→confidence ratchet; Track B (static-analysis findings, identified by the existing module-scoped `STATIC` set) keeps locked severity + confidence-only ratchet + floor-50 + never-dismissed. `blocks_goal` rides through unchanged so rubric row 1 still fires.

**Tech Stack:** Node.js (ES module, but run under a sandbox that strips `export` and `eval`s the source — no `import()`, no exported functions). Bash + `jq` + `node -e` test harness (`tests/lib/test_panel_review.sh`). No new dependencies.

## Global Constraints

- **The pure helpers CANNOT be unit-tested in isolation** — `review-core.mjs` is eval'd as stripped source in a sandbox, so `export function` would break production. Every test drives the whole workflow end-to-end through `_pan_run_core` (mock specialists + mock panelists + mock writer) and asserts on the returned bundle's `.verdict`, `.comments`, and `.log.findings[].tier` / `.confidence` / `.severity`. Mirror the existing `test_panel_review.sh` pattern exactly.
- **`panelSize` (`N`) is a validated ODD integer ≥ 3.** Ratchet steps derive from `N` (surviving panelists), never a hardcoded constant. Do not add a constant to retune.
- **Track A/B discriminator is `STATIC.has(finding.domain)`** — the module-scoped `const STATIC = new Set(['jbinspect','eslint','ruff','trivy','housekeeper'])` at `review-core.mjs:239`. A flattened finding carries `domain` (stamped by `flattenFindings:609`). Do NOT match on `[eslint]`-style text tags or `rule_id` — `domain` is the mechanical field present at tally time.
- **Confidence gate is `≥ 70`.** Track A realness span is `31` (step `ceil(31/N)`) so unanimous `is_real:false` drops a spec-100 finding strictly below 70. Track B confidence span is `50` (step `ceil(50/N)`), clamped `max(50, 100 − Σsteps)`.
- **Severity levels:** `Suggestion = 1, Important = 2, Critical = 3`. Block iff `round(effectiveLevel) ≥ 2` AND effective confidence `≥ 70`.
- **`blocks_goal` must keep being tallied and stamped** onto each emitted finding (`blocks_goal: tally.blocks_goal > s / 2`), or `applyRubric` row 1 silently stops firing.
- **Non-real panelists abstain from the severity notch.** Only `is_real: true` panelists cast `upVotes`/`downVotes`. Divisor stays `N` (surviving count), not the real-only count.
- **No `.5`-boundary rounding test** — for odd `N`, `(up−down)/N` can never equal exactly `0.5`, so the tie-break is unreachable. Standard `Math.round` suffices.
- **Spec:** `docs/superpowers/specs/2026-07-13-panel-severity-confidence-ratchet-design.md` is the authority for any detail not repeated here.
- Run the full suite with `bash tests/run.sh` from repo root. There is no single-test runner; scope a run by temporarily sourcing one file, or just run the whole suite (it is fast). Expected baseline before this work: full green.

---

## File Structure

- **Modify** `plugins/code-review-suite/workflows/review-core.mjs`
  - `PANEL_SCHEMA` (`:104`) — replace `votes[].vote` enum with `is_real` (boolean) + `severity` (enum).
  - `tallyVotes` (`:623`) — tally `is_real`/`blocks_goal` counts and collect per-panelist severity opinions from `is_real:true` panelists.
  - `mapSpreadToTierConfidence` (`:658`) — the two-track ratchet + tier mapping. Reads module-scoped `STATIC`.
  - `applyRubric` (`:682`) — **unchanged**. Do not touch.
- **Modify** `plugins/code-review-suite/includes/panel-concern-brief.md` — rewrite the vote instructions to "two separate honest opinions, no arithmetic".
- **Modify** `tests/lib/test_panel_review.sh` — rewrite existing vote fixtures to the new schema; add ratchet-specific tests. This is where every behavioural assertion lives.

The three code changes are interdependent (schema → tally → ratchet form one data path) and share one test file, so Tasks 2–5 build them incrementally with the test harness green at each step. Task 1 updates the harness fixtures first (they currently emit the old `vote` enum and would break the moment the schema changes).

---

## Task 1: Migrate the test harness to the new vote schema (red baseline)

The existing `test_panel_review.sh` fixtures emit `{"vote":"real"}`. The schema change in Task 2 makes those fixtures invalid. This task converts every existing panelist fixture to `{"is_real":..., "severity":...}` and updates the assertions to the *new* expected behaviour, producing a RED suite that Tasks 2–5 turn green. This keeps the old passing tests meaningful rather than deleting them.

**Files:**
- Modify: `tests/lib/test_panel_review.sh` (all `_pan_run_core` fixtures with a `votes` array)
- Test: same file (it *is* the test)

**Interfaces:**
- Consumes: `_pan_run_core`, `_pan_args`, `_pan_args_goal` (unchanged helpers).
- Produces: the new-schema fixture convention every later task copies — a vote is `{"finding_id":N,"is_real":true|false,"severity":"Critical|Important|Suggestion","blocks_goal":bool,"rationale":"r"}`.

- [ ] **Step 1: Convert the vote fixtures.** In each test function that has a `pans=` line with `"vote":"..."`, replace every vote object. Translation rule for the *specialist-anchored* Track A tests: `real` → `{"is_real":true,"severity":<match the specialist severity in that test's `specs`>}`; `not_a_problem` → `{"is_real":false,"severity":<specialist severity>}`; `minor` → `{"is_real":true,"severity":"Suggestion"}`. Keep `blocks_goal` and `rationale` as-is. Example — `test_panel_unanimous_real_important_is_rc` (specialist severity is `Important`):

```bash
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
```

- [ ] **Step 2: Update the assertions to new expected behaviour.** Under the ratchet, a unanimous-real Important with all panelists agreeing severity=Important stays Important, confidence stays ≥ 70 (no `is_real:false` votes → no confidence drop) → blocks → consensus → RC. So `test_panel_unanimous_real_important_is_rc` still expects `REQUEST_CHANGES` and 1 comment — assertion unchanged, only the fixture changed. Work through each test; the detailed target behaviours are specified in Tasks 3–5. For this task, just get the fixtures onto the new schema and set assertions to match the spec's ratchet outcome.

- [ ] **Step 3: Run the suite to confirm it is RED.**

Run: `bash tests/run.sh`
Expected: FAIL — the panel tests error or mis-verdict because `review-core.mjs` still reads the old `vote` enum (production `tallyVotes` looks for `v.vote === 'real'`, which is now `undefined`), so every finding tallies zero and lands dismissed. This red state is the target: it proves the tests exercise the new schema.

- [ ] **Step 4: Commit the red harness.**

```bash
git add tests/lib/test_panel_review.sh
git commit -m "test(panel): migrate vote fixtures to is_real + severity schema (red)"
```

---

## Task 2: Replace the PANEL_SCHEMA vote token

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs:104-129` (the `PANEL_SCHEMA` `votes[].items`)
- Test: `tests/lib/test_panel_review.sh` (via Task 1's fixtures)

**Interfaces:**
- Consumes: nothing new.
- Produces: the panelist vote object shape `{finding_id:int, is_real:bool, severity:enum, blocks_goal:bool, rationale:string}` that `tallyVotes` (Task 3) reads.

- [ ] **Step 1: Edit the schema.** Replace the `vote` property and the `required` list inside `PANEL_SCHEMA.properties.votes.items`:

```javascript
                required: ['finding_id', 'is_real', 'severity', 'blocks_goal', 'rationale'],
                properties: {
                    finding_id: { type: 'integer', minimum: 0, description: 'Index into the flattened Stage-1 finding list.' },
                    is_real: { type: 'boolean', description: 'True issue vs false positive — purely epistemic, independent of importance.' },
                    severity: { enum: ['Critical', 'Important', 'Suggestion'], description: "The panelist's own honest severity opinion. Ignored for static-analysis findings (severity is locked)." },
                    blocks_goal: { type: 'boolean', description: 'True iff this finding shows the stated goal is not achieved. Always false when no goal is in scope.' },
                    rationale: { type: 'string' },
                },
```

- [ ] **Step 2: Update the `PANEL_SCHEMA` header comment** (`:99-103`) so it describes `is_real` + `severity` instead of the `vote` enum. One-line change to the "votes every Stage-1 finding" sentence: note the split into realness + severity.

- [ ] **Step 3: Run the suite.**

Run: `bash tests/run.sh`
Expected: still FAIL (production `tallyVotes` / `mapSpreadToTierConfidence` don't yet read the new fields), but NOT a schema-validation error. The bundle should still be valid JSON. This isolates the schema change as correct-in-shape.

- [ ] **Step 4: Commit.**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs
git commit -m "feat(panel): replace vote enum with is_real + severity in PANEL_SCHEMA"
```

---

## Task 3: Rewrite tallyVotes to aggregate the two axes

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs:622-636` (`tallyVotes`)
- Test: `tests/lib/test_panel_review.sh`

**Interfaces:**
- Consumes: the new vote shape from Task 2; `flat` (flattened findings, each with `domain`, `severity`, `confidence`, `finding_id`).
- Produces: a per-finding tally object `{ finding, tally }` where `tally = { is_real_true, is_real_false, blocks_goal, sevVotes }`. `sevVotes` is an array of severity strings from `is_real:true` panelists only (used by the Track-A notch). This is the exact shape `mapSpreadToTierConfidence` (Task 4) consumes.

- [ ] **Step 1: Rewrite the function.**

```javascript
// Aggregate the two independent axes per Stage-1 finding across surviving panelists.
// is_real_true / is_real_false drive the realness→confidence ratchet; sevVotes (from
// is_real:true panelists only) drive the severity notch; blocks_goal is the panel
// majority feeding applyRubric row 1. A panelist who voted is_real:false abstains from
// the severity notch (a severity opinion on a false positive is incoherent).
function tallyVotes(panelists, flat) {
    return flat.map(f => {
        const tally = { is_real_true: 0, is_real_false: 0, blocks_goal: 0, sevVotes: [] }
        for (const p of panelists) {
            const v = (p.votes ?? []).find(x => x.finding_id === f.finding_id)
            if (!v) continue
            if (v.is_real) {
                tally.is_real_true++
                tally.sevVotes.push(v.severity)
            } else {
                tally.is_real_false++
            }
            if (v.blocks_goal) tally.blocks_goal++
        }
        return { finding: f, tally }
    })
}
```

- [ ] **Step 2: Run the suite.**

Run: `bash tests/run.sh`
Expected: still FAIL — `mapSpreadToTierConfidence` still reads the old `tally.real`/`tally.minor`/`tally.not_a_problem` fields, which are now `undefined`, so tiering is wrong. Confirm no crash/throw (the bundle is still valid JSON).

- [ ] **Step 3: Commit.**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs
git commit -m "feat(panel): tally is_real + severity axes, abstaining non-real from severity"
```

---

## Task 4: Implement the two-track ratchet in mapSpreadToTierConfidence

This is the core task. It rewrites the voted-finding branch of `mapSpreadToTierConfidence` with the Track A/B dispatch. The `raisedClusters` branch (`:669-675`) is **out of scope** — leave it exactly as-is (raised findings have no Stage-1 anchor; the spec defers them).

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs:658-677` (`mapSpreadToTierConfidence`, voted-finding loop only)
- Test: `tests/lib/test_panel_review.sh`

**Interfaces:**
- Consumes: `voteTallies` (Task 3 shape), `raisedClusters` (unchanged), `s` (surviving panelist count = `N`), module-scoped `STATIC`.
- Produces: the four-tier envelope `{consensus, synthesiser, contested, dismissed}` where each pushed finding carries `confidence` (ratcheted int), `severity` (Track A: effective; Track B: locked), and `blocks_goal` (panel majority bool). `finding_id` is dropped (not a `FINDING_SHAPE` property). Consumed by `applyRubric` (unchanged).

- [ ] **Step 1: Write the failing tests first.** Add these to `tests/lib/test_panel_review.sh`. (Fixtures use the Task-1 schema.)

Test A — Track A severity UPGRADE promotes a Suggestion to a blocking Important. N=3, specialist says Suggestion/confidence 100, all 3 vote `is_real:true` severity=Important. Notch: up=3, down=0 → effectiveLevel = clamp(1 + 3/3, 1, 3) = 2 → Important; confidence 100 (no is_real:false) ≥ 70 → blocks → consensus → RC.

```bash
test_panel_trackA_severity_upgrade_blocks() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"nit that matters","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "unanimous severity upgrade Suggestion→Important blocks → RC"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "upgraded finding lands in consensus"
}
```

Test B — Track A realness ratchet: unanimous `is_real:false` drops a spec-100 Important below 70 → not blocking → dismissed. N=3, step ceil(31/3)=11, 3×11=33, 100−33=67 < 70.

```bash
test_panel_trackA_realness_drops_below_gate() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"maybe false","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "unanimous is_real:false → confidence 67 < 70 → not blocking"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority is_real:false → dismissed"
}
```

Test C — Track A confidence-anchored asymmetry: a spec-100 Important with ONE is_real:false stays blocking (100−11=89 ≥ 70), severity intact (2 real votes agree Important; up=down=0) → consensus → RC.

```bash
test_panel_trackA_single_dissent_still_blocks() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"solid bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "spec-100 Important with 1 dissent → confidence 89 ≥ 70 → still blocks"
}
```

Test D — Non-real panelists abstain from the severity notch. N=3, specialist Suggestion/100; 2 vote is_real:false (severity field present but must be ignored), 1 votes is_real:true severity=Critical. If non-real votes counted, up would swamp; with abstention, up=1 (the one real Critical), down=0, effectiveLevel = 1 + 1/3 = 1.33 → rounds to 1 (Suggestion) → not blocking. Also is_real_false=2 → majority not-real → dismissed.

```bash
test_panel_trackA_nonreal_abstains_from_severity() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"nit","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "non-real Critical votes abstain from notch → stays Suggestion, majority not-real → dismissed"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority is_real:false → dismissed regardless of their severity field"
}
```

Test E — Track B static severity is LOCKED and never dismissed. Domain `eslint` (in STATIC), specialist Important; all 3 vote is_real:false severity=Suggestion. Severity stays Important (locked, no notch); confidence 100−3×ceil(50/3)=100−51 → clamp max(50,49)=50; 50 < 70 → not blocking → contested (NOT dismissed).

```bash
test_panel_trackB_static_locked_and_never_dismissed() {
    local specs pans out
    specs='{"eslint":[{"file":"a.js","line":2,"severity":"Important","confidence":100,"rule_id":"no-eval","description":"eval used","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "static floor-50 confidence < 70 → not blocking"
    assert_equals "contested" "$(echo "$out" | jq -r '.log.findings[0].tier')" "static finding with heavy dissent → contested, NEVER dismissed"
    assert_equals "Important" "$(echo "$out" | jq -r '.log.findings[0].severity')" "static severity is locked — panel Suggestion votes ignored"
    assert_equals "50" "$(echo "$out" | jq -r '.log.findings[0].confidence')" "static confidence clamps at floor 50"
}
```

Test F — Track B static blocks when undissented. Domain `trivy`, Important, all 3 is_real:true → confidence stays 100, severity locked Important, 100 ≥ 70 → blocks → consensus → RC.

```bash
test_panel_trackB_static_blocks_when_undissented() {
    local specs pans out
    specs='{"trivy":[{"file":"main.tf","line":5,"severity":"Important","confidence":100,"rule_id":"AVD-AWS-0089","description":"public bucket","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "undissented static Important (conf 100) → consensus → RC"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "undissented static → consensus"
}
```

- [ ] **Step 2: Run the new tests to verify they FAIL.**

Run: `bash tests/run.sh`
Expected: the six new tests FAIL (production still reads the old tally fields; every finding mis-tiers). Confirm they fail for the RIGHT reason — wrong verdict/tier, not a JSON parse error.

- [ ] **Step 3: Implement the two-track ratchet.** Replace the voted-finding loop (the `for (const { finding, tally } of voteTallies)` block) in `mapSpreadToTierConfidence`. Leave the `raisedClusters` loop untouched.

```javascript
function mapSpreadToTierConfidence(voteTallies, raisedClusters, s) {
    const tiers = { consensus: [], synthesiser: [], contested: [], dismissed: [] }
    const SEV_TO_LEVEL = { Suggestion: 1, Important: 2, Critical: 3 }
    const LEVEL_TO_SEV = { 1: 'Suggestion', 2: 'Important', 3: 'Critical' }
    const majorityNotReal = t => t.is_real_false > t.is_real_true
    const blocksGoal = t => t.blocks_goal > s / 2
    for (const { finding, tally } of voteTallies) {
        const { finding_id, ...rest } = finding
        const isStatic = STATIC.has(finding.domain)
        let tier, confidence, severity

        if (isStatic) {
            // Track B — severity locked, confidence-only ratchet, floor 50, never dismissed.
            const step = Math.ceil(50 / s)
            confidence = Math.max(50, 100 - tally.is_real_false * step)
            severity = finding.severity // locked
            const blocks = SEV_TO_LEVEL[severity] >= 2 && confidence >= 70
            tier = blocks ? 'consensus' : 'contested'
        } else {
            // Track A — realness→confidence ratchet + symmetric severity notch.
            const step = Math.ceil(31 / s)
            confidence = Math.max(0, (finding.confidence ?? 0) - tally.is_real_false * step)
            const specLevel = SEV_TO_LEVEL[finding.severity] ?? 1
            let up = 0, down = 0
            for (const sv of tally.sevVotes) {
                const lvl = SEV_TO_LEVEL[sv] ?? specLevel
                if (lvl > specLevel) up++
                else if (lvl < specLevel) down++
            }
            const effLevel = Math.min(3, Math.max(1, specLevel + (up - down) / s))
            const roundedLevel = Math.round(effLevel)
            severity = LEVEL_TO_SEV[roundedLevel]
            const blocks = roundedLevel >= 2 && confidence >= 70
            if (blocks) tier = 'consensus'
            else if (majorityNotReal(tally)) tier = 'dismissed'
            else tier = 'contested'
        }
        tiers[tier].push({ ...rest, severity, confidence, blocks_goal: blocksGoal(tally) })
    }
    for (const c of raisedClusters) {
        let tier, confidence
        if (c.corroboration >= Math.ceil((2 * s) / 3)) { tier = 'consensus'; confidence = 80 }
        else if (c.corroboration > 1) { tier = 'contested'; confidence = 60 }
        else { tier = 'contested'; confidence = 40 }
        tiers[tier].push({ ...c.rep, domain: 'panel', confidence })
    }
    return tiers
}
```

Note: `{ ...rest, severity, ... }` overrides the finding's original `severity` with the effective (Track A) or locked (Track B, identical) value. `rest` still carries `domain`, `file`, `line`, `description`, `suggested_fix`, `rule_id`. `superT` is no longer used for voted findings — keep it only inside the `raisedClusters` loop (inlined above as `Math.ceil((2*s)/3)`), and delete the now-unused top-level `const superT` line if present.

- [ ] **Step 4: Run the suite to verify the six new tests + Task-1 migrated tests pass.**

Run: `bash tests/run.sh`
Expected: PASS for Tests A–F and all Task-1 migrated panel tests. If a Task-1 test still fails, its assertion needs reconciling with the ratchet (e.g. `test_panel_contested_not_posted` — 1 real / 2 not-real is now majority-not-real → dismissed, not contested; update that assertion to `dismissed`). Fix such fixtures/assertions now.

- [ ] **Step 5: Update the function header comment** (`:654-657`) to describe the two-track ratchet instead of the `real/minor/not_a_problem` spread.

- [ ] **Step 6: Commit.**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_panel_review.sh
git commit -m "feat(panel): two-track severity/confidence ratchet in tier mapping"
```

---

## Task 5: Verify blocks_goal still drives rubric row 1 + N=5 scaling

Guards the two properties most likely to silently regress: `blocks_goal` carry-through (Gap 2 from spec review) and `N`-scaling of the ratchet.

**Files:**
- Modify: `tests/lib/test_panel_review.sh` (add tests)
- Test: same file

**Interfaces:**
- Consumes: everything from Tasks 2–4.
- Produces: no new interface — regression guards only.

- [ ] **Step 1: Write the tests.**

Test G — row 1 still fires on a goal-blocking consensus finding. Goal present; specialist Suggestion/100; all 3 vote is_real:true, severity=Suggestion (no upgrade → stays Suggestion, rows 2/3 inert), blocks_goal=true on 2 of 3. Must be RC via row 1 — proving `blocks_goal` rode through the ratchet.

```bash
test_panel_ratchet_row1_still_fires() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "goal + majority blocks_goal on a Suggestion → RC row 1 (blocks_goal survived ratchet)"
}
```

Wait — for row 1 the finding must be in the `consensus` tier (`applyRubric` reads `consensus.some(f => f.blocks_goal)`). A unanimous-real Suggestion with no confidence drop: confidence 100 ≥ 70 but roundedLevel=1 < 2 → NOT blocking → lands `contested`, not `consensus`. So row 1 would NOT fire. This mirrors the OLD behaviour: check `test_panel_row1_fires_on_goal_block` in the current suite — under the old code a majority-real finding hit `consensus` even as a Suggestion (real=3 ≥ superT=2). **The ratchet changes this**: a Suggestion no longer reaches consensus on realness alone. Confirm the intended semantics with the finding below before asserting.

- [ ] **Step 2: Resolve the row-1/consensus-tier interaction.** This is a genuine design question the ratchet surfaces: under the old tiering, a majority-`real` finding of ANY severity landed in `consensus`, so a goal-blocking Suggestion could drive row 1. Under the new ratchet, only severity-≥-Important-AND-confidence-≥-70 findings reach `consensus` — a real-but-Suggestion finding lands in `contested`, so `applyRubric` row 1 (which scans only `consensus`) can no longer see it. **STOP and flag this to the reviewer/user**: either (a) row 1 should scan `consensus ∪ contested` for `blocks_goal` (preserves old behaviour — a goal-blocking finding blocks regardless of severity), or (b) accept that goal-blocking now requires the finding to independently clear the severity+confidence gate (stricter). The spec says "`applyRubric` unchanged" which implies (b), but that silently weakens row 1. Do not guess — get a decision, then write Test G to match. Record the decision inline in the plan and in the spec's tier-mapping section.

- [ ] **Step 3: Write the N=5 scaling test** (independent of Step 2). Track A realness step at N=5 is ceil(31/5)=7; unanimous is_real:false on spec-100 Important → 100−5×7=65 < 70 → not blocking → dismissed.

```bash
test_panel_n5_realness_scaling() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"n5 bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 5)" "$specs" "$pans")
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "N=5: 5×ceil(31/5)=35 drop → conf 65 < 70 → dismissed"
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "N=5 unanimous not-real → APPROVE"
}
```

- [ ] **Step 4: Run the suite.**

Run: `bash tests/run.sh`
Expected: PASS (Test G per the Step-2 decision; N=5 test passes).

- [ ] **Step 5: Commit.**

```bash
git add tests/lib/test_panel_review.sh plugins/code-review-suite/workflows/review-core.mjs docs/superpowers/specs/2026-07-13-panel-severity-confidence-ratchet-design.md
git commit -m "test(panel): guard blocks_goal row-1 survival and N=5 ratchet scaling"
```

---

## Task 6: Rewrite the panelist concern brief

The panelists are LLMs; the brief is their instruction. It must match the new schema or the panelists will emit the wrong shape at runtime.

**Files:**
- Modify: `plugins/code-review-suite/includes/panel-concern-brief.md:5-9` and `:31-34`
- Test: none automatable (prose). Verified by reading + the `test_panel_wiring.sh` / sync-note tests if they reference the brief.

**Interfaces:**
- Consumes: nothing.
- Produces: runtime instruction consistent with `PANEL_SCHEMA` (Task 2).

- [ ] **Step 1: Rewrite the intro** (`:5-9`). Replace "Vote each Stage-1 finding `real`, `minor`, or `not_a_problem`" with the two-axis instruction:

```markdown
For each Stage-1 finding, emit two INDEPENDENT judgements and do no arithmetic:
`is_real` (is this a true issue or a false positive? — purely epistemic) and `severity`
(`Critical`, `Important`, or `Suggestion` — how much it matters, your honest opinion). A
genuine but low-stakes finding is `is_real: true, severity: Suggestion`. Do not fuse the
two; do not compute thresholds or tiers — the rubric combines your opinions mechanically.
Also raise any net-new cross-cutting issue the specialists missed.
```

- [ ] **Step 2: Rewrite the closing severity note** (`:31-34`). Replace the `real`/`minor`/`not_a_problem` gloss:

```markdown
Vote independently. Do not assume the other panelists or the specialists are right — your
disagreement is the signal that surfaces contested findings. Answer the two questions
separately: `is_real` is your epistemic call (true issue vs false positive); `severity` is
your honest importance rating even for a finding you think is real but minor. For
static-analysis findings (eslint, ruff, trivy, jbinspect, housekeeper) your `severity` is
advisory only — the tool's severity is authoritative and the rubric locks it.
```

- [ ] **Step 3: Check for a sync-note or wiring test** that pins the brief's vocabulary.

Run: `bash tests/run.sh 2>&1 | grep -iE "sync|wiring|brief" || echo "no brief-coupled test failures"`
Expected: no failures. If `test_sync_notes.sh` or `test_panel_wiring.sh` pins the old vote words, update the pinned regex/string there too, and re-run.

- [ ] **Step 4: Commit.**

```bash
git add plugins/code-review-suite/includes/panel-concern-brief.md
git commit -m "docs(panel): rewrite concern brief for is_real + severity two-axis vote"
```

---

## Task 7: Full-suite green + spec status bump

**Files:**
- Modify: `docs/superpowers/specs/2026-07-13-panel-severity-confidence-ratchet-design.md:4` (status line)
- Test: full suite

- [ ] **Step 1: Run the entire suite.**

Run: `bash tests/run.sh`
Expected: full green (matching the pre-work baseline count plus the new panel tests, 0 failures). If any non-panel test regressed, investigate — the change is scoped to panel functions and should not touch classic.

- [ ] **Step 2: Bump the spec status** from `design (awaiting review)` to `implemented` (or `design (implemented)`), and add a one-line pointer to this plan.

- [ ] **Step 3: Commit.**

```bash
git add docs/superpowers/specs/2026-07-13-panel-severity-confidence-ratchet-design.md
git commit -m "docs(panel): mark ratchet spec implemented"
```

- [ ] **Step 4: Validate plugin structure** (marketplace convention check).

Run: `bash tests/run.sh` (already covers structural tests) — confirm the manifest/convention tests are green.

---

## Self-Review Notes

- **Spec coverage:** PANEL_SCHEMA change → Task 2; tallyVotes → Task 3; two-track ratchet + tier mapping → Task 4; concern brief → Task 6; `applyRubric` unchanged → respected throughout; test list (step sizing N=3/N=5, confidence-anchored asymmetry, severity notch abstention, static lock/floor-50/never-dismissed, realness veto, blocks_goal row-1) → Tasks 4 & 5. `raised[]` out-of-scope → Task 4 leaves that loop untouched. All spec sections covered.
- **Open design question surfaced (Task 5, Step 2):** the ratchet changes which findings reach the `consensus` tier, which interacts with `applyRubric` row 1's `consensus`-only scan. This is a real semantic decision (does a goal-blocking Suggestion still block?) that the spec's "applyRubric unchanged" glosses over. The plan STOPS for a human decision rather than guessing — this is the one item requiring input during execution.
- **Type consistency:** tally shape `{is_real_true, is_real_false, blocks_goal, sevVotes}` defined in Task 3, consumed verbatim in Task 4. `STATIC` referenced as module-scoped (confirmed at `review-core.mjs:239`). Vote object shape consistent across Tasks 1/2/3.
- **No placeholders:** every code and test step contains complete, runnable content.
