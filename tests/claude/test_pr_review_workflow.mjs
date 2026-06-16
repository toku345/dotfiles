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

function finding(fields, decision = {}) {
  return {
    blocking: decision.blocking ?? true,
    impact_scope: decision.impact_scope || 'user-visible behavior',
    verified_assumptions: decision.verified_assumptions || ['grounded in supplied committed diff fixture'],
    unverified_assumptions: decision.unverified_assumptions || [],
    ...fields,
  }
}

const STAGE1_FINDINGS = {
  'code-reviewer': [
    finding({ label: 'Important', confidence: 95, file: 'src/app.js', line: 10, why: 'crash on null input', fix: 'guard null' }),
    finding({ label: 'Suggestion', confidence: 40, file: 'src/app.js', line: 22, why: 'duplicated branch', fix: 'extract helper' }, { blocking: false, impact_scope: 'maintainability' }),
  ],
  'security-reviewer': [
    finding({ label: 'high', confidence: 9, file: 'src/app.js', line: 30, why: 'command injection via unsanitized arg', fix: 'use execFile' }, { impact_scope: 'security' }),
    finding({ label: 'Medium', confidence: 9, file: 'src/app.js', line: 44, why: 'path traversal possible', fix: 'normalize path' }, { blocking: false, impact_scope: 'security' }),
  ],
  'adversarial-reviewer': [
    finding({ label: 'finding', confidence: 0.8, file: 'src/app.js', line: 50, why: 'race on concurrent writes loses data', fix: 'lock file' }, { impact_scope: 'data integrity' }),
    finding({ label: 'Important', confidence: 0.5, file: 'src/app.js', line: 60, why: 'rollback leaves partial state', fix: 'wrap in txn' }, { blocking: false, impact_scope: 'rollback safety' }),
  ],
  'silent-failure-hunter': [
    finding({ label: 'CRITICAL', file: 'src/app.js', line: 70, why: 'catch block swallows error silently', fix: 'rethrow' }, { impact_scope: 'authoritative gate' }),
  ],
  'pr-test-analyzer': [
    // deliberate case drift: must still escalate via case_insensitive category_label
    finding({ label: 'Critical gap', confidence: 80, file: 'tests/foo.test.js', why: 'no test for error path', fix: 'add failing-input case' }, { blocking: false, impact_scope: 'test coverage' }),
  ],
  'comment-analyzer': [
    finding({ label: 'Nit', file: 'docs/readme.md', why: 'comment wording could be nicer', fix: 'reword' }, { blocking: false, impact_scope: 'documentation wording' }),
  ],
  'type-design-analyzer': [],
}

// scenario knobs consumed by the agent stub
let scenario = {}

async function agentStub(prompt, opts = {}) {
  const label = opts.label || ''
  if (label === 'categorize') {
    return {
      packetShaObserved: scenario.badPacket ? 'f'.repeat(64) : SHA,
      commentChanges: false,
      typeChanges: true,
      statusShort: '',
      commitLog: 'commit b\n  feat: x',
    }
  }
  if (label.startsWith('stage1:')) {
    const name = label.slice('stage1:'.length)
    if (scenario.nullSpecialist === name) throw new Error('simulated agent death')
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
      findings: [finding({ label: 'Suggestion', confidence: 50, file: 'src/app.js', line: 5, why: 'two branches collapse to one', fix: 'merge branches' }, { blocking: false, impact_scope: 'maintainability' })],
      strengths: [],
    }
  }
  if (label.startsWith('verify:')) {
    const echo = scenario.badVerdictEcho
      ? { scope: SCOPE, packetSha: 'e'.repeat(64) }
      : { scope: SCOPE, packetSha: SHA }
    if (prompt.includes('path traversal possible')) return { verdict: 'refuted', reasoning: 'path is constant, not user input', ...echo }
    if (scenario.criticalNeedsVerification && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'needs-verification', reasoning: 'exploitability depends on runtime argument source', missingVerification: 'trace runtime argument source', ...echo }
    }
    if (scenario.confirmedWithMissingVerification && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'confirmed', reasoning: 'confirmed blocker but stale missing proof leaked through', missingVerification: 'trace runtime argument source', ...echo }
    }
    if (scenario.needsVerificationWithoutMissing && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'needs-verification', reasoning: 'exploitability depends on runtime argument source', ...echo }
    }
    if (scenario.refutedWithMissingVerification && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'refuted', reasoning: 'not exploitable, but stale missing proof leaked through', missingVerification: 'trace runtime argument source', ...echo }
    }
    if (scenario.needsVerificationBlankMissing && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'needs-verification', reasoning: 'exploitability depends on runtime argument source', missingVerification: '   ', ...echo }
    }
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
assert(r1.suggestionsTotal === 1, `S1: Nit excluded from fix queue (only the code-reviewer Suggestion remains) — got ${r1.suggestionsTotal}`)
assert(r1.stopCondition.includes('Re-run only after addressing Critical/Important'), 'S1: active blockers return re-run guidance')

