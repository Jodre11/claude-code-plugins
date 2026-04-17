# Playwright CLI Plugin

Browser automation via `playwright-cli` — a lighter-weight CLI alternative to the Playwright
MCP server approach. Wraps the `playwright-cli` binary for testing, form filling, screenshots,
and data extraction.

## Usage

The skill triggers automatically when Claude Code needs browser interaction, or can be
invoked explicitly with `/playwright-cli`.

Reference documentation is included for:
- Test generation
- Video recording
- Running custom Playwright code
- Storage state management
- Tracing
- Request mocking
- Session management

## Prerequisites

- `playwright-cli` — `brew install playwright-cli` or `npx playwright-cli`

## Installation

    claude plugins install playwright-cli@jodre11-plugins
