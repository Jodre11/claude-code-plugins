# Adoption Glance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a manually-run maintenance script that prints a one-screen GitHub-traffic adoption pulse for the plugin marketplace repo.

**Architecture:** A single Bash script at `scripts/adoption-glance.sh` wraps `gh api` calls to three GitHub endpoints (clones, views, repo core), extracts fields with `jq`, and prints a plain-text summary with an anonymity/upper-bound caveat. No storage, no scheduling, no history. A lightweight structural check (executable bit + `bash -n`) is bolted onto the existing shell test suite.

**Tech Stack:** Bash, `gh` CLI (authenticated owner token), `jq`.

## Global Constraints

- Shell scripts use **4-space indentation**, **LF line endings**, and must be **`chmod +x`** (CLAUDE.md / `.editorconfig` / `.gitattributes`).
- Shebang: `#!/usr/bin/env bash`.
- Target repo is `Jodre11/claude-code-plugins` (the marketplace repo).
- Traffic endpoints are **owner-only** — a missing/underscoped token returns HTTP 403; surface a clear message, not a raw API error.
- Fail fast with an install hint if `gh` or `jq` is missing.
- `clones/person = total ÷ unique`, guarded against divide-by-zero (print `n/a` when unique cloners is 0).
- Output is plain text to stdout; the summary carries the caveat: anonymous; includes your own machines + CI; 14-day rolling; upper bound.
- Home is repo-level `scripts/` (a maintenance tool, not a shipped plugin feature). The `scripts/` directory does not exist yet and must be created.
- Output mode is text-only. No `--json` flag (explicit YAGNI).

---

### Task 1: The adoption-glance script

**Files:**
- Create: `scripts/adoption-glance.sh`

**Interfaces:**
- Consumes: nothing (entry point).
- Produces: an executable script invoked as `scripts/adoption-glance.sh` with no arguments; exits `0` on success, non-zero on a missing-dependency or API failure.

**Behaviour contract:**
- Set strict mode: `set -euo pipefail`.
- A `REPO` variable set to `Jodre11/claude-code-plugins`.
- Preflight: verify `gh` and `jq` are on `PATH`; if either is missing, print `error: <tool> is required (install: <hint>)` to stderr and exit `1`.
- Fetch three endpoints via `gh api`, capturing each into a variable:
  - `repos/$REPO/traffic/clones`
  - `repos/$REPO/traffic/views`
  - `repos/$REPO`
- If a `gh api` call fails, detect a 403 and print a clear owner-token message; otherwise surface the failure and exit non-zero.
- Extract with `jq -r`: clones `.count`/`.uniques`, views `.count`/`.uniques`, repo `.stargazers_count`/`.forks_count`/`.subscribers_count`.
- Compute `clones/person`: if unique cloners is `0`, use `n/a`; else `total ÷ unique` to one decimal place.
- Print the summary block to stdout (format below).

- [ ] **Step 1: Create `scripts/` and write the script**

Create `scripts/adoption-glance.sh` with exactly this content:

```bash
#!/usr/bin/env bash
#
# adoption-glance.sh — one-screen GitHub-traffic adoption pulse for the
# plugin marketplace repo. Manually run; no storage, no scheduling, no history.
# Traffic endpoints are owner-only and report a 14-day rolling window.

set -euo pipefail

REPO="Jodre11/claude-code-plugins"

for tool in gh jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        case "$tool" in
            gh) hint="https://cli.github.com" ;;
            jq) hint="brew install jq" ;;
        esac
        printf 'error: %s is required (install: %s)\n' "$tool" "$hint" >&2
        exit 1
    fi
done

fetch() {
    # fetch <api-path> — echo JSON on success; on failure print a clear
    # message (403 => owner-token scope) and exit non-zero.
    local path="$1" out
    if ! out="$(gh api "$path" 2>&1)"; then
        if printf '%s' "$out" | grep -q "HTTP 403"; then
            printf 'error: %s returned 403 — traffic endpoints are owner-only; run `gh auth status` and ensure you are authenticated as the repo owner.\n' "$path" >&2
        else
            printf 'error: failed to fetch %s:\n%s\n' "$path" "$out" >&2
        fi
        exit 1
    fi
    printf '%s' "$out"
}

clones_json="$(fetch "repos/$REPO/traffic/clones")"
views_json="$(fetch "repos/$REPO/traffic/views")"
repo_json="$(fetch "repos/$REPO")"

clone_total="$(printf '%s' "$clones_json" | jq -r '.count')"
clone_unique="$(printf '%s' "$clones_json" | jq -r '.uniques')"
view_unique="$(printf '%s' "$views_json" | jq -r '.uniques')"
stars="$(printf '%s' "$repo_json" | jq -r '.stargazers_count')"
forks="$(printf '%s' "$repo_json" | jq -r '.forks_count')"

if [ "$clone_unique" -eq 0 ]; then
    per_person="n/a"
else
    per_person="$(printf '%s %s' "$clone_total" "$clone_unique" \
        | awk '{ printf "%.1f", $1 / $2 }')"
fi

printf '%s — adoption glance (14-day window)\n' "${REPO##*/}"
printf '  Unique cloners : %-10s ~how many different people\n' "$clone_unique"
printf '  Total clones   : %-10s pull volume\n' "$clone_total"
printf '  Clones/person  : %-10s ~how often each re-pulls (autoUpdate-driven)\n' "$per_person"
printf '  Unique viewers : %s\n' "$view_unique"
printf '  Stars / Forks  : %s / %s\n' "$stars" "$forks"
printf 'Caveat: anonymous; includes your own machines + CI; 14-day rolling; upper bound.\n'
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/adoption-glance.sh`

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/adoption-glance.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Verify strict-mode/logic with a stubbed run (no live API)**

