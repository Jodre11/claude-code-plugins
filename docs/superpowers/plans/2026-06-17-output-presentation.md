# Output Presentation & Mechanical Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the posted code-review output into a tight action document for the reviewee (headline verdict, promoted assessment, one-line finding index pointing to per-finding comments, reformatted dependency table) while persisting the full unfiltered analytical record to an opt-in durable log.

**Architecture:** All logic changes live in the Workflow core `review-core.mjs` (the default orchestration path) as pure, node-eval-testable functions. The core *returns* an extra `log` payload in its sealed bundle; the markdown host (which has Bash/filesystem access the sandbox lacks) writes the durable log files and posts file-level comments. The inline Class A–D markdown fallback (`$USE_WORKFLOW == false`) is explicitly OUT OF SCOPE.

**Tech Stack:** JavaScript ES module (Workflow sandbox dialect — no `import()`, no `Date.now()`/`new Date()`, no filesystem), Bash test harness (`tests/lib/*.sh` driven by node-eval), JSON Schema (`includes/finding-schema.json`), Markdown host skills.

## Global Constraints

- Bash: one command per call; no `&&`/`||`/`;`/`$(...)`/subshells/pipes/redirects (HEREDOC commit messages exempt). Copied verbatim from CLAUDE.md.
- Markdown/JSON: 2-space indent. Shell: 4-space indent. All text files: LF line endings, final newline.
- `plugin.json` carries no `version` field (version = marketplace git SHA).
- Commits: focused, one logical group each; NO `Co-Authored-By` trailer.
- Workflow sandbox forbids `Date.now()`, `Math.random()`, argless `new Date()`, `import()`, and all filesystem/Node APIs inside `review-core.mjs`. Timestamps and SHAs are passed IN from the host.
- The synthesiser agent prompt and prose output format are NOT modified. Only the envelope **schema** (`file` becomes optional) changes.
- The verdict rubric, the user-confirmation gate (Class A), the inline comment body format, the ≥75 APPROVE filter, and the REQUEST_CHANGES=post-everything rule are NOT changed.
- Full log is OFF by default (`orchestration.full_log` in `.claude/code-review.toml`).

**Reference spec:** `docs/superpowers/specs/2026-06-17-output-presentation-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `plugins/code-review-suite/includes/finding-schema.json` | Canonical schema. Make `finding.file` optional; document `sealedBundle.comments[].subjectType` + `sealedBundle.log`. | Modify |
| `plugins/code-review-suite/workflows/review-core.mjs` | All presentation logic: finding classification, log payload, anchor-ladder comment routing, body construction, dependency reformat. | Modify |
| `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` | PR host: post file-level comments; write durable log when toggled on. | Modify |
| `plugins/code-review-suite/commands/pre-review.md` | Local host: write durable log when toggled on (no posting). | Modify |
| `tests/lib/test_output_presentation.sh` | New node-eval-driven structural + behavioural tests for the above. | Create |

The new functions added to `review-core.mjs` are testable by evaluating the whole script with mock globals where `agent()` returns crafted envelopes keyed on the call `label` — exactly the pattern in `tests/lib/test_workflow_migration.sh:210-256`.

---

## Task 1: Schema — make `file` optional, document bundle extensions

**Files:**
- Modify: `plugins/code-review-suite/includes/finding-schema.json`
- Modify: `plugins/code-review-suite/workflows/review-core.mjs:30-44` (the `FINDING_SHAPE` const)
- Test: `tests/lib/test_output_presentation.sh` (create), plus existing `tests/lib/test_workflow_migration.sh::test_inlined_schema_matches_canonical` must stay green.

**Interfaces:**
- Produces: a `finding` shape whose `required` no longer lists `file`; a `sealedBundle` whose `comments[].subjectType` (optional enum `["file"]`) and `log` (optional object) are documented.
- Consumes: nothing from earlier tasks (this is the foundation).

- [ ] **Step 1: Write the failing test**

Create `tests/lib/test_output_presentation.sh` with this first test:

```bash
#!/usr/bin/env bash
# Output-presentation tests: schema relaxation, log payload, anchor ladder,
# body construction, dependency reformat. review-core.mjs logic is exercised by
# evaluating the whole script with mock globals (see _op_run_core below).

_op_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

