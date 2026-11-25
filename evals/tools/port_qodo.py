#!/usr/bin/env python3
"""Port Qodo PR-Review-Bench pull requests into offline eval fixtures.

For each permissively licensed repo, takes the lowest-numbered benchmark PRs whose diff is
large enough for the suite's full review route, and vendors the base and head versions of
every touched file, the upstream LICENSE, the repo's extracted rules (as the fixture's
CLAUDE.md) and the planted issues into evals/fixtures/qodo-<repo>-<pr>/. The eval child has no
network, so a fixture must carry everything its scaffold needs. Uses the `gh` CLI for GitHub
access; run it on the host, never inside an eval.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / 'evals' / 'fixtures'
DATASET = 'https://huggingface.co/datasets/Qodo/PR-Review-Bench/resolve/main/'
BENCH_FILE = 'git_code_review_bench_100_w_open_prs.jsonl'
RULES_FILE = 'rules_for_repo.jsonl'
ORG = 'agentic-review-benchmarks'
REPOS = ('Ghost', 'aspnetcore', 'prefect', 'tauri')
ALLOWED_LICENCES = ('MIT', 'Apache-2.0')
# The suite's lightweight route takes diffs with at most this many files and lines.
LIGHTWEIGHT_MAX_FILES = 5
LIGHTWEIGHT_MAX_LINES = 150


class PortError(Exception):
    """A benchmark PR cannot be ported faithfully."""


def gh_json(path):
    out = subprocess.run(['gh', 'api', path], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def gh_pages(path):
    out = subprocess.run(
        ['gh', 'api', '--paginate', '--slurp', path],
        check=True,
        capture_output=True,
        text=True).stdout
    return [item for page in json.loads(out) for item in page]


def gh_raw(repo, file_path, ref):
    """Return the bytes of file_path at ref, or None when it does not exist there."""
    api = f'repos/{ORG}/{repo}/contents/{quote(file_path)}?ref={ref}'
    proc = subprocess.run(
        ['gh', 'api', '-H', 'Accept: application/vnd.github.raw+json', api],
        check=False,
        capture_output=True)
    if proc.returncode != 0:
        if b'Not Found' in proc.stderr or b'404' in proc.stderr:
            return None
        raise PortError(f'cannot fetch {repo}:{file_path}@{ref}: {proc.stderr.decode(errors="replace")}')
    return proc.stdout


def load_jsonl(name, cache_dir):
    path = cache_dir / name
    if not path.exists():
        with urllib.request.urlopen(DATASET + name) as resp:
            path.write_bytes(resp.read())
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]


def render_rules(repo, rules):
    """Render the dataset's extracted rules as a CLAUDE.md the reviewers can read."""
    lines = [f'# {repo}: project rules', '']
    for rule in rules:
        lines += [f'## {rule["title"]}', '', rule['objective'].strip(), '']
        if rule.get('success_criteria'):
            lines += [f'- Do: {rule["success_criteria"].strip()}']
        if rule.get('failure_criteria'):
            lines += [f'- Do not: {rule["failure_criteria"].strip()}']
        lines.append('')
    return '\n'.join(lines)


def has_narrative(text):
    """Approximate /pre-review's intent rule: the first block is prose, with two sentences and over seven words."""
    for block in re.split(r'\n\s*\n', text.strip()):
        block = block.strip()
        if not block:
            continue
        if re.match(r'(#|[-*+] |\d+\. |\||```|<details)', block):
            return False
        return len(re.findall(r'[^.!?]+[.!?](?=\s|$)', block)) >= 2 and len(block.split()) > 7
    return False


