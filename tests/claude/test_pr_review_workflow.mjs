#!/usr/bin/env node
// Logic tests for the pr-review dynamic workflow (private_dot_claude/workflows/pr-review.js).
//
// The workflow runs inside the Claude Code Workflow runtime, which injects
// agent/parallel/pipeline/log/phase/budget and allows top-level await/return.
// This harness reproduces that contract: it wraps the script body in an
// AsyncFunction with stubbed primitives, so the gate-control logic (args
// validation, severity-rule interpretation, coverage gate, caps aggregation)
// is exercised against the real canonical severity-rules.json with no LLM.

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const WORKFLOW_PATH = join(REPO_ROOT, 'private_dot_claude', 'workflows', 'pr-review.js')
const RULES_PATH = join(REPO_ROOT, 'private_dot_codex', 'skills', 'pr-review', 'references', 'severity-rules.json')

const rules = JSON.parse(readFileSync(RULES_PATH, 'utf8'))
const body = readFileSync(WORKFLOW_PATH, 'utf8').replace(/^export /m, '')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const runWorkflow = new AsyncFunction('args', 'agent', 'parallel', 'pipeline', 'log', 'phase', 'budget', body)

const BASE = 'a'.repeat(40)
const HEAD = 'b'.repeat(40)
const SHA = 'c'.repeat(64)
const SCOPE = `${BASE}...${HEAD}`
const FILES = ['src/app.js', 'docs/readme.md', 'tests/foo.test.js', '.github/workflows/ci.yml']

const STAGE1_FINDINGS = {
  'code-reviewer': [
    { label: 'Important', confidence: 95, file: 'src/app.js', line: 10, why: 'crash on null input', fix: 'guard null' },
    { label: 'Suggestion', confidence: 40, file: 'src/app.js', line: 22, why: 'duplicated branch', fix: 'extract helper' },
  ],
  'security-reviewer': [
    { label: 'high', confidence: 9, file: 'src/app.js', line: 30, why: 'command injection via unsanitized arg', fix: 'use execFile' },
    { label: 'Medium', confidence: 9, file: 'src/app.js', line: 44, why: 'path traversal possible', fix: 'normalize path' },
  ],
  'adversarial-reviewer': [
    { label: 'finding', confidence: 0.8, file: 'src/app.js', line: 50, why: 'race on concurrent writes loses data', fix: 'lock file' },
    { label: 'Important', confidence: 0.5, file: 'src/app.js', line: 60, why: 'rollback leaves partial state', fix: 'wrap in txn' },
  ],
  'silent-failure-hunter': [
    { label: 'CRITICAL', file: 'src/app.js', line: 70, why: 'catch block swallows error silently', fix: 'rethrow' },
  ],
  'pr-test-analyzer': [
    // deliberate case drift: must still escalate via case_insensitive category_label
    { label: 'Critical gap', confidence: 80, file: 'tests/foo.test.js', why: 'no test for error path', fix: 'add failing-input case' },
  ],
  'comment-analyzer': [
    { label: 'Nit', file: 'docs/readme.md', why: 'comment wording could be nicer', fix: 'reword' },
  ],
  'type-design-analyzer': [],
}

// scenario knobs consumed by the agent stub
let scenario = {}

