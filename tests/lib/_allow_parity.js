// Prints, per static tool, the Critical allow-list review-core.js enforces beside the one its agent
// file documents under `## Critical-allow-list:`, normalised for comparison. Env: CR = plugin root.
'use strict';
const fs = require('fs');
const path = require('path');

const cr = process.env.CR;
const src = fs.readFileSync(path.join(cr, 'workflows/review-core.js'), 'utf8');
const m = src.match(/\nconst STATIC_CRITICAL_ALLOW = (\{[\s\S]*?\n\})\n/);
if (!m) {
    process.stdout.write('NO_CONSTANT');
    process.exit(1);
}
const allow = new Function('return ' + m[1])();

const sorted = (xs) => [...new Set(xs)].sort();
const ticks = (s) => [...s.matchAll(/`([^`]+)`/g)].map((t) => t[1]);

// Bullets under the agent's allow-list heading. A bullet's identifiers are the backticked tokens
// before its ` — ` gloss; a **Pattern** bullet names an ID glob or title words instead.
function documented(tool) {
    const file = path.join(cr, 'agents', tool + '-reviewer.md');
    const text = fs.readFileSync(file, 'utf8');
    const start = text.indexOf('\n## Critical-allow-list:');
    if (start < 0) return null;
    const rest = text.slice(start + 1);
    const end = rest.indexOf('\n## ', 1);
    const section = end < 0 ? rest : rest.slice(0, end);
    const out = { ids: [], idGlobs: [], titleWords: [] };
    for (const line of section.split('\n')) {
        if (!line.startsWith('- ')) continue;
        if (line.includes('**Pattern (rule ID):**')) out.idGlobs.push(...ticks(line));
        else if (line.includes('**Pattern (title):**')) out.titleWords.push(...ticks(line).map((w) => w.toLowerCase()));
        else out.ids.push(...ticks(line.split(' — ')[0]));
    }
    return { ids: sorted(out.ids), idGlobs: sorted(out.idGlobs), titleWords: sorted(out.titleWords) };
}

// `AVD-*-SECRET-*` → `^AVD-.*-SECRET-` (a trailing `*` adds nothing to an unanchored-end match).
const globToSource = (g) => '^' + g.replace(/\*$/, '').split('*').map((p) => p.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*');

const report = {};
for (const tool of Object.keys(allow)) {
    const a = allow[tool];
    const md = documented(tool);
    report[tool] = {
        code: {
            ids: sorted(a.ids),
            idPatterns: sorted((a.idPatterns || []).map((p) => p.source)),
            titleWords: sorted((a.titlePatterns || []).flatMap((p) => p.source.toLowerCase().split('|'))),
        },
        doc: md && { ids: md.ids, idPatterns: sorted(md.idGlobs.map(globToSource)), titleWords: md.titleWords },
    };
}
process.stdout.write(JSON.stringify(report));
