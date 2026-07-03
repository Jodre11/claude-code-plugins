# Markdown to Clipboard Plugin

Convert Markdown to Teams-compatible rich text and copy to the macOS clipboard. Paste directly
into Microsoft Teams, Slack, Outlook, or any rich-text editor.

## Usage

The skill triggers automatically when Claude Code needs to share Markdown via rich-text apps,
or can be invoked explicitly with `/md-to-clipboard`.

## Setup

After installing the plugin, symlink `md2clip` onto your PATH:

    # Find the plugin install path
    claude plugins list

    # Create the symlink (adjust the path to match your install location)
    ln -sf <plugin-install-path>/tools/md2clip ~/.local/bin/md2clip

## Prerequisites

- macOS (uses NSPasteboard for clipboard access)
- `pandoc` — `brew install pandoc`

## Installation

    claude plugins install md-to-clipboard@jodre11-plugins
