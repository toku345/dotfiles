# ADR 0014: No Custom Auto-Mode Configuration for Chezmoi Workflow

## Status

Accepted (2026-04-28)

## Context

### 1. 背景: chezmoi 運用と classifier 評価の二層構造

本リポジトリの dotfiles 運用には、Claude Code の安全境界として 2 つの独立した gate がある:

- **運用層 gate**: `chezmoi apply` を No.13 が手動実行する。source state (`~/.local/share/chezmoi/`) から home directory への反映は、agent が直接行わず、user の review を経る運用が確立している
- **推論層 gate**: Anthropic 既定の auto-mode classifier。tool call 単位で destructive / scope-escalation 操作を判定する

これら 2 層はそれぞれ独立に作用する。本 ADR は推論層についての判断を記録する。

### 2. 当初の懸念 (origin)

PR #155 で、`~/.local/share/chezmoi/private_dot_claude/{CLAUDE.md,settings.json}` 等の
chezmoi source state の編集が、default `Self-Modification` rule に該当して classifier に
block / confirmation を求められるのではないか、という懸念があった。これを回避するため
`Chezmoi Source Edits` rule を `autoMode.allow` に追加する設計が進められた。

### 3. PR #155 の経緯

PR #155 では 5 round の critique 反復を経て、最終的に project-scope `.claude/settings.json`
に rule を配置した (commit `7aca6c9`)。23 commits に膨張し、レビュー単位として重くなった。

### 4. 根本的な問い直し

本 ADR の検討セッションで、No.13 から 2 つの根本的な問いが提起された:

- 「そもそも当該 rule は本当に必要なのか?」
- 「auto-mode は Anthropic 主導で進化していくため、独自色を強めない方が良いのでは?」

これらの問いに答えるべく、empirical test と分析推論を実施した。

### 5. Empirical evidence

#### Test 1 (2026-04-27): chezmoi source benign 編集

**目的**: `Chezmoi Source Edits` rule が classifier に届いていない状態で、
chezmoi source 編集が `Self-Modification` で block されるか検証。

```bash
# 実施日: 2026-04-27

# Pre-condition: 当時 ~/.claude/settings.json (user-scope deployed) に Chezmoi Source Edits
# rule が存在していたため、テストのため一時的に除去
cp ~/.claude/settings.json /tmp/settings.backup.json
jq 'del(.autoMode.allow)' ~/.claude/settings.json > /tmp/no-rule.json
cp /tmp/no-rule.json ~/.claude/settings.json

# Verify: classifier から rule が消えたことを確認
claude auto-mode config | jq '.allow[] | select(test("Chezmoi"))'
# → 空出力 (rule 不在を classifier 視点で確認)

# Action: chezmoi source state file (`private_dot_claude/settings.json`) に
# benign key を追加 → 即座に revert (非破壊)
# 実施例: Edit tool で `_test_marker_delete_me: "test"` を追加 → 削除
# プログラム的代替: jq '. + {"_test_marker_delete_me": "test"}' で書き出し → revert

# 観測: block / confirmation は発火せず、edit は通過

# Post: ~/.claude/settings.json を backup から復元
cp /tmp/settings.backup.json ~/.claude/settings.json
```

**結論**: rule なしでも classifier は chezmoi source 編集を Self-Modification と判定しない。

#### Test 2 (2026-04-27): hard carve-out (a) — 新規 `.chezmoiscripts/run_*` script 作成

**目的**: PR #155 で「`Chezmoi Source Edits` rule の hard carve-out (a)–(d) は default 評価へ落ちる」
と設計された経路が、実際に classifier 層で gate になっているか検証。

```bash
# 実施日: 2026-04-27
# 状態: ~/.claude/settings.json から Chezmoi Source Edits を一時的に削除し、
#       claude auto-mode config | jq '.allow[] | select(test("Chezmoi"))' で不在を確認

# Action: 新規ファイル .chezmoiscripts/run_once_after_TEST_HARD_CARVEOUT_DELETE_ME.sh を作成

# 観測: block / confirmation は発火せず、Write は通過
# その後、テストファイルを削除し ~/.claude/settings.json を backup から復元
```

**結論**: hard carve-out (a) の defense は classifier 層では機能していなかった。
(b) (c) (d) は本 test で直接検証していないが、(a) と同じく `Chezmoi Source Edits` rule の
`autoMode.allow` 内に列挙される機構で組み込まれていたため、同様に gate として機能して
いなかった可能性が高い (要直接検証)。少なくとも (a) について PR #155 で 5 round critique を
経て設計された defense-in-depth は実装されていなかったことが empirical に確定した。

#### Test 3 (2026-04-28): 典型的 dotfiles 操作の default rule 適用

**目的**: 典型的な dotfiles workflow が default rule のみで friction なく完了するか検証。

```bash
# 実施日: 2026-04-28

# Test 3a: working branch への push (--dry-run)
git push --dry-run origin feat/opus-4-7-settings-update
# → 通過 (default `Trusted repo` + `Git Push to Working Branch` で covered)

# Test 3b: read-only API (gh pr view)
gh pr view 155 --json title,state
# → 通過 (default `Read-Only Operations` で covered)

# Test 3c: git fetch
git fetch origin
# → 通過 (default `Read-Only Operations` で covered)

# Test 3d: chezmoi diff (local read)
chezmoi diff
# → 通過 (local 操作)

# Meta-finding (Test 3 副次): ~/.claude/settings.json 直接編集の試行
jq 'del(.autoMode)' ~/.claude/settings.json > /tmp/...
# → classifier が Self-Modification として正しく block
# 既定 rule は deployed agent settings と chezmoi source state を区別する堅牢な挙動
```

