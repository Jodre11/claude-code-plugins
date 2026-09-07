# Spec Review Plugin

An adversarial review panel for a written spec, sitting between `superpowers:brainstorming` and
`superpowers:writing-plans`. Independent reviewers who never saw the design conversation read the
committed spec, and the lead verifies their findings before anything changes.

Both existing self-review steps — brainstorming's spec self-review and writing-plans' — are
same-agent, same-context passes that end "fix inline and move on". The only independent critic of a
spec in that flow is the human. This adds the missing pass, at the point where design mistakes are
cheapest to fix.

## Usage

The skill triggers automatically once brainstorming has committed a spec, and can be invoked
explicitly:

    /review-spec
    /review-spec docs/superpowers/specs/2026-09-07-my-feature-design.md

With no argument it takes the most recently modified file in `docs/superpowers/specs/`.

It runs unattended. You are consulted once, for genuine trade-offs only — batched into a single
question with options, trade-offs, and a recommendation. Everything verified and unambiguous is
applied without asking.

## Installation

    claude plugin install spec-review@jodre11-plugins

No prerequisites — no binaries, no hooks, no scripts.

## How It Works

1. Resolve the spec. No context file is built; the spec is already the self-contained artefact.
2. Dispatch reviewers in parallel, one lens each:

   | Lens | Asks |
   |---|---|
   | `subtraction` | What should be cut? Is there a simpler shape? |
   | `completeness` | What is missing, or readable two ways? |
   | `framing` | Right problem? Right shape? (the only lens that may `REJECT`) |

3. Verify every finding against the spec and the repo. Reviewer output is treated as *intern
   findings* — plausible, must be checked, sometimes wrong.
4. Classify each into **apply**, **choice**, or **reject**. Escalating trivia is a failure of this
   step, not caution.
5. Apply, commit the amended spec, and emit a receipt of what changed, what was rejected, and what
   was decided on your behalf.
6. Hand over to `writing-plans` via the `handover` skill.

## Design notes

**Lenses are ordered by marginal value, not blast radius.** A spec can be wrong in three
non-overlapping ways: wrong problem, incomplete answer, over-built answer. `subtraction` comes
first because brainstorming instructs itself to apply YAGNI ruthlessly but only ever self-checks
it. `framing` comes last, and is the one to drop for a two-lens panel, because the brainstorming
dialogue has usually already interrogated it.

**The reviewer model is chosen at dispatch, never pinned in agent frontmatter.** An alias that
fails to resolve silently inherits the parent model, producing a review that only *looks*
independent. The rule is "not weaker than the authoring session, superior where available" — a
reviewer below the author's capability rubber-stamps.

**The receipt claims only what is verifiable.** It never asserts model independence, because the
skill cannot confirm which model actually ran. A receipt implying scrutiny that did not happen is
worse than no receipt.

**No hooks.** Both trigger paths live in the skill's `description`, so there is no per-prompt
context cost.
