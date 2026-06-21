# roslyn-lsp

> **Origin.** This plugin is a re-host of
> [`unsafePtr/ClaudeCodeRoslynLspProxy`](https://github.com/unsafePtr/ClaudeCodeRoslynLspProxy)
> (MIT) with a single locally-tuned default (`--logLevel Warning` instead of `Information`).
> All credit for the proxy and the original plugin manifest goes upstream.

Solution-aware C# language server for Claude Code, via Microsoft's Roslyn LSP and the
[`ClaudeCodeRoslynLspProxy`](https://github.com/unsafePtr/ClaudeCodeRoslynLspProxy) shim that
injects the Roslyn-specific `solution/open` notification Claude Code's built-in LSP client
omits.

Without the proxy, `findReferences` / `goToDefinition` / `goToImplementation` return
file-scoped or empty results on multi-project solutions. With it, they return solution-wide
results, sub-second after the initial 10–30 s warm-up.

> **Read-only by design.** Claude Code's LSP tool exposes 9 navigation operations only
> (`findReferences`, `goToDefinition`, `goToImplementation`, `hover`, `documentSymbol`,
> `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`, `workspaceSymbol`). It does
> not surface `rename`, `codeAction`, or `formatting`, even though Roslyn implements them.
> This plugin cannot change that — it only makes the read-only ops work solution-wide.

## Conflict with `csharp-lsp@claude-plugins-official` (REQUIRED to read)

The official `csharp-lsp@claude-plugins-official` plugin uses
[`csharp-ls`](https://github.com/razzmatazz/csharp-language-server) (deprecated) and also
claims `.cs`. **Both plugins compete on file extension. Whichever the LSP resolver picks
first wins, and the other is silently inert** — typically `csharp-ls` wins, which means the
Roslyn proxy never spawns and you continue getting file-scoped results without realising.

To use this plugin you **must** disable the official one in your personal `settings.json`:

```jsonc
"enabledPlugins": {
  "csharp-lsp@claude-plugins-official": false,
  "roslyn-lsp@jodre11-plugins": true
}
```

`csharp-ls` will continue to spawn until that line says `false`. After flipping it, restart
Claude Code (a fresh terminal session is safest — the harness caches its plugin/extension
resolver per session).

To verify the conflict is resolved:

```bash
pgrep -af csharp-ls           # expect: empty
pgrep -af ClaudeCodeRoslynLspProxy   # expect: a PID
```

## Prerequisites

- .NET 10 SDK (`dotnet --list-sdks`)
- Claude Code 2.1.50 or later
- `ENABLE_LSP_TOOL=1` exported in your shell. This gates Claude Code's LSP tool surface and
  is currently undocumented but mandatory — without it, no LSP plugin (including this one)
  is reachable. Set it in your shell rc, your `~/.claudeenv`, or per-session.

## Installation

```bash
dotnet tool install --global roslyn-language-server --prerelease
dotnet tool install --global ClaudeCodeRoslynLspProxy
```

Confirm `~/.dotnet/tools` is on `PATH`:

```bash
which ClaudeCodeRoslynLspProxy
```

If empty, append `~/.dotnet/tools` to `PATH` and restart Claude Code.

Then enable the plugin from inside Claude Code:

```text
/plugin install roslyn-lsp@jodre11-plugins
```

Disable the official `csharp-lsp` (see "Conflict" section above), then restart Claude Code.
The LSP server is spawned lazily on the first `.cs` file open or LSP tool call — no process
exists until then.

## Tuning vs. upstream

This manifest pins `--logLevel Warning` (upstream defaults to `Information`, which is
chatty). All other args mirror upstream `roslyn-lsp@claude-roslyn-lsp`.

## Verify it's working

In a C# project, ask Claude to find references to a symbol (use the LSP tool, not grep).
Then check the proxy log:

```bash
tail -5 "${TMPDIR:-/tmp}/roslyn-lsp-logs/proxy.log"
```

The proxy uses .NET's `Path.GetTempPath()`, so the log path is **platform-dependent**:

| Platform | Resolved log path |
|---|---|
| macOS | `${TMPDIR}/roslyn-lsp-logs/proxy.log` (e.g. `/var/folders/.../T/roslyn-lsp-logs/`) |
| Linux | `/tmp/roslyn-lsp-logs/proxy.log` |
| Windows | `%TEMP%\roslyn-lsp-logs\proxy.log` |

Last line should be `[proxy] open notification sent: solution/open (file:///.../*.slnx)`.
First call after a cold start takes 10–30 s while Roslyn indexes the solution; subsequent
calls are sub-second.

## Update

```bash
dotnet tool update --global roslyn-language-server --prerelease
dotnet tool update --global ClaudeCodeRoslynLspProxy
```

Then fully restart Claude Code — `/reload-plugins` does not respawn already-running LSP
processes.

## Credit

The proxy itself is upstream work by [unsafePtr](https://github.com/unsafePtr). This plugin
is a thin re-host of the manifest with locally-tuned defaults.
