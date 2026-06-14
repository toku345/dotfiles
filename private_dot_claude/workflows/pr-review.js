/*
 * pr-review dynamic workflow — Claude-side counterpart of the Codex $pr-review skill.
 *
 * Launched by ~/.claude/skills/pr-review/SKILL.md from the main session, which resolves
 * the base ref (gh is sandbox-blocked inside workflow subagents — sandbox-boundary split,
 * ADR 0029), writes the diff packet, reads review-criteria.md / severity-rules.json, and
 * passes everything in via args. Workflow scripts have no filesystem access, so every
 * input crosses the boundary as data:
 *
 *   args = {
 *     base:          base branch name or ref (display only),
 *     baseCommit:    40-hex pinned base commit OID,
 *     headRef:       40-hex HEAD commit OID at launch,
 *     packetPath:    absolute path to the authoritative diff packet,
 *     packetBytes:   diff packet byte count,
 *     packetSha:     64-hex SHA-256 of the diff packet,
 *     changedFiles:  git diff --name-only BASE...HEAD list (authoritative, main-session-computed),
 *     criteria:      contents of references/review-criteria.md (deployed copy, with sentinel),
 *     severityRules: parsed references/severity-rules.json (shared escalation table),
 *   }
 *
 * Design: docs/design/claude-pr-review.md (dotfiles repo).
 */
export const meta = {
  name: 'pr-review',
  description: 'Pre-PR gate: fan out review specialists over a pinned diff packet, fail closed on coverage, verify Critical/Important findings only',
  whenToUse: 'Launched by the pr-review skill with a full args packet (base/baseCommit/headRef/packetPath/packetBytes/packetSha/changedFiles/criteria/severityRules). Do not launch bare.',
  phases: [
    { title: 'Categorize', detail: 'packet integrity + changed-file list + content flags' },
    { title: 'Stage1', detail: 'parallel specialist reviews (barrier, coverage fail-closed)' },
    { title: 'Stage2', detail: 'code-simplifier, only when Stage1 found no Critical' },
    { title: 'Verify', detail: 'adversarial verification of Critical/Important findings only' },
  ],
}

function fail(msg) {
  throw new Error(`pr-review workflow: ${msg}`)
}

// ---------------------------------------------------------------------------
// Args validation (fail-closed before spawning anything)
// ---------------------------------------------------------------------------

const HEX40 = /^[0-9a-f]{40}$/
const HEX64 = /^[0-9a-f]{64}$/

// the harness may deliver args as a JSON-encoded string instead of an object
let a = args || {}
if (typeof a === 'string') {
  try {
    a = JSON.parse(a)
  } catch (e) {
    fail(`args arrived as a string but is not valid JSON: ${e.message}`)
  }
}
if (typeof a.base !== 'string' || a.base === '') fail('args.base (base branch name or ref) is required')
if (!HEX40.test(a.baseCommit || '')) fail(`args.baseCommit must be a 40-hex commit OID, got '${a.baseCommit}'`)
if (!HEX40.test(a.headRef || '')) fail(`args.headRef must be a 40-hex commit OID, got '${a.headRef}'`)
if (typeof a.packetPath !== 'string' || !a.packetPath.startsWith('/')) fail('args.packetPath must be an absolute path to the diff packet')
if (typeof a.packetBytes !== 'number' || a.packetBytes <= 0) fail('args.packetBytes must be the positive byte count of the diff packet')
if (!HEX64.test(a.packetSha || '')) fail(`args.packetSha must be a 64-hex SHA-256, got '${a.packetSha}'`)
if (!Array.isArray(a.changedFiles) || a.changedFiles.length === 0 || a.changedFiles.some(f => typeof f !== 'string' || f === ''))
  fail('args.changedFiles must be the non-empty `git diff --name-only BASE...HEAD` list from the main session (authoritative — the workflow must not re-derive it from an unverified agent echo)')
if (typeof a.criteria !== 'string' || !a.criteria.includes('PR_REVIEW_CRITERIA_SHARED_V1'))
  fail('args.criteria must be the deployed ~/.claude/skills/pr-review/references/review-criteria.md (sentinel PR_REVIEW_CRITERIA_SHARED_V1 missing — deploy skew? run `chezmoi apply -v` and retry)')

