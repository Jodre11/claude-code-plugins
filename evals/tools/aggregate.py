#!/usr/bin/env python3
"""Turn `claude plugin eval --json` results into the review eval's comparison and decision.

Reads one or more result files (a first run plus any reruns), keeps each case's valid runs,
and computes, per arm on the decision set: bug recall (BR), rule recall (RR), noise pass rate
(NP), must-fix recall, cost and wall-clock. A cluster bootstrap over PRs gives a 90 % CI for
each between-arm difference, and the decision rule from docs/specs/2026-11-25-review-eval.md
picks KEEP, HYBRID or a SWITCH candidate. The sanity set is reported separately and never
enters the rule.
"""

import argparse
import json
import random
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / 'evals' / 'fixtures'
ARMS = ('suite', 'native', 'hybrid')
RESAMPLES = 10_000
CI = 0.90
SEED = 20261125
UNANIMITY_FLOOR = 0.85


def load_fixtures():
    return {p.parent.name: json.loads(p.read_text(encoding='utf-8')) for p in FIXTURES.glob('*/fixture.json')}


def split_case(name):
    fixture_id, _, arm = name.rpartition('-')
    if arm not in ARMS or not fixture_id:
        raise ValueError(f'case name {name!r} is not <fixture>-<arm>')
    return fixture_id, arm


def vote_value(vote):
    if isinstance(vote, bool):
        return vote
    if isinstance(vote, str):
        return vote.strip().upper().startswith('PASS')
    if isinstance(vote, dict):
        for key in ('passed', 'pass', 'verdict', 'vote', 'result'):
            if key in vote:
                return vote_value(vote[key])
    return None


def unanimous(grader):
    """Return True/False for an llm grader's vote agreement, or None when it carries no votes."""
    votes = grader.get('judgeVotes')
    if isinstance(votes, dict):
        passes, fails = votes.get('pass', votes.get('passed')), votes.get('fail', votes.get('failed'))
        if isinstance(passes, int) and isinstance(fails, int):
            return passes == 0 or fails == 0
        return None
    if not isinstance(votes, list) or not votes:
        return None
    values = {vote_value(v) for v in votes}
    return None if None in values else len(values) == 1


def collect_runs(paths):
    """Return {(fixture id, arm): [run, ...]} across every result file, in file order."""
    runs = {}
    for path in paths:
        result = json.loads(Path(path).read_text(encoding='utf-8'))
        for case in result.get('cases', []):
            key = split_case(case['name'])
            for run in case.get('arms', {}).get('with', []):
                runs.setdefault(key, []).append(run)
    return runs


def grader_map(run):
    return {g['name']: g for g in run.get('graders', [])}


def is_valid(run):
    graders = grader_map(run)
    checks = [g for name, g in graders.items() if name.startswith('valid-')]
    return bool(checks) and all(g.get('passed') for g in checks) and not run.get('error')


def rate(values):
    values = list(values)
    return sum(values) / len(values) if values else None


def per_fixture(fixture, runs):
    """Per-issue detection rates and per-run noise, must-fix, cost and duration for one (fixture, arm)."""
    graded = [grader_map(r) for r in runs]

    def passed(name):
        return [bool(g[name].get('passed')) for g in graded if name in g]

    return {
        'detect': {i['key']: rate(passed(f'detect-{i["key"]}')) for i in fixture['issues']},
        'mustfix': {i['key']: rate(passed(f'mustfix-{i["key"]}')) for i in fixture['issues'] if i['class'] == 'bug'},
        'noise': rate(passed('noise')),
        'near_miss': rate(passed('near-miss')),
        'route_full': rate(passed('route-full')),
        'cost': rate(r.get('costUsd', 0.0) for r in runs),
        'judge_cost': rate(r.get('judgeCostUsd', 0.0) for r in runs),
        'duration': rate(r.get('durationSeconds', 0.0) for r in runs),
    }


def pooled(stats, fixtures, ids, metric):
    """Pool a metric over the given PR ids (duplicates allowed, for the bootstrap)."""
    if metric in ('bug', 'rule'):
        values = [stats[i]['detect'][issue['key']] for i in ids for issue in fixtures[i]['issues']
                  if issue['class'] == metric and stats[i]['detect'][issue['key']] is not None]
    elif metric == 'mustfix':
        values = [v for i in ids for v in stats[i]['mustfix'].values() if v is not None]
    else:
        values = [stats[i][metric] for i in ids if stats[i][metric] is not None]
    return rate(values)


