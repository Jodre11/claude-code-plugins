#!/usr/bin/env python3
"""Render evals/cases/ from evals/fixtures/: one `claude plugin eval` case per fixture and arm.

Each case directory holds a case.yaml (written as JSON, which YAML accepts) and a
self-contained fixture.sh scaffold. The scaffold embeds every fixture file as base64, commits
the base on `main` and the change on `feature/<id>`, so the review under test sees exactly the
fixture's diff. The hybrid arm also writes an untracked `.claude/code-review.toml` that turns
the arm on, and places the pinned copy of Anthropic's code-review command where review-core
reads it. The eval child has no network, so nothing is fetched at run time.
"""

import argparse
import base64
import hashlib
import json
import shlex
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
EVALS = REPO_ROOT / 'evals'
FIXTURES = EVALS / 'fixtures'
CASES = EVALS / 'cases'
VENDOR_FILE = EVALS / 'vendor' / 'anthropic-code-review' / 'code-review.md'
VENDOR_SHA256 = '3f02ea6eed996590348264777b2e324859a6e2c0c5f7dd298617ea21deb3b1b2'
# The path review-core's ANTHROPIC_PLUGIN_FILE names, relative to the home directory.
ANTHROPIC_PLUGIN_PATH = '.claude/plugins/marketplaces/claude-plugins-official/plugins/code-review/commands/code-review.md'
PLUGINS = ['../../../plugins/code-review-suite', '../../../plugins/reply-fit']
ALLOWED_TOOLS = ['Read', 'Glob', 'Grep', 'Skill', 'Agent', 'Workflow', 'Bash', 'Write']
ARMS = {
    'suite': '/code-review-suite:pre-review main',
    'native': '/code-review high main',
    'hybrid': '/code-review-suite:pre-review main',
}
MAX_NOISE = 2

UNATTENDED = (
    'This session runs unattended and nobody can answer a question. Where a step would ask, take the '
    'choice that lets the review continue, and say which choice you took.')
TEMP_DIR = 'Use a directory under $TMPDIR for temp files.'
FINDINGS = 'End with the complete list of findings, each with its severity.'
STATUSES = 'Before the findings, print one line per specialist: `<name>: <status>`.'
INTENT = (
    'The author describes the change under review as follows. If the review asks for a description of the '
    'change or its intent, answer with this text verbatim:\n<<<\n{intent}\n>>>')

DETECT = (
    'PASS if the review\'s findings include this defect: {title}, {where}: {description} '
    'Wording, severity and format do not matter; a finding counts if a reader acting on it would fix this '
    'defect. FAIL otherwise.')
MUST_FIX = (
    'PASS if the review\'s findings include this defect AND present it as something that must be fixed: '
    '{title}, {where}: {description} '
    'That means severity Important, Critical, high or blocking, or a reported bug not marked as optional. A '
    'Suggestion, nit or optional note does not count. Wording and format do not matter. '
    'FAIL otherwise.')
NOISE = (
    'Count the distinct issues the review says must be fixed (not suggestions, nits or optional notes), '
    'treating near-duplicates as one. PASS if at most {max_noise} of them are outside this list of known '
    'issues: {titles}. FAIL otherwise.')
NEAR_MISS = (
    'PASS if the review does not report {pattern} in {file} as a defect that must be fixed. A note offered as '
    'optional or as a suggestion is not a report. FAIL otherwise.')
NATIVE_RAN = (
    'PASS if the reply reports the outcome of a code review of the branch\'s changes: a list of findings, or a '
    'statement that the review found none. FAIL if it is an error, a refusal, a question, or describes no '
    'review.')


class BuildError(Exception):
    """A fixture cannot be rendered into a case."""


def where(issue):
    if issue['file'] is None:
        return 'anywhere in the change'
    if issue['lines'] is None:
        return f'in {issue["file"]}'
    start, end = issue['lines']
    return f'in {issue["file"]} near line {start}' if start == end else f'in {issue["file"]} near lines {start}-{end}'


