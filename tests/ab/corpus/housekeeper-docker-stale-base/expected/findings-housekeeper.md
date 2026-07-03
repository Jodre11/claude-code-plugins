## Housekeeper Findings

### Finding — node behind latest GA
- **File:** src/Api/Dockerfile:1
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/docker
- **Description:** node is at 18.20.0; latest GA is 22.3.0.
- **Suggested fix:** Upgrade node to 18.20.4.
