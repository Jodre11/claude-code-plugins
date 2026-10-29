#!/usr/bin/env python3
"""Render the generated regions in plugin markdown from their single sources.

Several prompt files must carry the same prose inline, because agents skip a "follow the
instructions in <file>" reference. A source file marks the shared text with a BEGIN SOURCE
and an END SOURCE comment line. A consumer holds a copy between a BEGIN GENERATED and an
END GENERATED comment line that name the source by its path relative to the plugin root.
This script rewrites every generated region from its source; --check writes nothing and
exits 1 when any region is stale. A source may itself contain generated regions: those are
rendered first, so a nested copy is always current.
"""

import argparse
import difflib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE_BEGIN = (
    '<!-- BEGIN SOURCE: copied into BEGIN GENERATED regions; '
    'after editing, run scripts/render-includes.py -->'
)
SOURCE_END = '<!-- END SOURCE -->'
GEN_BEGIN = re.compile(
    r'<!-- BEGIN GENERATED from (\S+): edit that file, then run scripts/render-includes\.py -->')
GEN_END = '<!-- END GENERATED from {} -->'


class RenderError(Exception):
    """A marker is malformed, unmatched, cyclic or points outside its plugin."""


class Renderer:
    """Renders markdown files, memoising each so a shared source is rendered once."""

    def __init__(self, plugins_dir):
        self.plugins_dir = plugins_dir
        self.rendered = {}
        self.active = []

    def rel(self, path):
        return path.relative_to(self.plugins_dir).as_posix()

    def plugin_root(self, path):
        return self.plugins_dir / path.relative_to(self.plugins_dir).parts[0]

    def render(self, path):
        """Return the text of path with every generated region refreshed from its source."""
        if path in self.rendered:
            return self.rendered[path]
        if path in self.active:
            chain = ' -> '.join(self.rel(p) for p in self.active + [path])
            raise RenderError(f'include cycle: {chain}')
        self.active.append(path)
        lines = path.read_text(encoding='utf-8').split('\n')
        out = []
        i = 0
        while i < len(lines):
            line = lines[i]
            match = GEN_BEGIN.fullmatch(line)
            if not match:
                if line.startswith('<!-- BEGIN GENERATED') or line.startswith('<!-- END GENERATED'):
                    raise RenderError(f'{self.rel(path)}:{i + 1}: malformed or unmatched marker: {line}')
                out.append(line)
                i += 1
                continue
            source = match.group(1)
            end = GEN_END.format(source)
            try:
                j = lines.index(end, i + 1)
            except ValueError:
                raise RenderError(f'{self.rel(path)}:{i + 1}: no matching "{end}"') from None
            out.append(line)
            out.extend(self.source_region(path, source, i + 1))
            out.append(end)
            i = j + 1
        self.active.pop()
        text = '\n'.join(out)
        self.rendered[path] = text
        return text

    def source_region(self, consumer, source, lineno):
        """Return the rendered lines between the source file's SOURCE markers."""
        root = self.plugin_root(consumer)
        path = (root / source).resolve()
        where = f'{self.rel(consumer)}:{lineno}'
        if root not in path.parents or not path.is_file():
            raise RenderError(f'{where}: source {source} is not a file inside {self.rel(root)}')
        lines = self.render(path).split('\n')
        begins = [k for k, line in enumerate(lines) if line == SOURCE_BEGIN]
        ends = [k for k, line in enumerate(lines) if line == SOURCE_END]
        if len(begins) != 1 or len(ends) != 1 or ends[0] < begins[0]:
            raise RenderError(f'{where}: {source} must hold exactly one BEGIN SOURCE ... END SOURCE pair')
        return lines[begins[0] + 1:ends[0]]


def main():
    parser = argparse.ArgumentParser(description='Render generated regions in plugin markdown from their sources.')
    parser.add_argument('--check', action='store_true', help='write nothing; exit 1 if any region is stale')
    parser.add_argument('--plugins-dir', type=Path, default=REPO / 'plugins', help=argparse.SUPPRESS)
    args = parser.parse_args()

    plugins_dir = args.plugins_dir.resolve()
    renderer = Renderer(plugins_dir)
    stale = {}
    try:
        for path in sorted(plugins_dir.rglob('*.md')):
            path = path.resolve()
            current = path.read_text(encoding='utf-8')
            text = renderer.render(path)
            if text != current:
                stale[path] = (current, text)
    except RenderError as err:
        print(f'render-includes: {err}', file=sys.stderr)
        return 2

    for path, (current, text) in stale.items():
        name = renderer.rel(path)
        if args.check:
            diff = difflib.unified_diff(
                current.split('\n'),
                text.split('\n'),
                f'{name} (committed)',
                f'{name} (rendered)',
                n=1,
                lineterm='')
            print('\n'.join(list(diff)[:40]))
        else:
            path.write_text(text, encoding='utf-8')
            print(f'rendered {name}')
    if args.check and stale:
        print(f'render-includes: {len(stale)} file(s) stale; run scripts/render-includes.py', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
