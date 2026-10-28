# Spec Review Plugin

An adversarial review panel for a written spec, run after the design is committed and before its
implementation is planned. Independent reviewers who never saw the design conversation read the
committed spec, and the lead verifies their findings before anything changes.

An author's self-review is a same-agent, same-context pass that ends "fix inline and move on". The
only independent critic of a spec is then the human. This adds the missing pass, at the point where
design mistakes are cheapest to fix.

## Usage

The skill triggers once a spec is committed, and can be invoked explicitly:

    /review-spec
    /review-spec docs/specs/2026-09-07-my-feature-design.md

With no argument it takes the most recently modified file in `docs/specs/`, falling back to
`docs/superpowers/specs/`.

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
6. Stop, leaving implementation planning to a fresh session.

## Design notes

**Lenses are ordered by marginal value, not blast radius.** A spec can be wrong in three
non-overlapping ways: wrong problem, incomplete answer, over-built answer. `subtraction` comes
first because authors rarely cut their own design. `framing` comes last, and is the one to drop for
a two-lens panel, because the design dialogue has usually already interrogated it.

**The reviewer model is chosen at dispatch, never pinned in agent frontmatter.** An alias that
fails to resolve silently inherits the parent model, producing a review that only *looks*
independent. The rule is "not weaker than the authoring session, superior where available" — a
reviewer below the author's capability rubber-stamps.

**The receipt claims only what is verifiable.** It never asserts model independence, because the
skill cannot confirm which model actually ran. A receipt implying scrutiny that did not happen is
worse than no receipt.

**No hooks.** Both trigger paths live in the skill's `description`, so there is no per-prompt
context cost.