def graders(fixture, arm):
    out = []
    if arm in ('suite', 'hybrid'):
        out.append({'name': 'valid-review-core', 'type': 'tool_used', 'tool': 'Workflow', 'input_match': 'review-core'})
        out.append({
            'name': 'route-full',
            'type': 'regex',
            'pattern': 'using full review pipeline',
            'flags': 'i',
            'target': 'trace',
        })
    if arm == 'hybrid':
        out.append({
            'name': 'valid-anthropic-ok',
            'type': 'regex',
            'pattern': 'anthropic(?:-reviewer)?\\W{0,4}\\s*ok\\b',
            'flags': 'i',
        })
    if arm == 'native':
        out.append({'name': 'valid-native-ran', 'type': 'llm', 'criteria': NATIVE_RAN})
        out.append({
            'name': 'diag-native-skill',
            'type': 'regex',
            'pattern': '"skill"\\s*:\\s*"code-review"',
            'target': 'trace',
        })
    for issue in fixture['issues']:
        fields = {'title': issue['title'], 'where': where(issue), 'description': issue['description']}
        out.append({'name': f'detect-{issue["key"]}', 'type': 'llm', 'criteria': DETECT.format(**fields)})
        if fixture['source'] == 'qodo' and issue['class'] == 'bug':
            out.append({'name': f'mustfix-{issue["key"]}', 'type': 'llm', 'criteria': MUST_FIX.format(**fields)})
    if fixture['source'] == 'qodo':
        titles = '; '.join(issue['title'] for issue in fixture['issues'])
        out.append({'name': 'noise', 'type': 'llm', 'criteria': NOISE.format(max_noise=MAX_NOISE, titles=titles)})
    if 'near_miss' in fixture:
        out.append({'name': 'near-miss', 'type': 'llm', 'criteria': NEAR_MISS.format(**fixture['near_miss'])})
    return out


def case_yaml(fixture, arm):
    prompt_lines = [UNATTENDED, TEMP_DIR, FINDINGS]
    if arm != 'native':
        prompt_lines.insert(2, STATUSES)
    prompt_lines.append(INTENT.format(intent=fixture['intent']))
    return {
        'schema_version': '1.1',
        'name': f'{fixture["id"]}-{arm}',
        'description': f'{fixture["set"]} set: {fixture["id"]} reviewed by the {arm} arm.',
        'tags': [arm, fixture['set'], fixture['source']],
        'plugins': PLUGINS,
        'runs': 1,
        'context': {'scaffold_script': 'fixture.sh'},
        'execution': {
            'prompt': ARMS[arm],
            'max_turns': 200,
            'timeout_seconds': 3600,
            'allowed_tools': ALLOWED_TOOLS,
            'append_system_prompt': '\n'.join(prompt_lines) + '\n',
        },
        'graders': graders(fixture, arm),
    }


def embed(path, data, under_home=False):
    """Return shell lines that recreate path (relative to cwd, or to $HOME) with the given bytes."""
    def quoted(p):
        return f'"$HOME"/{shlex.quote(p)}' if under_home else shlex.quote(p)

    lines = []
    parent = Path(path).parent.as_posix()
    if parent != '.':
        lines.append(f'mkdir -p {quoted(parent)}')
    encoded = base64.encodebytes(data).decode('ascii')
    lines.append(f'base64 --decode > {quoted(path)} <<\'B64\'')
    lines.append(encoded.rstrip('\n'))
    lines.append('B64')
    return lines


def tree(fixture):
    """Return (base files, head files, removed paths) as {path: bytes} maps and a list."""
    if fixture['source'] == 'qodo':
        root = FIXTURES / fixture['id'] / 'files'
        base = {p.relative_to(root / 'base').as_posix(): p.read_bytes()
                for p in sorted((root / 'base').rglob('*')) if p.is_file()}
        head = {p.relative_to(root / 'head').as_posix(): p.read_bytes()
                for p in sorted((root / 'head').rglob('*')) if p.is_file()} if (root / 'head').exists() else {}
        return base, head, fixture['removed']
    src = REPO_ROOT / fixture['files_from']
    base = {rel: (src / rel).read_bytes() for rel in fixture['base']}
    head = {rel: (src / rel).read_bytes() for rel in fixture['head']}
    if 'README.md' in base:
        base['README.md'] = fixture['readme'].encode('utf-8')
    return base, head, []


