# Claude-side PR Review — Handoff Notes

**As of 2026-06-10. Branch `claude-pr-review-skill`, draft PR #258.**

別 PC で作業を再開するための引き継ぎ資料。詳細設計は [`claude-pr-review.md`](claude-pr-review.md)、決定の経緯は [ADR 0029](../adr/0029-claude-pr-review-dynamic-workflow.md) を参照。この資料は Phase 7 (finalize) で削除してよい一時ドキュメント。

## TL;DR

会社環境で Codex CLI が使えないため、Codex `$pr-review` 相当の pre-PR レビュー gate を **Claude Code の dynamic workflow** で作る。**Phase 1-6/7 完了**。Phase 5/6 は 2026-06-10 にこの branch 自身の diff で実走済み（gate は本物の Critical 2件を検出・verify confirmed → 修正済み、これが seeded-control を上回る positive control になった）。残は **Phase 7 finalize**（この handoff 削除 + design doc Accepted 化）と、任意の re-review 実走。

## 現在地

- branch `claude-pr-review-skill`（メイン repo で作業。**worktree は廃止済み**）、latest main (`78b543e`) に rebase 済み
- draft PR #258、**CI 全 green**（gitleaks 含む。specialist `.md` の "API keys/passwords/tokens" 散文は誤検知されない）
- コミット: `0bb42d6` docs / `38a1b9b` feat

## 完了 (Phase 1-2)

| ファイル | 内容 |
|---|---|
| `docs/adr/0029-claude-pr-review-dynamic-workflow.md` | 決定記録 (Accepted) |
| `docs/design/claude-pr-review.md` | 詳細設計 (7 phase, workflow 疑似コード, sandbox-boundary split) |
| `private_dot_claude/agents/security-reviewer.md` | MIT。upstream 逐語保持 + scope contract を構造化 coverage に調整 |
| `private_dot_claude/agents/adversarial-reviewer.md` | Apache-2.0。同上 |
| `private_dot_claude/agents/LICENSE-*` / `NOTICE-*` | upstream と sha256 一致で同梱 |
| `docs/design/codex-pr-review.md` | N3: 前方参照 + 環境分岐注記を追記 |
| `private_dot_codex/skills/pr-review/references/severity-rules.json` | Phase 2: severity escalation table (canonical, sentinel `PR_REVIEW_SEVERITY_RULES_V1`)。Codex `SKILL.md` step 4 のインライン logic を置換 |
| `private_dot_claude/skills/pr-review/references/*.tmpl` | Phase 2: `{{ include }}` thin template で canonical を Claude 側へ配信 (drift 構造的に不可能)。Go Template Policy 逸脱の理由は design doc に記録 |
| `private_dot_claude/workflows/pr-review.js` | Phase 3: dynamic workflow 本体。args sentinel 検証 → categorizer agent (packet sha + file list + content flags) → Stage1 `parallel()` barrier → coverage fail-closed → severity-rules.json 解釈で正規化 → Stage2 条件 spawn → Critical/Important のみ verify → caps 集約。stub harness で 17 assertions pass (S1 混在 / S2 Stage2 / S3 coverage 失敗 / S4 args 不正) |
| `private_dot_claude/skills/pr-review/SKILL.md` | Phase 4: main-session wrapper。preconditions / `gh` base 解決 (OID 照合) / diff packet / sentinel 検証付き reference 読込 / `Workflow({scriptPath, args})` / 事後 worktree+HEAD guard / markdown render |

## Phase 5-6 実走結果 (2026-06-10)

