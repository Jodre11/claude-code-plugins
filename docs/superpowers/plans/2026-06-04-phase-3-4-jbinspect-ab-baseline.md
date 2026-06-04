# Phase 3.4 — jbinspect static-specialist A/B baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the jbinspect-reviewer A/B apparatus (corpus fixture, parser-dispatch case, configs, live-captured worked example) and run the matched 2×20 Sonnet/default vs Haiku/low probe, producing a verdict + cost-ratio result note — closing the Phase 3 static-specialist sweep (the 4th and final specialist).

**Architecture:** Mirror the trivy/eslint/ruff per-agent A/B pattern exactly. jbinspect's tool (`jb inspectcode`) is global-on-PATH (like trivy/ruff) so NO `setup:` provisioning block is needed — InspectCode restores + builds the project internally inside each per-trial hermetic copy (empirically verified: a clean copy with no `bin/obj` produces the identical finding set). The fixture is a real, compilable C# project (`.sln` + `.csproj` + `.cs`) — InspectCode needs a solution to inspect, unlike a single Dockerfile/py/js file. Three offline tasks (fixture, parser, configs) are TDD'd against captured/synthetic output and committed before any Bedrock spend; then two GATED live steps (worked-example capture, then the 2×20 sweep) require explicit operator go-ahead.

**Tech Stack:** bash test harness (`tests/ab/`), JetBrains InspectCode 2026.1.0.1 (`jb inspectcode`), dotnet SDK 10.0.300, yq/jq/awk, Claude Code per-agent stream-json capture.

---

## Critical offline findings (already established this session — do NOT re-derive)

The C# fixture has **already been authored and its ground truth established** (Task 1
below documents what was done — the files already exist on disk). A live
`jb inspectcode … --format=Xml --severity=WARNING` run against the fixture produced this
**deterministic** finding set (captured 2026-06-03, InspectCode 2026.1.0.1, dotnet
10.0.300; re-confirmed identical on a clean no-`bin/obj` copy):

| TypeId | Native severity | Mapped | Line | Category (XML `Category` attr) |
|--------|-----------------|--------|------|--------------------------------|
| `RedundantUsingDirective` | WARNING | **Important** | 2 | Redundancies in Code |
| `PossibleNullReferenceException` | WARNING | **Important** | 11 | Potential Code Quality Issues |
| `UnusedMember.Local` | WARNING | **Important** | 14 | Redundancies in Symbol Declarations |

**Three load-bearing facts:**

1. **All three findings are line-bearing** (`Line="2"`, `Line="11"`, `Line="14"`),
   so all three survive the §5 changed-line intersection against changed lines
   `2,11,14`. No line-less finding to suppress (unlike trivy's DS-0002, which needed
   a `USER` directive). The fixture was designed so the compiler emits **0 warnings**
   (`dotnet build` is clean) — InspectCode's deeper analysis is the sole source of the
   three findings, exactly the "ground truth is the tool, not the human" discipline.

2. **All three map to `Important`** (every `WARNING` → `Important` per the agent's
   severity table; jbinspect's Critical-allow-list is empty). Unlike trivy (which had a
   `Critical` via the secret allow-list), jbinspect's canonical tuple set is uniform
   `Important`. This is correct and expected — do not "add a Critical" to diversify.

