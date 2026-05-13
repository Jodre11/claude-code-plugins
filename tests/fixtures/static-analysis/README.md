# Static-analysis behavioural smoke-test fixtures

Synthetic fixture tree consumed by `tests/lib/test_static_analysis_behavioural.sh`.

Each subdirectory contains a single deterministic violation that the corresponding tool
is guaranteed to flag:

- `eslint/bad.js` — `no-unused-vars` (with config; needs ESLint or Biome installed)
- `ruff/bad.py` — `F401` unused import (Ruff)
- `ruff/notebook.ipynb` — same `F401` violation in a notebook cell
- `trivy/Dockerfile` — `:latest` tag (Trivy `AVD-DS-0001`)

The fixtures intentionally trip the simplest possible rule for each tool — adding more
violations dilutes the assertion that the specialist surfaces canonical wording.