async function agentStub(prompt, opts = {}) {
  const label = opts.label || ''
  if (label === 'categorize') {
    return {
      packetShaObserved: SHA,
      commentChanges: false,
      typeChanges: true,
      statusShort: '',
      commitLog: 'commit b\n  feat: x',
    }
  }
  if (label.startsWith('stage1:')) {
    const name = label.slice('stage1:'.length)
    const findings = scenario.suggestionsOnly
      ? (name === 'code-reviewer' ? [STAGE1_FINDINGS['code-reviewer'][1]] : [])
      : STAGE1_FINDINGS[name]
    const badSha = scenario.badCoverage === name
    return {
      coverage: { specialist: name, scope: SCOPE, packetSha: badSha ? 'd'.repeat(64) : SHA },
      framing: name === 'adversarial-reviewer' ? 'needs-attention' : undefined,
      findings,
      strengths: name === 'code-reviewer' ? ['clear naming'] : [],
    }
  }
  if (label === 'stage2:code-simplifier') {
    return {
      coverage: { specialist: 'code-simplifier', scope: SCOPE, packetSha: SHA },
      findings: [{ label: 'Suggestion', confidence: 50, file: 'src/app.js', line: 5, why: 'two branches collapse to one', fix: 'merge branches' }],
      strengths: [],
    }
  }
  if (label.startsWith('verify:')) {
    const echo = scenario.badVerdictEcho
      ? { scope: SCOPE, packetSha: 'e'.repeat(64) }
      : { scope: SCOPE, packetSha: SHA }
    if (prompt.includes('path traversal possible')) return { verdict: 'refuted', reasoning: 'path is constant, not user input', ...echo }
    if (prompt.includes('rollback leaves partial state')) return { verdict: 'needs-verification', reasoning: 'cannot reproduce locally', missingVerification: 'run migration rollback in staging', ...echo }
    return { verdict: 'confirmed', reasoning: 'grounded in diff', ...echo }
  }
  throw new Error('unexpected agent label: ' + label)
}

const stubs = {
  agent: agentStub,
  parallel: async thunks => Promise.all(thunks.map(t => t().catch(() => null))),
  pipeline: async () => { throw new Error('pipeline unused') },
  log: () => {},
  phase: () => {},
  budget: { total: null, spent: () => 0, remaining: () => Infinity },
}

function makeArgs(overrides = {}) {
  return {
    base: 'main',
    baseCommit: BASE,
    headRef: HEAD,
    packetPath: '/tmp/fake-packet.diff',
    packetBytes: 1234,
    packetSha: SHA,
    changedFiles: FILES.slice(),
    criteria: '<!-- PR_REVIEW_CRITERIA_SHARED_V1 -->\n# pr-review Review Criteria\n(test stub)',
    severityRules: rules,
    ...overrides,
  }
}

async function run(args, sc = {}) {
  scenario = sc
  return runWorkflow(args, stubs.agent, stubs.parallel, stubs.pipeline, stubs.log, stubs.phase, stubs.budget)
}

async function expectThrow(args, sc, pattern, name) {
  try {
    await run(args, sc)
  } catch (e) {
    assert(pattern.test(e.message), `${name} — got: ${e.message.slice(0, 120)}`)
    return
  }
  assert(false, `${name} — expected throw, none occurred`)
}

let failed = false
function assert(cond, msg) {
  if (!cond) { failed = true; console.error('FAIL: ' + msg) } else { console.log('ok: ' + msg) }
}

// S1: mixed findings — Critical present, Stage2 skipped, verify prunes one
const r1 = await run(makeArgs())
assert(r1.specialists.length === 7 && !r1.specialists.includes('code-simplifier'), 'S1: 7 specialists, no simplifier')
assert(r1.critical.length === 4, `S1: 4 Critical — got ${r1.critical.length}`)
assert(r1.importantTotal === 2, `S1: 2 Important kept after refutation (adv Important, pr-test case-drift gap) — got ${r1.importantTotal}`)
assert(r1.refuted.length === 1 && r1.refuted[0].why.includes('path traversal'), 'S1: sec Medium refuted')
assert(r1.stage2Ran === false, 'S1: Stage2 skipped on Critical')
assert(r1.critical.every(f => f.verdict), 'S1: every Critical carries a verdict')
assert(r1.important.find(f => f.missingVerification), 'S1: needs-verification kept with missingVerification')
assert(r1.categories.docsPaths.length === 1 && r1.categories.codePaths.length === 3, 'S1: path categorization (docs=1, code=3)')
assert(r1.important.some(f => (f.label || '').toLowerCase() === 'critical gap'), 'S1: case-drifted pr-test-analyzer label still escalates to Important')
assert(r1.importantOverflow.length === 0 && r1.suggestionsOverflow.length === 0, 'S1: no overflow under caps')

