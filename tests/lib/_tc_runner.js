// Runner for the thin-core tests: evaluates review-core.js with mock globals.
// Two modes.
//   Call mode (TC_CALL set): runs the script up to `const resolvedArgs`, then calls the named
//   hoisted function with the arguments in TC_INPUT (a JSON array) and prints its result as JSON.
//   Every top-level const above that line is initialised by then.
//   End-to-end mode (TC_CALL unset): runs the whole script.
//     TC_ARGS        review args (JSON string, passed through as the Workflow tool does)
//     TC_NATIVE      native-reviewer's result as a JSON string literal, or null for a dead agent
//     TC_SPECIALISTS domain → findings array, or a raw result object returned verbatim
//     TC_EDITOR      the comment-editor's result as JSON, or the bare word THROW to reject
//   Prints {bundle, editorCalls, dispatches: [{label, prompt, opts}], logs} as JSON.
'use strict';
const fs = require('fs');

const marker = '\nconst resolvedArgs = ';
let src = fs.readFileSync(process.env.WF, 'utf8').replace(/^export\s+const\s+meta/m, 'const meta');
const call = process.env.TC_CALL || '';
if (call) {
    // eval resolves the hoisted function by name in the script's own scope; the name must be a
    // bare identifier, so nothing else reaches it.
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(call)) {
        process.stdout.write('BAD_CALL');
        process.exit(1);
    }
    if (!src.includes(marker)) {
        process.stdout.write('NO_MARKER');
        process.exit(1);
    }
    src = src.replace(marker, '\nreturn __tcCall((n) => eval(n));' + marker);
}
const specialists = JSON.parse(process.env.TC_SPECIALISTS || '{}');
const native = JSON.parse(process.env.TC_NATIVE || 'null');
const editorRaw = process.env.TC_EDITOR || 'null';
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
    dispatches.push({ label, prompt, opts: { ...opts, schema: undefined, hasSchema: Boolean(opts && opts.schema) } });
    if (label === 'native') return native;
    const s = specialists[label];
    if (Array.isArray(s)) return { status: 'ok', findings: s };
    if (s && typeof s === 'object') return s;
    if (s === null) return null;
    return { status: 'ok', findings: [] };
};
const parallel = (thunks) => Promise.all(thunks.map((t) => t().catch(() => null)));
const pipeline = (items, ...stages) => Promise.all(items.map(async (item, i) => {
    let r = item;
    try {
        for (const stage of stages) r = await stage(r, item, i);
        return r;
    } catch {
        return null;
    }
}));
const noop = () => {};
const timeoutId = setTimeout(() => { process.stdout.write('TIMEOUT'); process.exit(1); }, 10000);

(async () => {
    const fn = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'workflow', '__tcCall',
        'return (async()=>{' + src + '\n})()');
    const log = (m) => { logs.push(String(m)); };
    const tcCall = (lookup) => lookup(call)(...JSON.parse(process.env.TC_INPUT || '[]'));
    const out = await fn(agent, parallel, pipeline, noop, log, process.env.TC_ARGS, async () => null, tcCall);
    clearTimeout(timeoutId);
    process.stdout.write(JSON.stringify(call ? { result: out } : { bundle: out, editorCalls, dispatches, logs }));
    process.exit(0);
})().catch((e) => { clearTimeout(timeoutId); process.stdout.write('THREW: ' + e.message); process.exit(1); });
