# Handover — execute the housekeeper PyPI slice (subagent-driven)

**Date:** 2026-06-12
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (the personal plugin
marketplace — independently versioned, its own CI/CLAUDE.md/test suite; push to
its own `origin`, NOT the `claude-settings` repo).
**Branch:** `main` (house rule: direct-push to `main`, push immediately after
each commit).

---

## 1. What this is

The housekeeper PyPI slice is **fully designed and planned**. Brainstorm → spec →
plan is DONE and committed. Your job is to **execute the plan**, task by task,
via **`superpowers:subagent-driven-development`** (the user's chosen execution
mode for this programme — fresh implementer subagent per task + two-stage review:
spec-compliance, then code-quality).

This is the sixth vertical slice on the `housekeeper-freshness` chassis
(Actions/runner → npm → NuGet → Docker → **PyPI**). After PyPI comes Go modules
(do NOT start it — its own brainstorm/spec/plan cycle later).

**Do NOT re-brainstorm or re-plan.** The design decisions are settled (§4 below).
Start by reading the two artifacts, then drive `subagent-driven-development`.

---

## 2. First action (mandatory)

1. Read the **plan** — it is the execution script (15 tasks, each with exact file
   paths, full test code, full implementation code, exact commands + expected
   output): `docs/superpowers/plans/2026-06-12-housekeeper-pypi-slice.md`
2. Read the **spec** for the "why" behind any task:
   `docs/superpowers/specs/2026-06-12-housekeeper-pypi-slice-design.md`
3. Skim the chassis so the engine shape is in context:
   - Engine: `plugins/code-review-suite/bin/housekeeper-freshness` (~1110 lines,
     5 source classes — PyPI is the 6th).
   - Agent: `plugins/code-review-suite/agents/housekeeper-reviewer.md`.
   - Tests: `tests/python/test_housekeeper_engine.py` (plain `unittest`).
   - The most recent precedent (Docker slice 3) spec + result note, if you want a
     worked analogue: `docs/superpowers/specs/2026-06-11-housekeeper-docker-slice-design.md`,
     `docs/superpowers/notes/2026-06-12-housekeeper-docker-haiku-low-result.md`.
4. Invoke **`superpowers:subagent-driven-development`** and execute Tasks 1–13 as
   subagent dispatches with the two-stage review between each. Tasks 14–15 are
   the verification + manual sweep (see §5 — Task 15 is NOT subagent-runnable).

---

## 3. Execution shape (subagent-driven)

- **One subagent per plan task** (Tasks 1–13). Each task is self-contained TDD:
  write failing test → run (fail) → implement → run (pass) → commit + push.
- **Two-stage review per task before moving on:** (1) spec-compliance — does the
  change match the plan/spec? (2) code-quality. Both can be subagent dispatches
  or inline, your call — but do not skip the gate.
- **Subagent dispatch rules (house):** set `mode: "auto"` and a kebab-case `name`
  on every Agent dispatch (so a plan-mode parent does not stall the subagent).
  Pass the resolved `$CLAUDE_TEMP_DIR` LITERAL (`/tmp/claude-<session-id>`) into
  each subagent prompt — it is injected into your context by a SessionStart hook
  but is NOT exported into the Bash shell env.
- **Each task ends with a commit + immediate push to `main`** (the plan spells
  out the exact commit messages). Do NOT batch commits across tasks — the
  marketplace `autoUpdate` has wiped unpushed work in this dir before
  (memory `project_marketplace_autoupdate_wiped_branch`). Push after every task.
- The plan's per-task commands assume **`unittest`, not pytest** (pytest is NOT
  installed): `python3 -m unittest tests.python.test_housekeeper_engine.<Class> -v`.

---

## 4. Decisions ALREADY settled (do NOT re-litigate)

All resolved in the brainstorm; the spec is the source of truth. Carry them:

- **Manifests:** `pyproject.toml` (PEP 621 `[project]` tables + Poetry legacy
  `[tool.poetry...]` tables) + `requirements*.txt`. `setup.cfg`/`setup.py`/
  `Pipfile` are OUT (setup.py permanently — arbitrary code).
- **Trust gate:** act on the FLOOR of single-anchor forms (`==`, `===`, `~=`,
  `>=`, Poetry `^`/`~`, bare). Skip wildcards, comma/upper-bounded ranges, `!=`,
  bare `<`/`>`/`<=`, URL/VCS/path. Strip extras + markers first. Mirrors the
  20/20-validated npm behaviour.
