# A/B harness hook-leak — generalisation trace (backlog #2)

**Date:** 2026-06-04
**Outcome:** CLOSED as already-fixed. No code change.

## Question

Phase 3.4 fixed a bare-`/tmp` fallback in the per-agent trial path only
(`tests/ab/run.sh:264`, commit `830905b`). Backlog item #2 asked whether the fix
should generalise: (a) route every harness `mktemp`/temp path under `/tmp/claude-`,
or (b) run A/B subagents isolated from the operator's global hooks
(`~/.claude/hooks/bash-guard.sh` et al.).

## Mechanism (the rule that decides everything)

`bash-guard.sh` is a `PreToolUse` hook. It fires **only on a dispatched
subagent's Bash tool calls** — never on the A/B harness's own shell commands.
Its temp-path policy denies a command that mentions a bare `/tmp/`, `$TMPDIR`, or
`/var/folders/` path unless the command string also contains the `/tmp/claude-`
exempt substring (`_lib.sh: mentions_temp_path` / `cmd_mentions_session_temp`).

So a harness `mktemp` site is only a hazard if its **absolute path can end up
inside a command the subagent runs**. A path the harness merely reads/writes in
its own shell is invisible to the hook.

## Site-by-site trace

| Site | Consumer | Subagent-reachable? |
|---|---|---|
| `run.sh:264` trial `cwd` (`tmp_base`/`trials_root`/`trial_work`) | the subagent's cwd — it puts the **absolute** trial path in tool commands (e.g. `jb inspectcode /private/tmp/.../foo.sln`) | **YES** — the one real hazard, **already fixed by `830905b`** |
| `run.sh:337` `synth_dir` | `agent_capture_parse_trial` in the harness shell (faithfulness baseline synth); no dispatch | No |
| `agent_dispatch.sh:120-121` `body_tmp` / `user_msg_tmp` | `body_tmp` → CLI `--append-system-prompt-file` (CLI reads the file); `user_msg_tmp` → `cat`'d into argv. Subagent sees the **contents**, never the path | No |
| `mutate.sh:45,70` | harness-shell `sed`/`awk` write to tmp then atomic `mv` onto an in-repo file; never passed to a subagent | No |

## Decisions

- **Fix (a) rejected.** The four non-cwd `mktemp` sites are not subagent-reachable,
  so routing them under `/tmp/claude-` is defensive code for a scenario that cannot
  occur. It would add regression tests that assert a property nothing depends on.
- **Fix (b) rejected as actively unfaithful.** In production the code-review
  specialists run as Task subagents *inside the operator's session* and therefore
  **do** inherit the operator's hooks. The harness inheriting `bash-guard.sh` is
  faithful apparatus, not a leak. The only defect was the rig placing the trial
  `cwd` *outside* `/tmp/claude-`, manufacturing a hook trip that production (which
  runs in the real repo tree) never sees. `830905b` restores faithful behaviour;
  isolating hooks would make the rig diverge from production.
  (`claude --bare` skips hooks and would be the isolation lever if it were ever
  wanted — recorded here only so a future reader doesn't re-derive it.)

## Net

The one real mechanism is already fixed (`830905b`) and guarded by
`test_ab_run_sh_per_agent_tmp_base_is_hook_exempt` in
`tests/lib/test_ab_harness.sh`. #2 needs no further code.
