# Agent-generated-code hardening for the code-review plugin

Date: 2026-05-11
Status: design (approved)
Plan source: `~/.claude/plans/crispy-launching-castle.md`

## Context

The local code-review plugin (`plugins/code-review/`) catches the bugs
a typical reviewer or linter looks for, but agent-generated code has a
distinct failure profile. Bugs surface as "plausible-but-wrong" rather
than "obviously broken": code compiles, tests pass, comments read
sensibly, and the diff looks idiomatic — yet quietly drifts from the
problem the author actually asked about, picks historic dependency
versions, or fabricates API signatures.

This design hardens the plugin against seven such failure classes
without rebuilding the existing pipeline. Most coverage lands on
existing specialists by extending their prompts; one new specialist
(`alignment-reviewer`) is added to handle intent and scope, which
require a different reasoning frame. A new Phase 0 captures intent
before fan-out and halts when a PR provides no description.

## Goals

- Detect the seven agent-flavoured bug classes listed below.
- Make missing PR context a hard halt (matches the user's
  organisational policy: every PR begins with a text description).
- Keep the plugin's existing strengths (cross-review, severity
  reclassification, mandatory dispatch, no-filter rule) unchanged.
- Stay format-agnostic and workflow-agnostic — no assumption of
  Markdown, superpowers, or any specific spec layout.

## Non-goals

- Replacing or restructuring the existing specialists.
- Building a persistent artifact / cumulative token-spend system
  (that is a separate piece of work, see
  `docs/adamsreview-comparison.md`).
- Auto-fixing findings.
- Triggering on commit hooks or CI.

## Bug classes covered

| # | Class                          | Description                                                                                                       |
|---|--------------------------------|-------------------------------------------------------------------------------------------------------------------|
| 1 | Plausible-but-wrong            | Wrong API version, hallucinated function signature, off-by-one in an uncovered place, unmodelled race.            |
| 2 | Surface-correct, intent-drifted| The diff solved a slightly different problem than the one asked.                                                  |
| 3 | Over-scoped                    | Opportunistic refactoring, abstractions nobody asked for, stray dependencies.                                     |
| 4 | Convention drift               | Pattern-matched to "generic best practice" instead of how this codebase does things.                              |
| 5 | Lying comments                 | Docstrings/comments describe what the agent thought it was doing, not what the code does.                         |
| 6 | Security and supply-chain      | Dependency choices without advisory checks, shell construction without injection review, secrets handling drift. |
| 7 | Version staleness              | Newly introduced or modified dependency / action versions match training-era versions, not current latest stable. |

## Design

### Phase 0 — intent ledger and CI signal

A new Phase 0 runs before the existing Step 1. It is implemented in a
new shared include
(`plugins/code-review/includes/intent-ledger.md`) consumed by both
`skills/review-gh-pr/SKILL.md` and `commands/pre-review.md`.

#### Intent capture

Source priority — first sufficient source wins:

1. **In-diff prose document.** Any added or modified prose document in
   the diff that reads as intent. Format-agnostic: Markdown is the
   common default, but `.rst`, `.txt`, `.org` are equally valid.
   Detection uses common doc-folder hints (`docs/`, `design/`,
   `specs/`, `rfcs/`, `proposals/`, `adr/`) plus a future
   repo-configurable override (e.g. `.claude/code-review.toml`).
2. **Verbatim prompt block.** A fenced "Prompt:" section in the PR
   body or a commit message, or a prompt artifact in the diff (e.g.
   under `.claude/prompts/`). Treated as authoritative when present.
3. **PR body prose.** The author's own description.
4. **Branch commit subjects.** Last-resort fallback for local
   pre-review only — never sufficient on its own in PR mode.

The ledger is a structured object passed downstream to every
specialist:

```
{
  "goal": "<prose>",
  "non_goals": "<prose | null>",
  "files_in_scope": ["..."] | null,
  "source": "in_diff_doc" | "prompt_block" | "pr_body" | "commit_subjects"
}
```

`non_goals` and `files_in_scope` are populated only if the source
states them; the alignment-reviewer treats their absence as a
Suggestion-tier finding rather than a halt.

#### Sufficiency rule

Structural, not LLM-judged. Intent is sufficient if any of sources
1–3 contains a **narrative prose paragraph** that all of:

- Sits at the top of the body, before any checklist, table, or
  collapsed details block (i.e. it reads as the description, not as a
  trailing footnote).
- Is at least **two sentences** of prose, each ending in `.!?`.
- Totals **more than seven words** combined (a hard floor — most
  bodies will be substantially longer; this is the bare-minimum gate).
- Is not entirely composed of checklist items (`- [ ]`, `- [x]`),
  headings, code fences, or template placeholders.
- Is not a verbatim quote of the PR template (template detection: a
  paragraph is suspect if every line also appears in
  `.github/pull_request_template.md` or equivalent).

The shape that should pass is a paragraph written for the human
reviewer — explaining what the change is for, as the author would
explain it in conversation. Below that bar → halt.