- **実測**: 20 agents (categorizer 1 + Stage1 7 + verify 12) / **約 1.23M subagent tokens / 約 25 分**（18 files, 113KB packet）。token gate は機能（Suggestion 9件は verify 除外）したが、コストは diff サイズでなく **Critical/Important 件数**に比例する — 詳細は design doc の Open questions 更新参照
- **Gate 検出 → 修正済み**: ①`normConfidence` が security-reviewer の 0-10 scale を未正規化（cap 切り捨てで security finding が silent drop）→ per-specialist `confidenceScale` + `importantOverflow`/`suggestionsOverflow` 返却で修正。②workflow logic のテスト未コミット → `tests/claude/test_pr_review_workflow.mjs`（25 assertions）+ CI job 追加。③`category_label` rule の case-sensitivity → `case_insensitive: true` + verifier mirror。④categorizer の file list 信頼ギャップ → `args.changedFiles`（main session 計算値）を authoritative 化
- **運用 gotcha**: Workflow tool は `args` を JSON 文字列で渡すことがある → script 冒頭で defensive `JSON.parse`。sandbox ghost char-special entries が precondition 1 を偽陽性にする → SKILL.md に注記済み。早発の completed task-notification があり得る（TaskOutput が running を返す間は信用しない）
- 未表示だった Important 5件 (cap 超過分・旧実装で silent drop) は transcripts (`subagents/workflows/wf_40ebee15-f21/`) に残存。修正後の re-review で再収集可能

## 残作業 (Phase 7)

- **Phase 7**: finalize（この handoff doc 削除、design doc を Accepted に）。任意: 修正後の re-review 実走（コスト ~1M tokens 級、ユーザー判断）

## 別 PC での再開手順

1. `git fetch origin && git switch claude-pr-review-skill`（PR #258 のブランチ）
2. **worktree は使わない**（メイン repo で作業する方針に変更済み。理由: worktree は `~/.local/share/chezmoi-worktrees/` の sandbox write 許可が要り煩雑だった）
3. `docs/design/claude-pr-review.md` の Phase 2 から着手
4. dynamic workflow を試すときは下記「制約」を踏まえる

## 重要な決定・制約・gotcha（実装前に必読）

- **gh は workflow subagent の Bash から動かない**（sandbox-pinned、`~/.config/gh/hosts.yml: operation not permitted`。PoC 実証済）。→ base 解決は**メインループ**で `gh`（`dangerouslyDisableSandbox` 可）、workflow 内は `git` のみ。これが sandbox-boundary split の核心
- **cross-model adversarial は放棄**（Claude-in-Claude、self-review bias 受容）。会社環境で Codex 不可のため。adversarial-reviewer も Claude subagent として動かす
- **token gate 必須**: 全 finding を verify に回すと 671k tokens（PoC 実測）。Critical/Important のみ verify に回す枝刈りを Phase 3 で必ず実装
- **specialist の構成**: pr-review-toolkit の6体（`code-reviewer`/`silent-failure-hunter`/`type-design-analyzer`/`comment-analyzer`/`pr-test-analyzer`/`code-simplifier`）は `agentType` で再利用。不足2体（`security-reviewer`/`adversarial-reviewer`）が今回移植した `private_dot_claude/agents/*.md`
- **Workflow API は `agent/parallel/pipeline/log/phase/budget` のみ**。lifecycle handle (agent kill) は無い → fail-closed は「`parallel()` barrier で全 subagent 完了を待ってから JS 判定」で実現。`parallel()` は barrier、`pipeline()` は barrier-free。Workflow script は **plain JS**（`Date.now`/`Math.random` 不可）
- **2系統共存**: Codex 版 `$pr-review`（自宅・Codex 利用可能環境）と Claude 版（会社）は**環境別に共存**、merge しない。ADR 0012（Skill tool 限定）も Codex design の credit-economy 決定も覆さない
- **gitleaks の既知ダミー**: `private_dot_config/git/config:65` の AWS 公式ダミーキー（`AKIA…EXAMPLE` 形式。この handoff doc では gitleaks 誤検知を避けて literal を伏せている）は git-secrets の allowlist（実 secret でなく、2023年からの既存設定）。specialist `.md` は gitleaks 誤検知なし（CI green で実証済）

## 参照

- 決定: [`docs/adr/0029-claude-pr-review-dynamic-workflow.md`](../adr/0029-claude-pr-review-dynamic-workflow.md)
- 設計: [`docs/design/claude-pr-review.md`](claude-pr-review.md)
- Codex 版（環境別 sibling、Codex 利用可能環境で authoritative）: [`docs/design/codex-pr-review.md`](codex-pr-review.md)
- PR: [#258](https://github.com/toku345/dotfiles/pull/258) (draft)
- 元ネタ: dynamic workflows = Anthropic blog "A harness for every task"
