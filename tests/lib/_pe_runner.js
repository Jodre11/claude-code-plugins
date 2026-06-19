// Runner for _pe_build_log_payload: invokes buildLogPayload in isolation.
// Env vars: WF (path to review-core.mjs), PE_ENV (envelope JSON), PE_PHASELOG (optional).
//
// Uses the async-wrapper pattern so top-level `await` in review-core.mjs is
// valid. A sentinel return injected before `const resolvedArgs` causes the
// async body to return buildLogPayload's result before any agent() call runs.
'use strict';
const fs = require('fs');

const src = fs.readFileSync(process.env.WF, 'utf8')
    .replace(/^export\s+const\s+meta/m, 'const meta');

const env = JSON.parse(process.env.PE_ENV);
const pl = process.env.PE_PHASELOG ? JSON.parse(process.env.PE_PHASELOG) : undefined;

// Minimal mock globals to satisfy the arg-parse preamble line
// (`typeof args === 'string' ? JSON.parse(args) : args`) without
// reaching any real agent() calls.
const mockArgs = JSON.stringify({
    agentPrompt: 'x',
    flags: {},
    route: 'full',
    selfReReview: false,
    reviewMode: 'pr',
    base: 'main',
    headSha: 'a'.repeat(40),
    emptyTreeMode: false,
    pathScope: '',
    tempDir: '/tmp/pe-test',
});
const agent    = async () => ({ status: 'ok', findings: [] });
const parallel = (thunks) => Promise.all(thunks.map((t) => t()));
const phase    = () => {};
const log      = () => {};
const pipeline = async () => [];
const workflow = async () => null;

// Inject a sentinel return before the first line of top-level execution
// (resolvedArgs) so the async body exits with buildLogPayload's result
// before any pipeline agent() call is made.
const srcWithReturn = src.replace(
    /^const resolvedArgs\s*=/m,
    'return buildLogPayload(envIn, plIn);\nconst resolvedArgs ='
);

(async () => {
    const fn = new Function(
        'agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'workflow',
        'envIn', 'plIn',
        'return (async()=>{\n' + srcWithReturn + '\n})();'
    );
    const payload = await fn(
        agent, parallel, pipeline, phase, log, mockArgs, workflow, env, pl
    );
    process.stdout.write(JSON.stringify(payload));
    process.exit(0);
})().catch((e) => {
    process.stderr.write('THREW: ' + e.message + '\n');
    process.exit(1);
});
