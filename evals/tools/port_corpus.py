#!/usr/bin/env python3
"""Port the A/B corpus's judgement fixtures into the eval's sanity set.

Each tests/ab/corpus/<id>/source.yaml builds a two-commit repo by moving the planted files
aside, committing the rest as the base, then committing the planted files. This porter reads
that split from the setup command and writes evals/fixtures/<id>/fixture.json, which points at
the files in tests/fixtures/** instead of copying them. The issue titles, descriptions and
near-miss patterns are hand-reviewed and live in CURATED, so a rerun reproduces them. Needs
`yq` (mikefarah, v4) on PATH.
"""

import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CORPUS = REPO_ROOT / 'tests' / 'ab' / 'corpus'
FIXTURES = REPO_ROOT / 'evals' / 'fixtures'
# Lines either side of a planted single-line anchor that still count as the same place.
LINE_SLACK = 3

BUG = 'bug'
QUALITY = 'quality'

# id -> (class, title, description) for a hit, or (None, None, near-miss pattern) for a near-miss.
CURATED = {
    'silentfail-hit': (
        BUG,
        'Exception swallowed without any signal',
        ('fetch_user_profile catches every exception and returns None with no log or re-raise, so a network '
        'failure, a timeout or a malformed body is indistinguishable from a missing profile.')),
    'silentfail-unique-hit': (
        BUG,
        'Default rate limit silently impersonates a real tenant limit',
        ('resolve_tenant_rate_limit falls back to DEFAULT_RATE_LIMIT (100) when the config API omits '
        'rate_limit; 100 is also a legitimate tenant limit, so a missing value is served as if it were real, '
        'with nothing logged.')),
    'reuse-hit': (
        QUALITY,
        'Reimplements the existing format_currency helper',
        'render_invoice_summary formats money by hand, duplicating format_currency in utils/formatting.py.'),
    'style-hit': (
        QUALITY,
        'get_user_settings writes to the database',
        'The name promises a pure read, but the function performs a database write on first call.'),
    'test-quality-hit': (
        QUALITY,
        'Test asserts on its own mock',
        ('test_rejects_invalid_email mocks validate() and then asserts the return value it configured on the '
        'mock, so the test proves nothing about validation.')),
    'test-adequacy-f1-hit': (
        BUG,
        'OrderProcessor has no tests',
        ('The new public OrderProcessor carries the loyalty-discount logic but has no direct test, so a change '
        'to that logic passes the whole suite.')),
    'test-adequacy-f4-hit': (
        BUG,
        'Producer side of the InvoicePayload contract is untested',
        ('The test stubs an empty payload and only checks that publish is called; nothing asserts that the '
        'emitter publishes a populated InvoicePayload.')),
    'api-contract-apitruth-hit': (
        BUG,
        'json.loads called with a keyword argument that does not exist',
        ('load_config passes strict_mode=True to json.loads, which has no such parameter, so every call raises '
        'TypeError.')),
    'api-contract-commenttruth-hit': (
        BUG,
        'Docstring contradicts the behaviour of get_value',
        ('The docstring says get_value returns None for an absent key, but the code indexes the dict directly '
        'and raises KeyError.')),
    'latent-hazard-hit': (
        BUG,
        'A missing column silently becomes a legitimate value',
        ('read_subdepartment returns "" when the ZB61 column is missing, which downstream code reads as the '
        'legitimate "000 = None" sub-department, so column drift corrupts data without an error.')),
    'silentfail-nearmiss': (
        None,
        None,
        'the exception handling in fetch_user_profile (it logs the exception before returning None)'),
    'reuse-nearmiss': (
        None,
        None,
        'the one-line slug logic in generate_report_filename duplicating slugify from utils/strings.py'),
    'style-nearmiss': (
        None,
        None,
        'the length of build_audit_report (it is long but linear, with no branching)'),
    'test-quality-nearmiss': (
        None,
        None,
        'the tests in tests/test_user_service.py as weak, tautological or false-green'),
    'test-adequacy-f1-nearmiss': (
        None,
        None,
        'TaxCalculator as lacking tests (tests/test_tax_calculator.py tests it directly)'),
    'api-contract-nearmiss': (
        None,
        None,
        'the json.loads call in load_config as having a wrong signature, or its docstring as inaccurate'),
    'latent-hazard-nearmiss': (
        None,
        None,
        'the required column read raising KeyError on a missing column'),
}

