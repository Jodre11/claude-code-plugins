## ESLint Findings

### Finding — `var` used instead of `let`/`const`
- **File:** bad.js:1
- **Confidence:** 100
- **Severity:** Important
- **Rule:** no-var (eslint)
- **Description:** Unexpected var, use let or const instead.
- **Suggested fix:** Replace `var legacy` with `const legacy` on line 1 (or `let` if reassignment is needed — but given `legacy` is only read, `const` is the safer choice).

### Finding — `let` never reassigned
- **File:** bad.js:2
- **Confidence:** 100
- **Severity:** Important
- **Rule:** prefer-const (eslint)
- **Description:** 'neverReassigned' is never reassigned. Use 'const' instead.
- **Suggested fix:** Change `let neverReassigned = 2;` to `const neverReassigned = 2;` on line 2.

### Finding — unused variable
- **File:** bad.js:3
- **Confidence:** 100
- **Severity:** Important
- **Rule:** no-unused-vars (eslint)
- **Description:** 'unused' is assigned a value but never used.
- **Suggested fix:** Remove the `const unused = 42;` declaration on line 3, or reference it where intended.

### Finding — loose equality
- **File:** bad.js:6
- **Confidence:** 100
- **Severity:** Important
- **Rule:** eqeqeq (eslint)
- **Description:** Expected '===' and instead saw '=='.
- **Suggested fix:** Replace `a == b` with `a === b` on line 6 to use strict equality.
