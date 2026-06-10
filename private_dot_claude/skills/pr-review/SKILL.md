---
name: pr-review
description: >
  Claude-side pre-PR review gate. Resolves the branch's base ref (gh PR view or explicit
  --base), pins an authoritative diff packet, then launches the pr-review dynamic workflow
  (~/.claude/workflows/pr-review.js) which fans out up to 8 review specialists
  (code-reviewer, security-reviewer, adversarial-reviewer, pr-test-analyzer,
  comment-analyzer, silent-failure-hunter, type-design-analyzer, code-simplifier),
  fails closed on coverage, and verifies Critical/Important findings. Use before creating
  a pull request as a quality gate for thick changes — especially where the Codex CLI
  `$pr-review` skill is unavailable. Triggers: "pre-PR review", "PR 前レビュー",
  "レビュー gate を回して", "run the pr-review gate".
---

# pr-review (Claude-side)

## Goal

Run a comprehensive specialist review of the current branch's committed changes against its base, then render a single actionable report. This is the Claude Code counterpart of the Codex `$pr-review` skill for environments where Codex is unavailable; both share one gate policy (`references/review-criteria.md`) and one severity table (`references/severity-rules.json`). Design: `docs/design/claude-pr-review.md` (dotfiles repo), decision: ADR 0029.

## Architecture note (read first)

`gh` does NOT work inside workflow subagents (sandbox-pinned). Everything that needs `gh` or `dangerouslyDisableSandbox` happens HERE in the main session (Preconditions + Collect). The workflow receives all of it as `args` and uses only `git`. Do not move base resolution into the workflow.

## Preconditions

Run these in order. If any fails, abort with the indicated error; do not launch the workflow.

1. **Clean worktree** — Run `git status --porcelain --untracked-files=normal`. If the command fails, abort with its output. If output is non-empty, abort with:
   > "Worktree has uncommitted changes: <list>. The review covers committed branch diff only; uncommitted changes would be silently excluded. Commit or stash first, then retry."

   Sandbox caveat: in repos whose tracked names collide with sandbox baseline denies (e.g. a chezmoi source dir), sandboxed `git status` reports ghost char-special entries (`crw-rw-rw- nobody nogroup 1, 3` under `ls -la`) as untracked. Verify with `ls -la | grep '^c'` and re-run the status check outside the sandbox before trusting a non-empty result.