// S2: suggestions only — Stage2 runs and contributes
const r2 = await run(makeArgs(), { suggestionsOnly: true })
assert(r2.stage2Ran === true, 'S2: Stage2 ran when no Critical')
assert(r2.critical.length === 0 && r2.importantTotal === 0, 'S2: no Critical/Important')
assert(r2.suggestionsTotal === 2, `S2: stage1 + simplifier suggestions — got ${r2.suggestionsTotal}`)

// S3: cross-scale confidence ordering — security 9/10 must outrank code-reviewer 85/100
{
  const savedCr = STAGE1_FINDINGS['code-reviewer']
  const savedSec = STAGE1_FINDINGS['security-reviewer']
  STAGE1_FINDINGS['code-reviewer'] = [
    { label: 'Important', confidence: 85, file: 'src/a.js', line: 1, why: 'cr a', fix: 'f' },
    { label: 'Important', confidence: 80, file: 'src/b.js', line: 2, why: 'cr b', fix: 'f' },
    { label: 'Important', confidence: 75, file: 'src/c.js', line: 3, why: 'cr c', fix: 'f' },
    { label: 'Important', confidence: 70, file: 'src/d.js', line: 4, why: 'cr d', fix: 'f' },
    { label: 'Important', confidence: 65, file: 'src/e.js', line: 5, why: 'cr e', fix: 'f' },
  ]
  STAGE1_FINDINGS['security-reviewer'] = [
    { label: 'Medium', confidence: 9, file: 'src/app.js', line: 44, why: 'weak random token generation', fix: 'use crypto.randomBytes' },
  ]
  const r3 = await run(makeArgs())
  STAGE1_FINDINGS['code-reviewer'] = savedCr
  STAGE1_FINDINGS['security-reviewer'] = savedSec
  // security Medium (9/10 → 90 normalized) must rank above all code-reviewer Importants (≤85)
  const secIdx = r3.important.findIndex(f => f.specialist === 'security-reviewer')
  assert(secIdx === 0, `S3: security-reviewer 9/10 sorts first among Importants — index ${secIdx}`)
  assert(r3.importantTotal > rules.output_caps.important, `S3: cap exceeded in fixture (total ${r3.importantTotal})`)
  assert(r3.importantOverflow.length === r3.importantTotal - rules.output_caps.important, 'S3: overflow returns the capped-out tail in full')
  assert(r3.importantOverflow.every(f => f.why && f.specialist), 'S3: overflow entries carry full finding content')
}

// S4: coverage gate fails closed on echo mismatch
await expectThrow(makeArgs(), { badCoverage: 'security-reviewer' }, /coverage gate failed for security-reviewer/, 'S4: stage1 coverage mismatch throws')

// S5: verifier echo mismatch rejects the verdict (fail closed)
await expectThrow(makeArgs(), { badVerdictEcho: true }, /verdict rejected, fail closed/, 'S5: verifier echo mismatch throws')

// S6: args validation fails before any spawn
await expectThrow(makeArgs({ packetSha: 'nothex' }), {}, /packetSha/, 'S6: malformed packetSha rejected')
await expectThrow(makeArgs({ criteria: 'missing sentinel' }), {}, /PR_REVIEW_CRITERIA_SHARED_V1/, 'S6: criteria sentinel enforced')
await expectThrow(makeArgs({ severityRules: { ...rules, version: 2 } }), {}, /version 2 is not supported/, 'S6: unknown rules version rejected')
await expectThrow(makeArgs({ changedFiles: [] }), {}, /changedFiles/, 'S6: empty changedFiles rejected')
const noFiles = makeArgs(); delete noFiles.changedFiles
await expectThrow(noFiles, {}, /changedFiles/, 'S6: missing changedFiles rejected')

// S7: string-encoded args are parsed (harness delivers args as JSON string)
const r7 = await run(JSON.stringify(makeArgs()))
assert(r7.critical.length === 4, 'S7: JSON-string args accepted and parsed')

if (failed) {
  console.error('SOME ASSERTIONS FAILED')
  process.exit(1)
}
console.log('OK: pr-review workflow logic tests passed')
