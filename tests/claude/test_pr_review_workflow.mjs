#!/usr/bin/env node
// Logic tests for the pr-review dynamic workflow (private_dot_claude/workflows/pr-review.js).
//
// The workflow runs inside the Claude Code Workflow runtime, which injects
// agent/parallel/pipeline/log/phase/budget and allows top-level await/return.
// This harness reproduces that contract: it wraps the script body in an
// AsyncFunction with stubbed primitives, so the gate-control logic (args
// validation, severity-rule interpretation, coverage gate, caps aggregation)
// is exercised against the real canonical severity-rules.json with no LLM.

import { execFileSync, spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
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

// Verifier citations point at EVIDENCE_FILE, which the evidence integration
// test (S19) commits into a scratch repo so the real validator can resolve them.
const EVIDENCE_FILE = 'src/app.js'
function evidenceAt(line, observation) {
  return [{ path: EVIDENCE_FILE, line, observation }]
}

// prompts by agent label from the most recent run, for prompt-contract checks
let capturedPrompts = {}

async function agentStub(prompt, opts = {}) {
  const label = opts.label || ''
  capturedPrompts[label] = prompt
  if (label === 'categorize') {
    return {
      packetShaObserved: scenario.badPacket ? 'f'.repeat(64) : SHA,
      commentChanges: scenario.catFlags ? scenario.catFlags.commentChanges : false,
      typeChanges: scenario.catFlags ? scenario.catFlags.typeChanges : true,
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
    if (scenario.evidenceFor && prompt.includes('command injection via unsanitized arg')) {
      return { reasoning: 'evidence fixture', ...scenario.evidenceFor, ...echo }
    }
    if (prompt.includes('path traversal possible')) return { verdict: 'refuted', reasoning: 'path is constant, not user input', evidence: evidenceAt('2', 'path is a literal constant'), ...echo }
    if (scenario.criticalNeedsVerification && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'needs-verification', reasoning: 'exploitability depends on runtime argument source', missingVerification: 'trace runtime argument source', ...echo }
    }
    if (scenario.confirmedWithMissingVerification && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'confirmed', reasoning: 'confirmed blocker but stale missing proof leaked through', missingVerification: 'trace runtime argument source', evidence: evidenceAt('1', 'fixture'), ...echo }
    }
    if (scenario.needsVerificationWithoutMissing && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'needs-verification', reasoning: 'exploitability depends on runtime argument source', ...echo }
    }
    if (scenario.refutedWithMissingVerification && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'refuted', reasoning: 'not exploitable, but stale missing proof leaked through', missingVerification: 'trace runtime argument source', evidence: evidenceAt('1', 'fixture'), ...echo }
    }
    if (scenario.needsVerificationBlankMissing && prompt.includes('command injection via unsanitized arg')) {
      return { verdict: 'needs-verification', reasoning: 'exploitability depends on runtime argument source', missingVerification: '   ', ...echo }
    }
    if (prompt.includes('rollback leaves partial state')) return { verdict: 'needs-verification', reasoning: 'cannot reproduce locally', missingVerification: 'run migration rollback in staging', ...echo }
    return { verdict: 'confirmed', reasoning: 'grounded in diff', evidence: evidenceAt('1', 'the cited line shows the failure mode'), ...echo }
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
    commentChanges: false,
    typeChanges: false,
    criteria: '<!-- PR_REVIEW_CRITERIA_SHARED_V1 -->\n# pr-review Review Criteria\n(test stub)',
    severityRules: rules,
    ...overrides,
  }
}