def bootstrap_diff(a, b, fixtures, ids, metric, rng):
    """Point estimate and CI of pooled(b) - pooled(a) under a cluster bootstrap over ids, or Nones."""
    hi, lo = pooled(b, fixtures, ids, metric), pooled(a, fixtures, ids, metric)
    if hi is None or lo is None:
        return None, None, None
    point = hi - lo
    diffs = []
    for _ in range(RESAMPLES):
        sample = [rng.choice(ids) for _ in ids]
        hi, lo = pooled(b, fixtures, sample, metric), pooled(a, fixtures, sample, metric)
        if hi is not None and lo is not None:
            diffs.append(hi - lo)
    diffs.sort()
    tail = (1 - CI) / 2
    return point, diffs[int(tail * len(diffs))], diffs[min(len(diffs) - 1, int((1 - tail) * len(diffs)))]


def decide(diffs, cost):
    """Apply the spec's rule; diffs maps (comparison, metric) to (point, lo, hi).

    A metric with no estimate (None) never satisfies a bound, so the rule falls through to KEEP.
    """
    diffs = {k: (v if v[0] is not None else (0.0, float('-inf'), float('inf'))) for k, v in diffs.items()}
    lines = []
    reference = 'suite'
    if 'hybrid' in cost:
        br, rr, np_ = (diffs[('hybrid', m)] for m in ('bug', 'rule', 'noise'))
        ratio = cost['hybrid'] / cost['suite']
        hybrid = br[1] > 0 and br[0] >= 0.05 and rr[1] > -0.05 and np_[1] > -0.10 and ratio <= 1.5
        lines.append(f'Rule 1 (HYBRID): {"holds" if hybrid else "does not hold"} '
                     f'(BR lower bound {br[1]:+.3f}, point {br[0]:+.3f}; RR lower {rr[1]:+.3f}; '
                     f'NP lower {np_[1]:+.3f}; cost {ratio:.2f}x)')
        if hybrid:
            reference = 'hybrid'
    if 'native' in cost:
        key = 'native' if reference == 'suite' else 'native-vs-hybrid'
        br, rr, np_ = (diffs[(key, m)] for m in ('bug', 'rule', 'noise'))
        ratio = cost['native'] / cost[reference]
        switch = br[1] > -0.05 and rr[1] > -0.05 and np_[1] > -0.10 and ratio <= 0.50
        lines.append(f'Rule 2 (SWITCH candidate, against {reference}): {"holds" if switch else "does not hold"} '
                     f'(BR lower {br[1]:+.3f}; RR lower {rr[1]:+.3f}; NP lower {np_[1]:+.3f}; cost {ratio:.2f}x)')
        if switch:
            return 'SWITCH candidate (the user confirms)', lines
    if reference == 'hybrid':
        return 'HYBRID', lines
    wide = [m for (_, m), (point, lo, hi) in diffs.items() if abs(point) >= 0.05 and lo < 0 < hi]
    if wide:
        lines.append('Point estimates differ by 5 pp or more inside an inconclusive CI '
                     f'({", ".join(sorted(set(wide)))}): port more Qodo PRs before deciding.')
    return 'KEEP', lines


def pct(value):
    return '-' if value is None else f'{100 * value:.1f}%'


def pp(value):
    return '-' if value is None else f'{100 * value:+.1f}'


def money(value):
    return '-' if value is None else f'${value:.2f}'


def minutes(value):
    return '-' if value is None else f'{value / 60:.1f} min'


