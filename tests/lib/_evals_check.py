#!/usr/bin/env python3
"""Structural checks on evals/fixtures/ and a rendered cases directory; prints one line per problem.

Usage: _evals_check.py fixtures | _evals_check.py cases <cases-dir>
"""

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / 'evals' / 'fixtures'
LICENCES = {'MIT', 'Apache-2.0'}
CLASSES = {'bug', 'rule', 'quality'}


def check_fixtures():
    problems, sets = [], {'decision': 0, 'sanity': 0}
    for entry in sorted(FIXTURES.iterdir()):
        if entry.is_dir() and not (entry / 'fixture.json').is_file():
            problems.append(f'{entry.name}: no fixture.json (a partial port?)')
    for path in sorted(FIXTURES.glob('*/fixture.json')):
        f = json.loads(path.read_text(encoding='utf-8'))
        fid = path.parent.name
        for key in ('id', 'set', 'source', 'commit_title', 'intent', 'issues'):
            if key not in f:
                problems.append(f'{fid}: missing {key}')
        if f.get('id') != fid:
            problems.append(f'{fid}: id {f.get("id")} does not match its directory')
        sets[f.get('set')] = sets.get(f.get('set'), 0) + 1
        if len(f.get('intent', '').split()) <= 7:
            problems.append(f'{fid}: intent is too short for the suite\'s intent rule')
        for issue in f.get('issues', []):
            if issue.get('class') not in CLASSES:
                problems.append(f'{fid}/{issue.get("key")}: class {issue.get("class")!r}')
            lines = issue.get('lines')
            if lines is not None and (len(lines) != 2 or not all(isinstance(n, int) for n in lines)
                                      or lines[0] > lines[1]):
                problems.append(f'{fid}/{issue.get("key")}: bad lines {lines}')
        if 'near_miss' in f and f.get('issues'):
            problems.append(f'{fid}: a near-miss fixture must carry no issues')
        if not f.get('issues') and 'near_miss' not in f:
            problems.append(f'{fid}: nothing to grade')
        if f.get('source') == 'qodo':
            root = path.parent
            if f['upstream'].get('licence') not in LICENCES:
                problems.append(f'{fid}: licence {f["upstream"].get("licence")} is not permissive')
            if not (root / 'UPSTREAM-LICENSE').is_file():
                problems.append(f'{fid}: no UPSTREAM-LICENSE')
            if not (root / 'files' / 'base' / 'CLAUDE.md').is_file():
                problems.append(f'{fid}: the repo rules are not in the base CLAUDE.md')
        elif f.get('source') == 'corpus':
            src = REPO_ROOT / f['files_from']
            for rel in f['base'] + f['head']:
                if not (src / rel).is_file():
                    problems.append(f'{fid}: {f["files_from"]}/{rel} is missing')
    if sets != {'decision': 12, 'sanity': 17}:
        problems.append(f'expected 12 decision and 17 sanity fixtures, found {sets}')
    return problems


def check_cases(cases_dir):
    problems = []
    for path in sorted(Path(cases_dir).glob('*/case.yaml')):
        case = json.loads(path.read_text(encoding='utf-8'))
        name = path.parent.name
        arm = name.rpartition('-')[2]
        ex = case['execution']
        if case['name'] != name:
            problems.append(f'{name}: case name {case["name"]}')
        if ex['max_turns'] != 200 or ex['timeout_seconds'] != 3600:
            problems.append(f'{name}: turn or time limit would cut a review short')
        # Plugin paths are relative to the case directory once it sits in evals/cases/.
        anchor = REPO_ROOT / 'evals' / 'cases' / name
        for plugin in case['plugins']:
            if not ((anchor / plugin).resolve() / '.claude-plugin' / 'plugin.json').is_file():
                problems.append(f'{name}: plugin path {plugin} does not resolve to a plugin')
        names = [g['name'] for g in case['graders']]
        if len(names) != len(set(names)):
            problems.append(f'{name}: duplicate grader names')
        if not any(n.startswith('valid-') for n in names):
            problems.append(f'{name}: no validity grader')
        if any('weight' in g for g in case['graders']):
            problems.append(f'{name}: weight is set; aggregate.py reads each grader on its own')
        if arm == 'hybrid' and 'valid-anthropic-ok' not in names:
            problems.append(f'{name}: hybrid arm without the anthropic validity grader')
        if not (path.parent / 'fixture.sh').is_file():
            problems.append(f'{name}: no fixture.sh')
    return problems


def main():
    problems = check_fixtures() if sys.argv[1] == 'fixtures' else check_cases(sys.argv[2])
    print('\n'.join(problems))


if __name__ == '__main__':
    main()