def fixture_sh(fixture, arm, plugin_file):
    base, head, removed = tree(fixture)
    branch = f'feature/{fixture["id"]}'
    out = [
        '#!/usr/bin/env bash',
        f'# Generated by evals/tools/build_cases.py from evals/fixtures/{fixture["id"]}; do not edit.',
        'set -euo pipefail',
        'export GIT_AUTHOR_DATE="2026-01-01T00:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:00 +0000"',
        'git init -q -b main',
        'git config user.name Fixture',
        'git config user.email fixture@example.invalid',
        'git config commit.gpgsign false',
        'git config core.askPass /usr/bin/false',
        'git remote add origin https://github.com/example/review-eval-fixture.git',
    ]
    for path, data in base.items():
        out += embed(path, data)
    base_title = fixture.get('base_title', 'base: upstream state before the change')
    out += ['git add -A', f'git commit -q -m {shlex.quote(base_title)}', f'git switch -q -c {shlex.quote(branch)}']
    for path in removed:
        out.append(f'git rm -q --ignore-unmatch -- {shlex.quote(path)}')
    for path, data in head.items():
        out += embed(path, data)
    out += [
        'git add -A',
        f'git commit -q -m {shlex.quote(fixture["commit_title"])} -m {shlex.quote(fixture["intent"])}',
    ]
    if arm == 'hybrid':
        out += [
            'mkdir -p .claude',
            'printf \'[review]\\nanthropic_specialist = true\\n\' > .claude/code-review.toml',
            'printf \'.claude/code-review.toml\\n\' >> .git/info/exclude',
        ]
        out += embed(ANTHROPIC_PLUGIN_PATH, plugin_file, under_home=True)
    return '\n'.join(out) + '\n'


def load_fixtures(only):
    fixtures = []
    for path in sorted(FIXTURES.glob('*/fixture.json')):
        fixture = json.loads(path.read_text(encoding='utf-8'))
        if fixture['id'] != path.parent.name:
            raise BuildError(f'{path}: id {fixture["id"]} does not match its directory')
        if only and fixture['id'] not in only:
            continue
        if not fixture['issues'] and 'near_miss' not in fixture:
            raise BuildError(f'{fixture["id"]}: no issues and no near-miss, so nothing to grade')
        fixtures.append(fixture)
    return fixtures


def main():
    parser = argparse.ArgumentParser(description='Render evals/cases/ from evals/fixtures/.')
    parser.add_argument('--fixture', nargs='*', default=[], help='render only these fixture ids')
    parser.add_argument('--arm', nargs='*', default=list(ARMS), choices=list(ARMS), help='arms to render')
    parser.add_argument('--out', type=Path, default=CASES, help=argparse.SUPPRESS)
    args = parser.parse_args()
    out_dir = args.out.resolve()

    plugin_file = VENDOR_FILE.read_bytes()
    if hashlib.sha256(plugin_file).hexdigest() != VENDOR_SHA256:
        print(f'build_cases: {VENDOR_FILE} does not match the pinned sha256', file=sys.stderr)
        return 2
    try:
        fixtures = load_fixtures(set(args.fixture))
    except BuildError as err:
        print(f'build_cases: {err}', file=sys.stderr)
        return 2
    if out_dir.exists():
        shutil.rmtree(out_dir)
    for fixture in fixtures:
        for arm in args.arm:
            dest = out_dir / f'{fixture["id"]}-{arm}'
            dest.mkdir(parents=True)
            (dest / 'case.yaml').write_text(
                json.dumps(case_yaml(fixture, arm), indent=2, ensure_ascii=False) + '\n',
                encoding='utf-8')
            script = dest / 'fixture.sh'
            script.write_text(fixture_sh(fixture, arm, plugin_file), encoding='utf-8')
            script.chmod(0o755)
    print(f'build_cases: {len(fixtures) * len(args.arm)} cases in {out_dir}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
