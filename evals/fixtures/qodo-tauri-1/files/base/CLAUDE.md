# tauri: project rules

## All New Source Files Must Include Copyright and SPDX License Headers

Ensure proper legal attribution and license compliance by requiring standardized copyright and SPDX license identifiers at the top of all source files. This protects the project's legal standing and makes license information machine-readable.

- Do: Every new Rust (.rs), TypeScript/JavaScript (.ts, .js), and workflow (.yml) file begins with a copyright header containing 'Copyright 2019-2024 Tauri Programme within The Commons Conservancy' followed by SPDX license identifiers 'SPDX-License-Identifier: Apache-2.0' and 'SPDX-License-Identifier: MIT'
- Do not: New source files are missing the copyright header, have incorrect copyright attribution, or lack the required SPDX license identifiers

## Rust Code Must Pass Clippy Linting with Warnings Denied

Maintain high code quality and catch potential bugs, performance issues, and non-idiomatic patterns by enforcing Clippy lints as errors. This ensures all code adheres to Rust best practices and community standards.

- Do: All Rust code passes 'cargo clippy --all-targets --all-features -- -D warnings' without any warnings or errors
- Do not: Running clippy produces any warnings or errors, indicating code that violates Rust best practices or contains potential issues

## Rust Code Must Be Formatted According to Project rustfmt Configuration

Ensure consistent code style across the entire Rust codebase by enforcing automated formatting rules. This improves readability, reduces merge conflicts, and eliminates style debates in code reviews.

- Do: All Rust code passes 'cargo fmt --all -- --check' without modifications, adhering to the project's rustfmt.toml configuration (max_width=100, tab_spaces=2, Unix newlines, etc.)
- Do not: Running cargo fmt identifies files that require formatting changes, indicating inconsistent code style

## TypeScript and JavaScript Code Must Be Formatted with Prettier

Maintain consistent formatting in frontend and tooling code by enforcing Prettier formatting standards. This ensures uniformity across TypeScript/JavaScript files and prevents style inconsistencies.

- Do: All TypeScript and JavaScript files pass prettier format checks without requiring modifications
- Do not: Running prettier --check identifies files that need formatting, indicating code that doesn't conform to the project's style

## TOML Configuration Files Must Be Formatted with taplo

Ensure consistent formatting of TOML configuration files (Cargo.toml, rustfmt.toml, etc.) by enforcing taplo formatting standards. This maintains readability and reduces noise in configuration file diffs.

- Do: All TOML files pass 'taplo fmt --check --diff' without requiring changes
- Do not: Running taplo detects formatting inconsistencies in TOML files

## All Source Files Must Follow EditorConfig Standards

Enforce consistent basic formatting across all file types (charset, indentation, line endings) by adhering to the .editorconfig specification. This ensures cross-editor consistency and prevents common formatting issues.

- Do: All files use UTF-8 encoding, 2-space indentation, LF line endings, include a final newline, and have trailing whitespace trimmed
- Do not: Files contain CRLF line endings, inconsistent indentation, wrong encoding, missing final newlines, or trailing whitespace

## Public APIs Must Include Documentation Comments

Ensure all public APIs are properly documented to support developers using the framework and to generate comprehensive API documentation. This improves usability and reduces the learning curve for the library.

- Do: All public functions, types, modules, and methods include /// documentation comments explaining their purpose, parameters, return values, and usage examples where appropriate
- Do not: Public API elements lack documentation comments, or documentation is incomplete/unclear

## Error Types Must Use thiserror for Structured Error Handling

Maintain consistent and ergonomic error handling throughout the codebase by using the thiserror crate for custom error types. This provides clear error messages and proper error propagation.

- Do: All custom error enums use #[derive(thiserror::Error)] with appropriate #[error(...)] attributes providing descriptive error messages
- Do not: Custom error types implement Display/Error traits manually instead of using thiserror, or error messages are unclear/missing

## Public Error Enums Must Be Marked as Non-Exhaustive