async function run(args, sc = {}) {
  scenario = sc
  capturedPrompts = {}
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

// SKILL.md aborts the gate unless every verified finding has a verification
// entry, so this invariant must hold on every path that changes the counts:
// caps, verifier downgrades, and Stage 2.
function assertVerificationsCoverTally(result, name) {
  const expected = result.tally.critical + result.tally.important + result.tally.refuted
  assert(result.verifications.length === expected,
    `${name}: verifications cover critical + important + refuted (${result.verifications.length} vs ${expected})`)
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
assert(r1.argsContract === 'PR_REVIEW_ARGS_V3', 'S1: argsContract sentinel returned for the render-side skew guard')
assert(r1.typeChanges === true && r1.commentChanges === false, 'S1: effective flags are the OR of args floor and categorizer judgment')

// S2: suggestions only — Stage2 runs and contributes
const r2 = await run(makeArgs(), { suggestionsOnly: true })
assert(r2.stage2Ran === true, 'S2: Stage2 ran when no Critical')
assert(r2.critical.length === 0 && r2.importantTotal === 0, 'S2: no Critical/Important')
assert(r2.suggestionsTotal === 2, `S2: stage1 + simplifier suggestions — got ${r2.suggestionsTotal}`)
assert(r2.stopCondition.includes('Critical 0 / Important 0'), 'S2: suggestions-only result returns stop guidance')
assert(r2.reviewChurnGuidance.includes('third or later pass'), 'S2: review churn guidance returned')
assertVerificationsCoverTally(r2, 'S2')

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
  // the tally exists to measure cap pressure, so it must track the pre-cap
  // total precisely where the rendered list stops being able to
  assert(r3.tally.important === r3.importantTotal && r3.important.length === rules.output_caps.important,
    'S3: tally reports the pre-cap Important total while the rendered list stays capped')
  assertVerificationsCoverTally(r3, 'S3')
  const verifiedIds = new Set(r3.verifications.map(v => v.candidateId))
  assert(r3.importantOverflow.every(f => verifiedIds.has(f.candidateId)), 'S3: capped-out Importants are still in verifications')
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
const noFlags = makeArgs(); delete noFlags.commentChanges
await expectThrow(noFlags, {}, /commentChanges.*typeChanges must be booleans/, 'S6: missing routing flags rejected (stale-SKILL.md skew)')
await expectThrow(makeArgs({ typeChanges: 'yes' }), {}, /commentChanges.*typeChanges must be booleans/, 'S6: non-boolean routing flag rejected')

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
  assertVerificationsCoverTally(r7c, 'S7c')
}

// S7d: Critical impact-scope downgrades are table-driven
{
  const savedCr = STAGE1_FINDINGS['code-reviewer']
  const tableRules = JSON.parse(JSON.stringify(rules))
  tableRules.critical.downgrade_to_important.impact_scope_patterns = ['fixture local']
  tableRules.critical.downgrade_to_important.override_patterns = ['fixture authoritative']

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
      { label: 'Critical', confidence: 99, file: 'src/table-driven-negated-local.js', line: 1, why: 'negated local scope should not downgrade', fix: 'tighten guard' },
      { blocking: true, impact_scope: 'not fixture-local user-visible behavior', verified_assumptions: ['grounded in fixture'], unverified_assumptions: [] },
    ),
  ]
  const negatedDowngrade = await run(makeArgs({ severityRules: tableRules }))
  assert(negatedDowngrade.critical.some(f => f.file === 'src/table-driven-negated-local.js'), 'S7d: negated downgrade pattern does not match')

  STAGE1_FINDINGS['code-reviewer'] = [
    finding(
      { label: 'Critical', confidence: 99, file: 'src/table-driven-authoritative.js', line: 1, why: 'override scope should remain Critical', fix: 'keep blocker visible' },
      { blocking: true, impact_scope: 'fixture-local fixture-authoritative workflow', verified_assumptions: ['grounded in fixture'], unverified_assumptions: [] },
    ),
  ]
  const preserved = await run(makeArgs({ severityRules: tableRules }))
  assert(preserved.critical.some(f => f.file === 'src/table-driven-authoritative.js'), 'S7d: custom override pattern preserves Critical')

  STAGE1_FINDINGS['code-reviewer'] = [
    finding(
      { label: 'Critical', confidence: 99, file: 'src/table-driven-negated-authoritative.js', line: 1, why: 'negated override should still downgrade', fix: 'tighten guard' },
      { blocking: true, impact_scope: 'fixture-local non-fixture-authoritative workflow', verified_assumptions: ['grounded in fixture'], unverified_assumptions: [] },
    ),
  ]
  const negatedOverride = await run(makeArgs({ severityRules: tableRules }))
  assert(negatedOverride.critical.length === 3, `S7d: negated override pattern ignored — Critical ${negatedOverride.critical.length}`)
  assert(negatedOverride.important.some(f => f.file === 'src/table-driven-negated-authoritative.js'), 'S7d: negated override candidate remains visible as Important')
  STAGE1_FINDINGS['code-reviewer'] = savedCr
}

// S7e: the args grep floor widens routing even when the categorizer misses it
// (no docs paths, categorizer stub says commentChanges=false — only the
// main-session flag can route comment-analyzer here)
{
  const r7e = await run(makeArgs({ changedFiles: ['src/app.js'], commentChanges: true }))
  assert(r7e.specialists.includes('comment-analyzer'), 'S7e: args.commentChanges floor routes comment-analyzer without docs paths or agent flag')
  assert(r7e.commentChanges === true, 'S7e: effective commentChanges reflects the args floor')
}

