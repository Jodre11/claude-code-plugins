# Ghost: project rules

## Migration Files Must Follow Strict Naming Convention

Ensure database migration files follow the required timestamp-based naming pattern to maintain chronological order and enable proper migration tracking

- Do: Migration files in core/server/data/migrations/versions/ (excluding versions 1.x, 2.x, 3.x) match the pattern: YYYY-MM-DD-HH-MM-descriptive-name-with-hyphens (e.g., 2022-04-05-12-00-add-member-alert-setting.js)
- Do not: Migration files do not follow the required timestamp format or use underscores, camelCase, or other naming styles

## Enforce Module Boundary Between core/shared and core/server

Maintain architectural separation by preventing core/shared modules from depending on core/server code, ensuring shared code remains truly reusable across server and frontend

- Do: Files in core/shared/ do not contain require() or import statements that reference core/server/ paths
- Do not: Files in core/shared/ import or require modules from core/server/

## Enforce Module Boundary Between core/shared and core/frontend

Maintain architectural separation by preventing core/shared modules from depending on core/frontend code, ensuring shared code remains truly reusable across server and frontend

- Do: Files in core/shared/ do not contain require() or import statements that reference core/frontend/ paths
- Do not: Files in core/shared/ import or require modules from core/frontend/

## Database Schema Must Not Include User Audit Fields

Prevent using created_by and updated_by fields in database schema to enforce the use of the action log for tracking user actions, providing better audit trails and separation of concerns

- Do: The schema definition in core/server/data/schema/schema.js does not contain properties named 'created_by' or 'updated_by'
- Do not: The schema definition includes 'created_by' or 'updated_by' fields

## Database Migrations Must Not Use Loop Constructs

Prevent performance issues in database migrations by prohibiting loop constructs (for, while, forEach) that can cause migrations to run slowly or fail on large datasets

- Do: Migration files in core/server/data/migrations/versions/ do not contain for statements, for-of statements, for-in statements, while statements, forEach calls, or _.each calls
- Do not: Migration files contain any loop constructs including for, for-of, for-in, while, forEach, or _.each

## Database Migrations Must Not Use Multiple JOIN Statements

Prevent complex and poorly performing database queries in migrations by prohibiting multiple JOIN operations in a single Knex query block

- Do: Migration files do not chain multiple join/innerJoin/leftJoin calls on a single Knex query object
- Do not: Migration files contain Knex queries with multiple chained join operations

## Database Migrations Must Not Return Early from Loops

Prevent data processing errors in migrations by ensuring all records are processed when loops are used (in legacy migrations or utility functions)

- Do: Migration files do not contain return statements inside loop bodies
- Do not: Migration files contain return statements within loop constructs

## API Endpoint Controllers Must Have Type Annotations

Ensure type safety and IDE support for API endpoint controllers by requiring JSDoc type annotations from @tryghost/api-framework

- Do: API endpoint controller objects in core/server/api/endpoints/ include JSDoc type comment '@type {import('@tryghost/api-framework').Controller}'
- Do not: API endpoint controllers lack the required JSDoc type annotation

## API Endpoints Must Enforce Complexity Limits

Maintain code quality and prevent overly complex API endpoint implementations by enforcing complexity metrics on endpoint handler functions

- Do: API endpoint files in core/server/api/endpoints/ pass the 'ghost/ghost-custom/max-api-complexity' ESLint rule
- Do not: API endpoint functions exceed the maximum allowed cyclomatic complexity threshold

## Internationalization Files Must Use Kebab-Case Naming

Ensure consistent file naming across all i18n translation files to maintain a uniform codebase structure and simplify automated tooling

- Do: All files in ghost/i18n/ use kebab-case naming (lowercase letters, numbers, hyphens, and dots only): matching pattern ^[a-z0-9.-]+$
- Do not: i18n files use camelCase, PascalCase, snake_case, or contain uppercase letters

## Admin React Apps Must Use Kebab-Case File Naming

Enforce consistent kebab-case file naming convention across React admin applications to align with the codebase migration to kebab-case naming standards

- Do: All files in apps/admin-x-* directories use kebab-case naming (lowercase letters, numbers, hyphens, and dots only): matching pattern ^[a-z0-9.-]+$
- Do not: Admin app files use camelCase, PascalCase, snake_case, or contain uppercase letters

