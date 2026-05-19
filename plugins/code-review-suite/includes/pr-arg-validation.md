## PR Argument Validation

Validate that `$ARGUMENTS` matches `^[0-9]+$` (PR number) or `^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/pull/[0-9]+$` (PR URL). If neither matches, report the error and stop.