Preserve API flexibility and prevent breaking changes by marking public error enums as #[non_exhaustive]. This allows adding new error variants in the future without breaking downstream code.

- Do: Public error enums that may need future variants include the #[non_exhaustive] attribute
- Do not: Public error enums that should be extensible lack the #[non_exhaustive] attribute, potentially causing breaking changes when new variants are added

## Functions Returning Values Should Be Marked with must_use Where Appropriate

Prevent logic errors by ensuring return values that represent important state or results are not accidentally ignored. This catches bugs where critical return values are discarded without handling.

- Do: Functions returning builders, handles, or results that must be used for correctness include #[must_use] attribute with explanatory messages
- Do not: Functions returning important values that should not be ignored lack #[must_use], allowing silent errors

## Platform-Specific Code Must Use Appropriate Conditional Compilation

Ensure code compiles correctly on all target platforms by properly gating platform-specific functionality behind #[cfg(...)] attributes. This prevents compilation failures and enables cross-platform builds.

- Do: Platform-specific code uses #[cfg(target_os = "...")] or similar attributes to conditionally compile only on supported platforms, and includes appropriate #[cfg_attr(docsrs, doc(cfg(...)))] for documentation
- Do not: Platform-specific APIs are used without conditional compilation guards, causing build failures on unsupported platforms

## Tests Must Be Organized in cfg(test) Modules Named 'tests'

Maintain consistent test organization and ensure tests are only compiled during testing by placing unit tests in properly configured modules. This keeps production binary sizes small and test code clearly separated.

- Do: Unit tests are placed in 'mod tests' blocks with #[cfg(test)] attribute at the module level
- Do not: Tests are not properly gated with #[cfg(test)] or use inconsistent module naming, causing tests to compile in production builds

## Changes Requiring a Version Bump Must Include a Change File

Ensure proper version management and changelog generation by requiring change files for all changes that will be released. This provides clear release documentation and enables automated versioning.

- Do: Pull requests that modify functionality include a markdown file in the .changes directory following the covector format, specifying the appropriate version bump (major/minor/patch) and change summary
- Do not: PRs with user-facing changes lack a corresponding change file, preventing proper version tracking and changelog generation

## Generated Files Must Be Kept in Sync with Source Code

Prevent runtime errors and inconsistencies by ensuring generated files (TypeScript API bundles, JSON schemas) are regenerated when their source code changes. This maintains integrity between source and generated artifacts.

- Do: When source files for generated artifacts change (packages/api/src/**, crates/tauri-utils/src/config.rs, schema files), the corresponding generated files are updated by running the appropriate build commands
- Do not: Generated files become stale and out of sync with their source code, causing type mismatches, missing features, or validation errors

## Unsafe Code Must Include Safety Documentation

Ensure unsafe code blocks are properly justified and their safety invariants are clearly documented to prevent undefined behavior. This makes code review more effective and helps maintainers understand safety requirements.

- Do: All unsafe blocks and functions include comments explaining why the code is safe, what invariants must be maintained, and under what conditions the code is valid
- Do not: Unsafe code lacks documentation of safety invariants, making it impossible to verify correctness or maintain the code safely

## Functions Should Return Result Types for Fallible Operations

Enable proper error handling and propagation by using Result<T, E> return types for operations that can fail. This makes error conditions explicit in the API and allows callers to handle errors appropriately.

- Do: Operations that can fail (I/O, parsing, validation, etc.) return Result<T> with appropriate error types rather than panicking or returning Option
- Do not: Fallible operations use panic!, unwrap(), expect(), or Option where Result would be more appropriate, hiding error conditions from callers

## Workspace Members Must Use Consistent Metadata

Maintain consistent package metadata across all workspace members by inheriting common fields from workspace.package in Cargo.toml. This ensures uniform author attribution, licensing, repository links, and Rust edition.

- Do: Individual crate Cargo.toml files inherit workspace-level metadata (authors, license, repository, homepage, edition, rust-version) rather than duplicating them
- Do not: Crates duplicate metadata that should be inherited from the workspace, causing inconsistencies in licensing, authorship, or other package information