## React Components Must Sort JSX Props in Standard Order

Maintain consistent and readable JSX code by enforcing a standard ordering of component props: reserved props first, callbacks last, shorthand props last

- Do: JSX elements in React files have props ordered according to: reserved props (key, ref) first, then regular props alphabetically, then callbacks, then shorthand props last
- Do not: JSX elements have props in non-standard order (e.g., callbacks before regular props, shorthand before callbacks)

## React Button Elements Must Have Explicit Type Attribute

Prevent unintended form submissions and unclear button semantics by requiring all button elements to explicitly specify their type attribute (button, submit, or reset)

- Do: All <button> elements in React files include an explicit type attribute
- Do not: Button elements lack a type attribute or rely on browser default behavior

## React List Rendering Must Not Use Array Index as Key

Prevent rendering bugs and performance issues by prohibiting the use of array indices as React key props, which can cause incorrect component state when lists are reordered or modified

- Do: React components rendering lists use stable, unique identifiers (e.g., item.id) as key props, not array indices
- Do not: List items use array index as the key prop (e.g., key={index} or key={i})

## Tailwind CSS Classes Must Follow Standard Ordering

Ensure consistent and maintainable Tailwind CSS class lists by enforcing the standard ordering convention defined in the Tailwind configuration

- Do: Tailwind utility classes in className attributes follow the ordering specified in tailwind.config.cjs (layout, positioning, sizing, spacing, typography, visual, etc.)
- Do not: Tailwind classes are in non-standard order or randomly organized

## TypeScript Files Must Enable Strict Type Checking

Ensure type safety and catch potential runtime errors at compile time by requiring strict mode and noImplicitAny in all TypeScript configurations

- Do: tsconfig.json files include 'strict': true and 'noImplicitAny': true in compilerOptions
- Do not: TypeScript configuration files have strict or noImplicitAny set to false or omitted

## Code Must Use 4-Space Indentation

Maintain consistent code formatting across the codebase by enforcing 4-space indentation for all source files (except JSON and YAML which use 2 spaces)

- Do: All JavaScript, TypeScript, and other source files use 4 spaces for indentation levels
- Do not: Source files use tabs, 2-space indentation, or mixed indentation styles

## Code Must Use Single Quotes for Strings

Ensure consistent string literal formatting across the codebase by requiring single quotes for all string values (template literals are allowed)

- Do: String literals in JavaScript and TypeScript files use single quotes, except when using template literals for interpolation
- Do not: String literals use double quotes without justified reason

## Code Must Always Use Semicolons

Prevent subtle bugs from automatic semicolon insertion and maintain explicit statement termination by requiring semicolons at the end of all statements

- Do: All JavaScript and TypeScript statements end with explicit semicolons
- Do not: Statements rely on automatic semicolon insertion (ASI) instead of explicit semicolons

## Code Must Use let or const Instead of var

Prevent hoisting-related bugs and unclear variable scoping by prohibiting var declarations in favor of block-scoped let and const

- Do: All variable declarations use let (for reassignable variables) or const (for constants), never var
- Do not: Code contains var declarations

## Code Must Use Strict Equality Operators

Prevent type coercion bugs by requiring strict equality checks (=== and !==) instead of loose equality (== and !=)

- Do: All equality comparisons use === or !== operators
- Do not: Code contains == or != operators for equality checks

## Code Must Not Use console.* Calls

Prevent debug statements from being committed to production code by prohibiting console.log, console.warn, and other console method calls

- Do: Source files do not contain console.log, console.warn, console.error, or other console method calls
- Do not: Code contains calls to console methods

## Package Manager Must Be Yarn v1

Ensure consistent dependency management and workspace functionality by requiring Yarn v1 for all package operations, as the monorepo relies on Yarn workspaces

- Do: All package management commands (install, add, remove, run) use yarn, not npm or other package managers
- Do not: Code documentation, scripts, or CI configuration references npm or other package managers for dependency management

## Node.js Version Must Match Engine Requirement

Ensure compatibility and prevent runtime errors by enforcing the specific Node.js version required by the Ghost application

- Do: Development and production environments use Node.js version matching the engines.node specification in ghost/core/package.json (^22.13.1)
- Do not: Environment uses a Node.js version outside the specified semver range
