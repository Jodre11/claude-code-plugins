#!/usr/bin/env python3
"""Prepare earlier result files for aggregate.py after a grader or fixture fix.

Two corrections, each recorded in the results doc when used:

- `--drop <fixture>...` removes every run of those fixtures, for fixtures whose prompt changed
  after the file was written, so only reruns against the committed fixture count.
- `--regrade <grader>...` re-applies a regex grader's current pattern (from build_cases.py) to
  the run's final message, for a pattern fixed after the run. Only last-message regex graders
  can be regraded this way; the final message is read from an llm grader's evidence.

Writes a curated copy beside each input (`<name>.curated.json`) and prints what changed.
"""

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_cases import graders  # noqa: E402  (the current grader definitions)

FLAGS = {'i': re.IGNORECASE, 'm': re.MULTILINE, 's': re.DOTALL}


def final_message(run):
    return next((g['evidence'] for g in run.get('graders', []) if g.get('evidence')), None)


def current_regexes(names):
    """Return {grader name: compiled pattern} for last-message regex graders, from a decision-set hybrid case."""
    defs = graders({'set': 'decision', 'source': 'qodo', 'issues': []}, 'hybrid')
    found = {}
    for g in defs:
        if g['name'] in names:
            if g['type'] != 'regex' or g.get('target', 'last_message') != 'last_message':
                raise SystemExit(f'curate: {g["name"]} is not a last-message regex grader')
            flags = 0
            for ch in g.get('flags', ''):
                flags |= FLAGS[ch]
            found[g['name']] = re.compile(g['pattern'], flags)
    missing = set(names) - set(found)
    if missing:
        raise SystemExit(f'curate: no such grader {sorted(missing)}')
    return found


def main():
    parser = argparse.ArgumentParser(description='Drop stale fixtures and regrade fixed regex graders.')
    parser.add_argument('results', nargs='+', type=Path)
    parser.add_argument('--drop', nargs='*', default=[], help='fixture ids whose runs are removed')
    parser.add_argument('--regrade', nargs='*', default=[], help='last-message regex graders to re-apply')
    args = parser.parse_args()

    patterns = current_regexes(args.regrade)
    for path in args.results:
        result = json.loads(path.read_text(encoding='utf-8'))
        dropped = flipped = 0
        kept = []
        for case in result.get('cases', []):
            fixture_id = case['name'].rpartition('-')[0]
            if fixture_id in args.drop:
                dropped += len(case.get('arms', {}).get('with', []))
                continue
            for run in case.get('arms', {}).get('with', []):
                text = final_message(run)
                for g in run.get('graders', []):
                    if g['name'] in patterns and text is not None:
                        now = bool(patterns[g['name']].search(text))
                        if now != g.get('passed'):
                            g['passed'] = now
                            g['explanation'] = f'regraded by curate.py with the current pattern: {now}'
                            flipped += 1
            kept.append(case)
        result['cases'] = kept
        out = path.with_name(path.stem + '.curated.json')
        out.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print(f'{path}: dropped {dropped} runs, regraded {flipped} verdicts -> {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
