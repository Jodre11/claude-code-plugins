## PR Argument Validation

Validate that `$ARGUMENTS` matches `^[0-9]+$` (PR number) or `^https://github\.com/.+/pull/[0-9]+$` (PR URL). If neither matches, report the error and stop.