const rules = a.severityRules
if (!rules || rules.sentinel !== 'PR_REVIEW_SEVERITY_RULES_V1')
  fail('args.severityRules must be the parsed severity-rules.json (sentinel PR_REVIEW_SEVERITY_RULES_V1 missing — deploy skew? run `chezmoi apply -v` and retry)')
if (rules.version !== 1)
  fail(`severity-rules version ${rules.version} is not supported (this workflow interprets version 1) — update ~/.claude/workflows/pr-review.js together with the table`)
if (!rules.critical || !Array.isArray(rules.critical.any_of)) fail('severityRules.critical.any_of must be an array')
if (!rules.important || !Array.isArray(rules.important.any_of)) fail('severityRules.important.any_of must be an array')
const caps = rules.output_caps || {}
if (typeof caps.important !== 'number' || typeof caps.suggestion !== 'number')
  fail('severityRules.output_caps.{important,suggestion} must be numbers')

const scope = `${a.baseCommit}...${a.headRef}`

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const CATEGORIZE_SCHEMA = {
  type: 'object',
  required: ['packetShaObserved', 'commentChanges', 'typeChanges', 'statusShort', 'commitLog'],
  additionalProperties: false,
  properties: {
    packetShaObserved: { type: 'string', description: "observed SHA-256 of the diff packet, or 'UNREADABLE'" },
    commentChanges: { type: 'boolean', description: 'any added or removed comment line in source files (including mixed code+comment hunks)' },
    typeChanges: { type: 'boolean', description: 'any hunk introducing or modifying class/interface/type/struct/enum/trait/dataclass/schema definitions' },
    statusShort: { type: 'string', description: 'git status --short output, verbatim (may be empty)' },
    commitLog: { type: 'string', description: 'git log --no-decorate BASE..HEAD output, verbatim' },
  },
}

const SPECIALIST_SCHEMA = {
  type: 'object',
  required: ['coverage', 'findings', 'strengths'],
  additionalProperties: false,
  properties: {
    coverage: {
      type: 'object',
      required: ['specialist', 'scope', 'packetSha'],
      additionalProperties: false,
      properties: {
        specialist: { type: 'string' },
        scope: { type: 'string', description: "the reviewed BASE_COMMIT...HEAD_REF scope, or 'FATAL' on a coverage error" },
        packetSha: { type: 'string', description: 'the diff-packet SHA-256 you verified yourself' },
      },
    },
    framing: {
      type: 'string',
      enum: ['needs-attention', 'acceptable'],
      description: 'adversarial-reviewer only: overall verdict framing',
    },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['label', 'file', 'why', 'blocking', 'impact_scope', 'verified_assumptions', 'unverified_assumptions'],
        additionalProperties: false,
        properties: {
          label: { type: 'string', description: "the specialist's native severity/category label (e.g. Critical, Important, High, Medium, CRITICAL, 'Critical Gap')" },
          confidence: { type: 'number', description: 'native confidence scale: 0-1 (adversarial-reviewer), 0-10 (security-reviewer), 0-100 (all other specialists)' },
          file: { type: 'string' },
          line: { type: 'integer' },
          why: { type: 'string', description: 'concrete risk grounded in the committed diff: observed failure mode + user/operational impact' },
          fix: { type: 'string', description: 'smallest reasonable fix' },
          blocking: { type: 'boolean', description: 'true only when the committed diff proves a merge blocker' },
          impact_scope: { type: 'string', description: 'what would be affected if merged as-is, e.g. user-visible behavior, security, data integrity, deploy/apply gate, machine-local developer workflow' },
          verified_assumptions: { type: 'array', items: { type: 'string' }, description: 'facts verified from the supplied committed diff, status, log, or packet' },
          unverified_assumptions: { type: 'array', items: { type: 'string' }, description: 'assumptions still needed to make the blocker claim true; must be empty for Critical' },
        },
      },
    },
    strengths: { type: 'array', items: { type: 'string' }, description: 'positive observations' },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['verdict', 'reasoning', 'scope', 'packetSha'],
  additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'needs-verification'] },
    reasoning: { type: 'string' },
    missingVerification: { type: 'string', description: "for 'needs-verification': the specific check that is missing" },
    scope: { type: 'string', description: 'the BASE_COMMIT...HEAD_REF scope you verified against' },
    packetSha: { type: 'string', description: 'the diff-packet SHA-256 you verified yourself before judging' },
  },
}

