---
name: pr-review-coach
description: Japanese-only PR understanding coach. Use when the user wants to prepare their own review, understand a branch diff, identify questions to ask, or build review judgment before running a merge gate. Requires an explicit --base <ref-or-commit> for the first turn, then resumes from local state on answer turns. Asks exactly one question at a time and stores resumable local state outside the target worktree. Single-agent only; does not spawn specialist reviewers, does not produce Critical/Important/Suggestions gate findings, and does not decide merge readiness.
---

# pr-review-coach

## Goal

Help the user understand the committed branch diff before a gate review. Run a one-question-at-a-time coaching loop with a local state file, so the conversation can resume without turning into a fix queue.

This skill is intentionally separate from `$pr-review`:
- `$pr-review-coach` builds the user's review judgment.
- `$pr-review` is the merge gate / audit workflow.

## Hard Boundaries

- Respond in Japanese.
- Require an explicit `--base <ref-or-commit>` on the first turn. If `--base` is missing, continue only when exactly one state file for the current repo and HEAD can be resolved.
- Treat `<base>` as an already available local ref or commit. Do not run `git fetch`, `gh`, or network commands.
- Review only committed changes in `<base>...HEAD`.
- Do not edit project files, apply patches, run formatters, or dirty tracked files.
- The only permitted write is the external coach state file under `${XDG_STATE_HOME:-$HOME/.local/state}/codex/pr-review-coach/`.
- Do not spawn subagents or specialist reviewers.
- Do not read unrelated memory files, previous session logs, or review history. Use only the current user prompt, this skill file, the local coach state file, and the git context collected below unless the user explicitly supplies extra context.
- Do not use the merge-gate taxonomy `Critical`, `Important`, or `Suggestions`.
- Do not decide whether the PR can merge.
- Do not create a fix queue. Phrase observations as questions, reading focus, assumptions to verify, or learning notes.
- Ask exactly one question per response unless the user explicitly asks for a summary or the coaching loop is complete.

## Preconditions

Run these checks before reading the diff:

1. **Clean worktree** — Run `git status --porcelain --untracked-files=normal`.
   - If the command fails, abort with the command output.
   - If output is non-empty, abort and explain that the coach covers committed branch diff only, so uncommitted changes would be silently excluded.

2. **State location and HEAD pinning** — Run:
   - `REPO_ROOT=$(git rev-parse --show-toplevel)`
   - Compute `REPO_KEY` as the SHA-256 of the absolute `REPO_ROOT` path.
   - `STATE_ROOT=${CODEX_PR_REVIEW_COACH_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/codex/pr-review-coach}`
   - `STATE_DIR=$STATE_ROOT/repos/$REPO_KEY`
   - `HEAD_REF=$(git rev-parse HEAD)`
   - `HEAD_SHORT=$(git rev-parse --short=12 HEAD)`
   If any command fails, abort with the command output.

3. **Base or continuation resolution** — Extract optional `--base <ref-or-commit>` from the user prompt.
   - Reject base values that start with `-` or `+`, contain `:`, or contain whitespace.
   - If `--base` is present, set `BASE` to that value, run `BASE_COMMIT=$(git rev-parse --verify "$BASE^{commit}")`, `BASE_SHORT=$(git rev-parse --short=12 "$BASE_COMMIT")`, and `STATE_FILE=$STATE_DIR/$BASE_SHORT-$HEAD_SHORT.md`. If either command fails, abort with the command output and ask the user to provide a valid local base ref or commit.
   - If `--base` is missing, treat the prompt as an answer continuation. Find state files matching `$STATE_DIR/*-$HEAD_SHORT.md`.
   - If no matching state file exists, stop with: `--base <ref-or-commit> を指定してください。例: $pr-review-coach --base main`
   - If multiple matching state files exist, stop and ask the user to rerun with `--base` because the continuation base is ambiguous.
   - If exactly one matching state file exists, set `STATE_FILE` to it, load `status`, `base`, `base_commit`, and `head_ref` from the file, set `BASE` and `BASE_COMMIT` from those fields, and compute `BASE_SHORT=$(git rev-parse --short=12 "$BASE_COMMIT")`.
   - For continuation state, abort if `status` is not `active`, if `head_ref` differs from `HEAD_REF`, if `BASE_COMMIT` does not resolve to a commit, or if the state file lacks `current_question`.