3. **The CamelCase + spaced-category tokeniser question is ANSWERED.** The `Rule:`
   field is `TypeId (Category)` (agent body line 86), e.g.
   `UnusedMember.Local (Redundancies in Symbol Declarations)`. The shared tokeniser
   `split(v, a, /[ \t(]/)` (`agent_capture.sh:185`) takes token 1 = `UnusedMember.Local`
   — the `.` is internal to the token (no space/tab/paren before it), and the first
   delimiter is the space *before* `(Category)`, so the spaced category text is
   discarded cleanly. **No tokeniser change needed.** Task 2's parser test asserts this
   on the spaced-category form (a stronger assertion than trivy's bare `DS-NNNN`).

**Canonical tuple set** (sorted by file, line, rule_id — the §6 `findings.json` shape):

```json
[{"file":"BadCode.cs","line":2,"rule_id":"RedundantUsingDirective","severity":"Important","confidence":100},
 {"file":"BadCode.cs","line":11,"rule_id":"PossibleNullReferenceException","severity":"Important","confidence":100},
 {"file":"BadCode.cs","line":14,"rule_id":"UnusedMember.Local","severity":"Important","confidence":100}]
```

---

## Sync coupling you MUST respect (jbinspect-specific)

`jbinspect-reviewer.md` is **mirrored** into `agents/code-analysis.md` (the monolithic
reviewer). Both the agent body (line 92) and `code-analysis.md` (line 19) carry a
"keep in sync" directive. If the Task-5 worked-example pin or any C#-procedure
clarification changes the jbinspect body's **C#-specific solution-discovery +
`jb inspectcode` invocation**, check whether `code-analysis.md`'s InspectCode section
(lines 13-19, 71-98) needs the mirror. A worked-example section added at the END of the
jbinspect body (after `## Output`) is a NEW section, not a change to the mirrored
solution-discovery/invocation procedure — so it does **not** require mirroring into
`code-analysis.md` (which carries its own §7 format block, lines 71-98). Run
`bash tests/run.sh` and watch for sync-note failures regardless. (ruff/eslint/trivy had
no monolith mirror — this is the new wrinkle for 3.4.)

---

## File Structure

- `tests/fixtures/static-analysis/jbinspect/JbInspectSmoke.sln` — EXISTS (Task 1, classic `.sln` format).
- `tests/fixtures/static-analysis/jbinspect/JbInspectSmoke.csproj` — EXISTS (net10.0, nullable off).
- `tests/fixtures/static-analysis/jbinspect/BadCode.cs` — EXISTS (3-finding C# source).
- `.gitignore` — MODIFIED (Task 1, ignores the fixture's `bin/`/`obj/`).
- `tests/ab/corpus/jbinspect-smoke-bad-cs/source.yaml` — CREATE. Fixture metadata (NO `setup:`).
- `tests/ab/corpus/jbinspect-smoke-bad-cs/diff/changed-lines.txt` — CREATE. §5 scope (BadCode.cs 2,11,14).
- `tests/ab/corpus/jbinspect-smoke-bad-cs/expected/findings-jbinspect.md` — CREATE (promoted from Task 4 live capture, NOT pre-authored).
- `tests/ab/corpus/jbinspect-smoke-bad-cs/expected/findings.json` — CREATE (promoted, Task 4).
- `tests/ab/corpus/index.yaml` — MODIFY. Register the fixture.
- `tests/ab/lib/agent_capture.sh` — MODIFY. Add the `jbinspect|jbinspect-reviewer` case.
- `tests/ab/fixtures/jbinspect-stdout-three-findings.log` — CREATE. Parser test input.
- `tests/lib/test_ab_per_agent_lib.sh` — MODIFY. Add jbinspect parser + config-parse tests.
- `tests/ab/configs/per-agent/jbinspect-baseline.yaml` — CREATE. sonnet/default.
- `tests/ab/configs/per-agent/jbinspect-haiku-low.yaml` — CREATE. haiku/low.
- `plugins/code-review-suite/agents/jbinspect-reviewer.md` — MODIFY (Task 5, post-capture). Pin the live-captured worked example.
- `docs/superpowers/notes/2026-06-04-jbinspect-haiku-low-result.md` — CREATE (Task 7).

---

### Task 1: Corpus fixture (offline, no Bedrock) — fixture files ALREADY EXIST

The C# project under `tests/fixtures/static-analysis/jbinspect/` was authored and its
ground truth established earlier this session (see "Critical offline findings" above).
This task creates the remaining corpus-registration files and the `.gitignore` entry,
and re-verifies the fixture.

**Files:**
- Verify (exist): `tests/fixtures/static-analysis/jbinspect/{JbInspectSmoke.sln,JbInspectSmoke.csproj,BadCode.cs}`
- Verify (exists): `.gitignore` entry for the fixture's `bin/`/`obj/`
- Create: `tests/ab/corpus/jbinspect-smoke-bad-cs/source.yaml`
- Create: `tests/ab/corpus/jbinspect-smoke-bad-cs/diff/changed-lines.txt`
- Modify: `tests/ab/corpus/index.yaml`

- [ ] **Step 1: Verify the fixture files exist and the source is exactly as expected**

Run (separate Bash calls — no compound operators per CLAUDE.md):
```
find tests/fixtures/static-analysis/jbinspect -type f
```
Expected exactly: `JbInspectSmoke.sln`, `JbInspectSmoke.csproj`, `BadCode.cs` (no `bin/`/`obj/`).
Then read `BadCode.cs` and confirm it is byte-for-byte:
```csharp
using System;
using System.Text;

namespace JbInspectSmoke
{
    public class BadCode
    {
        public int LengthOfNothing()
        {
            string value = null;
            return value.Length;
        }

        private void UnusedHelper()
        {
            Console.WriteLine("never called");
        }
    }
}
```
(`System.Text` on line 2 is the redundant using; `value.Length` on line 11 is the
null-deref; `UnusedHelper` on line 14 is the unused private member. `System` IS used
by `Console`, so only line 2 is redundant.)

- [ ] **Step 2: Verify the fixture yields the expected 3-finding set (re-confirm ground truth)**

The harness does not shell-expand `$CLAUDE_TEMP_DIR`; use the literal session temp dir.
Run (single Bash call):
```
jb inspectcode tests/fixtures/static-analysis/jbinspect/JbInspectSmoke.sln --output=$CLAUDE_TEMP_DIR/inspectcode-verify.xml --format=Xml --severity=WARNING
```
(Resolve `$CLAUDE_TEMP_DIR` to the literal path from the SessionStart context — e.g.
`/tmp/claude-<session-id>/` — if the shell does not export it.)
Then in a SEPARATE call extract the issues:
```
grep -E '<Issue ' $CLAUDE_TEMP_DIR/inspectcode-verify.xml
```
Expected exactly three `<Issue>` lines, all with a `Line=` attribute:
```
<Issue TypeId="RedundantUsingDirective" File="BadCode.cs" Offset="14-32" Line="2" Message="..." />
<Issue TypeId="PossibleNullReferenceException" File="BadCode.cs" Offset="191-196" Line="11" Message="..." />
<Issue TypeId="UnusedMember.Local" File="BadCode.cs" Offset="237-249" Line="14" Message="..." />
```
If any finding is missing, a fourth appears, or any lacks a `Line=` attribute, STOP —
the fixture drifted; do not proceed. Clean up: `rm -f $CLAUDE_TEMP_DIR/inspectcode-verify.xml`
and `rm -rf tests/fixtures/static-analysis/jbinspect/bin tests/fixtures/static-analysis/jbinspect/obj`
(the in-place run leaves build artefacts — they are gitignored but remove them so the
working tree stays clean).

- [ ] **Step 3: Verify the `.gitignore` entry exists**

Run:
```
git check-ignore tests/fixtures/static-analysis/jbinspect/bin tests/fixtures/static-analysis/jbinspect/obj
```
Expected: both paths echoed (exit 0). If exit 1, the `.gitignore` entry is missing — add
under the "# Test artefacts" block:
```
tests/fixtures/static-analysis/jbinspect/bin/
tests/fixtures/static-analysis/jbinspect/obj/
```

- [ ] **Step 4: Write the changed-lines scope file**

Create `tests/ab/corpus/jbinspect-smoke-bad-cs/diff/changed-lines.txt`:
```
Changed lines:
  BadCode.cs: 2,11,14
```
(Lines 2/11/14 are the three finding lines — the §5 intersection keeps all three.)

- [ ] **Step 5: Write source.yaml (NO `setup:` block)**

Create `tests/ab/corpus/jbinspect-smoke-bad-cs/source.yaml`. Copy the trivy shape (no
`setup:` — InspectCode restores internally, like trivy is global-on-PATH):
```yaml
id: jbinspect-smoke-bad-cs
agent: jbinspect-reviewer
captured_at: 2026-06-04T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: PLACEHOLDER_FILL_AT_CAPTURE
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/jbinspect/
base_sha: ""  # synthetic fixture: no real diff
head_sha: ""
path_scope: ""
empty_tree_mode: false
intent_ledger: |
  ## Intent ledger
  - Synthetic smoke fixture exercising jbinspect-reviewer against a single C#
    project with a deterministic three-finding set (RedundantUsingDirective
    line 2, PossibleNullReferenceException line 11, UnusedMember.Local line 14),
    all mapped Important. Phase 3.4 baseline for the Haiku/low cost-tuning probe.
    InspectCode 2026.1.0.1 restores + builds the project internally; no setup needed.
depends_on:
  - plugins/code-review-suite/agents/jbinspect-reviewer.md
  - plugins/code-review-suite/agents/code-analysis.md
  - plugins/code-review-suite/includes/static-analysis-context.md
  - tests/fixtures/static-analysis/jbinspect/BadCode.cs
  - tests/fixtures/static-analysis/jbinspect/JbInspectSmoke.csproj
  - tests/fixtures/static-analysis/jbinspect/JbInspectSmoke.sln
```
NOTE: `suite_sha` is filled at capture time (Task 4) with the then-current HEAD; leave
the literal `PLACEHOLDER_FILL_AT_CAPTURE` until then so a forgotten fill is visible.

- [ ] **Step 6: Register the fixture in the corpus index**

In `tests/ab/corpus/index.yaml`, append under `fixtures:`:
```yaml
  - id: jbinspect-smoke-bad-cs
    agent: jbinspect-reviewer
    type: synthetic
    description: Three-finding C# set (RedundantUsingDirective line 2, PossibleNullReferenceException line 11, UnusedMember.Local line 14) on a single project. Phase 3.4 baseline.
    tags: [smoke, deterministic]
```

- [ ] **Step 7: Run the suite (expect green except the known dirty-tree artifact)**

Run: `bash tests/run.sh`
Expected: all pass EXCEPT `A/B run.sh: bad-config rejection leaves working tree clean`
(false-fails on uncommitted changes). No OTHER failures.

- [ ] **Step 8: Commit + push**

```bash
git add tests/fixtures/static-analysis/jbinspect/JbInspectSmoke.sln tests/fixtures/static-analysis/jbinspect/JbInspectSmoke.csproj tests/fixtures/static-analysis/jbinspect/BadCode.cs .gitignore tests/ab/corpus/jbinspect-smoke-bad-cs/source.yaml tests/ab/corpus/jbinspect-smoke-bad-cs/diff/changed-lines.txt tests/ab/corpus/index.yaml
git commit -m "test(ab): add jbinspect-smoke-bad-cs corpus fixture (3 deterministic C# findings)"
git push origin main
```

---

### Task 2: Parser-dispatch case + tests (offline, no Bedrock)

**Files:**
- Modify: `tests/ab/lib/agent_capture.sh` (add `jbinspect|jbinspect-reviewer` case after the `trivy` case)
- Create: `tests/ab/fixtures/jbinspect-stdout-three-findings.log`
- Modify: `tests/lib/test_ab_per_agent_lib.sh`

- [ ] **Step 1: Write the captured-output test fixture**

Create `tests/ab/fixtures/jbinspect-stdout-three-findings.log`. Mirror the trivy fixture
shape (preamble noise + canonical §7 block + trailing prose). Use the REAL TypeIds and
the `Important` mapped severity. The `Rule:` field uses the spaced-category form to
exercise the tokeniser:
```
Some preamble noise from the dispatched session.

## JetBrains InspectCode Findings

### Finding — redundant using directive
- **File:** BadCode.cs:2
- **Confidence:** 100
- **Severity:** Important
- **Rule:** RedundantUsingDirective (Redundancies in Code)
- **Description:** Using directive is not required by the code and can be safely removed.
- **Suggested fix:** Remove the `using System.Text;` directive on line 2.

### Finding — possible null reference
- **File:** BadCode.cs:11
- **Confidence:** 100
- **Severity:** Important
- **Rule:** PossibleNullReferenceException (Potential Code Quality Issues)
- **Description:** Possible 'System.NullReferenceException'.
- **Suggested fix:** Guard `value` against null before dereferencing `.Length` on line 11.

### Finding — unused private member
- **File:** BadCode.cs:14
- **Confidence:** 100
- **Severity:** Important
- **Rule:** UnusedMember.Local (Redundancies in Symbol Declarations)
- **Description:** Method 'UnusedHelper' is never used.
- **Suggested fix:** Remove the unused private method `UnusedHelper` on line 14, or call it where intended.

Trailing prose that must not be parsed as a finding.
```

- [ ] **Step 2: Write the failing parser tests**

In `tests/lib/test_ab_per_agent_lib.sh`, after the trivy parser tests
(`test_ab_agent_capture_trivy_non_path_skip_marks_inconclusive`, ~line 469), add:

```bash
test_ab_agent_capture_jbinspect_parses_three_findings() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/jbinspect-stdout-three-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture jbinspect: lib + fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial jbinspect "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "3" "$count" "A/B agent_capture jbinspect: three findings extracted"

    local first_rule first_file first_line
    first_rule=$(jq -r '.[0].rule_id' "$trial_dir/findings.json")
    first_file=$(jq -r '.[0].file' "$trial_dir/findings.json")
    first_line=$(jq -r '.[0].line' "$trial_dir/findings.json")
    assert_equals "RedundantUsingDirective" "$first_rule" "A/B agent_capture jbinspect: line-2 finding sorts first"
    assert_equals "BadCode.cs" "$first_file" "A/B agent_capture jbinspect: file parsed"
    assert_equals "2" "$first_line" "A/B agent_capture jbinspect: line parsed"

    # The CamelCase + spaced-category Rule field must tokenise to the bare TypeId.
    local unused_rule
    unused_rule=$(jq -r '.[] | select(.line == 14) | .rule_id' "$trial_dir/findings.json")
    assert_equals "UnusedMember.Local" "$unused_rule" "A/B agent_capture jbinspect: CamelCase rule_id with spaced category tokenises cleanly"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_jbinspect_zero_findings_is_empty_array() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## JetBrains InspectCode Findings\n\n0 findings — no C# files in diff.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial jbinspect "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture jbinspect: zero-state yields empty array"
    rm -rf "$trial_dir"
}

test_ab_agent_capture_jbinspect_no_solution_is_empty_array() {
    # The solution-discovery-miss zero-state ('could not determine solution for
    # changed C# files') is a genuine 'nothing to inspect', not a tool failure —
    # the parser treats it as zero, not skip/INCONCLUSIVE.
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## JetBrains InspectCode Findings\n\n0 findings — could not determine solution for changed C# files.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial jbinspect "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture jbinspect: no-solution zero-state yields empty array (not skip)"
    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        fail "A/B agent_capture jbinspect: no-solution is zero not INCONCLUSIVE" "INCONCLUSIVE marker present"
    else
        pass "A/B agent_capture jbinspect: no-solution is zero not INCONCLUSIVE"
    fi
    rm -rf "$trial_dir"
}

test_ab_agent_capture_jbinspect_skipped_marks_inconclusive() {
    # 'Skipped — jb inspectcode not available on PATH.' is the single logical
    # skip path; the broad '^Skipped — ' sentinel marks it INCONCLUSIVE.
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## JetBrains InspectCode Findings\n\nSkipped — jb inspectcode not available on PATH.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial jbinspect "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture jbinspect: skip marks INCONCLUSIVE"
    else
        fail "A/B agent_capture jbinspect: skip marks INCONCLUSIVE" "marker absent"
    fi
    rm -rf "$trial_dir"
}
```

- [ ] **Step 3: Run the new tests to verify they FAIL**

Run: `bash tests/run.sh 2>&1 | grep -i jbinspect`
Expected: the four new jbinspect tests FAIL with "unknown agent: jbinspect" (the parser
case doesn't exist yet).

- [ ] **Step 4: Add the jbinspect parser-dispatch case**

In `tests/ab/lib/agent_capture.sh`, in `_agent_capture_params()`, add a case BEFORE the
`*)` fallthrough (after the `trivy` case, ~line 45). Use the BROAD `^Skipped — ` opener
(jbinspect has a single logical skip path → any skip is full), and an alternation
zero-state covering BOTH the file-filter miss and the solution-discovery miss:
```bash
        jbinspect|jbinspect-reviewer)
            _AC_HEADING='^## JetBrains InspectCode Findings$'
            # jbinspect has a single invocation path (jb not on PATH) → any
            # skip is a full skip → INCONCLUSIVE. Broad opener from the start.
            _AC_SKIP='^Skipped — '
            # Two zero-states: the file-extension miss and the solution-discovery
            # miss. Both are genuine 'nothing to inspect' (not tool failures), so
            # both map to zero findings, not skip.
            _AC_ZERO='^0 findings — (no C# files in diff|could not determine solution for changed C# files)\.'
            ;;
```
Update the header comment block (lines 11-15) to note jbinspect's CamelCase TypeIds with
a spaced `(Category)` suffix also tokenise cleanly (the first space/tab/paren delimits
token 1 = the bare TypeId; the `.` is internal so it never splits the ID).

- [ ] **Step 5: Run the new tests to verify they PASS**

Run: `bash tests/run.sh 2>&1 | grep -i jbinspect`
Expected: all four new jbinspect tests PASS.

- [ ] **Step 6: Run the FULL suite**

Run: `bash tests/run.sh`
Expected: all pass except the known dirty-tree artifact. Note the new total.

- [ ] **Step 7: Commit + push**

```bash
git add tests/ab/lib/agent_capture.sh tests/ab/fixtures/jbinspect-stdout-three-findings.log tests/lib/test_ab_per_agent_lib.sh
git commit -m "test(ab): add jbinspect parser-dispatch case + captured-output tests"
git push origin main
```

---

### Task 3: A/B configs (offline, no Bedrock)

**Files:**
- Create: `tests/ab/configs/per-agent/jbinspect-baseline.yaml`
- Create: `tests/ab/configs/per-agent/jbinspect-haiku-low.yaml`
- Modify: `tests/lib/test_ab_per_agent_lib.sh` (add the config-parse test)

- [ ] **Step 1: Write the baseline config**

Create `tests/ab/configs/per-agent/jbinspect-baseline.yaml` (copy trivy-baseline shape):
```yaml
name: jbinspect-baseline
description: Production reference for jbinspect-reviewer — sonnet at default effort.
mode: per-agent
agent: jbinspect-reviewer
session:
  model: sonnet
  effort: default
```

- [ ] **Step 2: Write the haiku-low config**

Create `tests/ab/configs/per-agent/jbinspect-haiku-low.yaml`:
```yaml
name: jbinspect-haiku-low
description: Phase 3.4 directional probe — jbinspect-reviewer at Haiku/low. Compared against jbinspect-baseline (sonnet/default) on per-trial findings hash.
mode: per-agent
agent: jbinspect-reviewer
session:
  model: haiku
  effort: low
```

- [ ] **Step 3: Add the config-parse test**

In `tests/lib/test_ab_per_agent_lib.sh`, after `test_ab_config_per_agent_trivy_haiku_low_parses`
(~line 765), add the mirrored jbinspect version:
```bash
test_ab_config_per_agent_jbinspect_haiku_low_parses() {
    # Phase 3.4: the haiku-low probe arm config must parse and expose
    # session.model=haiku, session.effort=low. The harness drives all
    # variation; the agent file is never touched at runtime.
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local probe="$REPO_ROOT/tests/ab/configs/per-agent/jbinspect-haiku-low.yaml"

    if [[ ! -f "$config" ]]; then
        fail "A/B config: per-agent jbinspect-haiku-low parses" "config.sh missing"
        return
    fi
    if [[ ! -f "$probe" ]]; then
        fail "A/B config: per-agent jbinspect-haiku-low parses" "jbinspect-haiku-low.yaml not yet authored"
        return
    fi

    local mode agent model effort
    mode=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_MODE:-}"
    )
    agent=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_AGENT:-}"
    )
    model=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_MODEL:-}"
    )
    effort=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_EFFORT:-}"
    )

    assert_equals "per-agent" "$mode" "A/B config: jbinspect-haiku-low.mode = per-agent"
    assert_equals "jbinspect-reviewer" "$agent" "A/B config: jbinspect-haiku-low.agent = jbinspect-reviewer"
    assert_equals "haiku" "$model" "A/B config: jbinspect-haiku-low.session.model = haiku"
    assert_equals "low" "$effort" "A/B config: jbinspect-haiku-low.session.effort = low"
}
```

- [ ] **Step 4: Run the suite + commit + push**

Run: `bash tests/run.sh` (expect green bar the dirty-tree artifact; the new
config-parse test PASSES).
```bash
git add tests/ab/configs/per-agent/jbinspect-baseline.yaml tests/ab/configs/per-agent/jbinspect-haiku-low.yaml tests/lib/test_ab_per_agent_lib.sh
git commit -m "test(ab): add jbinspect baseline + haiku-low per-agent configs"
git push origin main
```

---

### Task 4: Live worked-example capture (GATED — Bedrock spend, ~1-3 trials)

**STOP. This task spends real Bedrock. Get explicit operator go-ahead before running
anything in it.** The capture-then-pin discipline (per [[worked-example-gap]]):
jbinspect-reviewer.md has NO worked example, so the first capture WILL likely parse to
zero tuples until we see the real §7 layout and pin it. **Budget more wall-clock than
trivy** — InspectCode loads a solution and runs the .NET analyser, so each trial is
slower than a trivy/ruff/eslint trial.

**Watch for the temp-dir over-literalism failure mode.** jbinspect ACTUALLY writes
`inspectcode-<sln>.xml` to `$CLAUDE_TEMP_DIR` and parses it (unlike trivy/ruff/eslint
which can stream stdout), so the trial-016-style self-abort on the unexpanded
`$CLAUDE_TEMP_DIR` token is MORE likely to bite. If a capture trial self-aborts citing
a missing temp dir, that is the known mechanism — characterise it; the fix (a temp-dir
clarification mirroring trivy's `5ccb692`) is deferred to the verdict/fix arc (Task 7),
not pre-authored here.

**Files:**
- Create: `tests/ab/corpus/jbinspect-smoke-bad-cs/expected/findings-jbinspect.md`
- Create: `tests/ab/corpus/jbinspect-smoke-bad-cs/expected/findings.json`
- Modify: `tests/ab/corpus/jbinspect-smoke-bad-cs/source.yaml` (fill `suite_sha`)

- [ ] **Step 1: Capture ONE Sonnet/default trial**

Run:
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/jbinspect-baseline.yaml --corpus jbinspect-smoke-bad-cs --trials 1 --stream-json
```
(NO `--mode` flag — mode is config-derived.)

- [ ] **Step 2: Inspect the captured stdout.log for the REAL §7 layout**

Read the run's trial-001 `stdout.log` under `tests/ab/runs/<ts>-jbinspect-baseline/`. Note
EXACTLY how the agent laid out the findings block: heading text, the `### Finding` shape,
the `Rule:` field format (does it emit `TypeId (Category)` with the spaced category, or
`TypeId (CategoryId)` with the CamelCase `DeclarationRedundancy`?), severity tokens.
Check `findings.json` — if it parsed to `[]` despite a visible report, that's the
zero-tuple gap; the worked example (Task 5) fixes it.

- [ ] **Step 3: Promote the captured report as the expected baseline**

Copy the captured findings block into
`tests/ab/corpus/jbinspect-smoke-bad-cs/expected/findings-jbinspect.md` and the parsed
tuples into `expected/findings.json` (these should match the canonical tuple set in the
header — three `Important` findings on BadCode.cs lines 2, 11, 14). Fill `suite_sha` in
`source.yaml` with the current HEAD sha (replace `PLACEHOLDER_FILL_AT_CAPTURE`).

---

### Task 5: Pin the worked example (offline, depends on Task 4 capture)

**Files:**
- Modify: `plugins/code-review-suite/agents/jbinspect-reviewer.md`

- [ ] **Step 1: Add a `### Worked example` section**

After the `## Output` section (~line 90, before the "Keep in sync" line) add a
`### Worked example` modelled on trivy-reviewer.md lines 82-117, using the ACTUAL
captured layout from Task 4 (the three findings on BadCode.cs lines 2/11/14). Do NOT
invent — match what the agent emitted. The example MUST end with the same closing
guidance trivy uses (em-dash heading shape, exact field names `File`/`Confidence`/
`Severity`/`Rule`/`Description`/`Suggested fix`, no `### <Severity>` grouping, no
prose-block/`---` layout — the harness parser pins to the §7 names).

Example skeleton (replace bullet *prose* with the real captured text; keep the structure):
```
### Worked example

For the C# project whose changed lines 2, 11, 14 trip three InspectCode rules (a redundant `using System.Text;` on line 2, a possible null-reference on `value.Length` at line 11, and an unused private method `UnusedHelper` at line 14), the canonical §7 output is:

​```
## JetBrains InspectCode Findings

### Finding — redundant using directive
- **File:** BadCode.cs:2
- **Confidence:** 100
- **Severity:** Important
- **Rule:** RedundantUsingDirective (Redundancies in Code)
- **Description:** Using directive is not required by the code and can be safely removed.
- **Suggested fix:** Remove the `using System.Text;` directive on line 2 — nothing in the file references the `System.Text` namespace.

### Finding — possible null reference
- **File:** BadCode.cs:11
- **Confidence:** 100
- **Severity:** Important
- **Rule:** PossibleNullReferenceException (Potential Code Quality Issues)
- **Description:** Possible 'System.NullReferenceException'.
- **Suggested fix:** `value` is assigned `null` on line 10, so `value.Length` on line 11 always throws — return `0`/guard with a null check, or remove the dead method.

### Finding — unused private member
- **File:** BadCode.cs:14
- **Confidence:** 100
- **Severity:** Important
- **Rule:** UnusedMember.Local (Redundancies in Symbol Declarations)
- **Description:** Method 'UnusedHelper' is never used.
- **Suggested fix:** Remove the unused private method `UnusedHelper` on line 14, or wire it into the call path it was written for.
​```

The heading is `### Finding — <title>` (em-dash, U+2014). The `Rule:` field is `TypeId (Category)` (the `Category` attribute from the XML `<IssueType>` header, e.g. `Redundancies in Code` — not the `CategoryId`). All three InspectCode `WARNING`s map to `Important` (jbinspect's Critical-allow-list is empty). The bullet field names are exactly `File`, `Confidence`, `Severity`, `Rule`, `Description`, `Suggested fix` — do not substitute synonyms, do not group under a `### <Severity>` sub-heading, and do not use a prose-block or `---`-separated layout; the harness parser pins to the §7 names and per-finding `### Finding` blocks.
```
**Adjust the `Rule:` category text to match whatever Task 4 actually captured** (if the
agent emitted `(CodeRedundancy)`/`(DeclarationRedundancy)` CategoryId form instead of the
spaced `Category` form, pin THAT — the rule_id tokenises identically either way, but the
worked example must reflect reality).

- [ ] **Step 2: Sync check against code-analysis.md**

A new `### Worked example` section at the end of the jbinspect body does not alter the
mirrored solution-discovery/invocation procedure, so `code-analysis.md` needs no change.
CONFIRM this by re-reading `code-analysis.md` lines 13-19 and 71-98: the worked example
must not contradict the §7 format block already there. Run `bash tests/run.sh` and verify
no sync-note test fails.

- [ ] **Step 3: Re-capture ONE trial to confirm the worked example fixes the parse (GATED)**

Get operator go-ahead. Re-run the Step-1 capture command. Confirm `findings.json` now
parses to the three expected tuples (the worked example closed the gap).

- [ ] **Step 4: Commit + push**

```bash
git add plugins/code-review-suite/agents/jbinspect-reviewer.md tests/ab/corpus/jbinspect-smoke-bad-cs/expected/findings-jbinspect.md tests/ab/corpus/jbinspect-smoke-bad-cs/expected/findings.json tests/ab/corpus/jbinspect-smoke-bad-cs/source.yaml
git commit -m "feat(jbinspect-reviewer): pin live-captured worked example for §7 parse"
git push origin main
```

---

### Task 6: The matched 2×20 probe (GATED — ~$4-5 list / ~25-40 min, the main Bedrock spend)

**STOP. Get explicit operator go-ahead.** "Continue" does NOT authorise the spend. Run
BOTH arms at n=20 (the full matched pair, NOT a Haiku-only shortcut — jbinspect has no
prior data). jbinspect trials are SLOWER than trivy (InspectCode loads a solution and
runs the .NET analyser) — budget more wall-clock. Consider `run_in_background: true` per
arm and let the completion notification land.

- [ ] **Step 1: Sonnet/default baseline arm, n=20**

```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/jbinspect-baseline.yaml --corpus jbinspect-smoke-bad-cs --trials 20 --stream-json
```

- [ ] **Step 2: Haiku/low arm, n=20**

```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/jbinspect-haiku-low.yaml --corpus jbinspect-smoke-bad-cs --trials 20 --stream-json
```

- [ ] **Step 3: Tabulate canonical-hash rate per arm + cost ratio**

For each run's `summary.csv`: count trials whose `findings_hash` equals the modal
(canonical) hash; tally any INCONCLUSIVE/skip markers; compute mean `total_cost_usd` per
arm and the Sonnet ÷ Haiku RATIO (report RATIO only — the stream cost is Anthropic LIST
price, not Bedrock, per [[phase-3-2b-pr-b-reprobe]]). Expect ~2.2-2.5× by the
three-specialist precedent (ruff ~2.2×, eslint 2.17×, trivy 2.34×).

---

### Task 7: Verdict + result note + memory (offline)

**Files:**
- Create: `docs/superpowers/notes/2026-06-04-jbinspect-haiku-low-result.md`

- [ ] **Step 1: Apply the verdict framework**

Per `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`:
- **EQUIVALENT** — Haiku matches the canonical hash within noise (clean, single-hash arm). → flip production.
- **INCONCLUSIVE (decision-4)** — mixed within-arm hashes default to inconclusive regardless of rate. → do not flip; characterise the tail.
- **WORSE** — >25 % NORMAL-rate drop. → do not flip.

If a real agent-side tail survives the clean apparatus (e.g. a temp-dir self-abort as
trivy's trial-016 did), CHARACTERISE it — do NOT pre-author a fix. Any fix must be a
general correctness improvement (helping Sonnet too — the tuning-to-the-test guard)
earning its own before/after re-sweep at n=20 on both arms (the eslint/trivy precedent).
The most likely jbinspect tail is the temp-dir over-literalism (trivy `5ccb692`
precedent) — if it appears, the analogous fix is a clarification in the jbinspect body's
`## Tool invocation` section (line 43, the terse `Check $CLAUDE_TEMP_DIR is present`)
that the literal unexpanded token satisfies the §4 contract; that change DOES touch the
mirrored invocation procedure, so it must also propagate to `code-analysis.md`.

- [ ] **Step 2: Write the result note**

Mirror `docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md` (the closest
precedent — it has the full shape): header block with run dirs + sweep SHA, sweep config,
hash-distribution table per arm, any agent-side tail characterised, cost delta + ratio
with the list-price caveat, verdict verbatim, production-flip recommendation, and — if you
fix-and-re-sweep — a "Fixes SHIPPED + re-sweep VALIDATED" section.

- [ ] **Step 3: Update memory**

Add `project_phase_3_4_jbinspect_shipped.md` to the `~/.claude` repo memory dir
(`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`, NOT this
clone): verdict, cost ratio, commits, whether production flipped, and the note that this
CLOSES the Phase 3 static-specialist sweep. Add the MEMORY.md index line. Commit + push
the `~/.claude` repo separately.

- [ ] **Step 4: Commit + push the result note**

```bash
git add docs/superpowers/notes/2026-06-04-jbinspect-haiku-low-result.md
git commit -m "docs(ab): Phase 3.4 jbinspect Haiku/low A/B result + verdict"
git push origin main
```

- [ ] **Step 5: Production flip (operator-gated, only on clean EQUIVALENT)**

Set BOTH `model: haiku` AND `effort: low` in `jbinspect-reviewer.md` frontmatter (mirror
trivy `ee23a79` / eslint+ruff `3b3a255`). NB jbinspect's frontmatter currently has only
`model: sonnet` (no `effort:` field) — add the `effort: low` line. To make it live
mid-session: `/plugins update` then `/reload-plugins` (the A/B harness reads the
working-tree file directly via `agent_dispatch.sh:113`, so the SWEEP needs no reload —
only the live `/code-review` pipeline does). **Operator-gated even on a clean
EQUIVALENT** — it changes a dispatched-agent definition.

---

## Self-review notes

- **Spec coverage:** spec Step 1 (smoke fixture — Task 1), Step 2 (Sonnet baseline
  capture — Task 4), Steps 3-4 (faithfulness + directional probe, here as the matched
  2×20 — Task 6), Step 5 (one-page report — Task 7). The spec's jbinspect fixture spec
  (lines 124, 257: `UnusedMember.Local` + `RedundantUsingDirective` + possible-NullRef,
  CamelCase rule IDs) — all three findings realised and ground-truthed in Task 1; the
  tooling-deferral condition (line 238) is lifted (InspectCode 2026.1.0.1 + dotnet
  10.0.300 present).
- **No `setup:` block:** empirically verified — InspectCode restores + builds the
  project internally inside the hermetic per-trial copy; a clean no-`bin/obj` copy
  produced the identical three-finding set. So no install-race and no provisioning step
  (matches trivy/ruff).
- **Gating:** Tasks 1-3 fully offline (commit freely). Tasks 4, 5-step-3, and 6 are
  Bedrock spends — each STOPs for operator go-ahead. Production flip (Task 7 step 5) is
  operator-gated even on a clean EQUIVALENT.
- **Sync coupling:** the jbinspect↔code-analysis mirror is the new 3.4 wrinkle —
  Task 5 step 2 checks it for the worked-example pin (no mirror needed), and Task 7
  step 1 flags that a temp-dir-contract fix WOULD need mirroring.
- **The `--mode` flag does NOT exist** — mode is config-derived. Every run command above
  omits it deliberately.