def describe(pr):
    """Return (title, intent) from a benchmark PR, as the original author wrote them.

    The benchmark wraps the upstream title and description in its own markup and keeps any
    Cursor Bugbot summary, which is another reviewer's output; both are stripped.
    """
    body = (pr.get('body') or '').replace('\r', '')
    body = re.sub(r'<!--\s*CURSOR_SUMMARY\s*-->.*?<!--\s*/CURSOR_SUMMARY\s*-->', '', body, flags=re.DOTALL)
    body = re.sub(r'<!--.*?-->', '', body, flags=re.DOTALL)
    # Screenshots are useless offline, and presigned image URLs carry credentials.
    body = re.sub(r'!\[[^\]]*\]\([^)]*\)', '', body)
    body = re.sub(r'\S*[?&](?:token|sig|signature|X-Amz-[A-Za-z]+)=\S*', '', body)
    title = re.search(r'\*\*Original PR Title\*\*:[ \t]*(.+)', body)
    title = title.group(1).strip() if title else re.sub(r'^Code Review Bench PR #\d+ - ', '', pr['title'])
    desc = re.search(r'\*\*Original PR Description\*\*:(.*?)(?=\*\*Original PR URL\*\*|\Z)', body, flags=re.DOTALL)
    desc = desc.group(1).strip() if desc else ''
    if len(desc.split()) < 8:
        # The suite's intent rule needs two sentences; say plainly that upstream gave no more.
        quoted = f' beyond "{desc}"' if desc else ''
        desc = f'{title.rstrip(".")}. The original pull request gave no other description{quoted}.'
    elif not has_narrative(desc):
        # A bot body or a bullet list would halt the suite's intent check at random, which the eval must not
        # measure; lead with a plain statement and keep the original text unchanged below it.
        desc = f'This change: {title.rstrip(".")}. The original description follows as written.\n\n{desc}'
    return title, desc


def write_file(root, rel, data):
    target = (root / rel).resolve()
    if root.resolve() not in target.parents:
        raise PortError(f'path escapes the fixture: {rel}')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)


def port_pr(row, rules_md, licence, licence_path, dest):
    """Vendor one benchmark PR into dest; return the fixture manifest."""
    repo = row['repo']
    number = int(row['pr_url_to_review'].rstrip('/').rsplit('/', 1)[1])
    pr = gh_json(f'repos/{ORG}/{repo}/pulls/{number}')
    base_sha, head_sha = pr['base']['sha'], pr['head']['sha']
    title, intent = describe(pr)
    files = gh_pages(f'repos/{ORG}/{repo}/pulls/{number}/files?per_page=100')
    if len(files) != pr['changed_files']:
        raise PortError(f'{repo}#{number}: file list truncated ({len(files)} of {pr["changed_files"]})')

    removed, skipped = [], []
    for f in files:
        name, status = f['filename'], f['status']
        if 'patch' not in f and status != 'removed' and f.get('changes', 0) > 0:
            skipped.append(name)
            continue
        if status == 'renamed':
            old = f['previous_filename']
            removed.append(old)
            data = gh_raw(repo, old, base_sha)
            if data is not None:
                write_file(dest / 'files' / 'base', old, data)
        elif status in ('modified', 'changed', 'removed'):
            data = gh_raw(repo, name, base_sha)
            if data is None:
                raise PortError(f'{repo}#{number}: {name} missing at base')
            write_file(dest / 'files' / 'base', name, data)
            if status == 'removed':
                removed.append(name)
        if status != 'removed':
            data = gh_raw(repo, name, head_sha)
            if data is None:
                raise PortError(f'{repo}#{number}: {name} missing at head')
            write_file(dest / 'files' / 'head', name, data)

    upstream_licence = gh_raw(repo, licence_path, base_sha)
    if upstream_licence is None:
        raise PortError(f'{repo}: no {licence_path} at {base_sha}')
    write_file(dest, 'UPSTREAM-LICENSE', upstream_licence)
    write_file(dest / 'files' / 'base', 'CLAUDE.md', rules_md.encode('utf-8'))

    issues = []
    for k, issue in enumerate(row['issues'], 1):
        start, end = issue['start_line'], issue['end_line']
        issues.append({
            'key': f'i{k}',
            'title': issue['title'],
            'description': issue['description'],
            # Some dataset issues carry no location; they are graded on the description alone.
            'file': issue['file_path'] or None,
            'lines': None if start is None else [start, end if end is not None else start],
            'class': 'rule' if issue.get('rule_name') else 'bug',
        })
    return {
        'id': dest.name,
        'set': 'decision',
        'source': 'qodo',
        'upstream': {
            'repo': repo,
            'pr': number,
            'url': row['pr_url_to_review'],
            'licence': licence,
            'base_sha': base_sha,
            'head_sha': head_sha,
        },
        'commit_title': title,
        'intent': intent,
        'removed': sorted(set(removed)),
        'skipped_binary': skipped,
        'diff': {'files': pr['changed_files'], 'lines': pr['additions'] + pr['deletions']},
        'issues': issues,
    }


