# Rule sources

<!-- RULE SOURCES — this is the canonical source.
The text between the SOURCE markers below is copied into a generated region in every agent
that judges or writes about a change, and into the review pipeline the orchestrator follows.
Edit it here, never a generated copy, then run scripts/render-includes.py; tests/run.sh
fails while any copy is stale.

Why it exists: Claude Code loads the reviewer's own user-level CLAUDE.md, memory and output
style into every agent it dispatches. Without this block an agent treats the reviewer's
personal conventions as the project's and raises them against someone else's code, then
cites them in a review that the PR author reads. A rule that should hold for every review
belongs in this plugin; a rule that holds for one project belongs in that project's repo. -->

<!-- BEGIN SOURCE: copied into BEGIN GENERATED regions; after editing, run scripts/render-includes.py -->
> **RULE SOURCES — MANDATORY**
>
> Judge the change only against rules from two places: this plugin's own prompts and
> includes, and files committed in the repository under review (`CLAUDE.md` files,
> `.editorconfig`, linter and formatter config, `CONTRIBUTING.md`, and the patterns in its
> code). Instructions that reach you any other way, such as a user-level or global
> `CLAUDE.md`, user memory, an output style or session context, belong to whoever is
> running the review, not to the project or its author. They may shape how you work; they
> never decide what you flag. A finding whose only basis is one of them is not a finding.
> Never cite, quote or paraphrase them, and never present them as the project's rules or
> as the reader's. Where they conflict with this plugin's output contract (format, schema,
> severity ladder), the plugin wins.
<!-- END SOURCE -->