// ---------------------------------------------------------------------------
// Specialist registry (six pr-review-toolkit agents reused, two ported agents)
// ---------------------------------------------------------------------------

// confidenceScale = the specialist's native confidence maximum; used to
// normalize cross-specialist ordering before the Important/Suggestion caps
const SPECIALISTS = {
  'code-reviewer': {
    agentType: 'pr-review-toolkit:code-reviewer',
    confidenceScale: 100,
    labelGuidance: 'Label each finding Critical, Important, or Suggestion, and attach your confidence on a 0-100 scale.',
  },
  'security-reviewer': {
    agentType: 'security-reviewer',
    confidenceScale: 10,
    labelGuidance: "Put the security severity (High, Medium, or Low) in `label` and your 0-10 exploitability confidence in `confidence`; include the vulnerability category in `why`.",
  },
  'adversarial-reviewer': {
    agentType: 'adversarial-reviewer',
    confidenceScale: 1,
    labelGuidance: "Set the top-level `framing` to 'needs-attention' or 'acceptable', and attach a 0-1 confidence to every finding.",
  },
  'pr-test-analyzer': {
    agentType: 'pr-review-toolkit:pr-test-analyzer',
    confidenceScale: 100,
    labelGuidance: "Label each finding 'Critical Gap', 'Important Improvement', or 'Suggestion', and attach your confidence on a 0-100 scale.",
  },
  'comment-analyzer': {
    agentType: 'pr-review-toolkit:comment-analyzer',
    confidenceScale: 100,
    labelGuidance: 'Label each finding Critical, Important, or Suggestion, and attach your confidence on a 0-100 scale.',
  },
  'silent-failure-hunter': {
    agentType: 'pr-review-toolkit:silent-failure-hunter',
    confidenceScale: 100,
    labelGuidance: 'Label each finding CRITICAL, HIGH, MEDIUM, or LOW, and attach your confidence on a 0-100 scale.',
  },
  'type-design-analyzer': {
    agentType: 'pr-review-toolkit:type-design-analyzer',
    confidenceScale: 100,
    labelGuidance: 'Label each finding Critical, Important, or Suggestion, and attach your confidence on a 0-100 scale.',
  },
  'code-simplifier': {
    agentType: 'pr-review-toolkit:code-simplifier',
    confidenceScale: 100,
    labelGuidance: 'Label every finding Suggestion — Stage 2 is advisory simplification only. Attach your confidence on a 0-100 scale.',
  },
}

const ALWAYS = ['code-reviewer', 'security-reviewer', 'adversarial-reviewer']

// ---------------------------------------------------------------------------
// Path categorization (ported from the Codex SKILL.md step 1 rules)
// ---------------------------------------------------------------------------

const TEST_DIR_RE = /(^|\/)(tests?|__tests__)\//
const TEST_FILE_RE = /(\.test\.[^/]+|\.spec\.[^/]+|_test\.go|_spec\.rb|\.bats)$/
const OPERATIONAL_RES = [
  /^\.github\/workflows\//,
  /(^|\/)\.claude\/hooks\//,
  /(^|\/)\.chezmoiscripts\//,
  /^dot_local\/bin\//,
  /(^|\/)SKILL\.md$/,
  /^private_dot_codex\//,
  /^private_dot_claude\//,
]
const DOCS_RE = /((^|\/)docs\/|\.(md|mdx)$|(^|\/)README[^/]*$)/i

function isTestPath(p) {
  const base = p.split('/').pop() || ''
  return TEST_DIR_RE.test(p) || TEST_FILE_RE.test(base) || base.startsWith('test_')
}