// S7f: the categorizer widens routing even when the args grep floor misses it
// (no docs paths, args commentChanges=false — only the agent flag can route
// comment-analyzer here; kills a dropped `|| cat.commentChanges` mutation)
{
  const r7f = await run(makeArgs({ changedFiles: ['src/app.js'] }), { catFlags: { commentChanges: true, typeChanges: true } })
  assert(r7f.specialists.includes('comment-analyzer'), 'S7f: categorizer commentChanges routes comment-analyzer over a false args floor')
  assert(r7f.commentChanges === true, 'S7f: effective commentChanges reflects the categorizer judgment')
}

// S7g: the args typeChanges floor widens routing even when the categorizer
// misses it (kills a dropped `a.typeChanges ||` mutation, which S1 cannot —
// the default categorizer stub already answers typeChanges=true)
{
  const r7g = await run(makeArgs({ changedFiles: ['src/app.js'], typeChanges: true }), { catFlags: { commentChanges: false, typeChanges: false } })
  assert(r7g.specialists.includes('type-design-analyzer'), 'S7g: args.typeChanges floor routes type-design-analyzer despite a categorizer miss')
  assert(r7g.typeChanges === true, 'S7g: effective typeChanges reflects the args floor')
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

// S13: review size limits refuse loudly instead of letting an oversized packet
// clear the coverage gate on a partial read (sha256sum succeeds at any size)
{
  await expectThrow(makeArgs({ packetBytes: 1048577 }), {},
    /1048577 bytes, over the 1048576-byte review limit/, 'S13: oversized diff packet throws')
  await expectThrow(makeArgs({ changedFiles: Array.from({ length: 501 }, (_, i) => `src/f${i}.js`) }), {},
    /changes 501 files, over the 500-file review limit/, 'S13: too many changed files throws')

  // boundary: exactly at each limit must still review — a guard that shrinks
  // the window it protects is its own regression
  const atByteLimit = await run(makeArgs({ packetBytes: 1048576 }))
  assert(atByteLimit.argsContract === 'PR_REVIEW_ARGS_V3', 'S13: packet exactly at the byte limit still reviews')
  const atFileLimit = await run(makeArgs({ changedFiles: Array.from({ length: 500 }, (_, i) => `src/f${i}.js`) }))
  assert(atFileLimit.argsContract === 'PR_REVIEW_ARGS_V3', 'S13: exactly 500 changed files still reviews')
}

// S14: the tally the render emits verbatim must agree with the structured
// result — recomputing it from the capped sections would understate the totals
{
  const r14 = await run(makeArgs())
  assert(r14.tally.critical === r14.critical.length, 'S14: tally.critical matches the Critical list')
  assert(r14.tally.important === r14.importantTotal, 'S14: tally.important is the pre-cap Important total')
  assert(r14.tally.suggestion === r14.suggestionsTotal, 'S14: tally.suggestion is the pre-cap Suggestion total')
  assert(r14.tally.refuted === r14.refuted.length, 'S14: tally.refuted matches the refuted list')
  assert(['critical', 'important', 'suggestion', 'refuted'].map(k => r14.tally[k]).every(n => Number.isInteger(n) && n >= 0), 'S14: tally values are non-negative integers')
}

// S15: verifier evidence contract — confirmed/refuted need well-formed
// citations; needs-verification may omit them and is normalized to []
{
  const cases = [
    ['confirmed without evidence', { verdict: 'confirmed' }, /returned confirmed without evidence/],
    ['refuted with empty evidence', { verdict: 'refuted', evidence: [] }, /returned refuted without evidence/],
    ['non-array evidence', { verdict: 'confirmed', evidence: 'src/app.js:1' }, /non-array evidence/],
    ['absolute path', { verdict: 'confirmed', evidence: [{ path: '/etc/passwd', line: '1', observation: 'x' }] }, /not a safe repository-relative path/],
    ['parent traversal', { verdict: 'confirmed', evidence: [{ path: 'src/../x.js', line: '1', observation: 'x' }] }, /not a safe repository-relative path/],
    ['zero line', { verdict: 'confirmed', evidence: [{ path: 'src/app.js', line: '0', observation: 'x' }] }, /not a positive line or ascending range/],
    ['reversed range', { verdict: 'confirmed', evidence: [{ path: 'src/app.js', line: '9-3', observation: 'x' }] }, /not a positive line or ascending range/],
    ['blank observation', { verdict: 'confirmed', evidence: [{ path: 'src/app.js', line: '3', observation: '  ' }] }, /empty observation/],
    ['extra field', { verdict: 'confirmed', evidence: [{ path: 'src/app.js', line: '3', observation: 'x', note: 'y' }] }, /expected exactly path, line, observation/],
    ['missing field', { verdict: 'confirmed', evidence: [{ path: 'src/app.js', line: '3' }] }, /expected exactly path, line, observation/],
    ['null item', { verdict: 'confirmed', evidence: [null] }, /is not an object/],
    ['backslash path', { verdict: 'confirmed', evidence: [{ path: 'src\\app.js', line: '3', observation: 'x' }] }, /not a safe repository-relative path/],
    ['padded path', { verdict: 'confirmed', evidence: [{ path: ' src/app.js', line: '3', observation: 'x' }] }, /not a safe repository-relative path/],
    ['empty path segment', { verdict: 'confirmed', evidence: [{ path: 'src//app.js', line: '3', observation: 'x' }] }, /not a safe repository-relative path/],
    ['numeric line', { verdict: 'confirmed', evidence: [{ path: 'src/app.js', line: 3, observation: 'x' }] }, /not a positive line or ascending range/],
    // present evidence is shape-checked even when the verdict does not require it
    ['malformed needs-verification evidence', { verdict: 'needs-verification', missingVerification: 'trace caller', evidence: [{ path: '../x.js', line: '1', observation: 'x' }] }, /not a safe repository-relative path/],
  ]
  for (const [name, evidenceFor, pattern] of cases) {
    await expectThrow(makeArgs(), { evidenceFor }, pattern, `S15: ${name} throws`)
  }

  const r15 = await run(makeArgs(), { criticalNeedsVerification: true })
  const nv = r15.verifications.find(v => v.verdict === 'needs-verification')
  assert(nv && Array.isArray(nv.evidence) && nv.evidence.length === 0, 'S15: omitted needs-verification evidence is normalized to []')
  const range = await run(makeArgs(), { evidenceFor: { verdict: 'confirmed', evidence: [{ path: 'src/app.js', line: '3-7', observation: 'range' }] } })
  assert(range.critical.some(f => f.evidence && f.evidence[0].line === '3-7'), 'S15: an ascending line range is accepted and carried on the finding')
}

// S16: verifications cover every verified finding, with candidate IDs the
// shared validator accepts (capped-out ones: S3; downgrades: S7c; Stage 2: S2)
{
  const r16 = await run(makeArgs())
  assertVerificationsCoverTally(r16, 'S16')
  assert(r16.verifications.every(v => /^f[0-9]{3,}$/.test(v.candidateId)), 'S16: candidate IDs match the validator pattern')
  assert(new Set(r16.verifications.map(v => v.candidateId)).size === r16.verifications.length, 'S16: candidate IDs are unique')
  assert(r16.verifications.some(v => v.verdict === 'refuted' && v.evidence.length > 0), 'S16: refuted verdicts carry their evidence')
  assert(r16.refuted.every(f => Array.isArray(f.evidence) && f.evidence.length > 0), 'S16: refuted findings expose evidence for the render')
}

// S17: per-specialist tally agrees with the aggregate tally
{
  const r17 = await run(makeArgs())
  const by = r17.tally.bySpecialist
  assert(Object.keys(by).sort().join() === r17.specialists.slice().sort().join(), 'S17: bySpecialist has exactly the specialists that ran')
  for (const key of ['critical', 'important', 'suggestion', 'refuted']) {
    const sum = Object.values(by).reduce((n, s) => n + s[key], 0)
    assert(sum === r17.tally[key], `S17: bySpecialist ${key} sums to tally.${key} (${sum})`)
  }
  const verdictSum = Object.values(by).reduce((n, s) => n + s.confirmed + s.refuted + s.needsVerification, 0)
  assert(verdictSum === r17.verifications.length, 'S17: bySpecialist verdict counts cover every verification')
  assert(by['security-reviewer'].refuted === 1 && by['security-reviewer'].confirmed === 1, 'S17: security-reviewer split into 1 confirmed / 1 refuted')
  const r17s = await run(makeArgs(), { suggestionsOnly: true })
  assert(r17s.tally.bySpecialist['code-simplifier'].suggestion === 1, 'S17: Stage 2 code-simplifier is counted when it runs')
}

// S18: prompt contracts — the removed-behavior focus reaches only the
// adversarial reviewer, and verifiers are told to cite HEAD lines
{
  await run(makeArgs())
  const stage1 = Object.entries(capturedPrompts).filter(([label]) => label.startsWith('stage1:'))
  assert(stage1.length === 7, `S18: captured every Stage 1 prompt (${stage1.length})`)
  for (const [label, prompt] of stage1) {
    const hasFocus = prompt.includes('## Removed-behavior audit')
    assert(hasFocus === (label === 'stage1:adversarial-reviewer'), `S18: removed-behavior focus ${hasFocus ? 'present' : 'absent'} in ${label}`)
  }
  const verify = Object.entries(capturedPrompts).filter(([label]) => label.startsWith('verify:'))
  assert(verify.length > 0, 'S18: captured verifier prompts')
  for (const [label, prompt] of verify) {
    assert(prompt.includes(`git show ${HEAD}:<path>`) && prompt.includes('not positions in the diff packet'), `S18: ${label} requires HEAD-line citations`)
  }
}

// S19: the workflow's verifications feed the shared validator unchanged. The
// SKILL.md step writes {candidate_id, evidence} per verification and requires
// `EVIDENCE_OK ... <count>`; this runs that exact hand-off against a real commit.
{
  const VALIDATOR = join(REPO_ROOT, 'private_dot_codex', 'skills', 'pr-review', 'scripts', 'validate_finding_evidence.py')
  const dir = mkdtempSync(join(tmpdir(), 'pr-review-evidence-'))
  try {
    const repo = join(dir, 'repo')
    mkdirSync(join(repo, 'src'), { recursive: true })
    writeFileSync(join(repo, EVIDENCE_FILE), Array.from({ length: 80 }, (_, i) => `line ${i + 1}`).join('\n') + '\n')
    const git = (...gitArgs) => execFileSync('git', ['-C', repo, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ...gitArgs], { encoding: 'utf8' })
    git('init', '--quiet')
    git('add', '--all')
    git('commit', '--quiet', '-m', 'fixture')
    const headRef = git('rev-parse', 'HEAD').trim()

    const validate = (verification, name) => {
      const resultFile = join(dir, `${name}.json`)
      writeFileSync(resultFile, JSON.stringify({ candidate_id: verification.candidateId, evidence: verification.evidence }))
      return spawnSync('python3', [VALIDATOR, '--repo-root', repo, '--head-ref', headRef, '--result-file', resultFile], { encoding: 'utf8' })
    }

    const r19 = await run(makeArgs(), { criticalNeedsVerification: true })
    assert(r19.verifications.some(v => v.verdict === 'needs-verification'), 'S19: fixture includes a needs-verification verdict')
    for (const v of r19.verifications) {
      const out = validate(v, v.candidateId)
      const expected = `EVIDENCE_OK finding-verifier ${v.candidateId} ${headRef} ${v.evidence.length}`
      assert(out.status === 0 && out.stdout.trim() === expected, `S19: ${v.candidateId} (${v.verdict}) passes the shared validator — got rc=${out.status} ${out.stdout.trim()}${out.stderr.trim()}`)
    }

    // shape-valid citations the workflow cannot disprove; only the validator can
    const rejected = [
      ['line past end of file', [{ path: EVIDENCE_FILE, line: '81', observation: 'x' }]],
      ['path absent from HEAD', [{ path: 'src/missing.js', line: '1', observation: 'x' }]],
    ]
    for (const [name, evidence] of rejected) {
      const r = await run(makeArgs(), { evidenceFor: { verdict: 'confirmed', evidence } })
      const v = r.verifications.find(x => x.evidence[0].path === evidence[0].path && x.evidence[0].line === evidence[0].line)
      const out = validate(v, `bad-${v.candidateId}`)
      assert(out.status !== 0 && out.stdout.trim() === '', `S19: ${name} passes the workflow but the validator rejects it (rc=${out.status})`)
    }
    const badId = validate({ candidateId: 'x1', evidence: evidenceAt('1', 'x') }, 'bad-id')
    assert(badId.status !== 0, 'S19: a malformed candidate ID is rejected by the validator')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

if (failed) {
  console.error('SOME ASSERTIONS FAILED')
  process.exit(1)
}
console.log('OK: pr-review workflow logic tests passed')
