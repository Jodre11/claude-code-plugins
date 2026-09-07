---
name: review-spec
description: >
  Adversarially review a written spec or design doc before it becomes an implementation plan.
  Dispatches a panel of independent reviewers with distinct lenses, verifies their findings
  against the spec and the repo, applies the unambiguous ones, and surfaces only genuine
  trade-offs — as one batched set of options with a recommendation. Use automatically the
  moment brainstorming has committed a spec and before invoking writing-plans. Also on
  "review the spec", "validate the spec", "verify the spec", "adversarially review the spec",
  "second opinion on the spec", "/review-spec". Skip for a spec already reviewed with no
  changes since.
argument-hint: "[spec-path]"
---

# Spec review panel

Brainstorming and writing-plans both check their own output — same agent, same context, same
blind spots, and both end "fix inline and move on". The only independent critic of a spec in
that flow is the human. This skill adds the missing pass: reviewers who never saw the
conversation, judging the artefact.

**You are the lead.** You wrote the spec (or inherited it). You also adjudicate the reviews,
and you treat reviewer output as *intern findings*: plausible, must be verified, sometimes
wrong.

**This runs unattended.** The author is consulted once, for genuine trade-offs only. Do not
ask permission to start, do not ask whether to apply a verified finding, and do not ask for
confirmation before moving on. Decide, act, report.

## Step 1 — Resolve the spec

Use `$ARGUMENTS` if given. Otherwise take the most recently modified file in
`docs/superpowers/specs/`. If neither resolves, ask for the path — that is the one blocking
question in this skill.

No context file is built. The spec is already the self-contained artefact, which is the whole
reason this review is cheap. Do not summarise it into a second document.

## Step 2 — Dispatch the panel

Three lenses, ordered by marginal value in this workflow:

| Lens | Asks | Notes |
|---|---|---|
| `subtraction` | What should be cut? Is there a simpler shape? | Highest value. Brainstorming says "YAGNI ruthlessly" but only ever self-checks it. |
| `completeness` | What is missing or readable two ways? | Overlaps spec self-review, but from outside the authoring context. |
| `framing` | Right problem? Right shape? | Only lens that may `REJECT`. Drop to a two-lens panel when the brainstorming dialogue interrogated framing thoroughly and the author approved the shape. |

Dispatch **in parallel, in one message**, each with `subagent_type: "spec-reviewer"` and a
distinct `name` (`spec-reviewer-subtraction`, etc.).

**Model selection is made here, at dispatch — never in the agent's frontmatter.** Choose the
most capable model available, and never one weaker than the session that wrote the spec: a
reviewer below the author's capability rubber-stamps. A frontmatter alias that fails to
resolve silently inherits the parent model, which yields a review that only looks
independent — hence the rule.

Prompt each with:

```
Review the attached spec under the <LENS> lens only. Be critical: verify it against the
repo and report what is actually wrong. Do not over-engineer, and do not stray into the
other lenses.

Spec: <absolute path>

Your plain-text output is NOT visible to the controller. Deliver your entire result via
SendMessage to "main".
```

## Step 3 — Verify every finding

Open the spec section and the cited code for each finding. A finding marked `unverified`, or
citing a location that does not say what the reviewer claims, gets no credit. Where reviewers
disagree, the spec and the repo decide — never majority vote.

## Step 4 — Classify

Every surviving finding lands in exactly one bucket.

**Apply** — verified, and has a single sensible resolution. Ambiguity with one reasonable
reading, a missing requirement plainly implied by the goal, a subtraction with no downside, a
contradiction with one correct side. Fold it into the spec and give it one line in the receipt.

**Choice** — escalate to the author *only* if one of these holds:
- it changes the spec's scope or user-visible behaviour, or
- reviewers disagree and neither the spec nor the repo settles it, or
- it trades off two things the author has expressed a preference about.

**Reject** — fails verification, out of scope, style-only, or over-engineering. One line and a
reason in the receipt. Never escalate a rejected finding.

Anything not meeting a Choice criterion is yours to decide. Escalating trivia is a failure of
this step, not caution.

## Step 5 — One batched choice

If there are Choices, present them in a **single** `AskUserQuestion` call — never a sequence.
Recommended option first, labelled as such, with the trade-off in each option's description.

More than four genuine Choices means the spec is not ready. Say so, recommend which sections
need rework, and stop rather than running a four-round interrogation.

If there are no Choices, skip this step silently and continue.

## Step 6 — Apply, commit, receipt

Amend the spec with the applied findings and the resolved Choices. Commit it — the spec is
already under version control from brainstorming, and the amendment belongs in the same
history.

Then a short receipt:

- Reviewers: N, lenses used.
- Applied: one line each, what changed.
- Rejected: one line each, why.
- Decided for you: one line each, the call and why it was not worth your time.
- Verdicts: each reviewer's verdict.

State only what is verifiable. **Do not claim the panel ran on a different model** — the
harness can silently substitute one, and a receipt asserting independence it cannot confirm is
worse than no receipt.

## Step 7 — Hand over to writing-plans

The spec→plan boundary is a phase seam and a natural context reset. Invoke the `handover`
skill so a fresh session can pick up at writing-plans, then stop. Do not invoke writing-plans
in this session, and do not ask whether to hand over.

## When NOT to run

- The spec was already reviewed and has not changed since.
- There is no written spec — a bounded in-chat design does not need a panel.
- The author said "no review" or "skip review".
- The change is a trivial spec edit (typo, renamed heading, clarified sentence).