function categorizePaths(files) {
  const testPaths = files.filter(isTestPath)
  const operationalPaths = files.filter(p => OPERATIONAL_RES.some(re => re.test(p)))
  const opSet = new Set(operationalPaths)
  const docsPaths = files.filter(p => DOCS_RE.test(p) && !opSet.has(p))
  const docsSet = new Set(docsPaths)
  const codePaths = files.filter(p => !docsSet.has(p))
  return { testPaths, operationalPaths, docsPaths, codePaths }
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------

function specialistPrompt(name, ctx, extra) {
  const lines = [
    `You are the ${name} specialist in the pr-review pre-PR gate.`,
    `Target: review of branch HEAD ${ctx.headRef} against base '${ctx.base}' (commit ${ctx.baseCommit}).`,
    '',
    '## Scope contract',
    `Review ONLY the committed branch diff ${ctx.scope}. Do not substitute an unqualified 'git diff', unstaged changes, PR re-detection, a different base commit, a different HEAD, or any other inferred scope.`,
    '',
    '## Diff packet (authoritative)',
    `Path: ${ctx.packetPath} — ${ctx.packetBytes} bytes, SHA-256 ${ctx.packetSha}.`,
    "Verify the packet hash yourself before reviewing. If the packet is missing, unreadable, or the hash does not match, set coverage.scope to 'FATAL', explain the reason in a finding, and stop.",
    '',
    '## Changed files',
    ...ctx.files.map(f => `- ${f}`),
    '',
    '## Git status (short)',
    ctx.statusShort.trim() === '' ? '(clean)' : ctx.statusShort,
    '',
    '## Commits in scope',
    ctx.commitLog,
    '',
    '## Gate policy (review-criteria.md)',
    ctx.criteria,
    '',
    '## Output contract',
    'You are advisory-only: do not edit files, create files, apply patches, run formatters that write files, or otherwise dirty the worktree. Do not explore the repository beyond the provided status, file list, commit log, and diff packet.',
    `Set coverage.specialist to '${name}', coverage.scope to '${ctx.scope}', and coverage.packetSha to the SHA-256 you verified.`,
    SPECIALISTS[name].labelGuidance,
    "Every finding must be grounded in the committed diff: name the file (and line where possible), the concrete failure mode and user/operational impact in `why`, and the smallest reasonable fix in `fix`. Include `blocking`, `impact_scope`, `verified_assumptions`, and `unverified_assumptions`. Set `blocking: true` only for clear merge blockers proven by the committed diff; machine-local or ignored state, local-only performance regressions, developer-workflow-only false-greens, advisory observability gaps, and assumption-dependent risks should use `blocking: false`. Do not emit nits, style preferences, or speculative rewrites. Put positive observations in `strengths`, not in findings.",
  ]
  if (extra) lines.push('', extra)
  return lines.join('\n')
}

function verifyPrompt(f, ctx) {
  return [
    'You are an adversarial verifier in the pr-review pre-PR gate. Try to REFUTE the finding below against the committed diff. Work read-only; do not modify any file.',
    '',
    `Scope: ${ctx.scope}. Diff packet: ${ctx.packetPath} (${ctx.packetBytes} bytes, SHA-256 ${ctx.packetSha}) — verify the hash before relying on it.`,
    '',
    `Finding by ${f.specialist} (normalized severity: ${f.severity}, native label: ${f.label}):`,
    `- file: ${f.file}${typeof f.line === 'number' ? `:${f.line}` : ''}`,
    `- claim: ${f.why}`,
    `- blocking: ${f.blocking ? 'yes' : 'no'}`,
    `- impact_scope: ${f.impact_scope || '(not stated)'}`,
    `- verified_assumptions: ${(f.verified_assumptions || []).join('; ') || '(none)'}`,
    `- unverified_assumptions: ${(f.unverified_assumptions || []).join('; ') || '(none)'}`,
    f.fix ? `- proposed fix: ${f.fix}` : null,
    '',
    "Verdict rules: return 'refuted' only with concrete evidence that the claim is wrong or not grounded in this diff; 'confirmed' when the failure mode is clearly grounded in the diff; otherwise 'needs-verification' with the specific missing check named in missingVerification. Severe-but-unproven risks are kept visible, never silently dropped.",
    `Echo coverage: set 'scope' to '${ctx.scope}' and 'packetSha' to the SHA-256 you verified yourself — the workflow rejects your verdict if either does not match what it supplied.`,
  ].filter(Boolean).join('\n')
}

// ---------------------------------------------------------------------------
// Coverage gate + severity normalization
// ---------------------------------------------------------------------------

function assertCoverage(result, expectedSpecialist) {
  if (!result) fail(`${expectedSpecialist} returned no usable output (skipped or errored) — coverage gate fails closed`)
  const c = result.coverage || {}
  if (c.specialist !== expectedSpecialist || c.scope !== scope || c.packetSha !== a.packetSha) {
    const detail = (result.findings || []).map(f => f.why).join(' | ')
    fail(`coverage gate failed for ${expectedSpecialist}: echoed specialist='${c.specialist}' scope='${c.scope}' packetSha='${c.packetSha}', expected scope='${scope}' packetSha='${a.packetSha}'.${detail ? ` Specialist reported: ${detail}` : ''}`)
  }
}

function ruleAppliesTo(rule, specialist) {
  return !rule.specialist || rule.specialist === '*' || rule.specialist === specialist
}

function labelMatches(rule, finding) {
  const wanted = rule.labels || rule.values
  if (!Array.isArray(wanted) || wanted.length === 0)
    fail(`severity-rules: ${rule.kind} rule carries neither 'labels' nor 'values' — a rule that can never match would silently weaken the gate`)
  const got = (finding.label || '').trim()
  return wanted.some(w => rule.case_insensitive ? w.toLowerCase() === got.toLowerCase() : w === got)
}

function matchesRule(rule, specialist, finding, framing) {
  if (!ruleAppliesTo(rule, specialist)) return false
  switch (rule.kind) {
    case 'explicit_label':
    case 'severity_field':
    case 'category_label':
      return labelMatches(rule, finding)
    case 'confidence_threshold':
      return typeof finding.confidence === 'number' && finding.confidence >= rule.min
    case 'framing_with_confidence':
      return framing === rule.framing && typeof finding.confidence === 'number' && finding.confidence >= rule.min
    default:
      // unknown kind = the table is newer than this interpreter; guessing would silently weaken the gate
      fail(`severity-rules: unknown rule kind '${rule.kind}' — update ~/.claude/workflows/pr-review.js to interpret it`)
  }
}

function criticalGuardSatisfied(finding) {
  return finding.blocking === true
    && typeof finding.impact_scope === 'string'
    && finding.impact_scope.trim() !== ''
    && !downgradeScopeMatches(finding.impact_scope)
    && nonBlankStringList(finding.verified_assumptions)
    && Array.isArray(finding.unverified_assumptions)
    && finding.unverified_assumptions.length === 0
}

function nonBlankStringList(value) {
  return Array.isArray(value)
    && value.length > 0
    && value.every(item => typeof item === 'string' && item.trim() !== '')
}

function downgradeScopeMatches(impactScope) {
  const scope = impactScope.toLowerCase()
  const localOrAdvisoryImpact = [
    /\bmachine-local\b/,
    /\blocal-only\b/,
    /\bdeveloper workflow\b/,
    /\badvisory\b/,
    /\bobservability\b/,
    /\bignored state\b/,
    /\bignored generated\b/,
  ].some(pattern => pattern.test(scope))
  if (!localOrAdvisoryImpact) return false

  return ![
    /\bauthoritative\b/,
    /\bmerge-blocking\b/,
  ].some(pattern => pattern.test(scope))
}

// The table's matcher identifies Critical candidates; this guard narrows final
// Critical severity to proven merge blockers. Candidates that fail it remain
// visible as Important instead of silently disappearing from the fix queue.
function normalizeSeverity(specialist, finding, framing) {
  if ((finding.label || '').trim().toLowerCase() === 'nit') return 'nit'
  if (rules.critical.any_of.some(r => matchesRule(r, specialist, finding, framing))) {
    return criticalGuardSatisfied(finding) ? 'critical' : 'important'
  }
  if (rules.important.any_of.some(r => matchesRule(r, specialist, finding, framing))) return 'important'
  return 'suggestion'
}

function normConfidence(f) {
  const c = typeof f.confidence === 'number' ? f.confidence : 0
  const scale = (SPECIALISTS[f.specialist] || {}).confidenceScale || 100
  return (c / scale) * 100
}

function byConfidenceDesc(x, y) {
  return normConfidence(y) - normConfidence(x)
}

// ---------------------------------------------------------------------------
// Phase: Categorize
// ---------------------------------------------------------------------------

phase('Categorize')
const cat = await agent([
  'You are the diff categorizer for the pr-review gate. Work read-only; do not modify any file. Do not review the changes — only verify and categorize.',
  '',
  `1. Verify the diff packet at ${a.packetPath}: compute its SHA-256 (sha256sum or shasum -a 256) and byte count (wc -c). Expected: SHA-256 ${a.packetSha}, ${a.packetBytes} bytes. Return the observed SHA-256 verbatim in packetShaObserved; if the file is missing or unreadable, return 'UNREADABLE'.`,
  `2. Run: git status --short — return verbatim in statusShort. Run: git log --no-decorate ${a.baseCommit}..${a.headRef} — return verbatim in commitLog.`,
  '3. Inspect the diff packet hunks and set two flags: commentChanges = any added or removed comment line in source files (including mixed code+comment hunks); typeChanges = any hunk introducing or modifying class / interface / type / struct / enum / trait / dataclass / schema definitions.',
].join('\n'), { label: 'categorize', phase: 'Categorize', schema: CATEGORIZE_SCHEMA })

if (!cat) fail('categorizer returned no usable output — fail closed')
if (cat.packetShaObserved !== a.packetSha)
  fail(`diff packet integrity check failed: expected SHA-256 ${a.packetSha}, observed '${cat.packetShaObserved}'`)

// path routing uses the main-session-computed args.changedFiles, never an
// agent echo — a truncated echo would silently narrow the specialist fan-out
const categories = categorizePaths(a.changedFiles)

const applicable = ALWAYS.slice()
if (categories.codePaths.length > 0) applicable.push('pr-test-analyzer')
if (categories.docsPaths.length > 0 || cat.commentChanges) applicable.push('comment-analyzer')
if (categories.codePaths.length > 0) applicable.push('silent-failure-hunter')
if (cat.typeChanges) applicable.push('type-design-analyzer')

log(`Categorized ${a.changedFiles.length} changed files (code=${categories.codePaths.length}, docs=${categories.docsPaths.length}, tests=${categories.testPaths.length}, operational=${categories.operationalPaths.length}); Stage 1 specialists: ${applicable.join(', ')}`)

const ctx = {
  base: a.base,
  baseCommit: a.baseCommit,
  headRef: a.headRef,
  scope,
  packetPath: a.packetPath,
  packetBytes: a.packetBytes,
  packetSha: a.packetSha,
  files: a.changedFiles,
  statusShort: cat.statusShort,
  commitLog: cat.commitLog,
  criteria: a.criteria,
}

// ---------------------------------------------------------------------------
// Phase: Stage 1 — parallel specialist fan-out (true barrier)
// ---------------------------------------------------------------------------

phase('Stage1')
const stage1 = await parallel(applicable.map(name => () =>
  agent(specialistPrompt(name, ctx), {
    agentType: SPECIALISTS[name].agentType,
    label: `stage1:${name}`,
    phase: 'Stage1',
    schema: SPECIALIST_SCHEMA,
  })))

// fail-closed: every specialist must echo matching scope + packetSha (no partial aggregation)
applicable.forEach((name, i) => assertCoverage(stage1[i], name))

const findings = []
const strengths = []
applicable.forEach((name, i) => {
  const r = stage1[i]
  for (const f of r.findings) {
    const severity = normalizeSeverity(name, f, r.framing)
    if (severity === 'nit') continue
    if (severity === 'suggestion' && (f.label || '').trim().toLowerCase() !== 'suggestion')
      log(`severity fallback: [${name}] label '${f.label}' matched no escalation rule — treated as Suggestion (verify the label vocabulary if this looks wrong)`)
    findings.push({ ...f, specialist: name, severity })
  }
  for (const s of r.strengths) strengths.push({ specialist: name, note: s })
})

const hasCritical = findings.some(f => f.severity === 'critical')
log(`Stage 1 complete: ${findings.length} findings from ${applicable.length} specialists (Critical present: ${hasCritical})`)

// ---------------------------------------------------------------------------
// Phase: Stage 2 — code-simplifier, only when no Critical
// ---------------------------------------------------------------------------

phase('Stage2')
let stage2Ran = false
if (hasCritical) {
  log('Stage 2 skipped: Critical findings present — polishing code with Critical issues is wasted effort')
} else {
  const flagged = findings.length === 0 ? 'Stage 1 flagged nothing.' :
    `Stage 1 already flagged the following (do not duplicate them):\n${findings.map(f => `- [${f.specialist}] ${f.severity}: ${f.why}`).join('\n')}`
  const stage2 = await agent(specialistPrompt('code-simplifier', ctx, `## Stage 1 summary\n${flagged}`), {
    agentType: SPECIALISTS['code-simplifier'].agentType,
    label: 'stage2:code-simplifier',
    phase: 'Stage2',
    schema: SPECIALIST_SCHEMA,
  })
  assertCoverage(stage2, 'code-simplifier')
  for (const f of stage2.findings) findings.push({ ...f, specialist: 'code-simplifier', severity: 'suggestion' })
  for (const s of stage2.strengths) strengths.push({ specialist: 'code-simplifier', note: s })
  stage2Ran = true
}

// ---------------------------------------------------------------------------
// Phase: Verify — token gate: Critical/Important ONLY
// (un-pruned verify over all findings measured 671k tokens in the PoC)
// ---------------------------------------------------------------------------

phase('Verify')
const toVerify = findings.filter(f => f.severity === 'critical' || f.severity === 'important')
log(`Verifying ${toVerify.length} Critical/Important findings (Suggestions are not verified — token gate)`)

const verdicts = await parallel(toVerify.map((f, i) => () =>
  agent(verifyPrompt(f, ctx), {
    label: `verify:${f.specialist}:${f.file}`,
    phase: 'Verify',
    schema: VERDICT_SCHEMA,
  })))

toVerify.forEach((f, i) => {
  const v = verdicts[i]
  if (!v) fail(`verifier for [${f.specialist}] ${f.file} returned no usable output — fail closed`)
  // a verdict can remove a Critical from the fix queue, so it gets the same
  // coverage echo gate as the specialists that put it there
  if (v.scope !== scope || v.packetSha !== a.packetSha)
    fail(`verifier for [${f.specialist}] ${f.file} echoed scope='${v.scope}' packetSha='${v.packetSha}', expected scope='${scope}' packetSha='${a.packetSha}' — verdict rejected, fail closed`)
  f.verdict = v.verdict
  f.verdictReasoning = v.reasoning
  if (v.missingVerification) f.missingVerification = v.missingVerification
  if (f.severity === 'critical' && (v.verdict === 'needs-verification' || v.missingVerification)) {
    f.severity = 'important'
    log(`verified downgrade: [${f.specialist}] ${f.file} moved Critical -> Important because verifier returned ${v.verdict}`)
  }
})

// ---------------------------------------------------------------------------
// Aggregate (caps from the shared severity table; refuted findings excluded
// but returned for transparency — no silent drops)
// ---------------------------------------------------------------------------

const refuted = findings.filter(f => f.verdict === 'refuted')
const kept = findings.filter(f => f.verdict !== 'refuted')
const critical = kept.filter(f => f.severity === 'critical').sort(byConfidenceDesc)
const important = kept.filter(f => f.severity === 'important').sort(byConfidenceDesc)
const suggestions = kept.filter(f => f.severity === 'suggestion').sort(byConfidenceDesc)

if (important.length > caps.important) log(`Important findings capped: showing ${caps.important} of ${important.length} (highest normalized confidence first; overflow returned in importantOverflow)`)
if (suggestions.length > caps.suggestion) log(`Suggestions capped: showing ${caps.suggestion} of ${suggestions.length} (overflow returned in suggestionsOverflow)`)
log(`pr-review gate result: ${critical.length} Critical, ${important.length} Important, ${suggestions.length} Suggestions, ${refuted.length} refuted by verification`)

// caps bound the rendered fix queue (review-criteria.md), but the capped-out
// tail is still returned — content must never be silently unrecoverable
return {
  scope,
  base: a.base,
  headRef: a.headRef,
  packetSha: a.packetSha,
  specialists: applicable.concat(stage2Ran ? ['code-simplifier'] : []),
  categories,
  commentChanges: cat.commentChanges,
  typeChanges: cat.typeChanges,
  critical,
  important: important.slice(0, caps.important),
  importantOverflow: important.slice(caps.important),
  importantTotal: important.length,
  suggestions: suggestions.slice(0, caps.suggestion),
  suggestionsOverflow: suggestions.slice(caps.suggestion),
  suggestionsTotal: suggestions.length,
  strengths,
  refuted,
  stage2Ran,
  stopCondition: critical.length === 0 && important.length === 0
    ? 'Critical 0 / Important 0: stop the gate loop; Suggestions alone do not justify another run.'
    : 'Re-run only after addressing Critical/Important findings, and focus the next pass on prior finding resolution.',
  reviewChurnGuidance: 'On the third or later pass, if Critical/Important findings keep appearing or changing without stable blocker evidence, call out possible review churn and return the decision to a human maintainer.',
}
