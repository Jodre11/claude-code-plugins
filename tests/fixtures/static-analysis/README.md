# Static-analysis behavioural smoke-test fixtures

Synthetic fixture tree consumed by `tests/lib/test_static_analysis_behavioural.sh`.

Each subdirectory contains a single deterministic violation that the corresponding tool
is guaranteed to flag:

- `eslint/bad.js` — `no-unused-vars` (with flat-config `eslint.config.js`; ESLint 9+ required)
- `ruff/bad.py` — `F401` unused import (Ruff)
- `ruff/notebook.ipynb` — same `F401` violation in a notebook cell
- `trivy/Dockerfile` — `:latest` tag (Trivy `AVD-DS-0001`, MEDIUM)

The fixtures intentionally trip the simplest possible rule for each tool — adding more
violations dilutes the assertion that the specialist surfaces canonical wording.

## Setup before running the smoke test

ESLint runs from the fixture's local `node_modules`. Before the first run, install
dependencies:

```
npm install --prefix tests/fixtures/static-analysis/eslint
```

Ruff and Trivy must be on PATH (`brew install ruff trivy` on macOS). InspectCode
requires the `jb` global tool (`dotnet tool install --global JetBrains.ReSharper.GlobalTools`).
