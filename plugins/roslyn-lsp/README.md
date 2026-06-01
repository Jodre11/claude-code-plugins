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

## Prerequisites

- .NET 10 SDK (`dotnet --list-sdks`)
- Claude Code 2.1.50 or later
- `ENABLE_LSP_TOOL=1` exported in your shell — wired in `~/dotfiles/zsh/.claudeenv.tmpl`

## Installation

    dotnet tool install --global roslyn-language-server --prerelease
    dotnet tool install --global ClaudeCodeRoslynLspProxy

Confirm `~/.dotnet/tools` is on `PATH`:

    which ClaudeCodeRoslynLspProxy

If empty, append `~/.dotnet/tools` to `PATH` and restart Claude Code.

Then enable the plugin from inside Claude Code:

    /plugin install roslyn-lsp@jodre11-plugins

Restart Claude Code. The LSP server is spawned lazily on the first `.cs` file open or LSP
tool call — no process exists until then.

## Tuning vs. upstream

This manifest pins `--logLevel Warning` (upstream defaults to `Information`, which is
chatty). All other args mirror upstream `roslyn-lsp@claude-roslyn-lsp`.

## Verify

In a C# project, ask Claude to find references to a symbol. Then:

    tail -5 /tmp/roslyn-lsp-logs/proxy.log

Last line should be `[proxy] open notification sent: solution/open (file:///.../*.slnx)`.

## Update

    dotnet tool update --global roslyn-language-server --prerelease
    dotnet tool update --global ClaudeCodeRoslynLspProxy

Then fully restart Claude Code — `/reload-plugins` does not respawn already-running LSP
processes.

## Credit

The proxy itself is upstream work by [unsafePtr](https://github.com/unsafePtr). This plugin
is a thin re-host of the manifest with locally-tuned defaults.
