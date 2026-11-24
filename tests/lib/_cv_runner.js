// Runner for the comment-voice tests: evaluates review-core.js end to end with mock globals.
// Env vars:
//   WF             path to review-core.js
//   CV_ARGS        review args (JSON string, passed through as the Workflow tool does)
//   CV_SPECIALISTS domain → findings array (code-analysis for the lightweight route), or a raw
//                  result object returned verbatim (e.g. the anthropic adapter's {status, issues})
//   CV_PANELISTS   array, one entry per seat; a missing entry is a dropped panelist
//   CV_WRITER      the writer's assessment as a JSON string literal
//   CV_EDITOR      the comment-editor's result as JSON, or the bare word THROW to reject
// Prints {bundle, editorCalls: [{prompt, opts}], dispatches: [{label, opts}], logs: [string]} as JSON.
'use strict';
const fs = require('fs');

const src = fs.readFileSync(process.env.WF, 'utf8').replace(/^export\s+const\s+meta/m, 'const meta');
const specialists = JSON.parse(process.env.CV_SPECIALISTS || '{}');
const panelists = JSON.parse(process.env.CV_PANELISTS || '[]');
const writer = JSON.parse(process.env.CV_WRITER || '"panel prose"');
const editorRaw = process.env.CV_EDITOR || 'null';
const roster = ['Cronus', 'Rhea', 'Oceanus', 'Hyperion', 'Themis'];
const editorCalls = [];
const dispatches = [];
const logs = [];

const agent = async (prompt, opts) => {
    const label = (opts && opts.label) || '';
    if (label === 'comment-editor') {
        editorCalls.push({ prompt, opts });
        if (editorRaw === 'THROW') throw new Error('editor failed');
        return JSON.parse(editorRaw);
    }
    if (label === 'panel-writer') return { assessment: writer };
    if (label.startsWith('panel-')) {
        const i = roster.indexOf(label.slice('panel-'.length));
        return panelists[i] === undefined ? null : panelists[i];
    }
    dispatches.push({ label, opts: { ...opts, schema: undefined, schemaRequired: opts && opts.schema && opts.schema.required } });
    const s = specialists[label];
    if (Array.isArray(s)) return { status: 'ok', findings: s };
    if (s && typeof s === 'object') return s;
    if (s === null) return null;
    return { status: 'ok', findings: [] };
};
const parallel = (thunks) => Promise.all(thunks.map((t) => t()));
const noop = () => {};
const timeoutId = setTimeout(() => { process.stdout.write('TIMEOUT'); process.exit(1); }, 10000);

(async () => {
    const fn = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'workflow',
        'return (async()=>{' + src + '\n})()');
    const log = (m) => { logs.push(String(m)); };
    const bundle = await fn(agent, parallel, async () => [], noop, log, process.env.CV_ARGS, async () => null);
    clearTimeout(timeoutId);
    process.stdout.write(JSON.stringify({ bundle, editorCalls, dispatches, logs }));
    process.exit(0);
})().catch((e) => { clearTimeout(timeoutId); process.stdout.write('THREW: ' + e.message); process.exit(1); });