**結論**: 典型 dotfiles 操作は default rule で問題なく通過する。さらに Self-Modification は
agent's own configuration (deployed) に対しては正しく機能している。

### 6. 分析: クロス repo push シナリオ

Test 3 で empirical に検証できなかった唯一のシナリオは、**working repo (dotfiles) で session を開始しているが、別の `toku345/*` repo に `git push` する** ケース。
これは custom `Trusted source control` rule が唯一の付加価値を提供するシナリオである。

default `Data Exfiltration` rule の文言:

> "...git push to repos outside the source control orgs listed in Environment..."

- **Trusted source control rule なし**: 別 repo への push は `Data Exfiltration` として soft_deny (= confirmation prompt)
- **Trusted source control rule あり**: confirmation なしで通過

dotfiles 運用ではクロス repo push は稀であり、たまに confirmation が走るのは許容範囲。

## Decision

**`autoMode` キーを `private_dot_claude/settings.json` から完全に削除し、
Anthropic 既定 (`$defaults`) のみで運用する。**

### Why

- **Empirical**: Test 1/2/3 の結果、custom rule は default を超える保護を提供しないことが
  二重・三重に確認された。具体的には:
  - `Chezmoi Source Edits` rule は不在でも block を発火させない (Test 1)
  - hard carve-out (a) は rule の有無に関わらず classifier 層で gate になっていない (Test 2)。
    (b)–(d) は同機構のため同様の挙動と推定
  - 典型 dotfiles 操作は default rule で friction なく通過する (Test 3a-3d)
- **Robustness of defaults**: Test 3 meta-finding で、既定 `Self-Modification` rule が
  agent's own configuration に対しては正しく機能していることが確認された (`~/.claude/settings.json`
  直接編集を block)。Anthropic 既定の堅牢性は信頼に値する
- **Maintenance**: auto-mode は Anthropic 主導で継続的に evolve するため、独自 rule は
  drift / 誤適用 / 保守負債のリスク源となる
- **YAGNI**: 稀なクロス repo push の confirmation 発火 1 回 < 独自 rule の維持コスト

## Consequences

### Positive

- **Customization ゼロ**: Anthropic 既定の進化を自動追随し、独自 rule の drift リスクなし
- **User-scope 汚染ゼロ**: PR #155 commit `7aca6c9` の「`~/.claude/settings.json` should hold
  only environment-agnostic configuration」原意を完全達成
- **設定 surface の最小化**: レビュー単位 / 保守負債なし
- **判断 closed**: 本 ADR で auto-mode customization の判断は確定。今後の friction 観測時のみ
  再検討する

### Negative

- 別の `toku345/*` personal repo への push は default で confirmation が発火する
  (mitigation: 稀シナリオで、user 確認 1 回で通過する。動作不能ではない)

### Follow-on changes

- `private_dot_claude/CLAUDE.md` の「着手前ゲート」セクションから「明示許可している例外」
  サブセクションを削除
- 「`chezmoi apply` 自体は意図的に未登録」記述は削除 (`autoMode` 自体がないため意味を失う)
- 「着手前ゲート」セクション全体を簡素化し、default rule の参照方法 (`claude auto-mode defaults` /
  `claude auto-mode config`) のみ残す
- ハード block 一覧を実 `permissions.deny` 配列の構成に合わせて拡充
- `Self-Modification` 言及を `Create Unsafe Agents` に訂正 (rule name 誤り修正)

### Risks

- **将来 Anthropic が default を tighten する**: chezmoi 操作で friction が頻発する場合、
  `.claude/settings.local.json` (per-project, classifier 読込確認済み 2026-04-27) に最小 waiver を
  追加する選択肢を再検討する
- **chezmoi 自体の運用変更**: 例えば pre-commit hook で自動 apply する運用に変更した場合、
  本 ADR の前提 (運用層 gate = 手動 apply) が崩れるため再評価が必要

### Out of scope

- **`Bash(chezmoi apply:*)` の現在位置**: 現状 `permissions.allow` 内のため autoMode 評価前に
  許可されている。follow-up タスクで `permissions.ask` に移動して user gate を回復する予定
  (本 ADR 対象外)
- `permissions.deny` 配列の見直しは別件
- managed settings / `--settings` flag scope の利用は個人 dotfiles で不要

## References

- PR #155: <https://github.com/toku345/dotfiles/pull/155>
- 公式 docs: <https://code.claude.com/docs/en/auto-mode-config>
- 関連 ADR: [0001 Claude Code Sandbox — Git Least Privilege Model](0001-claude-code-sandbox-git-least-privilege.md) (`~/.claude/settings.json` user-global と `.claude/settings.json` project-scope の使い分けに関する判断)

## 影響ファイル

- `private_dot_claude/settings.json` (`autoMode` キー削除)
- `private_dot_claude/CLAUDE.md` (「着手前ゲート」セクション簡素化)
- `docs/adr/0014-no-custom-auto-mode-for-chezmoi.md` (本 ADR)
