#!/usr/bin/env node
// Offline PR-mockup renderer. Replays a captured panel trial through the REAL
// review-core.mjs (model calls stubbed with captured fixtures) and renders the
// full user-facing surface a reviewed PR would show: the review submission body
// plus every inline comment thread at its file:line anchor.
//
// This does NOT re-run any model. It exists so panel PRESENTATION (routing,
// comment wording, body assembly) can be tuned and reviewed in ~1s instead of a
// ~50-min live review. Prose written by the model (bodyText) is replayed verbatim
// from the fixture — edits to model prose still require a live/writer replay.
//
// Usage:
//   node render_pr_mockup.mjs <fixture-dir>
// where <fixture-dir> holds: flat_findings.json, panelists.json, writer_body.md
// (produced from a run's durable-log.jsonl + the panel agent prompt).

import fs from 'node:fs'
import path from 'node:path'

const fixtureDir = process.argv[2]
if (!fixtureDir) {
    console.error('usage: render_pr_mockup.mjs <fixture-dir>')
    process.exit(64)
}

const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..', '..')
const WF = path.join(REPO_ROOT, 'plugins', 'code-review-suite', 'workflows', 'review-core.mjs')

const flat = JSON.parse(fs.readFileSync(path.join(fixtureDir, 'flat_findings.json'), 'utf8'))
const panelists = JSON.parse(fs.readFileSync(path.join(fixtureDir, 'panelists.json'), 'utf8'))
const writerBody = fs.readFileSync(path.join(fixtureDir, 'writer_body.md'), 'utf8')

// Rebuild findingsByDomain in the SAME iteration order the run used, so
// flattenFindings reassigns identical finding_ids and the captured votes align.
// flat_findings.json is already in finding_id order; group preserving first-seen
// domain order.
const byDomain = {}
for (const f of flat) {
    const d = f.domain
    if (!byDomain[d]) byDomain[d] = []
    // Strip the host-injected fields; the specialist emits the bare finding.
    const { domain, finding_id, ...bare } = f
    byDomain[d].push(bare)
}
const domainOrder = Object.keys(byDomain)

const src = fs.readFileSync(WF, 'utf8').replace(/^export\s+const\s+meta/m, 'const meta')

const args = JSON.stringify({
    agentPrompt: 'x', flags: {}, route: 'full', selfReReview: false,
    reviewMode: 'pr', base: 'main', headSha: 'a'.repeat(40), emptyTreeMode: false,
    pathScope: '', tempDir: '/tmp/claude-test/x', intentLedger: '',
    orchestrationMode: 'panel', panelSize: panelists.length, panelBrief: 'BRIEF',
})

const agent = async (_prompt, opts) => {
    const label = (opts && opts.label) || ''
    if (label === 'panel-writer') return { bodyText: writerBody }
    if (label.startsWith('panel-')) {
        const i = parseInt(label.slice('panel-'.length), 10)
        return panelists[i] === undefined ? null : panelists[i]
    }
    if (label.startsWith('cross-')) return { status: 'ok', opinionsMarkdown: '', escalations: [] }
    if (label === 'review-synthesiser') return null
    return { status: 'ok', findings: byDomain[label] || [] }  // specialist dispatch
}
const parallel = (thunks) => Promise.all(thunks.map(t => t()))
const phase = () => {}
const log = () => {}
const pipeline = async () => []
const workflow = async () => null

const fn = new Function('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'workflow',
    'return (async()=>{' + src + '\n})()')

const bundle = await fn(agent, parallel, pipeline, phase, log, args, workflow)

// ---- Render the PR mockup -------------------------------------------------
const out = []
out.push('# ┌─ PR REVIEW MOCKUP ' + '─'.repeat(50))
out.push(`# │ replayed from fixture: ${fixtureDir}`)
out.push(`# │ domains (flatten order): ${domainOrder.join(', ')}`)
out.push('# └' + '─'.repeat(68))
out.push('')
out.push(`## Review submission — verdict: ${bundle.verdict}`)
out.push('')
out.push('> This is the review BODY (the `gh pr review` submission text):')
out.push('')
out.push(bundle.bodyText)
out.push('')
out.push('─'.repeat(70))
out.push('')
const comments = bundle.comments || []
out.push(`## Inline comments (${comments.length}) — threaded at file:line on the diff`)
out.push('')
if (comments.length === 0) {
    out.push('_(no inline comments)_')
} else {
    for (const c of comments) {
        const anchor = c.subjectType === 'file'
            ? `${c.path} (file-level)`
            : `${c.path}:${c.line}${c.side && c.side !== 'RIGHT' ? ` [${c.side}]` : ''}`
        out.push(`### 💬 ${anchor}`)
        out.push('')
        out.push(c.body)
        out.push('')
    }
}

console.log(out.join('\n'))