def main():
    parser = argparse.ArgumentParser(description='Aggregate review eval results into the decision table.')
    parser.add_argument('results', nargs='+', type=Path, help='result.json files (first run, then reruns)')
    parser.add_argument('--out', type=Path, help='write the markdown report here instead of stdout')
    parser.add_argument(
        '--arms',
        nargs='+',
        choices=ARMS,
        default=list(ARMS),
        help='compare only these arms, so PRs run without the others still pair (default: all three)')
    args = parser.parse_args()

    fixtures = load_fixtures()
    runs = {k: v for k, v in collect_runs(args.results).items() if k[1] in args.arms}
    out = ['# Review eval results', '']

    valid, invalid = {}, []
    for key, case_runs in sorted(runs.items()):
        good = [r for r in case_runs if is_valid(r)]
        if len(good) < len(case_runs):
            invalid.append(f'{key[0]}-{key[1]}: {len(case_runs) - len(good)} of {len(case_runs)} runs invalid')
        if good:
            valid[key] = good

    arms = [a for a in ARMS if any(k[1] == a for k in runs)]
    decision_ids = sorted(i for i, f in fixtures.items() if f['set'] == 'decision'
                          and all((i, a) in valid for a in arms))
    dropped = sorted(i for i, f in fixtures.items() if f['set'] == 'decision'
                     and any((i, a) in runs for a in arms) and i not in decision_ids)

    out += ['## Validity', '']
    out += [f'- {line}' for line in invalid] or ['- every run valid']
    if dropped:
        out.append(f'- dropped from the paired comparison (invalid in some arm): {", ".join(dropped)}')
    out.append('')

    agreement = []
    for a in ARMS:
        votes = [unanimous(g) for (_, arm), case_runs in valid.items() if arm == a
                 for r in case_runs for g in r.get('graders', [])]
        votes = [v for v in votes if v is not None]
        if votes:
            share = sum(votes) / len(votes)
            flag = '' if share >= UNANIMITY_FLOOR else f' (below {UNANIMITY_FLOOR:.0%}: re-examine the criteria)'
            agreement.append(f'- {a}: {share:.1%} of {len(votes)} llm verdicts unanimous{flag}')
    if agreement:
        out += ['## Judge agreement', ''] + agreement + ['']

    stats = {a: {i: per_fixture(fixtures[i], valid[(i, a)]) for i in decision_ids} for a in arms}
    if decision_ids:
        out += [f'## Decision set ({len(decision_ids)} PRs)', '',
                '| Arm | BR | RR | NP | Must-fix | Full route | Cost/review | Judge cost | Wall-clock |',
                '|---|---|---|---|---|---|---|---|---|']
        cost = {}
        for a in arms:
            s = stats[a]
            cost[a] = pooled(s, fixtures, decision_ids, 'cost')
            out.append(
                f'| {a} | {pct(pooled(s, fixtures, decision_ids, "bug"))} '
                f'| {pct(pooled(s, fixtures, decision_ids, "rule"))} '
                f'| {pct(pooled(s, fixtures, decision_ids, "noise"))} '
                f'| {pct(pooled(s, fixtures, decision_ids, "mustfix"))} '
                f'| {pct(pooled(s, fixtures, decision_ids, "route_full"))} '
                f'| {money(cost[a])} | {money(pooled(s, fixtures, decision_ids, "judge_cost"))} '
                f'| {minutes(pooled(s, fixtures, decision_ids, "duration"))} |')
        out.append('')

        rng = random.Random(SEED)
        diffs = {}
        pairs = [(a, 'suite', a) for a in ('hybrid', 'native') if a in arms and 'suite' in arms]
        if 'hybrid' in arms and 'native' in arms:
            pairs.append(('native-vs-hybrid', 'hybrid', 'native'))
        if pairs:
            out += [f'Differences, {CI:.0%} cluster-bootstrap CI over PRs ({RESAMPLES} resamples):', '',
                    '| Comparison | Metric | Point | CI |', '|---|---|---|---|']
            for label, base, arm in pairs:
                for metric in ('bug', 'rule', 'noise', 'mustfix'):
                    point, lo, hi = bootstrap_diff(stats[base], stats[arm], fixtures, decision_ids, metric, rng)
                    diffs[(label, metric)] = (point, lo, hi)
                    out.append(f'| {arm} − {base} | {metric} | {pp(point)} pp | [{pp(lo)}, {pp(hi)}] |')
            out.append('')
            if 'suite' in cost:
                verdict, reasons = decide(diffs, cost)
                out += [f'**Decision: {verdict}**', ''] + [f'- {r}' for r in reasons] + ['']

    sanity = sorted(i for i, f in fixtures.items() if f['set'] == 'sanity' and any((i, a) in valid for a in arms))
    if sanity:
        out += ['## Sanity set (not in the rule; the suite was tuned on these)', '',
                '| Fixture | ' + ' | '.join(arms) + ' |', '|---|' + '---|' * len(arms)]
        for i in sanity:
            cells = []
            for a in arms:
                if (i, a) not in valid:
                    cells.append('invalid')
                    continue
                s = per_fixture(fixtures[i], valid[(i, a)])
                value = s['near_miss'] if 'near_miss' in fixtures[i] else rate(s['detect'].values())
                cells.append(pct(value))
            out.append(f'| {i} | ' + ' | '.join(cells) + ' |')
        out.append('')

    text = '\n'.join(out)
    if args.out:
        args.out.write_text(text, encoding='utf-8')
    else:
        print(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