test_finding_file_is_optional() {
    local cr
    cr=$(_op_cr_dir)
    local schema="$cr/includes/finding-schema.json"
    # `file` MUST NOT be in finding.required (fileless findings are valid).
    if jq -e '.["$defs"].finding.required | index("file")' "$schema" >/dev/null 2>&1; then
        fail "finding.file is optional" "file still listed in finding.required"
    else
        pass "finding.file is optional (not in required)"
    fi
    # `file` MUST still be a declared property (optional, not removed).
    if jq -e '.["$defs"].finding.properties.file' "$schema" >/dev/null 2>&1; then
        pass "finding.file still a declared property"
    else
        fail "finding.file still a declared property" "file property was removed entirely"
    fi
    # sealedBundle.comments items document the optional subjectType discriminator.
    if jq -e '.["$defs"].sealedBundle.properties.comments.items.properties.subjectType' "$schema" >/dev/null 2>&1; then
        pass "sealedBundle.comments[].subjectType documented"
    else
        fail "sealedBundle.comments[].subjectType documented" "missing optional file-level anchor discriminator"
    fi
    # sealedBundle documents the log payload field.
    if jq -e '.["$defs"].sealedBundle.properties.log' "$schema" >/dev/null 2>&1; then
        pass "sealedBundle.log documented"
    else
        fail "sealedBundle.log documented" "missing log payload field"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `file still listed in finding.required`, and the two bundle assertions fail (fields not yet documented).

- [ ] **Step 3: Edit `finding-schema.json` — relax `file`, document bundle fields**

In `$defs.finding`, change the `required` array from:

```json
"required": ["file", "line", "severity", "confidence", "description", "suggested_fix"],
```

to (drop `file`):

```json
"required": ["line", "severity", "confidence", "description", "suggested_fix"],
```

In `$defs.sealedBundle.properties.comments.items`, change `required` and `properties` to add the optional discriminator. Replace the items object with:

```json
"items": {
  "type": "object",
  "additionalProperties": false,
  "required": ["path", "body"],
  "properties": {
    "path": { "type": "string" },
    "line": { "type": "integer", "minimum": 1, "description": "Omitted for file-level comments (subjectType=file)." },
    "side": { "enum": ["RIGHT", "LEFT"], "description": "Omitted for file-level comments." },
    "subjectType": { "enum": ["file"], "description": "Present only for file-level comments (no usable line). Absent for line-level comments." },
    "body": { "type": "string" }
  }
}
```

In `$defs.sealedBundle.properties`, after `comments`, add the `log` field:

```json
"log": {
  "type": "object",
  "description": "Full unfiltered analytical payload for the durable log. Host writes it to disk when orchestration.full_log is true; absent on lightweight/empty bundles.",
  "additionalProperties": false,
  "required": ["bodyText", "findings"],
  "properties": {
    "bodyText": { "type": "string", "description": "The synthesiser's complete verbatim prose (all sections)." },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["tier", "severity", "confidence", "description", "verdict_relevant"],
        "properties": {
          "tier": { "enum": ["consensus", "synthesiser", "contested", "dismissed"] },
          "domain": { "type": "string" },
          "severity": { "enum": ["Critical", "Important", "Suggestion"] },
          "confidence": { "type": "integer", "minimum": 0, "maximum": 100 },
          "file": { "type": "string" },
          "line": { "type": "integer", "minimum": 0 },
          "description": { "type": "string" },
          "suggested_fix": { "type": "string" },
          "verdict_relevant": { "type": "boolean" }
        }
      }
    }
  }
}
```

- [ ] **Step 4: Edit `review-core.mjs` `FINDING_SHAPE` to match**

At `review-core.mjs:33`, change:

```javascript
    required: ['file', 'line', 'severity', 'confidence', 'description', 'suggested_fix'],
```

to:

```javascript
    required: ['line', 'severity', 'confidence', 'description', 'suggested_fix'],
```

(Leave the `file` property declaration at line 35 unchanged — it stays optional.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test_finding_file_is_optional` all green, AND `test_inlined_schema_matches_canonical` stays green (both `FINDING_SHAPE` and the canonical `finding` def changed identically, so the flatten-and-compare still matches).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/includes/finding-schema.json plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_output_presentation.sh
git commit -m "feat(code-review): make finding.file optional, document bundle log + file-level comments"
```

---

## Task 2: review-core — finding classification helpers (posted set + verdict-relevance)

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (add pure helpers in the helpers block after line 300)
- Test: `tests/lib/test_output_presentation.sh`

**Interfaces:**
- Produces:
  - `isPosted(finding, verdict)` → boolean. `REQUEST_CHANGES` → true for all; `APPROVE` → `finding.confidence >= 75`.
  - `isVerdictRelevant(finding, tier, verdict, rubricRowApplied, rubricReason, indexToken)` → boolean. APPROVE → false. RC → Critical (any conf) OR Important≥70 in consensus, OR finding whose `[#N]` token appears in `rubricReason`.
  - `POST_THRESHOLD = 75` (already exists at line 279; reuse it).
- Consumes: Task 1's optional-`file` finding shape.

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_output_presentation.sh` this helper (evaluates the script prefix-free by exposing internal functions) and test. Because the helpers are function declarations (hoisted, defined after the script's `return`), expose them by appending a `return { ... }` to a sliced copy — mirror the parity test's prefix-eval but slice the WHOLE file and replace the first top-level `return <bundle>` is unsafe; instead we test via the public bundle (Task 4). For pure-unit coverage here, add a self-test hook: a trailing exported map guarded by a sentinel arg.

Use the full-script mock-driven approach instead (no internal extraction). Add:

```bash
# Runs review-core.mjs end-to-end with mock globals. $1 = JSON args string.
# A crafted mock agent returns the envelope passed via OP_SYNTH_ENVELOPE (json)
# for the synthesiser label, and empty-ok specialist/cross outputs otherwise.
_op_run_core() {
    local wf
    wf="$(_op_cr_dir)/workflows/review-core.mjs"
    OP_ARGS="$1" OP_SYNTH_ENVELOPE="$2" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const synthEnv = JSON.parse(process.env.OP_SYNTH_ENVELOPE);
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            if (label === "review-synthesiser") return synthEnv;
            if (label.startsWith("cross-")) return { status: "ok", opinionsMarkdown: "", escalations: [] };
            return { status: "ok", findings: [] };           // specialists
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        (async () => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            const bundle = await fn(agent, parallel, pipeline, phase, log, process.env.OP_ARGS, workflow);
            process.stdout.write(JSON.stringify(bundle));
        })().catch(e => { process.stdout.write("THREW: " + e.message); });
    ' 2>&1
}

test_posted_set_respects_verdict() {
    local args env_rc out
    args='{"agentPrompt":"x","flags":{},"route":"full","selfReReview":false,"reviewMode":"pr","base":"main","headSha":"'"$(printf 'a%.0s' {1..40})"'","emptyTreeMode":false,"pathScope":"","tempDir":"/tmp/x","logTimestamp":"2026-06-18T00:00:00Z"}'
    # REQUEST_CHANGES with a conf-55 consensus Suggestion: it MUST still post.
    env_rc='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"Important [#1] conf 88","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":88,"description":"d1","suggested_fix":"f1"},{"file":"b.cs","line":20,"severity":"Suggestion","confidence":55,"description":"d2","suggested_fix":"f2"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> prose\n## Consensus Findings\n#### Finding #1 — t1\n#### Finding #2 — t2\n"}'
    WF="$(_op_cr_dir)/workflows/review-core.mjs" out=$(_op_run_core "$args" "$env_rc")
    # Both consensus findings post as comments under REQUEST_CHANGES.
    local n
    n=$(echo "$out" | jq '.comments | length' 2>/dev/null || echo "ERR")
    assert_equals "2" "$n" "REQUEST_CHANGES posts all consensus findings (incl conf 55)"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — current `review-core.mjs` already posts all consensus under RC, so this specific assertion may PASS by accident; the failing behaviour appears once synthesiser-tier findings and the new comment shape exist. If it passes here, that is acceptable — it is a guard test. Proceed; the substantive new behaviour is asserted in Tasks 3–5.

- [ ] **Step 3: Add the classification helpers**

In `review-core.mjs`, in the helpers block (after `sideFor`, around line 316), add:

```javascript
// Posted-set membership — the existing verdict-driven filter, extracted as a
// named predicate so body + comments share one rule. REQUEST_CHANGES posts
// everything; APPROVE posts confidence >= POST_THRESHOLD (75).
function isPosted(finding, verdict) {
    if (verdict === 'REQUEST_CHANGES') return true
    return (finding.confidence ?? 0) >= POST_THRESHOLD
}

// verdict_relevant — a log annotation: true iff this finding is what the rubric
// acted on to produce the verdict. APPROVE drives nothing. Under
// REQUEST_CHANGES: consensus Critical (any confidence) or Important >= 70, plus
// any finding whose positional [#N] token appears in rubricReason (covers the
// goal-block row 1). indexToken is the finding's 1-based [#N] within its tier.
function isVerdictRelevant(finding, tier, verdict, rubricReason, indexToken) {
    if (verdict !== 'REQUEST_CHANGES') return false
    if (tier === 'consensus') {
        if (finding.severity === 'Critical') return true
        if (finding.severity === 'Important' && (finding.confidence ?? 0) >= 70) return true
    }
    if (indexToken && rubricReason && rubricReason.includes(`[#${indexToken}]`)) return true
    return false
}
```

(Hoisting note: `POST_THRESHOLD` is a `const` at line 279 inside the PR-mode branch — move it to module scope so the helpers can read it. In Step 4 below, relocate it.)

- [ ] **Step 4: Hoist `POST_THRESHOLD` to module scope**

Cut the line `const POST_THRESHOLD = 75` from inside the PR-mode block (line 279) and re-add it once near the top of the helpers block, e.g. immediately before `renderCommentBody` (line 306):

```javascript
// Shared by isPosted and the PR-mode filter. The 75 bar is deliberate (above
// the rubric's 70) — see spec "Posted Set".
const POST_THRESHOLD = 75
```

Then ensure the PR-mode code at line 280-282 still references `POST_THRESHOLD` (it does; just no longer declares it).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test_posted_set_respects_verdict` green, all existing workflow-migration tests still green (syntax + parity + null-resilience).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_output_presentation.sh
git commit -m "feat(code-review): add posted-set + verdict-relevance predicates to review-core"
```

---

## Task 3: review-core — anchor-ladder comment routing

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (replace the PR-mode comment build at lines 285-290; add `renderComments` helper)
- Test: `tests/lib/test_output_presentation.sh`

**Interfaces:**
- Produces: `renderComments(postedFindings)` → array of bundle comment objects. Line-anchored (`file` present, `line > 0` OR deletion anchor) → `{path, line, side, body}`. File-anchored (`file` present, no usable line) → `{path, subjectType:'file', body}`. Fileless (no `file`) → no comment (returns nothing for it).
- Consumes: Task 2's `isPosted`; the existing `renderCommentBody`, `sideFor`.

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_output_presentation.sh`:

```bash
test_anchor_ladder_routes_comments() {
    local args env out
    args='{"agentPrompt":"x","flags":{},"route":"full","selfReReview":false,"reviewMode":"pr","base":"main","headSha":"'"$(printf 'a%.0s' {1..40})"'","emptyTreeMode":false,"pathScope":"","tempDir":"/tmp/x","logTimestamp":"2026-06-18T00:00:00Z"}'
    # Three findings: line-anchored, file-anchored (line 0), fileless (no file).
    env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"r","tiers":{"consensus":[{"file":"a.cs","line":42,"severity":"Important","confidence":90,"description":"line-anchored","suggested_fix":"f"},{"file":"b.cs","line":0,"severity":"Important","confidence":90,"description":"file-anchored","suggested_fix":"f"}],"synthesiser":[{"line":0,"severity":"Suggestion","confidence":90,"description":"fileless repo-wide","suggested_fix":"add changelog"}],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> prose\n"}'
    WF="$(_op_cr_dir)/workflows/review-core.mjs" out=$(_op_run_core "$args" "$env")
    local total line_c file_c
    total=$(echo "$out" | jq '.comments | length')
    line_c=$(echo "$out" | jq '[.comments[] | select(.subjectType == null and .line != null)] | length')
    file_c=$(echo "$out" | jq '[.comments[] | select(.subjectType == "file")] | length')
    assert_equals "2" "$total" "fileless finding produces no comment (2 of 3 anchor)"
    assert_equals "1" "$line_c" "line-anchored finding → line-level comment"
    assert_equals "1" "$file_c" "file-anchored finding (line 0, has file) → file-level comment"
    # The fileless finding's detail must appear in the body instead.
    if echo "$out" | jq -r '.bodyText' | grep -qF "fileless repo-wide"; then
        pass "fileless finding detail lands in body"
    else
        fail "fileless finding detail lands in body" "fileless description not found in bodyText"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — today synthesiser-tier findings never become comments, and line-0 findings are forced to line 1 (no `subjectType`), so the counts mismatch and the fileless detail is absent from the body.

- [ ] **Step 3: Add `renderComments` helper**

In the helpers block of `review-core.mjs`, add:

```javascript
// Anchor ladder (spec "Anchor Ladder"): route each posted finding to the most
// specific GitHub anchor it can carry. A line-0 finding WITH a file is a
// deletion/file-level anchor → file-level comment; a finding with NO file is
// fileless → no comment (its detail goes to the body, handled in buildBody).
function renderComments(postedFindings) {
    const comments = []
    for (const f of postedFindings) {
        if (!f.file) continue                                  // fileless → body only
        if (f.line > 0) {
            comments.push({ path: f.file, line: f.line, side: sideFor(f.line), body: renderCommentBody(f) })
        } else {
            // file present, no usable positive line → file-level comment.
            comments.push({ path: f.file, subjectType: 'file', body: renderCommentBody(f) })
        }
    }
    return comments
}

// True when a finding has no file at all (the body must carry its full detail).
function isFileless(f) {
    return !f.file
}
```

- [ ] **Step 4: Rewire the PR-mode block to use the posted set across BOTH tiers**

Replace `review-core.mjs:277-299` (the `const verdict = ...` through `return { verdict, bodyText, comments }`) with:

```javascript
const verdict = envelope.verdict  // APPROVE | REQUEST_CHANGES (synth never emits COMMENT)
const consensus = envelope.tiers.consensus ?? []
const synthFindings = envelope.tiers.synthesiser ?? []

// Posted set = consensus + synthesiser, filtered by the verdict-driven rule.
const postedSet = [...consensus, ...synthFindings].filter(f => isPosted(f, verdict))

const comments = renderComments(postedSet)

const bodyText = buildBody(envelope, postedSet)
const log = buildLogPayload(envelope)

return { verdict, bodyText, comments, log }
```

(`buildBody` is implemented in Task 4; `buildLogPayload` in Task 5. Add temporary stubs now so the script parses and Task 3's test runs — the stubs are replaced, not appended to, in the next tasks:)

```javascript
function buildBody(envelope, postedSet) {
    // TEMP STUB (replaced in Task 4): include fileless detail so Task 3's test passes.
    let body = stripCostAndDismissed(envelope.bodyText)
    for (const f of postedSet) {
        if (isFileless(f)) body += `\n\n${f.description}\n\n**Suggested fix:** ${f.suggested_fix}`
    }
    return body
}
function buildLogPayload(envelope) {
    // TEMP STUB (replaced in Task 5).
    return { bodyText: envelope.bodyText, findings: [] }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test_anchor_ladder_routes_comments` green; existing tests green (the local-mode and empty-bundle early returns above line 277 are untouched).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_output_presentation.sh
git commit -m "feat(code-review): route posted findings through the anchor ladder"
```

---

## Task 4: review-core — body construction (headline, promoted assessment, finding index)

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (replace the `buildBody` stub; add `extractSection`, `renderFindingIndex`)
- Test: `tests/lib/test_output_presentation.sh`

**Interfaces:**
- Produces: `buildBody(envelope, postedSet)` → the reshaped GitHub body string: headline verdict line, promoted (un-quoted) Synthesiser Assessment, a `### Findings` index (one summary line per posted line/file-anchored finding + full detail for fileless ones), and the (reformatted, Task 5) dependency section. NO Summary/Contested/Dismissed/Cost.
- Consumes: `extractSection(bodyText, heading)` → the text between `## <heading>` and the next `## `; `isFileless`.

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_output_presentation.sh`:

```bash
test_body_is_headline_and_index() {
    local args env out body
    args='{"agentPrompt":"x","flags":{},"route":"full","selfReReview":false,"reviewMode":"pr","base":"main","headSha":"'"$(printf 'a%.0s' {1..40})"'","emptyTreeMode":false,"pathScope":"","tempDir":"/tmp/x","logTimestamp":"2026-06-18T00:00:00Z"}'
    env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"consensus Important [#1] confidence 88","tiers":{"consensus":[{"file":"a.cs","line":42,"severity":"Important","confidence":88,"description":"the defect","suggested_fix":"fix it"}],"synthesiser":[],"contested":[{"file":"a.cs","line":42,"severity":"Critical","confidence":82,"description":"CONTESTED SEVERITY","suggested_fix":"x"}],"dismissed":[{"file":"z.cs","line":1,"severity":"Suggestion","confidence":40,"description":"DISMISSED NOISE","suggested_fix":"x"}]},"bodyText":"## Summary\n1 file | 1 finding\n## Synthesiser Assessment\n> This is the centrepiece.\n> Second line.\n## Consensus Findings\n#### Finding #1 — the defect\nblah\n## Contested Findings\nCONTESTED SEVERITY\n## Dismissed Findings\nDISMISSED NOISE\n## Cost\ntokens: 999\n"}'
    WF="$(_op_cr_dir)/workflows/review-core.mjs" out=$(_op_run_core "$args" "$env")
    body=$(echo "$out" | jq -r '.bodyText')
    # Headline verdict at the very top, bold.
    if echo "$body" | head -1 | grep -qF "**REQUEST_CHANGES**"; then
        pass "body opens with bold verdict headline"
    else
        fail "body opens with bold verdict headline" "first line: $(echo "$body" | head -1)"
    fi
    # Assessment promoted: the centrepiece text present WITHOUT a leading '>'.
    if echo "$body" | grep -qF "This is the centrepiece." && ! echo "$body" | grep -qE "^> This is the centrepiece"; then
        pass "Synthesiser Assessment promoted out of block-quote"
    else
        fail "Synthesiser Assessment promoted out of block-quote" "assessment still quoted or missing"
    fi
    # Finding index: one summary line pointing inline; NOT the full prose block.
    if echo "$body" | grep -qE "the defect.*a.cs:42"; then
        pass "finding index summary line present"
    else
        fail "finding index summary line present" "expected compact index line for finding"
    fi
    # Dropped sections absent from the body.
    assert_not_matches "DISMISSED NOISE" "$body" "Dismissed section dropped from body"
    assert_not_matches "CONTESTED SEVERITY" "$body" "Contested section dropped from body"
    assert_not_matches "tokens: 999" "$body" "Cost section dropped from body"
    assert_not_matches "## Summary" "$body" "Summary counts dropped from body"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — the Task 3 stub `buildBody` returns the cost/summary-stripped prose but keeps the full Consensus block, has no headline, and does not promote the assessment.

- [ ] **Step 3: Replace `buildBody` and add section helpers**

Replace the `buildBody` stub with:

```javascript
// Extract the body of a `## <heading>` section (text up to the next `## `
// heading or EOF). Returns '' when the heading is absent. Pure string op.
function extractSection(bodyText, heading) {
    const lines = bodyText.split('\n')
    const out = []
    let capturing = false
    for (const line of lines) {
        if (capturing) {
            if (line.startsWith('## ')) break
            out.push(line)
            continue
        }
        if (line.trim() === `## ${heading}`) capturing = true
    }
    return out.join('\n').trim()
}

// Strip a leading '> ' (or '>') block-quote prefix from every line. Promotes
// the Synthesiser Assessment from greyed quote to first-class prose.
function unquote(text) {
    return text.split('\n').map(l => l.replace(/^>\s?/, '')).join('\n')
}

// One compact index line per posted, anchorable finding. Fileless findings are
// rendered with full detail (no inline home to point to).
function renderFindingIndex(postedSet) {
    const lines = []
    for (const f of postedSet) {
        if (isFileless(f)) {
            lines.push(`- **[${f.severity}]** ${f.description}\n\n  **Suggested fix:** ${f.suggested_fix}`)
        } else {
            const pointer = f.line > 0 ? '↳ inline' : '↳ file comment'
            const loc = f.line > 0 ? `${f.file}:${f.line}` : f.file
            lines.push(`- **[${f.severity}]** ${shortTitle(f.description)} — \`${loc}\` ${pointer}`)
        }
    }
    return lines.join('\n')
}

// First sentence / first 80 chars of the description, for the index summary.
function shortTitle(desc) {
    const firstSentence = desc.split(/(?<=[.!?])\s/)[0]
    const t = (firstSentence || desc).trim()
    return t.length > 80 ? t.slice(0, 77) + '…' : t
}

function buildBody(envelope, postedSet) {
    const verdict = envelope.verdict
    const reason = envelope.rubricReason || ''
    const headline = `**${verdict}**${reason ? ` — ${reason}` : ''}`

    const assessment = unquote(extractSection(envelope.bodyText, 'Synthesiser Assessment'))
    const index = renderFindingIndex(postedSet)
    const freshness = buildFreshnessSection(envelope.bodyText)  // Task 5

    const parts = [headline]
    if (assessment) parts.push(assessment)
    if (index) parts.push(`### Findings\n\n${index}`)
    if (freshness) parts.push(freshness)
    return parts.join('\n\n')
}
```

Add a temporary `buildFreshnessSection` stub (replaced in Task 5):

```javascript
function buildFreshnessSection(bodyText) {
    return ''  // TEMP STUB (replaced in Task 5)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test_body_is_headline_and_index` all green; Task 3's anchor test still green (fileless detail now rendered by `renderFindingIndex`).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_output_presentation.sh
git commit -m "feat(code-review): rebuild PR body as headline + promoted assessment + finding index"
```

---

## Task 5: review-core — dependency freshness reformat + log payload

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (replace `buildFreshnessSection` and `buildLogPayload` stubs)
- Test: `tests/lib/test_output_presentation.sh`

**Interfaces:**
- Produces:
  - `buildFreshnessSection(bodyText)` → the `## Dependency Freshness` section reformatted (numeric columns first, never wrapped). Returns `''` when the synthesiser emitted no such section (no dep-bearing files); returns the all-current line when the section exists but has no drift rows.
  - `buildLogPayload(envelope)` → `{ bodyText, findings:[...] }` flattening all four tiers, each record carrying `tier`, `domain` (when present), `severity`, `confidence`, `file`, `line`, `description`, `suggested_fix`, `verdict_relevant`.
- Consumes: `isVerdictRelevant` (Task 2), `extractSection` (Task 4).

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_output_presentation.sh`:

```bash
test_log_payload_flattens_all_tiers() {
    local args env out
    args='{"agentPrompt":"x","flags":{},"route":"full","selfReReview":false,"reviewMode":"pr","base":"main","headSha":"'"$(printf 'a%.0s' {1..40})"'","emptyTreeMode":false,"pathScope":"","tempDir":"/tmp/x","logTimestamp":"2026-06-18T00:00:00Z"}'
    env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"consensus Important [#1] confidence 88","tiers":{"consensus":[{"file":"a.cs","line":42,"severity":"Important","confidence":88,"description":"d","suggested_fix":"f"}],"synthesiser":[{"line":0,"severity":"Suggestion","confidence":60,"description":"s","suggested_fix":"f"}],"contested":[{"file":"a.cs","line":42,"severity":"Critical","confidence":82,"description":"c","suggested_fix":"f"}],"dismissed":[{"file":"z.cs","line":1,"severity":"Suggestion","confidence":40,"description":"x","suggested_fix":"f"}]},"bodyText":"## Synthesiser Assessment\n> prose\n"}'
    WF="$(_op_cr_dir)/workflows/review-core.mjs" out=$(_op_run_core "$args" "$env")
    local nlog rel
    nlog=$(echo "$out" | jq '.log.findings | length')
    assert_equals "4" "$nlog" "log payload flattens all four tiers (4 findings)"
    # The conf-88 consensus Important is verdict_relevant under RC row 3.
    rel=$(echo "$out" | jq '[.log.findings[] | select(.verdict_relevant == true)] | length')
    assert_equals "1" "$rel" "exactly the rubric-driving finding marked verdict_relevant"
    # Full verbatim prose retained in the log.
    if echo "$out" | jq -r '.log.bodyText' | grep -qF "## Synthesiser Assessment"; then
        pass "log.bodyText retains verbatim synthesiser prose"
    else
        fail "log.bodyText retains verbatim synthesiser prose" "prose missing from log payload"
    fi
}

test_freshness_states() {
    local args base_env out
    args='{"agentPrompt":"x","flags":{},"route":"full","selfReReview":false,"reviewMode":"pr","base":"main","headSha":"'"$(printf 'a%.0s' {1..40})"'","emptyTreeMode":false,"pathScope":"","tempDir":"/tmp/x","logTimestamp":"2026-06-18T00:00:00Z"}'
    # No Dependency Freshness section at all → omitted from body.
    base_env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> all good\n"}'
    WF="$(_op_cr_dir)/workflows/review-core.mjs" out=$(_op_run_core "$args" "$base_env")
    assert_not_matches "Dependency Freshness" "$(echo "$out" | jq -r '.bodyText')" "no freshness section when synth emitted none"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `test_log_payload_flattens_all_tiers` fails (stub returns `findings: []`); `test_freshness_states` passes trivially against the stub (returns '') — that is fine, it guards the omission state.

- [ ] **Step 3: Replace `buildLogPayload`**

```javascript
// Flatten all four tiers into one record-per-finding array for the JSONL log.
// verdict_relevant is computed per the rubric (Task 2). domain is attached by
// review-core elsewhere for escalations; default to the tier name when absent.
function buildLogPayload(envelope) {
    const verdict = envelope.verdict
    const reason = envelope.rubricReason || ''
    const tiers = envelope.tiers || {}
    const findings = []
    for (const tier of ['consensus', 'synthesiser', 'contested', 'dismissed']) {
        const arr = tiers[tier] ?? []
        arr.forEach((f, i) => {
            findings.push({
                tier,
                domain: f.domain || tier,
                severity: f.severity,
                confidence: f.confidence ?? 0,
                file: f.file || '',
                line: f.line ?? 0,
                description: f.description,
                suggested_fix: f.suggested_fix || '',
                verdict_relevant: isVerdictRelevant(f, tier, verdict, reason, i + 1),
            })
        })
    }
    return { bodyText: envelope.bodyText, findings }
}
```

- [ ] **Step 4: Replace `buildFreshnessSection`**

```javascript
// Reformat the synthesiser's Dependency Freshness section for legibility.
// Three states (spec): omitted entirely when the synth produced no section;
// an all-current line when the section exists but has no drift table rows;
// otherwise the section verbatim (numeric columns are already first in the
// synthesiser's table — see review-synthesiser.md Output Format). The reformat
// keeps the section heading and its table; it strips only the synth's prose
// preamble blockquote to keep the body tight.
function buildFreshnessSection(bodyText) {
    const section = extractSection(bodyText, 'Dependency Freshness')
    if (!section) return ''                                    // no dep-bearing files → omit
    const hasTableRow = section.split('\n').some(l => /^\|.*\|.*\|/.test(l) && !/^\|\s*-+/.test(l) && !/Package|Current|Latest/i.test(l))
    if (!hasTableRow) {
        return `### Dependency Freshness\n\n✓ Dependencies checked — all current`
    }
    // Keep the table, drop the leading blockquote preamble lines.
    const kept = section.split('\n').filter(l => !l.trim().startsWith('>')).join('\n').trim()
    return `### Dependency Freshness\n\n${kept}`
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — both new tests green; all earlier tests green.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_output_presentation.sh
git commit -m "feat(code-review): reformat dependency freshness + build full-log payload"
```

---

## Task 6: Host — post file-level comments (PR mode)

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (Class C submission mechanics, ~line 1849; and the comment API conventions, ~line 1516)
- Test: `tests/lib/test_output_presentation.sh` (structural grep test, mirroring `test_host_wires_workflow_flag`)

**Interfaces:**
- Consumes: bundle `comments[]` entries that may carry `subjectType: 'file'` (Task 3) instead of `line`/`side`.
- Produces: host prose instructing a `subject_type=file` `gh api` call for those entries.

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_output_presentation.sh`:

```bash
test_host_documents_file_level_comments() {
    local cr file
    cr=$(_op_cr_dir)
    for file in skills/review-gh-pr/SKILL.md; do
        local path="$cr/$file"
        if grep -qF 'subject_type' "$path" && grep -qF 'subjectType' "$path"; then
            pass "host documents file-level comment posting: $file"
        else
            fail "host documents file-level comment posting: $file" \
                "Class C must handle bundle comments with subjectType=file via a gh api subject_type=file call"
        fi
    done
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `SKILL.md` does not yet mention `subject_type` / `subjectType`.

- [ ] **Step 3: Add file-level comment handling to Class C**

In `skills/review-gh-pr/SKILL.md`, in the "Comment API conventions" block (after the "For new comments" example, ~line 1528), add:

````markdown
**For file-level comments** (bundle entries with `subjectType: "file"` — findings that
name a file but no usable line, per the Anchor Ladder), omit `line` and `side` and pass
`subject_type=file`:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --method POST \
  -f commit_id='{head_sha}' \
  -f path='{file_path}' \
  -f subject_type='file' \
  --input -  <<'EOF_COMMENT_BODY'
{comment_body}
EOF_COMMENT_BODY
```

A bundle comment carries EITHER `line` + `side` (line-level) OR `subjectType: "file"`
(file-level), never both. Dispatch on the presence of `subjectType`.
````

In the Step 6.0 Workflow-bundle short-circuit (~line 1655), update the Class C posting bullet to read:

```markdown
- Class C posting consumes the bundle directly: post each `bundle.comments[i]` as an
  inline comment — a line-level comment when the entry has `line`/`side`, or a
  **file-level** comment (`subject_type=file`, no line/side) when the entry has
  `subjectType: "file"`. Then submit `bundle.bodyText` as the `gh pr review --input -`
  body, using the review flag chosen from `$FINAL_VERDICT`.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test_host_documents_file_level_comments` green.

- [ ] **Step 5: Verify sync-note consistency**

Run: `bash tests/run.sh`
Expected: PASS — `test_sync_notes` stays green (no sync-tracked region was altered destructively). If it flags the new block, follow its message to add the matching note; do not bypass.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/skills/review-gh-pr/SKILL.md tests/lib/test_output_presentation.sh
git commit -m "feat(code-review): post file-level comments for file-anchored findings"
```

---

## Task 7: Host — durable opt-in log write (PR + local modes)

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (Step 7, ~line 1357)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (Step 7, ~line 1252)
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (thread `logTimestamp` from args into nothing — the host stamps; ensure args destructure tolerates it)
- Test: `tests/lib/test_output_presentation.sh`

**Interfaces:**
- Consumes: bundle `log` payload (Task 5); `orchestration.full_log` toggle in `.claude/code-review.toml`.
- Produces: host prose that, when the toggle is true, resolves the durable path, writes `.md` + `.jsonl` with a provenance header.

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_output_presentation.sh`:

```bash
test_host_documents_durable_log() {
    local cr file ok=1
    cr=$(_op_cr_dir)
    for file in skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if grep -qF 'orchestration.full_log' "$path" \
           && grep -qF '.claude/code-review-suite/logs' "$path" \
           && grep -qF 'plugin_sha' "$path"; then
            pass "host documents durable opt-in log: $file"
        else
            fail "host documents durable opt-in log: $file" \
                "Step 7 must gate on orchestration.full_log (default off), write to ~/.claude/code-review-suite/logs, and stamp plugin_sha"
            ok=0
        fi
    done
    # Default-off guarantee must be stated.
    if grep -qiE 'default.*(false|off)|off by default' "$cr/skills/review-gh-pr/SKILL.md"; then
        pass "durable log documented as default-off"
    else
        fail "durable log documented as default-off" "the toggle's default-false must be explicit"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — neither host file mentions the toggle, path, or provenance yet.

- [ ] **Step 3: Add the log-write block to `review-gh-pr/SKILL.md` Step 7**

In `skills/review-gh-pr/SKILL.md`, immediately after the Step 7 "Present results" heading content (~line 1361), add:

````markdown
### Step 7a: Durable full log (opt-in, default OFF)

The full unfiltered analytical record is a fine-tuning instrument with a finite
useful life. It is **off by default**. Write it ONLY when
`orchestration.full_log = true` in `.claude/code-review.toml` (read the file the same
way as `intent.doc_paths`; treat a missing/malformed file as `false`). When off, skip
this entire step — write nothing.

When on, and when the bundle carries a `log` payload (`bundle.log`):

1. Resolve the marketplace short-SHA (provenance). The plugin has no version field, so
   the build identity is the marketplace commit:

   ```bash
   git -C "{plugin-marketplace-dir}" rev-parse --short HEAD
   ```

   Store as `$PLUGIN_SHA`. If the command fails, use `unknown`.

2. Resolve the durable directory and filenames. `<repo-slug>` is the reviewed repo's
   `owner/name` with `/` → `-`; `<pr>` is `pr-$ARGUMENTS`; `<sha>` is the 12-char
   `$HEAD_SHA`:

   ```bash
   mkdir -p "$HOME/.claude/code-review-suite/logs/{repo-slug}"
   ```

3. Write the markdown record (verbatim full prose + provenance header) to
   `$HOME/.claude/code-review-suite/logs/{repo-slug}/{pr}-{sha}.md`. The first line is the
   provenance comment, then `bundle.log.bodyText` verbatim:

   ```
   <!-- plugin_sha: $PLUGIN_SHA | ts: $LOG_TS -->
   ```

   `$LOG_TS` is the current UTC time in ISO-8601 (the host stamps it; e.g.
   `date -u +%Y-%m-%dT%H:%M:%SZ`).

4. Write the JSONL record to the sibling `.jsonl` file. The FIRST line is the meta
   record, then one line per `bundle.log.findings[]` entry, then the per-phase rows the
   orchestrator already holds from `$CLAUDE_TEMP_DIR/tokens.jsonl`:

   ```jsonl
   {"type":"meta","plugin_sha":"$PLUGIN_SHA","ts":"$LOG_TS"}
   ```

The durable log is NEVER posted to GitHub and NEVER committed — it is analysis exhaust
that may contain finding text from private repos.
````

- [ ] **Step 4: Add the equivalent block to `commands/pre-review.md` Step 7**

In `commands/pre-review.md`, after the Step 7 "Present results" content (~line 1263), add the same `### Step 7a` block, with two local-mode differences: `<pr-or-branch>` is the slugified branch name (run `git rev-parse --abbrev-ref HEAD`), and there is no `$ARGUMENTS` PR number. State explicitly: "local mode posts nothing; the durable log is the only persisted artefact."

- [ ] **Step 5: Ensure `review-core.mjs` tolerates `logTimestamp` in args**

The host stamps the timestamp, so the core does not need it — but the args object in `SKILL.md` Step 3.5 will carry no new field. Confirm the args destructure at `review-core.mjs:122-125` is unaffected (it destructures only named keys; extra keys are ignored). No code change required; this step is a verification:

Run: `bash tests/run.sh`
Expected: PASS — `test_review_core_accepts_string_args` still green.

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test_host_documents_durable_log` green; `test_sync_notes` green.

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md tests/lib/test_output_presentation.sh
git commit -m "feat(code-review): write durable opt-in full log with provenance header"
```

---

## Task 8: Remove the teasing footer + reconcile host posting-policy docs

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (the old footer code at lines 292-297 is already replaced by Task 3's rewrite — verify it is gone)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (the "Body construction" / "Append the footer" prose, ~lines 1724-1730 and D.4 ~lines 1897-1910)
- Modify: `plugins/code-review-suite/agents/review-synthesiser.md` (the duplicated "Body construction" footer prose, ~lines 240-246)
- Test: `tests/lib/test_output_presentation.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: removal of the "N additional finding(s) below the threshold were not posted" footer everywhere it is documented (the spec's no-teasing constraint).

- [ ] **Step 1: Write the failing test**

Add to `tests/lib/test_output_presentation.sh`:

```bash
test_no_teasing_footer() {
    local cr f
    cr=$(_op_cr_dir)
    # The core must not emit the count-of-hidden-findings footer.
    if grep -qF 'additional finding' "$cr/workflows/review-core.mjs"; then
        fail "no teasing footer in review-core.mjs" "the 'N additional finding(s)' footer must be removed"
    else
        pass "no teasing footer in review-core.mjs"
    fi
    # Behavioural: an APPROVE with a sub-75 consensus finding posts NO footer.
    local args env out body
    args='{"agentPrompt":"x","flags":{},"route":"full","selfReReview":false,"reviewMode":"pr","base":"main","headSha":"'"$(printf 'a%.0s' {1..40})"'","emptyTreeMode":false,"pathScope":"","tempDir":"/tmp/x","logTimestamp":"2026-06-18T00:00:00Z"}'
    env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[{"file":"a.cs","line":5,"severity":"Suggestion","confidence":55,"description":"low conf","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> ok\n"}'
    WF="$(_op_cr_dir)/workflows/review-core.mjs" out=$(_op_run_core "$args" "$env")
    body=$(echo "$out" | jq -r '.bodyText')
    assert_not_matches "additional finding" "$body" "APPROVE body has no teasing footer for the dropped conf-55 finding"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: depends — Task 3 already replaced the footer-emitting code in `review-core.mjs`, so the `grep` assertion likely PASSES. The host/synth prose still documents the footer, but those are not tested by this behavioural test. If all assertions pass, this test is a regression guard; proceed to remove the now-stale prose in Step 3.

- [ ] **Step 3: Remove the footer prose from the host and synthesiser docs**

In `skills/review-gh-pr/SKILL.md`:
- Delete the "When any findings were filtered, the orchestrator appends a footer…" paragraph and its blockquote (~lines 1724-1730).
- In D.4 (~lines 1897-1910), replace the "Append the footer when findings were filtered" subsection with a one-line note: `#### D.4 (removed) — no withheld-count footer is appended; omitted findings are simply absent (spec: no teasing).`

In `agents/review-synthesiser.md`:
- Delete the matching "When any findings were filtered, the orchestrator appends a footer…" paragraph and blockquote (~lines 240-246).

(These are documentation of behaviour the code no longer performs; the verdict rubric and posting-policy tables above them are unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test_no_teasing_footer` green; `test_sync_notes` green (the footer prose was duplicated by an existing sync note between SKILL.md and the synthesiser — if the sync test flags it, remove the footer in BOTH locations in the same commit, which this step does).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/agents/review-synthesiser.md tests/lib/test_output_presentation.sh
git commit -m "feat(code-review): remove withheld-count footer (no-teasing constraint)"
```

---

## Task 9: End-to-end guard + full suite green

**Files:**
- Test: `tests/lib/test_output_presentation.sh`

**Interfaces:**
- Consumes: the full pipeline from Tasks 1–8.

- [ ] **Step 1: Write an end-to-end test against the PR #80 shape**

Add a final test that drives a realistic multi-tier envelope (consensus Important + Suggestion, a synthesiser finding, a contested severity-dispute duplicate, a dismissed false-positive, and a Dependency Freshness table) and asserts the full set of invariants together:

```bash
test_end_to_end_pr80_shape() {
    local args env out body
    args='{"agentPrompt":"x","flags":{},"route":"full","selfReReview":false,"reviewMode":"pr","base":"main","headSha":"'"$(printf 'a%.0s' {1..40})"'","emptyTreeMode":false,"pathScope":"","tempDir":"/tmp/x","logTimestamp":"2026-06-18T00:00:00Z"}'
    env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"consensus Important [#1] confidence 88","tiers":{"consensus":[{"file":"RightToWorkClient.cs","line":240,"severity":"Important","confidence":88,"description":"SUPERSEDED filter case-sensitive.","suggested_fix":"OrdinalIgnoreCase"},{"file":"PollRtwHandlerLog.cs","line":104,"severity":"Suggestion","confidence":70,"description":"EventId ordering.","suggested_fix":"reorder"}],"synthesiser":[{"file":"RightToWorkStatusWire.cs","line":11,"severity":"Suggestion","confidence":55,"description":"missing XML docs.","suggested_fix":"add summary"}],"contested":[{"file":"RightToWorkClient.cs","line":240,"severity":"Critical","confidence":82,"description":"compliance bypass.","suggested_fix":"x"}],"dismissed":[{"file":"x.cs","line":1,"severity":"Suggestion","confidence":40,"description":"var doc false positive.","suggested_fix":"x"}]},"bodyText":"## Summary\n16 files\n## Synthesiser Assessment\n> Intent vs implementation analysis.\n## Consensus Findings\n#### Finding #1 — SUPERSEDED\n## Dependency Freshness\n> deps\n| Package | Current | Latest GA | Drift | Notes |\n|---|---|---|---|---|\n| AWSSDK | 4.0.4 | 4.0.5 | patch | x |\n## Dismissed Findings\nvar doc\n## Cost\ntokens 999\n"}'
    WF="$(_op_cr_dir)/workflows/review-core.mjs" out=$(_op_run_core "$args" "$env")
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "3" "$(echo "$out" | jq '.comments | length')" "3 posted findings become comments (2 consensus + 1 synth)"
    assert_matches "REQUEST_CHANGES" "$(echo "$body" | head -1)" "headline verdict"
    assert_not_matches "compliance bypass" "$body" "contested dispute not in body"
    assert_not_matches "var doc" "$body" "dismissed not in body"
    assert_not_matches "tokens 999" "$body" "cost not in body"
    if echo "$body" | grep -qF "Latest GA"; then
        pass "dependency table retained in body"
    else
        fail "dependency table retained in body" "freshness table missing"
    fi
    assert_equals "5" "$(echo "$out" | jq '.log.findings | length')" "log retains all 5 findings across tiers"
}
```

- [ ] **Step 2: Run the full suite**

Run: `bash tests/run.sh`
Expected: PASS — `test_end_to_end_pr80_shape` green; the printed summary shows the pre-existing baseline (450+ passed) PLUS the new tests, 0 failed.

- [ ] **Step 3: Mark `test_output_presentation.sh` executable and verify discovery**

```bash
chmod +x tests/lib/test_output_presentation.sh
```

Run: `bash tests/run.sh`
Expected: PASS — the new section appears in the output (run.sh sources every `lib/test_*.sh`).

- [ ] **Step 4: Commit**

```bash
git add tests/lib/test_output_presentation.sh
git commit -m "test(code-review): end-to-end output-presentation guard against PR #80 shape"
```

---

## Self-Review

**1. Spec coverage:**
- Governing principle / action-document → Tasks 4 (body), 8 (no footer). ✓
- Posted set (RC=all, APPROVE≥75, +synth tier) → Task 2 (`isPosted`), Task 3 (set across both tiers). ✓
- Contested/dismissed log-only → Task 4 (dropped from body), Task 5 (in log). ✓
- Settled-severity for consensus-and-contested → the consensus copy posts as-is; the contested copy is log-only (Tasks 3/5). ✓
- Verdict rubric unchanged → no task touches it. ✓
- Body shape (headline, promoted assessment, index, freshness) → Tasks 4, 5. ✓
- Sections dropped → Task 4 (`buildBody` omits them) + Task 8 (footer). ✓
- APPROVE empty-findings body → Task 4 (`if (index)` guard). ✓
- Inline comment format unchanged → `renderCommentBody` reused (Task 3). ✓
- Anchor ladder (line/file/body) + `file` optional → Tasks 1, 3. ✓
- Posting mechanics (subject_type=file) → Task 6. ✓
- Dependency reformat + 3 states → Task 5. ✓
- Durable opt-in log, default off, provenance SHA+ts → Task 7. ✓
- Log location + write-responsibility split → Tasks 5 (payload), 7 (host write). ✓
- JSONL fields incl. `file` absent for fileless → Tasks 1 (schema), 5 (payload). ✓

**2. Placeholder scan:** Temp stubs in Tasks 3/4 are explicitly labelled and replaced in the very next task (3→4→5), with real code shown at replacement — not left as placeholders. No "TBD"/"handle edge cases". ✓

**3. Type consistency:** `isPosted(finding, verdict)`, `isVerdictRelevant(f, tier, verdict, rubricReason, indexToken)`, `renderComments(postedSet)`, `buildBody(envelope, postedSet)`, `buildFreshnessSection(bodyText)`, `buildLogPayload(envelope)`, `extractSection(bodyText, heading)`, `isFileless(f)`, `shortTitle(desc)`, `renderFindingIndex(postedSet)`, `unquote(text)` — names and arities are consistent across the tasks that define and call them. `POST_THRESHOLD` hoisted once (Task 2). Bundle field `log: {bodyText, findings}` matches schema (Task 1) and payload (Task 5). ✓

No gaps found.