The *quality* of the prose is not judged at this gate. Anything
thinner than a reasonable explanation surfaces downstream as an
`alignment-reviewer` body-improvement finding (Suggestion-tier).
This matches the user's organisational policy that every PR begins
with a text description.

#### Insufficient → hard halt

Short-circuit before any specialist fan-out.

- **PR mode (any author).** Post one top-level review with verdict
  `REQUEST_CHANGES` and a single comment asking for a description of
  what the change is about. No fan-out, no synthesiser, no inline
  comments. End. The reviewer re-runs once the body is updated.
- **Local pre-review.** Prompt the user inline once. Either they
  provide intent (which becomes the ledger) or the run halts.

#### CI signal

After the body check passes, Phase 0 fetches `gh pr checks --json` (PR
mode only). Local pre-review skips this step.

A check is **failing** if its state is `FAILURE`, `ERROR`,
`TIMED_OUT`, or `ACTION_REQUIRED`. `SUCCESS`, `NEUTRAL`, `SKIPPED`,
`PENDING`, `IN_PROGRESS`, `QUEUED`, and `CANCELLED` are not failing.

Rationale for the not-failing list:

- `CANCELLED` is excluded because multi-trigger workflows legitimately
  cancel one trigger when another takes over (the actual run continues
  under a different hook).
- `SKIPPED` and `NEUTRAL` indicate the check intentionally did not run.

`TIMED_OUT` is treated as failing but classified as **transient** —
often resolvable by rerunning the workflow without code changes (e.g.
on slow self-hosted runners). The acknowledgement prompt must
distinguish transient (`TIMED_OUT`) from definitive (`FAILURE`,
`ERROR`, `ACTION_REQUIRED`) so the reviewer knows whether to chase a
fix or just rerun.

- **All checks passing or in-flight.** Proceed silently to fan-out.
- **One or more failing checks.** Display the failing-check summary
  to the human reviewer, marking each failure as transient or
  definitive, and ask for explicit acknowledgement before fan-out. If
  the reviewer declines (e.g. they want to rerun a transient timeout
  first), halt cleanly with no PR posting.
- **On acknowledgement.** Fan-out runs as normal. The synthesiser
  appends a "CI status" section listing failing checks (with
  transient/definitive labels). Definitive failures constrain the
  final verdict to `REQUEST_CHANGES` or `COMMENT` — never `APPROVE`.
  Transient-only failures (e.g. timeouts on legacy runners) constrain
  away from `APPROVE` but the synthesiser flags them as
  reviewer-judgement ("rerun may resolve") rather than code defects.

### Specialist consolidation

The pipeline keeps its existing specialists. Three are augmented and
one is added.

#### `correctness-reviewer` — augmented (#1, #5)

Existing remit (logic errors, off-by-one, null derefs, races, resource
leaks) gains:

- **Hallucinated APIs / wrong signatures / wrong API versions.** When
  the diff calls a library or framework function, verify the
  signature against the version pinned in the lockfile / project file.
  When in doubt, web-fetch the current docs. Flag confident-looking
  calls that don't exist or whose signature doesn't match.
- **Comment-truth verification.** Read each new or modified comment /
  docstring against the code it describes. Flag claims that don't
  match the actual behaviour.

Both fit the existing "does this code do what it claims" frame.

#### `security-reviewer` — augmented (#6, #7)

Existing remit (injection, authz, secrets, OWASP top 10) gains three
explicit bullet groups:

- **Version safety.** Check newly added or modified dependencies
  against advisories.
- **Version pinning.** Lockfile hygiene; exact pinning vs floating
  ranges per repo conventions.
- **Version freshness.** For dependencies and GitHub Actions newly
  introduced or modified by the diff, verify against the live
  registry (npm, NuGet, PyPI, RubyGems, crates.io, Go proxy, GitHub
  Marketplace) that the chosen version is current. Older versions
  always produce a **Suggestion finding** — there is no skip path.
  The framing depends on whether justification is present:
  - **No justification.** "Consider upgrading to the latest stable
    version, or document the constraint that requires this version."
  - **Clear, reasoned justification** (inline comment, commit message,
    or PR body — must explain *why* this version is required, not
    merely state that it was chosen). "Noted: <quoted reason>; no
    action required." Recording the finding keeps the reasoning
    visible in the review trail.

  Live web fetch is required; cached or trained-knowledge answers do
  not count. Do not flag versions the diff did not touch.

  Severity is intentionally low: staleness alone is a smell, not a
  defect. When a stale version *also* has a known security
  vulnerability, the version-safety check (above) raises it to
  Important or Critical — that is the security path, not this one.

#### `consistency-reviewer` — light addition (#4)

Existing remit (CLAUDE.md, editorconfig, eslint/prettier, naming) is
already well-suited; add a single framing bullet:

- Flag patterns that look like "generic best practice" boilerplate
  when the surrounding codebase uses a different convention (logging
  style, error handling shape, test structure, naming).

#### `alignment-reviewer` — new specialist (#2, #3)

Reasons inversely from the ledger to the diff. Two questions:

1. Does the diff achieve the stated goal? Anything in the goal that
   the diff does not deliver, or anything the diff delivers that
   contradicts the goal, is a finding.