2. **Base ref resolution** — Determine `$BASE` from one of three sources, in priority order:
   - (a) **Explicit base** from the user prompt (e.g. `--base develop`, "review against develop"): use it verbatim and skip `gh`. If it matches a full 40-character hexadecimal commit OID (the same shape the workflow's args validation requires), set `$BASE_REF` to it. Otherwise validate it as a branch name (`git check-ref-format --branch "$BASE"`; reject leading `-`/`+`, `:`, or other refspec separators), run `git fetch --quiet origin "refs/heads/$BASE"` (abort on failure), set `$BASE_REF=FETCH_HEAD`, and resolve `$BASE_COMMIT` immediately.
   - (b) **`--allow-no-pr`** in the prompt: skip `gh`. Run `git fetch --quiet origin` and `git remote set-head origin --auto` (abort if either fails), then `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` (abort if it fails or is empty). Strip `origin/` for `$BASE`, keep the full `origin/<branch>` as `$BASE_REF`, and add a `**Degraded coverage**: no PR base, fell back to default branch` line to the final report.
   - (c) **Open PR**: run `gh pr view --json baseRefName,baseRefOid --jq '[.baseRefName,.baseRefOid] | @tsv'`. `gh` typically needs `dangerouslyDisableSandbox: true` (macOS Seatbelt / hosts.yml restrictions). If it fails with a real credential error, abort with "Run `gh auth login` and retry." Only an explicit "no pull request found" result is the no-PR case; any other failure aborts loudly. On success: validate the branch name with the same rules as (a), `git fetch --quiet origin "refs/heads/$BASE"` (abort on failure), verify `FETCH_HEAD^{commit}` equals the returned `baseRefOid` exactly (abort with both OIDs if not), then set `$BASE_REF=FETCH_HEAD`.

   If none of (a)–(c) yields a base, abort with:
   > "No PR found for the current branch and no explicit base provided. Create a draft PR first (so the review pins the PR's base ref), provide an explicit base, or pass `--allow-no-pr` to fall back to the default branch (residual scope-divergence risk acknowledged)."

3. **Pin the base commit** — `BASE_COMMIT=$(git rev-parse --verify "$BASE_REF^{commit}")` immediately after assigning `$BASE_REF`; record the exact output. Abort on failure.

## Collect (main session)

1. `HEAD_REF=$(git rev-parse HEAD)` — record it.
2. **Empty diff check + changed files**: run `git diff --name-only "$BASE_COMMIT...$HEAD_REF"` and record the output as `changedFiles` (one path per array element — this main-session list is the authoritative specialist-routing input; the workflow refuses to re-derive it from an agent echo). If empty, run the Final guard below, then report `No committed changes relative to <base>; nothing to review.` and stop.
3. **Diff packet**: `diff_packet=$(mktemp "${TMPDIR:-/tmp}/pr-review-diff.XXXXXX")` (suffix-free template — suffixed templates collide on BSD mktemp), then `git diff "$BASE_COMMIT...$HEAD_REF" > "$diff_packet"`. Record byte count (`wc -c`) and SHA-256 (`sha256sum` / `shasum -a 256`). Abort if any step fails. The packet is authoritative for all specialists.
4. **Shared references** (deploy-skew defense — file existence alone is not enough):
   - Read `~/.claude/skills/pr-review/references/review-criteria.md` and verify it contains the sentinel `PR_REVIEW_CRITERIA_SHARED_V1`. Keep the full contents as `criteria`.
   - Read `~/.claude/skills/pr-review/references/severity-rules.json`, parse it as JSON, and verify `sentinel == "PR_REVIEW_SEVERITY_RULES_V1"` and `version == 1`. Keep the parsed object as `severityRules`.
   - If either check fails, abort with:
     > "Shared gate policy missing or stale at ~/.claude/skills/pr-review/references/. Run `chezmoi apply -v` to redeploy, then retry."

## Launch the workflow

Invoke the Workflow tool with the script deployed at `~/.claude/workflows/pr-review.js` (expand `~` to the absolute home path) and pass every value as real JSON (objects/arrays, not JSON-encoded strings):

```
Workflow({
  scriptPath: "<home>/.claude/workflows/pr-review.js",
  args: {
    base: "<$BASE>",
    baseCommit: "<$BASE_COMMIT>",
    headRef: "<$HEAD_REF>",
    packetPath: "<$diff_packet>",
    packetBytes: <byte count>,
    packetSha: "<sha256>",
    changedFiles: ["<path>", ...],
    criteria: "<contents of review-criteria.md>",
    severityRules: <parsed severity-rules.json object>
  }
})
```

The workflow validates args (including both sentinels) and fails closed on any coverage mismatch, so a thrown workflow error is a gate failure — report it verbatim and stop; never retry with weakened inputs or partial coverage.

The workflow runs in the background; wait for its completion notification before rendering. Do not start other work that mutates this repository while it runs.

## Final guard (after the workflow returns)

1. Re-run `git status --porcelain --untracked-files=normal`. If non-empty, abort with:
   > "Review subagents or concurrent tooling changed the worktree: <list>. These changes were not part of the reviewed committed diff. Revert, commit, or stash them, then retry."
2. Re-run `git rev-parse HEAD` and compare with the recorded `$HEAD_REF`. If it differs, abort with:
   > "HEAD changed during review: started at `<old>`, now `<new>`. The completed specialist results do not cover the current commit. Re-run the review."
3. Remove the diff packet temp file.

## Render the result

The workflow returns a structured object (`critical`, `important`/`importantOverflow`/`importantTotal`, `suggestions`/`suggestionsOverflow`/`suggestionsTotal`, `strengths`, `refuted`, `specialists`, `stage2Ran`). Render it as:

```
# PR Review: <branch> vs <base>

<**Degraded coverage** line if --allow-no-pr was used>

Specialists: <result.specialists, comma-separated> | scope `<result.scope>` | packet `<first 12 chars of packetSha>`

## Critical Issues (N found)
- [<specialist>] <why> [<file>:<line>]
  - Verdict: <verdict>(<verdictReasoning>; missing verification: <missingVerification> if present)
  - Suggested fix: <fix>

## Important Issues (shown X of <importantTotal>, cap 5)
- [<specialist>] <why> [<file>:<line>] — verdict: <verdict><, missing verification: ... if present>

<if importantOverflow is non-empty:>
### Beyond cap (verified but not prioritized)
- [<specialist>] <one-line summary of why> [<file>:<line>] — verdict: <verdict>

## Suggestions (shown X of <suggestionsTotal>, cap 3)
- [<specialist>] <why> [<file>:<line>]

## Refuted by verification (excluded from the fix queue)
- [<specialist>] <why> — <verdictReasoning>

## Strengths
- [<specialist>] <note>

## Recommended Action
1. Fix Critical issues first
2. Address Important issues
3. Consider Suggestions
4. Re-run this skill after fixes to verify prior Critical/Important findings
```

Omit empty sections (except render `## Critical Issues (0 found)` explicitly — the absence of Criticals is the gate's headline). Findings with `verdict: needs-verification` stay in the fix queue with their missing verification stated; never silently drop them.

## Re-review

On a re-run after fixes, prioritize confirming whether each prior Critical/Important finding was fixed, remains, or was intentionally rejected. Raise new findings only when they are clear merge blockers; do not extend the loop with new nits, style feedback, or optional refactors. (This guidance also reaches the specialists via the bundled criteria.)
