## Housekeeper Findings

### Finding — requests behind latest GA
- **File:** pkg/app/pyproject.toml:5
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/pypi
- **Description:** requests is at 2.20.0; latest GA is 2.31.0.
- **Suggested fix:** Upgrade requests to 2.31.0.

### Finding — urllib3 marked yanked
- **File:** pkg/app/pyproject.toml:6
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/pypi
- **Description:** urllib3 is at 2.0.0; latest GA is 2.2.1. Marked yanked in the registry: Truncated response bodies when streaming a large compressed body.
- **Suggested fix:** Upgrade urllib3 to 2.2.1.
