# shellcheck shell=bash
# shellcheck disable=SC2034  # read by guard-lib.sh and the hooks that source it
# Pattern sets and path exemptions for .githooks/pre-commit and .githooks/pre-push, sourced by .githooks/guard-lib.sh.
# Each pattern is a POSIX ERE, matched case-insensitively against each added line. .gitleaks.toml carries the same
# patterns; tests/test-pattern-sync.sh checks that the two stay in step. Both are this repository's own; the other
# guard files are copied unchanged from the claude-settings-template and dotfiles-template repositories.
#
# The IDENTITY_PATTERNS are placeholders. Names this repository must not publish are kept out of it, in the optional,
# gitignored .githooks/identity-patterns.local, one ERE per line; secret-shaped literals of your own go in
# .githooks/always-patterns.local the same way.

# Secret-shaped values: they bite on every path.
ALWAYS_PATTERNS=(
    # A 12-digit number within 24 characters of the word "account", on either side, and an ARN carrying one
    'account[^0-9]{0,24}[0-9]{12}([^0-9]|$)'
    '(^|[^0-9])[0-9]{12}[^0-9]{1,24}account'
    'arn:aws[a-z-]*:[^:]*:[^:]*:[0-9]{12}:'

    # ECR registry hostnames
    '[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com'

    # Bedrock application inference profile IDs
    'application-inference-profile/[a-z0-9]{10,16}'

    # SSH private key markers
    '-----BEGIN.*PRIVATE KEY-----'

    # Tokens / PATs
    'YOUR_NUGET_PAT'
)

# Organisation and personal identity markers: placeholders. Two of the seeds' placeholders, the bare organisation word
# and the fifth internal project, are left out: this repository's history uses them as examples, and that history
# must pass its own pre-push.
IDENTITY_PATTERNS=(
    # SSO portal
    'yourorg\.awsapps\.com'

    # Active Directory
    'DC=your-domain'

    # Organisation
    'YourOrgEngineering'
    'your-company\.com'
    'your-stage\.com'
    'your-dev-server'
    'your-prod-server'
    'yourorgltd'
    'internal-project-1'
    'internal-project-2'
    'internal-project-3'
    'internal-project-4'

    # Personal
    'YourGitHubUser'
    '@your-company\.com'
    '@your-email\.co\.uk'
    'your\.name'
    '/Users/yourusername/'
)

# Paths exempt from IDENTITY_PATTERNS. This ERE never matches, since nothing follows the end of a path: no path is
# exempt.
IDENTITY_EXEMPT_RE='^$.'

# Paths exempt from identity-patterns.local. None: this ERE never matches either.
LOCAL_IDENTITY_EXEMPT_RE='^$.'

# Patterns of identity-patterns.local this repository disregards on every path, each the exact text of one line of
# that list: the owner's GitHub handle, which names this repository and its marketplace, and the name of the internal
# S3 tool the s3-search plugin wraps. Both are this repository's own public identity. Every other local pattern, and
# always-patterns.local, still applies. An entry that matches no line drops nothing, so a changed pattern bites again.
LOCAL_IDENTITY_IGNORE=(
    'Jodre11'
    's3search'
)

# Paths the built-ins pass skips. This ERE never matches, so gitleaks' built-in rules scan every path. To clear a
# built-in false positive, replace it with an anchored alternation of the paths to exempt, in a reviewed commit.
BUILTINS_EXEMPT_RE='^$.'

# Paths exempt from ALWAYS_PATTERNS, for files that must carry secret-shaped dummy values. None: this ERE never
# matches. always-patterns.local and the identity patterns would still apply to such a path.
ALWAYS_EXEMPT_RE='^$.'
