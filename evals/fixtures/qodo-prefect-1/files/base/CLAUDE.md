# prefect: project rules

## All Python Source Files Must Import Future Annotations

Enable forward reference resolution and improve type checking performance by requiring `from __future__ import annotations` at the top of all Python files that use type hints

- Do: Every Python file in src/ that contains type annotations includes `from __future__ import annotations` as the first import statement
- Do not: Python files with type annotations lack the `from __future__ import annotations` import statement

## Type-Only Imports Must Use TYPE_CHECKING Guards

Prevent circular import errors and reduce runtime overhead by requiring type-only imports to be placed within TYPE_CHECKING conditional blocks

- Do: All imports used exclusively for type hints are placed within `if TYPE_CHECKING:` blocks, and the imported types are quoted in annotations
- Do not: Type-only imports are imported at module level instead of within TYPE_CHECKING guards, or unquoted in annotations

## Logger Instances Must Follow Standard Initialization Pattern

Ensure consistent logging configuration and type safety across the codebase by standardizing logger instantiation

- Do: All logger instances are created using the pattern `logger: "logging.Logger" = get_logger("module_name")` where module_name describes the logger's scope
- Do not: Loggers are instantiated using direct logging.getLogger() calls, or lack proper type annotations, or use inconsistent naming patterns

## Secret Values Must Use Pydantic Secret Types

Prevent accidental exposure of sensitive data in logs, error messages, and API responses by requiring proper secret field typing

- Do: All fields containing sensitive data (passwords, tokens, API keys, credentials) are typed as SecretStr, SecretBytes, or SecretDict from Pydantic
- Do not: Sensitive credential fields are typed as plain str, bytes, or dict instead of using Pydantic's Secret types

## FastAPI Router Endpoints Must Include Docstrings

Ensure API documentation is automatically generated and endpoints are self-documenting by requiring docstrings on all route handlers

- Do: All functions decorated with @router.get, @router.post, @router.patch, @router.delete, etc. include docstrings describing the endpoint purpose and behavior
- Do not: Route handler functions lack docstrings or have only placeholder/empty docstrings

## Test Files Must Mirror Source Directory Structure

Maintain test organization and discoverability by ensuring test files follow the same directory hierarchy as the source code they test

- Do: For every source file at src/prefect/module/file.py, a corresponding test file exists at tests/module/test_file.py with the same relative path structure
- Do not: Test files are placed in incorrect directories that don't mirror the source structure, or use different naming conventions

## Async Functions Must Have Sync Compatibility Wrappers Where Public

Provide user-friendly API that works in both async and sync contexts by ensuring public async functions offer sync compatibility

- Do: Public async functions that are part of the user-facing API have corresponding sync wrappers using @sync_compatible or explicit sync versions
- Do not: User-facing async functions lack sync compatibility wrappers, forcing users to always use asyncio.run() or similar

## Pydantic Models Must Use model_validator for Cross-Field Validation

Ensure data integrity and proper validation sequencing by using Pydantic's model_validator decorator for validations that depend on multiple fields

- Do: Validation logic that depends on multiple fields uses @model_validator decorator instead of individual field validators
- Do not: Cross-field validation is implemented using individual field validators, causing order-dependent validation issues or accessing unvalidated fields

## TypeScript Components Must Use Tab Indentation

Maintain consistent code formatting across the frontend codebase as enforced by Biome configuration

- Do: All TypeScript and TSX files in ui-v2/ use tab characters for indentation as specified in biome.json
- Do not: TypeScript files use spaces for indentation instead of tabs

## React Component Test Files Must Be Co-Located

Improve test discoverability and maintenance by placing test files alongside the components they test

- Do: For every React component file component.tsx, the test file component.test.tsx exists in the same directory
- Do not: Test files are separated from component files in different directories, making them harder to find and maintain

## TypeScript Must Enable Strict Type Checking

Catch type errors at compile time and ensure type safety throughout the frontend codebase

- Do: TypeScript compiler is configured with strict mode enabled and no-emit flag for validation, as evidenced by validate:types script running tsc -b --noEmit
- Do not: TypeScript strict mode is disabled or type checking is not part of the validation pipeline

## Unused Imports Must Be Automatically Removed

Keep the codebase clean and reduce bundle size by eliminating unused imports via automated linting

- Do: Biome and ESLint configurations enforce noUnusedImports as an error, and pre-commit hooks automatically remove unused imports
- Do not: Unused imports remain in the codebase after linting, or the linter is not configured to detect them as errors

## Pre-Commit Hooks Must Run Ruff for Python Code Quality

Enforce code quality standards and catch common issues before code is committed by running Ruff linter and formatter

- Do: The .pre-commit-config.yaml includes ruff-check and ruff-format hooks that run automatically on Python files before commits
- Do not: Pre-commit configuration lacks Ruff hooks, or they are configured to not block commits on failures

## Database Session Management Must Use Context Managers

Ensure proper resource cleanup and transaction handling by requiring database sessions to be managed via async context managers

- Do: All database operations use `async with db.session_context(begin_transaction=True) as session:` pattern for session management
- Do not: Database sessions are created and managed manually without context managers, or transactions are not properly scoped

## API Request Parameters Must Use Pydantic Schema Validation

Ensure data validation and automatic OpenAPI schema generation by using Pydantic models for all API request/response bodies

- Do: FastAPI route handlers accept request bodies typed as Pydantic schema classes from prefect.server.schemas.actions or prefect.client.schemas
- Do not: Route handlers accept raw dictionaries or unvalidated data structures instead of Pydantic models for request bodies