## Procedure

After preconditions pass:

1. Collect only read-only context:
   - `git status --short`
   - `git log --no-decorate "$BASE_COMMIT..$HEAD_REF"`
   - `git diff --name-only "$BASE_COMMIT"..."$HEAD_REF"`
   - `git diff "$BASE_COMMIT"..."$HEAD_REF"`
   - Run each command independently. If any command fails, abort with the command output and do not continue with partial context.

2. If the diff is empty, run the final guard and say there are no committed changes relative to the base.

3. Prepare or load the local coach state:
   - Use the `STATE_ROOT`, `STATE_DIR`, and `STATE_FILE` resolved in Preconditions.
   - Create the state directory with `mkdir -p`; if creation or a temporary write+rename preflight fails, abort instead of falling back to the target worktree.
   - Resolve `SKILL_DIR` as this skill's directory and run `bash "$SKILL_DIR/scripts/cleanup-state.sh" --state-root "$STATE_ROOT" --current "$STATE_FILE"` before creating or updating state. If cleanup fails, warn and continue; cleanup failure must not alter the coaching result.
   - The state file is outside the target worktree and must not be committed.
   - If the state file does not exist, create it after reading the diff.
   - If it exists, load it and resume from its `current_question`.
   - If `base_commit` or `head_ref` in the state file differs from the pinned values, do not reuse it. Create or use the state file derived from the current `$BASE_SHORT-$HEAD_SHORT` pair.
   - Cleanup policy is centralized in `scripts/cleanup-state.sh`: delete state files older than 30 days, keep the 20 newest files per repo, and always preserve `$STATE_FILE` even when that exceeds the cap.

4. State file contents should be compact Markdown:
   - `status`: `active` or `complete`
   - `base`: the user-provided base string
   - `base_commit`: pinned base commit
   - `head_ref`: pinned HEAD
   - `snapshot`: 2-3 bullets about the diff
   - `questions`: numbered candidate questions, maximum 5
   - `answered`: prior question/answer pairs
   - `current_question`: the single question to ask next
   - `review_focus`: up to 3 reading focus bullets
   - `learning_hook`: 1-2 learning notes
   - `ledger_draft`: notes the user can carry into their review

5. Read the diff for understanding, not triage:
   - What changed?
   - Which files should the user read first?
   - What intent or assumption is visible from the diff?
   - What is still unclear from code alone?
   - What review habit would help on this PR?

6. Keep output bounded:
   - Generate at most 5 candidate questions in the state file.
   - Output exactly 1 question in the response.
   - At most 3 review focus bullets.
   - At most 2 learning hooks.
   - Prefer one strong question over several weak ones.

7. Continuing a coaching loop:
   - If the user answers the current question, update `answered`, advance `current_question`, and ask the next question.
   - If the user invokes the skill again without an answer, repeat the current question with shorter context.
   - If all questions are answered, produce the final summary, set `status: complete`, and clear `current_question` so the state cannot be resumed as an active answer continuation.
   - If the user asks for a summary early, produce a summary from answered items and leave the state resumable.

8. Final guard:
   - Run `git status --porcelain --untracked-files=normal` again.
   - Run `git rev-parse HEAD` again and compare with `HEAD_REF`.
   - If any final guard command fails, abort with the command output.
   - If any worktree content or HEAD changed, abort and explain that the coaching output may not match the current branch state.

## Output Format

For an active coaching turn, use this section structure:

```markdown
# Review Coach

## State
- 状態ファイル:
- 進捗:

## Snapshot
- 何が変わったか:
- 最初に読むべき場所:

## Next Question
1. ...

## Why This Question
- ...
```

For the final summary, use this section structure:

```markdown
# Review Coach Summary

## What You Clarified
- ...

## Review Focus
- ...

## Learning Hook
- この PR から学べること:
- 練習するレビュー習慣:

## Review Ledger Draft
- 迷った点:
- 見落としやすい理由:
- 次のチェックリスト項目:
- 自動化候補:
```

## Style

- Be concrete and grounded in the committed diff.
- If a conclusion depends on missing information, state what to verify instead of guessing.
- Use plain Japanese. Keep each bullet short enough to act on.
- Keep the coaching loop one-question-at-a-time. Do not list the remaining questions unless the user asks.
- Avoid praise, scoring, severity labels, and merge advice.
