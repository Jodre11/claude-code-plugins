---
name: grill-with-docs
description: A relentless interview to sharpen a plan or design, which also creates docs (ADRs and glossary) as we go.
disable-model-invocation: true
---

# Grill With Docs

Run a relentless grilling interview to sharpen the plan or design, and capture the domain
language and decisions as you go using the `domain-modeling` skill (writing `CONTEXT.md`
glossary entries and ADRs the moment they crystallise).

## The interview

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing. Asking multiple questions at once is bewildering.

If a *fact* can be found by exploring the codebase, look it up rather than asking me. The *decisions*, though, are mine — put each one to me and wait for my answer.

Do not enact the plan until I confirm we have reached a shared understanding.

## Capturing docs as we go

While grilling, actively maintain the domain model using the `domain-modeling` skill:

- When a term is resolved or sharpened, update `CONTEXT.md` inline (see the `domain-modeling`
  skill's `CONTEXT-FORMAT.md`).
- When a decision meets the ADR bar — hard to reverse, surprising without context, the result
  of a real trade-off — offer to write an ADR (see `domain-modeling`'s `ADR-FORMAT.md`).
