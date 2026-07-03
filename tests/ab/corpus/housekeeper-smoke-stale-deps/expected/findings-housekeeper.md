## Housekeeper Findings

### Finding — ubuntu runner behind latest GA
- **File:** .github/workflows/ci.yml:5
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/runner
- **Description:** ubuntu-22.04 is at ubuntu-22.04; latest GA is ubuntu-24.04.
- **Suggested fix:** Upgrade ubuntu to ubuntu-24.04.

### Finding — actions/checkout behind latest GA
- **File:** .github/workflows/ci.yml:7
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/github-actions
- **Description:** actions/checkout is at v3; latest GA is v6.0.3.
- **Suggested fix:** Upgrade actions/checkout to v6.

### Finding — react behind latest GA
- **File:** package.json:4
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/npm
- **Description:** react is at 18.2.0; latest GA is 19.2.7.
- **Suggested fix:** Upgrade react to 19.2.7.
