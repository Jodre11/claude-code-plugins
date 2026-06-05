## Version Freshness Cookbook

Reference for the `version-freshness` Focus Area. List of registries and the canonical
endpoint for "latest stable" per ecosystem. Use these when verifying that newly introduced
or modified dependency / GitHub Action versions are current.

A live web fetch is required — cached or trained-knowledge answers do not count. Re-fetch
each time the reviewer runs.

When verifying multiple dependencies in a single review, issue registry fetches in parallel.
Cap at 10 concurrent fetches to avoid registry rate-limits.

| Ecosystem        | Manifest                              | Endpoint pattern                                                                |
|------------------|---------------------------------------|---------------------------------------------------------------------------------|
| npm              | `package.json`, `package-lock.json`   | `https://registry.npmjs.org/<package>` (read `dist-tags.latest`)                |
| NuGet            | `*.csproj`, `packages.lock.json`      | `https://api.nuget.org/v3-flatcontainer/<package-lower>/index.json`             |
| PyPI             | `pyproject.toml`, `requirements*.txt` | `https://pypi.org/pypi/<package>/json` (read `info.version`)                    |
| RubyGems         | `Gemfile.lock`                        | `https://rubygems.org/api/v1/gems/<gem>.json` (read `version`)                  |
| crates.io        | `Cargo.lock`                          | `https://crates.io/api/v1/crates/<crate>` (read `crate.max_stable_version`)     |
| Go modules       | `go.mod`, `go.sum`                    | `https://proxy.golang.org/<module>/@latest`                                     |
| GitHub Actions   | `.github/workflows/*.yml`             | `https://api.github.com/repos/<owner>/<action>/releases/latest` (read `tag_name`) |

### Runner labels (no live registry)

GitHub-hosted runner images have no registry endpoint. The housekeeper engine
ships a manually-maintained latest-label table (`LATEST_RUNNERS` in
`bin/housekeeper-freshness`). Keep this table in sync with that constant.
Reviewed 2026-06-05.

| Family   | Latest GA label |
|----------|-----------------|
| ubuntu   | `ubuntu-24.04`  |
| windows  | `windows-2025`  |
| macos    | `macos-15`      |

Unknown families (self-hosted, custom) and `-latest` floating labels are never
flagged — there is no trustworthy "latest GA" answer for them.

### GitHub Actions latest-major

A `uses: org/action@vN` pin floats minor/patch within major `N`. The housekeeper
reads the latest release `tag_name` (the existing GitHub Actions row above) and
flags only when the latest GA major exceeds `N`; the suggested target is the
latest major tag (`vM`). SHA pins (`@<sha>  # vX.Y.Z`) read the current version
from the trailing comment; a SHA pin without a version comment is never flagged.

### What counts as "stated justification"

A justification must explain *why* this older version is required — not merely state which
version was chosen. Acceptable forms:

- Inline comment near the dependency line (e.g. `# pinned to 1.4.x — 2.x drops the ABC API`).
- Commit message body referencing the constraint.
- A clearly-marked section of the PR body or in-diff doc (e.g. under
  `## Pinned versions` or `## Compatibility`).

A bare commit subject "Update dependency" or a comment "use 1.4.x" without a reason does NOT
count.

### Severity

A stale version always produces a Suggestion finding. Justification changes the framing,
not the severity:

- No justification → "Consider upgrading to the latest stable version, or document the
  constraint that requires this version."
- Clear justification → "Noted: <quoted reason>; no action required."

When a stale version *also* has a known security vulnerability, the **version-safety**
Focus Area raises it at Important or Critical via the security path. Freshness alone never
escalates above Suggestion.