2. Does the diff stay within declared scope? Touched files outside
   `files_in_scope` (when stated), or new dependencies not justified
   by the goal, are findings.

When the ledger is sufficient but thin, the alignment-reviewer also
emits Suggestion-tier findings on how the PR body could be improved
(missing non-goals, no acceptance criteria, unstated assumptions).
The hard break is "no minimum context"; everything beyond that is
constructive.

### Cross-review

Specialists remain broad enough that 2–3 peers can verdict any
finding. `alignment-reviewer` participates in cross-review on equal
footing with the others — it can verdict correctness or style
findings, and they can verdict its findings, because every specialist
sees the diff and the ledger.

### Synthesiser

`review-synthesiser` ingests the ledger as part of severity
reclassification. Specifically:

- A finding's relevance to the stated goal informs its severity.
- The CI status section (when present) is rendered before the
  Consensus Findings section and constrains the final verdict.
- "Body could be improved" findings render under Suggestions, never
  blocking.

### `address-pr-comments`

Out of scope. The command works through review threads against the
existing diff; it does not run the specialist fan-out and therefore
needs no ledger.

## Files to change

| File                                                                                            | Change                                                                                          |
|-------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| `plugins/code-review/includes/intent-ledger.md` (new)                                           | Shared ledger logic — source detection, structural sufficiency, halt path.                      |
| `plugins/code-review/includes/review-pipeline.md`                                               | Add Phase 0 (intent + CI) before Step 1. Pass ledger to specialists. Define halt path.          |
| `plugins/code-review/includes/specialist-context.md`                                            | Extend shared context block with the ledger schema.                                             |
| `plugins/code-review/agents/correctness-reviewer.md`                                            | Add #1 (hallucinated APIs / signatures / versions) and #5 (comment truth) bullets.              |
| `plugins/code-review/agents/security-reviewer.md`                                               | Add #6 (advisories, lockfile pinning) and #7 (version freshness, live registry check) bullets.  |
| `plugins/code-review/agents/consistency-reviewer.md`                                            | Add the "generic best practice vs codebase convention" framing bullet.                          |
| `plugins/code-review/agents/alignment-reviewer.md` (new)                                        | New specialist for #2 and #3.                                                                   |
| `plugins/code-review/agents/review-synthesiser.md`                                              | Ingest ledger; render CI section; constrain verdict on CI red.                                  |
| `plugins/code-review/skills/review-gh-pr/SKILL.md`                                              | Invoke Phase 0; implement halt path; fetch and gate on CI.                                      |
| `plugins/code-review/commands/pre-review.md`                                                    | Invoke Phase 0; implement local halt path (inline prompt).                                      |
| `plugins/code-review/README.md`                                                                 | Document the ledger, halt behaviour, and version-freshness rule.                                |

### Reused patterns

- **Self-re-review narrowing.** `review-gh-pr` already detects prior
  reviews via `gh pr view --json reviews`. The halt path reuses the
  same review-posting machinery.
- **Truncation rule.** The 4000-char-per-specialist findings cap
  applies unchanged.
- **Cross-review mode.** `includes/cross-review-mode.md` extends to
  `alignment-reviewer` automatically — no change needed.
- **Severity reclassification gate.** The synthesiser remains the
  authoritative severity gate, now informed by the ledger.

## Verification

End-to-end smoke tests:

- **Empty PR body.** `/review-gh-pr` against a PR with no body must
  post `REQUEST_CHANGES` and a single comment, with no fan-out and no
  inline comments.
- **Populated PR body.** Same command must fan out specialists with
  the ledger attached and proceed normally.
- **Local pre-review with no commit body.** Must halt and prompt the
  user inline; populated commit must proceed.
- **Scope creep.** A PR that touches files outside the declared scope
  must produce an `alignment-reviewer` finding.
- **Wrong API call.** A signature mismatch (e.g. wrong arg count for a
  pinned library version) must produce a `correctness-reviewer`
  finding.
- **Lying comment.** A docstring that contradicts its function's
  behaviour must produce a `correctness-reviewer` finding.
- **Outdated dependency.** Introducing an old version of an Action or
  library must always produce a `security-reviewer` version-freshness
  finding at Suggestion severity. With no justification: framed as
  "consider upgrading or document the constraint". With a clear
  reasoned justification: framed as "noted, no action required". An
  old version that *also* has a known advisory must additionally be
  raised at Important or Critical via the version-safety path.
- **Failing CI.** A PR with a red check must prompt for
  acknowledgement before fan-out and constrain the verdict away from
  `APPROVE`.
- **Existing structural tests.** `tests/run.sh` must remain green;
  the include-cross-reference checks cover the new
  `intent-ledger.md` include.

## Out of scope (for follow-on work)

The following appeared during the brainstorm but are deferred:

- Token instrumentation and persistent review artifact (see
  `docs/adamsreview-comparison.md`).
- Interactive walkthrough command.
- Auto-fix loop with regression revert.
- Codex peer-lens ensemble.
- Cheap-then-deep gating (Sonnet pre-score before Opus synthesiser).