MOVE_ASIDE = re.compile(r'^mv (\S+) (\.\S+\.planted)$')
COMMIT = re.compile(r'^git commit -q -m "([^"]+)"$')


class PortError(Exception):
    """A corpus fixture does not follow the expected two-commit shape."""


def load_source(fixture_id):
    out = subprocess.run(
        ['yq', '-o=json', '.', str(CORPUS / fixture_id / 'source.yaml')],
        check=True,
        capture_output=True,
        text=True).stdout
    return json.loads(out)


def split_setup(command):
    """Return (base files, head files, base subject, head subject) from a corpus setup command."""
    head, base, subjects = [], [], []
    for line in command.splitlines():
        line = line.strip()
        moved = MOVE_ASIDE.match(line)
        if moved:
            head.append(moved.group(1))
            continue
        commit = COMMIT.match(line)
        if commit:
            subjects.append(commit.group(1))
            continue
        if line.startswith('git add ') and not subjects:
            base.extend(shlex.split(line)[2:])
    if not head or not base or len(subjects) < 2:
        raise PortError('setup does not move planted files aside and commit base then head')
    return sorted(base), sorted(head), subjects[0], subjects[-1]


def port(fixture_id):
    source = load_source(fixture_id)
    src_dir = source['source_path'].rstrip('/')
    base, head, base_subject, head_subject = split_setup(source['setup']['command'])
    on_disk = sorted(
        p.relative_to(REPO_ROOT / src_dir).as_posix()
        for p in (REPO_ROOT / src_dir).rglob('*') if p.is_file())
    if sorted(base + head) != on_disk:
        raise PortError(f'{fixture_id}: setup covers {sorted(base + head)}, the directory holds {on_disk}')

    goal = re.search(r'^- goal: (.+)$', source['intent_ledger'], flags=re.MULTILINE)
    if not goal:
        raise PortError(f'{fixture_id}: intent_ledger has no goal line')
    goal = goal.group(1).strip().rstrip('.')
    klass, title, text = CURATED[fixture_id]
    planted = source['planted']
    line = int(planted['line'])
    manifest = {
        'id': fixture_id,
        'set': 'sanity',
        'source': 'corpus',
        'files_from': src_dir,
        'base': base,
        'head': head,
        # The corpus READMEs name the planted defect; the eval replaces them with this neutral text.
        'readme': f'# Project\n\n{base_subject.removeprefix("base: ").capitalize()}.\n',
        'base_title': base_subject,
        'commit_title': head_subject,
        # /pre-review's intent rule needs at least two sentences; the corpus ledger gives one goal.
        'intent': f'This change will {goal}. Nothing else in the repository changes.',
        'issues': [],
    }
    if klass is None:
        manifest['near_miss'] = {'file': planted['file'], 'pattern': text}
    else:
        manifest['issues'].append({
            'key': 'i1',
            'title': title,
            'description': text,
            'file': planted['file'],
            'lines': None if line == 0 else [max(1, line - LINE_SLACK), line + LINE_SLACK],
            'class': klass,
        })
    dest = FIXTURES / fixture_id
    dest.mkdir(parents=True, exist_ok=True)
    (dest / 'fixture.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'ported {fixture_id}')


def main():
    failed = 0
    for fixture_id in CURATED:
        try:
            port(fixture_id)
        except PortError as err:
            print(f'port_corpus: {err}', file=sys.stderr)
            failed += 1
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
