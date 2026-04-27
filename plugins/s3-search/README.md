# S3 Search Plugin

Search and list files in Amazon S3 buckets via the `internal-project-5` global .NET tool. Wraps
`internal-project-5 ls` and `internal-project-5 grep` with sensible defaults for the Haven Finance production
environment.

## Usage

The skill triggers automatically when Claude Code needs to query S3 bucket contents, or can
be invoked explicitly with `/s3-search`.

## Prerequisites

- `internal-project-5` global .NET tool (v1.1.0+)
- AWS SSO session authenticated for `your-aws-profile`

## Installation

    claude plugins install s3-search@jodre11-plugins
