#!/usr/bin/env python3
"""Write a synthetic `claude plugin eval --json` result for evals/tools/aggregate.py tests.

Scenarios (argv[1]):
  same    every arm finds every issue at equal cost             -> KEEP
  hybrid  only the hybrid finds the bugs, at 1.2x the suite cost -> HYBRID
  switch  every arm finds everything; native costs a quarter     -> SWITCH candidate
  invalid as same, but one decision case's native run is invalid -> that PR is dropped
"""

import json
import sys
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[2] / 'evals' / 'fixtures'
COST = {
    'same': {'suite': 2.0, 'native': 2.0, 'hybrid': 2.0},
    'hybrid': {'suite': 2.0, 'native': 2.0, 'hybrid': 2.4},
    'switch': {'suite': 2.0, 'native': 0.5, 'hybrid': 2.0},
    'invalid': {'suite': 2.0, 'native': 2.0, 'hybrid': 2.0},
}


def grader(name, passed, llm=True):
    out = {'name': name, 'type': 'llm' if llm else 'tool_used', 'passed': passed, 'scored': True}
    if llm:
        out['judgeVotes'] = ['PASS'] * 3 if passed else ['FAIL'] * 3
    return out


def run(fixture, arm, scenario, invalid):
    graders = [grader('valid-review-core' if arm != 'native' else 'valid-native-ran', not invalid, arm == 'native')]
    for issue in fixture['issues']:
        found = not (scenario == 'hybrid' and issue['class'] == 'bug' and arm != 'hybrid')
        graders.append(grader(f'detect-{issue["key"]}', found))
        if fixture['source'] == 'qodo' and issue['class'] == 'bug':
            graders.append(grader(f'mustfix-{issue["key"]}', found))
    if fixture['source'] == 'qodo':
        graders.append(grader('noise', True))
    if 'near_miss' in fixture:
        graders.append(grader('near-miss', True))
    return {'graders': graders, 'costUsd': COST[scenario][arm], 'judgeCostUsd': 0.1, 'durationSeconds': 600}


def main():
    scenario, out = sys.argv[1], Path(sys.argv[2])
    fixtures = sorted((json.loads(p.read_text()) for p in FIXTURES.glob('*/fixture.json')), key=lambda f: f['id'])
    first_decision = next(f['id'] for f in fixtures if f['set'] == 'decision')
    cases = []
    for fixture in fixtures:
        for arm in ('suite', 'native', 'hybrid'):
            invalid = scenario == 'invalid' and fixture['id'] == first_decision and arm == 'native'
            cases.append({
                'name': f'{fixture["id"]}-{arm}',
                'arms': {'with': [run(fixture, arm, scenario, invalid)]},
            })
    out.write_text(json.dumps({'cases': cases}), encoding='utf-8')
    print(first_decision)


if __name__ == '__main__':
    main()
