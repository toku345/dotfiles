---
name: triple-review
description: 3 種類のレビュー (/pr-review-toolkit:review-pr, /security-review, /codex:adversarial-review) を実行し、共通指摘・単独指摘・レビュー間の矛盾を集約するレビュー専用スキル。明示的な `/triple-review` 呼び出しでのみ起動する。review-only で修正は行わない。
disable-model-invocation: true
---

# Triple Review

Aggregate three independent pre-PR reviewers into a single summary:
`/pr-review-toolkit:review-pr`, `/security-review`, and
`/codex:adversarial-review`. Codex runs in the background; the two
Claude-side reviewers run sequentially in the foreground. Then the
findings are cross-referenced.

**This skill is review-only.** Never apply fixes, write patches, or
modify files — even if reviewers request it.

**All user-visible output — review content, the Summary, error
messages — MUST be in Japanese (日本語)**, per the global `CLAUDE.md`
convention. The English section headings (`## PR Review` etc.) are
kept as structural labels; everything else is Japanese.

Raw slash-command arguments:
`$ARGUMENTS`

## Supported argument forms

- `[<PR>]` — bare number (`123`), hash-prefixed (`#123`), or full
  GitHub PR URL. All three are passed through to `gh pr view`
  directly; no manual normalization is needed.
- `[--base <ref>]` — explicit base for working-tree review. Mutually
  exclusive with a PR argument.

## Steps

### 1. Parse arguments

From `$ARGUMENTS`, extract:

- `user_pr_arg`: the first positional value if any (the user may have
  passed `123`, `#123`, or a full URL — do not normalize)
- `user_base`: the value of `--base` if any

If both `user_pr_arg` and `user_base` are set, fail loud:

> エラー: PR 引数と `--base` は相互排他です。PR を指定した場合、
> base は PR 自身から取得します。

### 2. Verify dependencies

**Claude-side reviewers**: inspect the available-skills list in the
current session's system-reminder context and confirm both appear:

- `pr-review-toolkit:review-pr`
- `security-review`

**Codex**: verify the codex-companion script exists:

```bash
test -f "$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
```

The slash command `/codex:adversarial-review` has
`disable-model-invocation: true` and is therefore intentionally absent
from the available-skills list. Script-presence check is the reliable
equivalent for this dependency.

If any check fails, fail loud naming the missing component and
instructing the user to install the corresponding plugin.

### 3. Pre-flight validation

Determine the review target and `codex_base`:

**If `user_pr_arg` is set**:

1. Run `gh pr view "<user_pr_arg>" --json number,headRefName,baseRefName`.
   If this fails, fail loud (the PR was not found or not accessible).
2. Compare `.headRefName` with the output of `git branch --show-current`.
   If they differ, fail loud and instruct the user:
   > PR <PR#> のブランチではありません。`gh pr checkout <PR 引数>`
   > を実行してから再度お試しください。
3. Set `codex_base = .baseRefName`.

**Else**, try `gh pr view --json number,headRefName,baseRefName` with
no argument (this detects a PR associated with the current branch):

- If successful: this is a PR-branch review. Set
  `codex_base = .baseRefName`.
- If it fails: this is a working-tree review. Set
  `codex_base = user_base` if provided, else `main`.

### 4. Launch Codex adversarial review (background)

Invoke the Codex adversarial-review runtime directly via the `Bash`
tool with `run_in_background: true`:

```bash
node "$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs" adversarial-review --base <codex_base>
```

Record the returned shell ID for retrieval in Step 7.

**Why direct bash (not the `Skill` tool)**:
`/codex:adversarial-review` sets `disable-model-invocation: true` in
its frontmatter and therefore cannot be invoked by Claude via the
`Skill` tool. The plugin author designed review commands to require
explicit user invocation. The direct-bash invocation here is an
informed bypass of that constraint, justified because
`/triple-review` itself sets `disable-model-invocation: true` — so
the downstream Codex call is a user-initiated chain, not an
autonomous model decision.

### 5. Run /pr-review-toolkit:review-pr (foreground)

Invoke `pr-review-toolkit:review-pr` via the `Skill` tool with no
arguments. It derives the target from current git state.

Capture the sub-skill's final response text; this is what will be
rendered under `## PR Review` in step 8.

### 6. Run /security-review (foreground)

Invoke `security-review` via the `Skill` tool with no arguments.

Capture its final response text for `## Security Review`.

### 7. Retrieve Codex result

Use `BashOutput` with the shell ID from Step 4 to retrieve Codex
stdout. If the process has not finished, wait until it completes
before proceeding.

If the process exited with non-zero status, fail loud and include its
stderr plus the outputs already captured in steps 5 and 6 so the
user can still use them.

### 8. Aggregate & render

Emit the results in this order:

```
## PR Review
<step 5 output, verbatim>

## Security Review
<step 6 output, verbatim>

## Adversarial Review
<step 7 output, verbatim>

## Summary
- **共通指摘 (高信頼度)**: <2 名以上が指摘した項目>
- **単独指摘 (要確認)**: <1 名のみが指摘した項目>
- **矛盾**: <同一箇所/論点で主張が食い違う指摘>
```

The Summary is built by LLM judgment over the three captured outputs:

- **共通指摘 (高信頼度)**: findings agreed on by 2 or more reviewers.
  Match primarily by `file:line` when both findings anchor to
  lines; for architectural / design-level findings (typical of
  `/codex:adversarial-review`) without line anchors, match by
  semantic similarity of the finding text.
- **単独指摘 (要確認)**: findings flagged by only one reviewer.
- **矛盾**: reviewers disagree on the same location or topic (e.g.
  one says "extract this", another says "inline this").

## Error handling

Fail loud at any step on error. Do not silently degrade to a
two-reviewer summary or drop a failed reviewer. When failing, if
earlier reviewers already produced output, surface it in the failure
message so the user can still use it.

## 重要な制約 (再掲)

- **Review-only**: この skill は修正を行いません。パッチ提示、ファイル
  編集、修正案の実装は一切行わないでください。
- **日本語出力**: ユーザーに提示する全ての出力 (各レビューの本文、
  Summary、エラーメッセージ) は日本語で記述してください。English
  section headings (`## PR Review` 等) は構造ラベルとして保持しますが、
  その配下のコンテンツは全て日本語とします。