// S2: suggestions only — Stage2 runs and contributes
const r2 = await run(makeArgs(), { suggestionsOnly: true })
assert(r2.stage2Ran === true, 'S2: Stage2 ran when no Critical')
assert(r2.critical.length === 0 && r2.importantTotal === 0, 'S2: no Critical/Important')
assert(r2.suggestionsTotal === 2, `S2: stage1 + simplifier suggestions — got ${r2.suggestionsTotal}`)
assert(r2.stopCondition.includes('Critical 0 / Important 0'), 'S2: suggestions-only result returns stop guidance')
assert(r2.reviewChurnGuidance.includes('third or later pass'), 'S2: review churn guidance returned')

// S3: cross-scale confidence ordering — security 9/10 must outrank code-reviewer 85/100
{
  const savedCr = STAGE1_FINDINGS['code-reviewer']
  const savedSec = STAGE1_FINDINGS['security-reviewer']
  STAGE1_FINDINGS['code-reviewer'] = [
    finding({ label: 'Important', confidence: 85, file: 'src/a.js', line: 1, why: 'cr a', fix: 'f' }, { blocking: false }),
    finding({ label: 'Important', confidence: 80, file: 'src/b.js', line: 2, why: 'cr b', fix: 'f' }, { blocking: false }),
    finding({ label: 'Important', confidence: 75, file: 'src/c.js', line: 3, why: 'cr c', fix: 'f' }, { blocking: false }),
    finding({ label: 'Important', confidence: 70, file: 'src/d.js', line: 4, why: 'cr d', fix: 'f' }, { blocking: false }),
    finding({ label: 'Important', confidence: 65, file: 'src/e.js', line: 5, why: 'cr e', fix: 'f' }, { blocking: false }),
  ]
  STAGE1_FINDINGS['security-reviewer'] = [
    finding({ label: 'Medium', confidence: 9, file: 'src/app.js', line: 44, why: 'weak random token generation', fix: 'use crypto.randomBytes' }, { blocking: false, impact_scope: 'security' }),
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
await expectThrow(makeArgs(), { confirmedWithMissingVerification: true }, /returned confirmed with missingVerification/, 'S5: confirmed verdict with missingVerification throws')
await expectThrow(makeArgs(), { needsVerificationWithoutMissing: true }, /needs-verification without missingVerification/, 'S5: needs-verification without missingVerification throws')
await expectThrow(makeArgs(), { refutedWithMissingVerification: true }, /returned refuted with missingVerification/, 'S5: refuted verdict with missingVerification throws')
await expectThrow(makeArgs(), { needsVerificationBlankMissing: true }, /needs-verification without missingVerification/, 'S5: needs-verification with blank missingVerification throws')

// S6: args validation fails before any spawn
await expectThrow(makeArgs({ packetSha: 'nothex' }), {}, /packetSha/, 'S6: malformed packetSha rejected')
await expectThrow(makeArgs({ criteria: 'missing sentinel' }), {}, /PR_REVIEW_CRITERIA_SHARED_V1/, 'S6: criteria sentinel enforced')
await expectThrow(makeArgs({ severityRules: { ...rules, version: 2 } }), {}, /version 2 is not supported/, 'S6: unknown rules version rejected')
{
  const brokenDowngrade = JSON.parse(JSON.stringify(rules))
  brokenDowngrade.critical.downgrade_to_important = { impact_scope_patterns: ['local-only'] }
  await expectThrow(makeArgs({ severityRules: brokenDowngrade }), {}, /downgrade_to_important/, 'S6: malformed downgrade policy rejected')
}
await expectThrow(makeArgs({ changedFiles: [] }), {}, /changedFiles/, 'S6: empty changedFiles rejected')
const noFiles = makeArgs(); delete noFiles.changedFiles
await expectThrow(noFiles, {}, /changedFiles/, 'S6: missing changedFiles rejected')

// S7: string-encoded args are parsed (harness delivers args as JSON string)
const r7 = await run(JSON.stringify(makeArgs()))
assert(r7.critical.length === 4, 'S7: JSON-string args accepted and parsed')

// S7b: a Critical candidate with local-only impact or unverified assumptions is downgraded
{
  const savedCr = STAGE1_FINDINGS['code-reviewer']
  const cases = [
    {
      name: 'blocking=false',
      file: 'src/local-cache-blocking.js',
      decision: { blocking: false, impact_scope: 'user-visible behavior', verified_assumptions: ['grounded in fixture'], unverified_assumptions: [] },
    },
    {
      name: 'local-only impact',
      file: 'src/local-cache-scope.js',
      decision: { blocking: true, impact_scope: 'machine-local developer workflow; not CI or user-visible', verified_assumptions: ['cache path is ignored state'], unverified_assumptions: [] },
    },
    {
      name: 'unverified assumptions',
      file: 'src/local-cache-unverified.js',
      decision: { blocking: true, impact_scope: 'user-visible behavior', verified_assumptions: ['cache path is ignored state'], unverified_assumptions: ['the stale cache affects CI or a user-visible merge outcome'] },
    },
    {
      name: 'blank verified assumptions',
      file: 'src/local-cache-blank.js',
      decision: { blocking: true, impact_scope: 'user-visible behavior', verified_assumptions: ['   '], unverified_assumptions: [] },
    },
  ]
  for (const c of cases) {
    STAGE1_FINDINGS['code-reviewer'] = [
      finding(
        { label: 'Critical', confidence: 99, file: c.file, line: 1, why: `${c.name} should not remain Critical`, fix: 'tighten guard' },
        c.decision,
      ),
    ]
    const r7b = await run(makeArgs())
    assert(r7b.critical.length === 3, `S7b: ${c.name} Critical candidate downgraded — Critical ${r7b.critical.length}`)
    assert(r7b.important.some(f => f.file === c.file), `S7b: ${c.name} candidate remains visible as Important`)
  }
  STAGE1_FINDINGS['code-reviewer'] = savedCr
}

// S7c: verifier-discovered missing proof downgrades Critical to Important
{
  const r7c = await run(makeArgs(), { criticalNeedsVerification: true })
  assert(r7c.critical.length === 3, `S7c: needs-verification Critical downgraded — Critical ${r7c.critical.length}`)
  assert(r7c.important.some(f => f.why.includes('command injection') && f.missingVerification), 'S7c: verifier-downgraded Critical remains visible as Important with missingVerification')
}

// S7d: Critical impact-scope downgrades are table-driven
{
  const savedCr = STAGE1_FINDINGS['code-reviewer']
  const tableRules = JSON.parse(JSON.stringify(rules))
  tableRules.critical.downgrade_to_important.impact_scope_patterns = ['fixture-local']
  tableRules.critical.downgrade_to_important.override_patterns = ['fixture-authoritative']

  STAGE1_FINDINGS['code-reviewer'] = [
    finding(
      { label: 'Critical', confidence: 99, file: 'src/table-driven-local.js', line: 1, why: 'table-driven local scope should downgrade', fix: 'tighten guard' },
      { blocking: true, impact_scope: 'fixture-local workflow', verified_assumptions: ['grounded in fixture'], unverified_assumptions: [] },
    ),
  ]
  const downgraded = await run(makeArgs({ severityRules: tableRules }))
  assert(downgraded.critical.length === 3, `S7d: custom downgrade pattern applied — Critical ${downgraded.critical.length}`)
  assert(downgraded.important.some(f => f.file === 'src/table-driven-local.js'), 'S7d: table-downgraded candidate remains visible as Important')

  STAGE1_FINDINGS['code-reviewer'] = [
    finding(
      { label: 'Critical', confidence: 99, file: 'src/table-driven-authoritative.js', line: 1, why: 'override scope should remain Critical', fix: 'keep blocker visible' },
      { blocking: true, impact_scope: 'fixture-local fixture-authoritative workflow', verified_assumptions: ['grounded in fixture'], unverified_assumptions: [] },
    ),
  ]
  const preserved = await run(makeArgs({ severityRules: tableRules }))
  assert(preserved.critical.some(f => f.file === 'src/table-driven-authoritative.js'), 'S7d: custom override pattern preserves Critical')
  STAGE1_FINDINGS['code-reviewer'] = savedCr
}

// S8: categorizer packet-integrity gate fails closed on hash mismatch
await expectThrow(makeArgs(), { badPacket: true }, /diff packet integrity check failed/, 'S8: categorizer hash mismatch throws')

// S9: a dead Stage-1 specialist (null from parallel) fails closed
await expectThrow(makeArgs(), { nullSpecialist: 'adversarial-reviewer' }, /adversarial-reviewer returned no usable output/, 'S9: null specialist result throws')

// S10: rule-interpreter fail-loud guards — label-less rule and unknown kind
{
  const broken = JSON.parse(JSON.stringify(rules))
  broken.important.any_of.push({ kind: 'explicit_label', specialist: '*' })
  await expectThrow(makeArgs({ severityRules: broken }), {}, /neither 'labels' nor 'values'/, 'S10: label-less rule throws')
  const unknown = JSON.parse(JSON.stringify(rules))
  unknown.critical.any_of.push({ kind: 'vibes_based', specialist: '*' })
  await expectThrow(makeArgs({ severityRules: unknown }), {}, /unknown rule kind 'vibes_based'/, 'S10: unknown rule kind throws')
}

// S11: the JS confidenceScale registry must agree with the scale annotations
// in the canonical table (the live-run Critical was exactly this drift)
{
  const source = readFileSync(WORKFLOW_PATH, 'utf8')
  const registry = {}
  for (const m of source.matchAll(/'([\w-]+)':\s*\{\s*agentType:[^}]*?confidenceScale:\s*([0-9.]+)/gs)) {
    registry[m[1]] = Number(m[2])
  }
  const annotated = [...rules.critical.any_of, ...rules.important.any_of].filter(r => r.specialist && r.specialist !== '*' && r.scale)
  assert(annotated.length >= 2, `S11: table carries scale annotations to check (${annotated.length})`)
  for (const r of annotated) {
    const max = Number(r.scale.split('-')[1])
    assert(registry[r.specialist] === max, `S11: registry[${r.specialist}]=${registry[r.specialist]} matches table scale ${r.scale}`)
  }
}

// S12: schema source pins the decision metadata contract directly
{
  const source = readFileSync(WORKFLOW_PATH, 'utf8')
  const requiredMatch = source.match(/findings:\s*\{[\s\S]*?items:\s*\{[\s\S]*?required:\s*\[([^\]]+)\]/)
  const requiredText = requiredMatch ? requiredMatch[1] : ''
  for (const field of ['blocking', 'impact_scope', 'verified_assumptions', 'unverified_assumptions']) {
    assert(requiredText.includes(`'${field}'`), `S12: SPECIALIST_SCHEMA requires ${field}`)
  }
}

if (failed) {
  console.error('SOME ASSERTIONS FAILED')
  process.exit(1)
}
console.log('OK: pr-review workflow logic tests passed')
