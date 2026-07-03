# S3 Search Plugin

Search and list files in Amazon S3 buckets via the `s3search` global .NET tool. Wraps
`s3search ls` and `s3search grep` with environment-specific defaults stored in auto-memory.

## Usage

The skill triggers automatically when Claude Code needs to query S3 bucket contents, or can
be invoked explicitly with `/s3-search`.

## Prerequisites

- `s3search` global .NET tool (v1.1.0+)
- AWS SSO session authenticated for the target profile

## Installation

    claude plugins install s3-search@jodre11-plugins