- **PEP 440 version core:** a NEW `pypi_*` parse/compare/is_ga set —
  prereleases-without-hyphen (`1.2.3rc1`), post-releases, epochs, local versions.
  The existing semver-ish `parse_version`/`is_ga` are LEFT UNTOUCHED (hash
  stability for the other 5 sources). This is the biggest engine task (Task 1).
- **TOML:** stdlib `tomllib`, **hard-require 3.11+**. The agent emits
  `Skipped — python3 ≥3.11 required (PyPI TOML parsing).` on older interpreters.
  Rationale: the reviewer's/CI's interpreter, not the reviewed project's; a
  sub-3.11 review environment is itself a thing to update. No hand-rolled TOML.
- **Registry:** PyPI JSON API (`https://pypi.org/pypi/<project>/json`), no auth
  (simpler than Docker). Fixture override `pypi/<slug>.json`, slug = PEP 503
  normalised name. Compute GA explicitly from `releases.keys()`, never trust
  `info.version`.
- **`yanked` → health rider** (PEP 592): the PyPI analogue of npm `deprecated` /
  NuGet `unlisted`. Yanked-current → `health = {"state": "yanked", "detail": …}`;
  yanked releases excluded from the upgrade target. Emit rule: stale OR
  health-flagged.
- **Licence DEFERRED** — `licence_current`/`licence_latest` are null this slice
  (like Docker). PyPI licence data is messy (free-text/classifier/SPDX); a proper
  cross-source licence-diff is a focused follow-on, not bolted onto PyPI.
- **Scope:** `_PYPI_SCOPE_SUFFIXES = (".py", ".pyi")`. A changed `.py`/`.pyi`
  walks up to nearest-ancestor `pyproject.toml`; directly-changed manifest always
  in scope; source with no pyproject ancestor falls back to nearest-ancestor
  `requirements*.txt`.
- **T3 (uniform):** touched manifest line → latest GA; untouched (Anchor
  pull-in) → nearest in-major. Severity uniform `Suggestion`, confidence `100`.
- **Diff is selector, not filter** (memory
  `feedback_housekeeper_diff_is_selector_not_filter`): a changed source file
  selects WHICH unit to audit; never restricts findings to changed lines.
- **A/B is single-arm** haiku/low 20/20 recorded-fixture sweep. Chassis
  equivalence is closed (slices 1–3 all EQUIVALENT 20/20); the sweep guards
  apparatus determinism (empty-stdout, format drift, temp-dir self-abort, install
  race), not the model tier. A clean EQUIVALENT VALIDATES the already-shipped
  `model: haiku` + `effort: low` tier — **no production flip needed**. Sonnet is
  the documented fallback only if a tail appears.
- **Repo housekeeping (standing rule):** already checked during brainstorm —
  runners on `ubuntu-24.04`, Actions SHA-pinned-with-comment (the GOOD state), no
  IaC, no Python package of its own. Nothing to bump; no separate housekeeping PR.

---

## 5. The two non-subagent tasks (Tasks 14–15)

- **Task 14 (verification)** can be subagent or inline: full `unittest` suite,
  `bash tests/run.sh` green, clean/pushed tree, and a LIVE spot-check that the
  corpus packages are genuinely behind/yanked on real pypi.org.
- **Task 15 (the A/B sweep) is MANUAL, INTERACTIVE — it CANNOT be subagent-run.**
  Same as every prior slice:
  - **Cache refresh first:** `/plugins update` (refreshes DISK from GitHub) THEN
    `/reload-plugins` (reloads the in-memory registry from disk). The sweep
    exercises the engine BINARY — a stale cache captures the pre-PyPI engine and
    the sweep is meaningless (memories `project_plugin_cache_staleness`,
    `feedback_plugins_update_after_push`).
  - **Confirm the corpus is in `tests/ab/corpus/index.yaml`** before launching
    (the harness gates `fixture_load` on the index; Task 13 adds the row).
  - **Drive the sweep** (`run_in_background: true`):
    ```
    tests/ab/run.sh --config tests/ab/configs/per-agent/housekeeper-pypi-haiku-low.yaml \
      --trials 20 --corpus housekeeper-pypi-stale-deps \
      --faithfulness-check --stream-json
    ```
    Pass = exit 0 + "faithfulness check PASSED (20/20)" + all 20 `summary.csv`
    rows share one `findings_hash`, no skips/inconclusive/timeouts. If a tail
    appears, STOP and report — sonnet is the fallback.
  - **Live-honesty:** the harness scrubs subprocess env, so the engine hits real
    pypi.org during the sweep, not the fixture. The corpus uses real packages
    (`requests==2.20.0` stale; `urllib3==2.0.6` yanked for CVE-2023-45803) — but
    the RECORDED FIXTURE is the oracle, so the sweep is deterministic regardless
    of live drift. Re-verify the live spot-check (Task 14) before sweeping; if a
    pin is no longer behind/yanked, update the corpus + expected files in lockstep.
  - **Record the result** to
    `docs/superpowers/notes/2026-06-12-housekeeper-pypi-haiku-low-result.md`
    (mirror the slice-3 note) and update memory (§7). Commit + push.