Run (stubs `gh` and `jq` on PATH so no network/auth is needed):

```bash
tmp="$(mktemp -d)"
cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *traffic/clones*) echo '{"count":416,"uniques":128}' ;;
    *traffic/views*)  echo '{"count":4,"uniques":3}' ;;
    *)                echo '{"stargazers_count":0,"forks_count":0,"subscribers_count":0}' ;;
esac
STUB
chmod +x "$tmp/gh"
PATH="$tmp:$PATH" scripts/adoption-glance.sh
rm -rf "$tmp"
```

Expected: the summary block prints with `Unique cloners : 128`, `Total clones : 416`, `Clones/person : 3.2` (416 ÷ 128 = 3.25; awk rounds half-to-even → 3.2), `Unique viewers : 3`, `Stars / Forks : 0 / 0`, and the caveat line.

- [ ] **Step 5: Verify divide-by-zero guard**

Run (stub returns 0 unique cloners):

```bash
tmp="$(mktemp -d)"
cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *traffic/clones*) echo '{"count":0,"uniques":0}' ;;
    *traffic/views*)  echo '{"count":0,"uniques":0}' ;;
    *)                echo '{"stargazers_count":0,"forks_count":0,"subscribers_count":0}' ;;
esac
STUB
chmod +x "$tmp/gh"
PATH="$tmp:$PATH" scripts/adoption-glance.sh
rm -rf "$tmp"
```

Expected: `Clones/person  : n/a` — no divide-by-zero error, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/adoption-glance.sh
git commit -m "feat: add adoption-glance maintenance script"
```

---

### Task 2: README "Internal tooling" entry

**Files:**
- Modify: `README.md` (the `## Internal tooling` list, currently at lines 64–75)

**Interfaces:**
- Consumes: the script from Task 1 (its path and purpose).
- Produces: nothing downstream.

- [ ] **Step 1: Add a bullet to the Internal tooling list**

In `README.md`, under `## Internal tooling`, add this bullet to the existing list (after the `review-worktree` bullet):

```markdown
- [`scripts/adoption-glance.sh`](scripts/adoption-glance.sh) — manually-run
  GitHub-traffic adoption pulse for the marketplace repo (unique cloners, total
  clones, clones/person, viewers, stars/forks). Owner-only endpoints; requires
  an authenticated `gh` owner token and `jq`. Point-in-time glance over a 14-day
  rolling window — no storage or history.
```

- [ ] **Step 2: Add the dependency row to the Prerequisites table**

In `README.md`, under `## Prerequisites`, add this row to the table:

```markdown
| adoption-glance (script) | `gh` (authenticated as repo owner), `jq` (`brew install jq`) |
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document adoption-glance script in README"
```

---

### Task 3: Structural test for the script

**Files:**
- Modify: `tests/run.sh` (or the appropriate conventions test file — locate the executable-bit / `bash -n` checks first)

**Interfaces:**
- Consumes: the script from Task 1.
- Produces: nothing downstream.

**Note for the implementer:** Inspect `tests/run.sh` (and any files it sources) to find how existing shell files are checked for the executable bit and LF endings, and how a `bash -n` syntax assertion is expressed. Follow that existing pattern exactly rather than inventing a new harness. If the suite already globs `scripts/**` or all `*.sh` for these checks, the new script is covered automatically and this task reduces to confirming coverage (run the suite, see the script exercised) — in that case, skip adding a bespoke assertion and note it in the commit.

- [ ] **Step 1: Locate the existing convention checks**

Run: `grep -n -E "bash -n|chmod|executable|\.sh" tests/run.sh`
Read the surrounding lines to learn the established assertion pattern and whether `scripts/` is already in scope.

- [ ] **Step 2: Ensure the script is covered**

If existing globs already cover `scripts/*.sh`, confirm by running the suite (next step) and verifying the script appears in the checked set — no code change needed.

If not covered, add an assertion following the file's existing pattern that:
- asserts `scripts/adoption-glance.sh` is executable, and
- asserts `bash -n scripts/adoption-glance.sh` passes.

- [ ] **Step 3: Run the test suite**

Run: `tests/run.sh`
Expected: all tests pass, including coverage of `scripts/adoption-glance.sh`.

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh
git commit -m "test: cover adoption-glance script in structural suite"
```