def full_route(pr):
    return (pr['changed_files'] > LIGHTWEIGHT_MAX_FILES
            or pr['additions'] + pr['deletions'] > LIGHTWEIGHT_MAX_LINES)


def main():
    parser = argparse.ArgumentParser(description='Port Qodo PR-Review-Bench PRs into evals/fixtures/.')
    parser.add_argument('--per-repo', type=int, default=3, help='PRs to port per repo (default 3)')
    parser.add_argument('--cache-dir', type=Path, required=True, help='where the dataset files are cached')
    parser.add_argument('--repos', nargs='*', default=list(REPOS), help='repos to port (default: all four)')
    parser.add_argument(
        '--refresh-intent',
        action='store_true',
        help='for fixtures already ported, re-derive only the commit title and intent')
    args = parser.parse_args()

    args.cache_dir.mkdir(parents=True, exist_ok=True)
    bench = load_jsonl(BENCH_FILE, args.cache_dir)
    rules = {r['repo']: r['extracted_rules'] for r in load_jsonl(RULES_FILE, args.cache_dir)}
    for repo in args.repos:
        if repo not in REPOS:
            print(f'port_qodo: {repo} is not one of the permissive repos {REPOS}', file=sys.stderr)
            return 2
        detected = gh_json(f'repos/{ORG}/{repo}/license')
        licence, licence_path = detected['license']['spdx_id'], detected['path']
        if licence not in ALLOWED_LICENCES:
            print(f'port_qodo: {repo} is {licence}; only {ALLOWED_LICENCES} may be vendored', file=sys.stderr)
            return 2
        rows = sorted(
            (r for r in bench if r['repo'] == repo),
            key=lambda r: int(r['pr_url_to_review'].rstrip('/').rsplit('/', 1)[1]))
        ported = 0
        for row in rows:
            if ported == args.per_repo:
                break
            number = int(row['pr_url_to_review'].rstrip('/').rsplit('/', 1)[1])
            if not full_route(gh_json(f'repos/{ORG}/{repo}/pulls/{number}')):
                print(f'skip {repo}#{number}: small enough for the lightweight route')
                continue
            dest = FIXTURES / f'qodo-{repo.lower()}-{number}'
            manifest_path = dest / 'fixture.json'
            if manifest_path.exists():
                if args.refresh_intent:
                    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
                    manifest['commit_title'], manifest['intent'] = describe(
                        gh_json(f'repos/{ORG}/{repo}/pulls/{number}'))
                    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
                    print(f'refreshed {dest.name}: title and intent')
                else:
                    print(f'keep {dest.name}: already ported')
                ported += 1
                continue
            shutil.rmtree(dest, ignore_errors=True)
            try:
                manifest = port_pr(row, render_rules(repo, rules.get(repo, [])), licence, licence_path, dest)
            except PortError as err:
                shutil.rmtree(dest, ignore_errors=True)
                print(f'skip {repo}#{number}: {err}', file=sys.stderr)
                continue
            (dest / 'fixture.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
            print(f'ported {dest.name}: {len(manifest["issues"])} issues, {manifest["diff"]}')
            ported += 1
        if ported < args.per_repo:
            print(f'port_qodo: only {ported} of {args.per_repo} {repo} PRs ported', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