---

## 6. House rules (this repo)

- Direct-push to `main`; push immediately after each commit. No Co-Authored-By /
  advertising trailers.
- **Bash hook rules (strict):** one command per Bash call — no `&&`/`||`/`;`, no
  `$(...)`/backticks, no subshells, no heredocs in Bash. Carve-out: the
  `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC IS permitted for multi-line
  commit bodies. For multi-line Python, Write a file under `$CLAUDE_TEMP_DIR` and
  run it — do NOT pipe a heredoc to `python3` (the plan has one `<<<` example
  flagged with its hook-safe rewrite — use the rewrite).
- `$CLAUDE_TEMP_DIR` is the literal `/tmp/claude-<session-id>` — use the literal
  path string in Bash redirects, and pass it into subagent prompts.
- **`pytest` is NOT installed** — `python3 -m unittest …` (the plan's commands
  already use unittest; if any subagent reaches for pytest, correct it).
- **Known test artifact:** `A/B run.sh: bad-config rejection leaves working tree
  clean` false-fails on a DIRTY tree. Commit first, then re-run `bash tests/run.sh`
  to confirm green (expect the documented pre-existing skip).
- **Subagent Write-guard false-positive (seen in slice 3):** the Write tool may
  refuse to create `expected/findings-housekeeper.md` (matches a "subagent report
  file" heuristic on `findings`/`.md`). It is a legitimate corpus data fixture.
  Workaround: Write-to-`$CLAUDE_TEMP_DIR`-then-`cp`. (Task 13 Step 5 flags this.)
- Plugin-authoring frontmatter conventions (repo CLAUDE.md): command/skill files
  need `name` + `description` frontmatter and a blank line after the closing `---`.

---

## 7. Memory to update after the slice lands (in the `~/.claude` repo, separately)

- Add **slice-4 memory** `project_housekeeper_specialist_slice4.md` mirroring
  slice1/2/3: what shipped (PyPI source class, PEP 440 core, tomllib 3.11+ gate,
  pyproject+requirements parsers, yanked health rider, scope), the single-arm A/B
  verdict + cost note, execution learnings. Link
  `[[housekeeper-specialist-slice3]]`,
  `[[feedback_housekeeper_diff_is_selector_not_filter]]`.
- Update `MEMORY.md` index with the one-line pointer.
- Commit + push in the `~/.claude` repo (`claude-settings`) — a SEPARATE git repo
  with its own origin. The memory dir is exempt from org/identity scrubbing
  (private repo; public seed ships no memory). Secret-shaped patterns still bite.

---

## 8. After PyPI: Go modules (do NOT start without the user)

Go modules is the next slice — its own brainstorm → spec → plan → implement cycle
on the same chassis (parse `go.mod`; proxy
`https://proxy.golang.org/<module>/@v/list`; Go's `vN+` major-suffix import-path
convention is the analogue of the Docker variant wrinkle). Raise it with the user
once PyPI ships. Do not fold it into this slice.

---

## 9. Provenance / state at handover

- Brainstorm → spec → plan complete on 2026-06-12. Spec commit `afbf599`; plan
  commit `0788acf` (verify with `git log`). This handover follows.
- Current `main` HEAD before execution: the plan/handover commits (run
  `git rev-parse HEAD`). Task 13's `source.yaml` needs the then-current `main`
  HEAD as its `suite_sha`.
- Five source classes live: github-actions, runner, npm, nuget, docker. PyPI is
  the sixth (this slice).
- Relevant memories (in `~/.claude`): `project_housekeeper_specialist_slice3`,
  `…slice2`, `…slice1`, `feedback_housekeeper_diff_is_selector_not_filter`,
  `project_housekeeper_maintenance_health_axis`, `project_plugin_cache_staleness`,
  `feedback_plugins_update_after_push`, `project_marketplace_autoupdate_wiped_branch`,
  `project_code_review_suite_backlog`.
