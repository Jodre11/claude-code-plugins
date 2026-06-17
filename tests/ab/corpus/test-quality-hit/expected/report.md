## Test Quality Review Findings

### Finding — `test_rejects_invalid_email` asserts on the mock's own configured return
- **File:** tests/test_email_validation.py:13
- **Confidence:** 95
- **Severity:** Important
- **Description:** Smell: asserts-on-the-mock — the test mocks `email_validator.validate` to return `False`, then calls `validate("not-an-email")` and asserts the result is `False`. This asserts the mock's own configured return value — the test passes whether or not the real validation logic works. It is a false-green test that gives future agents false confidence the validation works.
- **Suggested fix:** Remove the mock and test the real `validate` function with an actual invalid email address, or mock only the external dependency (e.g. DNS lookup) and assert that the validator correctly identifies the structural invalidity.
