# Matt Pocock Skills (vendored subset)

A curated, vendored subset of [Matt Pocock's `skills` repo](https://github.com/mattpocock/skills)
("Skills for Real Engineers"). Upstream does not ship a `marketplace.json`, so rather than
reference the whole repo (20 skills) this plugin vendors only the skills that are additive and
non-conflicting with this stack — deliberately skipping the ones that overlap the `superpowers`
process skills, `code-review-suite`, `deep-research`, and the `/handover` workflow.

## Skills

| Skill                  | Invocation                                 | Purpose                                                                          |
|------------------------|--------------------------------------------|----------------------------------------------------------------------------------|
| `writing-great-skills` | user-invoked (`disable-model-invocation`)  | Reference vocabulary and principles for writing, editing, and critiquing skills. |
| `codebase-design`      | model-invoked (narrow trigger)             | Deep-module / seam / adapter vocabulary (Ousterhout + Feathers) for interface design. |
| `domain-modeling`      | model-invoked (narrow trigger)             | DDD ubiquitous-language (`CONTEXT.md`) and ADR maintenance.                       |
| `grill-with-docs`      | user-invoked (`disable-model-invocation`)  | Relentless design interview that captures glossary + ADRs as it goes.            |
| `teach`                | user-invoked (`disable-model-invocation`)  | Stateful, multi-session teaching workspace for learning a topic.                 |

User-invoked skills (`disable-model-invocation: true`) add zero context load and never auto-fire;
invoke them by name. The two model-invoked skills use narrow, specific triggers so they don't
compete with the process skills in this stack.

## Divergence from upstream

- **`grill-with-docs`** — upstream is a two-line alias that delegates to the model-invoked
  `grilling` skill. To avoid pulling in `grilling` (which would add permanent context load and
  compete with `superpowers:brainstorming`), the interview instructions from `grilling` are
  **inlined** here, and the skill remains fully self-contained and user-invoked. It still uses
  the sibling `domain-modeling` skill for `CONTEXT.md` and ADR capture.

## Installation

    claude plugins install mattpocock-skills@jodre11-plugins

## Provenance

Vendored from `mattpocock/skills` (MIT). See `LICENSE` for the upstream copyright.

- Upstream: https://github.com/mattpocock/skills
- Vendored at commit: `16a2a5cd00b4416f673f4ff38c7971a04dd708e7`
- Vendored on: 2026-07-07

To resync, diff the upstream skill folders against these copies and update the files plus the
commit SHA above. Upstream moves fast, so this is a manual step by design. Remember the
`grill-with-docs` divergence noted above when resyncing.
