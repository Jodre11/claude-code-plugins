# Design — broaden `$HOUSEKEEPING_DETECTED` to fire on edited source files

> Brainstorming design doc. On approval, the `superpowers:writing-plans` skill
> produces the implementation plan. Scope is deliberately small: a docs/test-only
> change to the dispatch trigger — no engine or agent code moves.

## Context

The user's global CLAUDE.md "Repo Housekeeping" intent is that dependency/version
freshness is audited as part of review whenever a project is worked on — the
housekeeping instinct, not diff-line-spotting. The original housekeeper design
(`2026-06-05-housekeeper-specialist-design.md`, "Scope model") settled a
three-tier model:

- **T1 scope gate (changed files):** a changed file pulls in its containing
  buildable unit; shared CI is always in scope.
- **T2 candidate set:** every dependency in an in-scope unit is an upgrade
  candidate — not only the ones whose lines changed.
- **T3 modulation (changed lines):** changed lines set the upgrade *target* only.

## Root cause (the defect this fixes)

The shipped **engine** (`bin/housekeeper-freshness`) already implements T1
correctly, per ecosystem:

- `nuget_scope_roots` (engine line 641) walks each changed `.cs`/`.fs`/`.vb`/
  `.razor`/`.cshtml` file up to its nearest-ancestor `.csproj` and audits ALL
  that project's NuGet dependencies. Scope set: `_NUGET_SCOPE_SUFFIXES`
  (line 615).
- `npm_scope_roots` (line 435) does the same for `.ts`/`.tsx`/`.js`/`.jsx`/
  `.mjs`/`.cjs`/`.mts`/`.cts`/`.vue`/`.svelte` → nearest `package.json`. Scope
  set: `_NPM_SCOPE_SUFFIXES` (line 416).

The defect is solely the **dispatch gate**. `$HOUSEKEEPING_DETECTED`
(`review-pipeline.md:693`) only fires when a *manifest file itself* is in the diff
(`.csproj`/`package.json`/`.props`/`packages.lock.json`/workflow). So a
source-only PR (e.g. PR #566 — seven `.cs` files, no manifest) never invokes the
engine, even though the engine, if dispatched, would walk each `.cs` file to its
`.csproj` and surface every stale NuGet package. **The trigger is strictly
narrower than the engine behind it.**

## The change

Widen `$HOUSEKEEPING_DETECTED` to also fire on the source-file extensions the
engine already treats as scope files — no wider (firing on `.py` today would
dispatch the housekeeper only to find nothing, since Python is not yet an engine
ecosystem), no narrower.

### Trigger contents after the change

Existing manifest/workflow triggers (unchanged):
`.github/workflows/*.yml`/`.yaml`, `package.json`,
`.csproj`/`.fsproj`/`.vbproj`/`.props`/`.targets`, `packages.lock.json`.

New source-file triggers (mirror the engine scope constants):

| Ecosystem | Source extensions | Engine constant |
|---|---|---|
| .NET / NuGet | `.cs`, `.fs`, `.vb`, `.razor`, `.cshtml` | `_NUGET_SCOPE_SUFFIXES` |
| npm | `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.mts`, `.cts`, `.vue`, `.svelte` | `_NPM_SCOPE_SUFFIXES` |

`.targets`/`.csproj`/`.props` are already in the engine NuGet scope set; the edit
also folds `.targets` into the trigger prose (a pre-existing minor prose-vs-engine
mismatch) so the two align cleanly.

### Why explicit extensions, not "any C#/npm source file"

Explicit extension lists are more directive for the executing agent and are the
only form a sync test can pin:

- A literal "ends with `.cs`/`.fs`/…" check is a mechanical string match the
  model performs reliably; "is this a *source* file?" invites interpretation and
  drift (especially on cheaper tiers — the housekeeper runs haiku/low).
- Every sibling flag (`$CSHARP_DETECTED`, `$JS_DETECTED`, `$PY_DETECTED`,
  `$IAC_DETECTED`) is already specified as an explicit extension list in the same
  Step 2.6 prose; uniform structure is itself directive.
- A semantic description is untestable — there is no list to grep against the
  engine constants.

## Mirror contract (maintenance rule)

The trigger's prose extension list is a projection of the engine's two
`_*_SCOPE_SUFFIXES` tuples. Future ecosystem slices add BOTH an engine scope set
AND the matching trigger extensions, in lockstep. A new sync-note test enforces
this so the engine and trigger cannot drift (either direction) silently — the
exact failure mode being fixed here.

## Files changed

1. `includes/review-pipeline.md` (canonical) — the Step 2.6 "Housekeeping
   detection" bullet.
2. `commands/pre-review.md` — mirror (currently byte-identical).
3. `skills/review-gh-pr/SKILL.md` — mirror (currently byte-identical).
4. `tests/lib/test_sync_notes.sh` — new test
   `test_housekeeping_trigger_mirrors_engine_scope`: extract every extension
   token from the detection prose's source-file clause and assert each appears in
   an engine `_*_SCOPE_SUFFIXES` tuple. Fails on drift either direction.

## Explicitly NOT changed

- The **engine** (`bin/housekeeper-freshness`) — already correct; this is the
  point of the fix.
- The **agent** (`agents/housekeeper-reviewer.md`) — consumes the file list it is
  given; no scope logic there.
- `$SPECIALIST_COUNT`, verify-completeness enumeration, cross-review wiring — the
  flag's plumbing is unchanged; only its firing condition widens. It remains a
  conditional static specialist.

## Verification

- `bash tests/run.sh` green: existing sync-note parity tests (detection prose
  byte-identical across the three files) + the new mirror test.
- Engine regression check: build a synthetic changed-files list containing only a
  `.cs` path under a fixture project, run `housekeeper-freshness`, confirm it
  returns that project's stale deps — documents why only the trigger needed
  fixing.
- The 31 existing engine unittests untouched and green.

## Out of scope

- Python/Go/crates/etc. source triggers — no engine ecosystem yet; added in
  future slices alongside their engine scope sets.
- A standalone "audit the whole tree regardless of diff" mode — a separate
  feature. This fix is strictly "edited project ⇒ audit that project".

## House rules (carried)

Direct-push to `main`, push immediately; no Co-Authored-By/advertising; Bash hook
rules (no `&&`/`;`/`$(...)` except the commit heredoc); `CLAUDE_TEMP_DIR` for temp
files; plugin-authoring frontmatter conventions. Memory: update the slice
memories' trigger note + MEMORY.md in the `~/.claude` repo, commit+push
separately.
