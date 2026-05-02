---
name: pre-review
description: Analyse local changes before creating a PR
argument-hint: "[base-branch]"
---

Before analysing, run `git fetch` and check whether the current branch is behind its remote tracking branch. If local is behind remote, warn me and ask whether to proceed — reviewing stale code may be wasted effort.

Follow the shared review pipeline instructions in `includes/review-pipeline.md`.
