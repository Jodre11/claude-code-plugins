## Phase 0.6: CI Status Gate

<!-- CANONICAL SOURCE — do not delete.
This file is the single source of truth for the CI-status gate. Its content is inlined
verbatim into both consumer files:
  - skills/review-gh-pr/SKILL.md
  - commands/pre-review.md

In mode `local` this section is a no-op (no PR exists). In mode `pr` it gates fan-out on
explicit reviewer acknowledgement when CI is failing.

MAINTENANCE: Edit this file first, then propagate to both consumers. The test suite verifies
the inlined copies match this canonical source. -->

### 0.6.1 Skip in local mode

If `$REVIEW_MODE` is `local`, skip this entire section and continue to Step 1.

### 0.6.2 Fetch CI status

Run:

```bash
gh pr checks "$ARGUMENTS" --json name,state,workflow,link --jq '.[]'
```

Store the parsed list as `$CI_CHECKS`. If the call fails (e.g. no CI configured), set
`$CI_CHECKS = []` and continue without gating.

### 0.6.3 Classify states

A check `c` is classified as:

- **failing-definitive** if `c.state` is one of `FAILURE`, `ERROR`, or `ACTION_REQUIRED`.
- **failing-transient** if `c.state` is `TIMED_OUT`. Transient failures often resolve with a
  rerun and do not necessarily indicate a code defect (e.g. slow self-hosted runners).
- **non-failing** if `c.state` is one of `SUCCESS`, `NEUTRAL`, `SKIPPED`, `PENDING`,
  `IN_PROGRESS`, `QUEUED`, or `CANCELLED`. `CANCELLED` is excluded from failing because
  multi-trigger workflows legitimately cancel one trigger when another takes over.

Compute counts: `$CI_DEF` = number of definitive failures, `$CI_TRA` = number of transient
failures.

### 0.6.4 Build $CI_STATUS for downstream

Build a structured status string for the synthesiser prompt:

```
$CI_STATUS = "CI status:
definitive_failures: <name1, name2 | none>
transient_failures: <name3 | none>
total_checks: <N>
"
```

If `$CI_DEF == 0 && $CI_TRA == 0`, set `$CI_STATUS = "CI status: all checks passing or in-flight"`.

### 0.6.5 Gate on failures

If `$CI_DEF + $CI_TRA == 0`: announce `> CI: all checks passing or in-flight` and continue
to Step 1.

Otherwise, present the failing-check summary to the user:

```
> CI status: $CI_DEF definitive failure(s), $CI_TRA transient failure(s).
> Definitive: <list of c.name for definitive failures>
> Transient: <list of c.name for transient failures>
>
> Definitive failures usually indicate a code defect. Transient failures (e.g. timeouts)
> often resolve with a rerun without code changes.
>
> Acknowledge and proceed with review? [y/N]
```

Read one line. If the answer begins with `y` or `Y`, announce
`> CI: acknowledged, proceeding with $CI_DEF definitive + $CI_TRA transient failure(s)` and
continue to Step 1. Otherwise halt cleanly with
`> Phase 0 halt: CI failures not acknowledged`.

The synthesiser later constrains the verdict based on `$CI_STATUS` (Task 8).
