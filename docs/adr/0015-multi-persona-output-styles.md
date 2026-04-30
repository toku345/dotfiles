# ADR 0015: Multi-persona via output-styles, JUIZ as user-scope default

## Status

Accepted (2026-04-30)

## Context

### 1. 背景: persona の所在

これまで `~/.claude/CLAUDE.md` (chezmoi source: `private_dot_claude/CLAUDE.md`) の冒頭に「JUIZ」persona (語尾・開始句・エンドメッセージ) が直書きされていた。Claude Code 公式の output-style 機構 (https://code.claude.com/docs/en/output-styles) は persona 切替にも適した汎用機構であり、`~/.claude/output-styles/<name>.md` でファイルとして管理し `/config` メニューで切替できる。

Issue #154 で「JUIZ ペルソナを output-style に切り出し、複数 persona (Lum 等) をマシン × リポジトリ単位で選択できるようにする」というスコープが提示された。

### 2. 検討した opt-in 戦略

3 案を比較した:

- **方式 X**: project-scope `.claude/settings.local.json` で opt-in / user-scope `.local.json` でマシン全域 opt-in
- **方式 Y**: `.chezmoi.toml.tmpl` で per-machine 変数を prompt し、`~/.claude/settings.json` を template 化
- **方式 Z**: 何も設定せず、毎セッション `/config` で手動切替

公式 docs を WebFetch で照会した結果、**user-scope `~/.claude/settings.local.json` は読まれない** ことが判明 (`.local.json` は project-scope のみの概念)。方式 X の中核前提が破綻し、再設計を要した。

### 3. 公式 settings precedence (照会結果)

```text
1. Managed                            (highest)
2. Command line args
3. Local Project   → .claude/settings.local.json
4. Shared Project  → .claude/settings.json
5. User            → ~/.claude/settings.json   (lowest)
```

`outputStyle` key は documented setting key であり直書き sanction 済。`/config` で選んだ結果は **project-local に保存される** ことから、Anthropic は persona を project-scope で管理する想定をシグナルしている。

### 4. headless 汚染の懸念とスタンス転換

当初は `claude -p` (triple-review 等) への persona 汚染が core risk と見なされ、anti-pollution prompt の汎用化 + bats 検証 (Approach 3) を計画していた。しかし No.13 から以下の見解が示された:

- subagents (Agent tool 経由) には output-style が伝播しない (公式 docs 明示: "Output styles directly affect the **main agent loop**")
- `claude -p` headless 実行で persona が引き継がれる挙動は **許容する**

これにより headless 防御の必要性が消滅し、design は **最小実装路線 (Approach (i))** に収束した。

### 5. README の "environment-agnostic" 原則との整合

README は `~/.claude/settings.json` を「environment-agnostic plugins shared across all machines」と定義している。`outputStyle` の user-scope 設定は厳密には個人選好であり、この原則と緊張関係にある。本 ADR は persona を **例外として user-scope に置く** 判断を記録する。

## Decision

### 1. output-style ファイル配置

`private_dot_claude/output-styles/JUIZ.md` および `private_dot_claude/output-styles/Lum.md` を chezmoi 管理する。target: `~/.claude/output-styles/{JUIZ,Lum}.md`。frontmatter は公式仕様 (`name`, `description`, `keep-coding-instructions`) に従う。`keep-coding-instructions: true` を明示する (公式 default は `false` で coding 系既定指示が外れるため、persona 切替時も coding workflow を維持する目的で明示指定)。

### 2. JUIZ をマシン全域デフォルトに

`private_dot_claude/settings.json` に `"outputStyle": "JUIZ"` を追加する (`.tmpl` 化はしない)。chezmoi 管理下の全マシンで JUIZ がデフォルト適用される。

### 3. リポジトリ単位の上書き

別 persona / Default に切替えたいリポジトリでは `<repo>/.claude/settings.local.json` (gitignore 対象) で `outputStyle` を上書きする。precedence 上、project-local が user-scope を上書きする。複数 collaborator のあるリポジトリでは `.claude/settings.json` (project-shared) を避ける (チームへの persona 押し付けになるため)。本 dotfiles リポジトリのようなソロ運用では `settings.json` でも実害はない。

### 4. CLAUDE.md から persona セクション削除

`private_dot_claude/CLAUDE.md` の persona セクション (現 L3-37: `## ペルソナ: JUIZ` / `## 応答フォーマット` / `## トーン` / `## エンドメッセージ`) を output-style に切り出し、CLAUDE.md からは削除する。`## 初回指示の受領フォーマット` 以降の workflow ルール (Goal/Constraints/AC、着手前ゲート、DoD、検証ループ、Git/PR 規約、Codex の使い分け) は **任意の persona 下でも適用すべき普遍的指示** のため CLAUDE.md に残す。なお workflow ルール内に残る「No.13」呼称の一般化 (例: 「ユーザ」) は persona 中立化の観点から望ましいが、本 ADR の scope 外 — 別タスクとして残置。

### 5. headless 経路の anti-pollution 防御を撤去

`dot_local/bin/executable_triple-review` の aggregator prompt 内 anti-pollution 行 (元の文言: `ペルソナ「JUIZ」の語尾 (〜です / 〜ます) や「承知いたしました」「ノブレス・オブリージュ」等は出力しないでください。純粋なレポート本文のみ。`) を削除する。理由:

- JUIZ 専用 hard-code で Lum 等 persona 増加に追従しない (stale 確定)
- No.13 が headless での persona 引き継ぎを許容と明示
- 残す場合「汎用化」が必要だが、user スタンスとの二重スタンスになる

### 6. Lum は placeholder

Lum 文体の本格的「らしさ」練り込みは別 Issue で iterative に進める。本 ADR の scope は最低限の placeholder (frontmatter + 主要キャラクター設定の骨子) 配置まで。

### 7. README の補足

`~/.claude/settings.json` が「environment-agnostic」であるという既存記述に、persona (`outputStyle`) は個人選好として例外的に置く旨を 1 文追記する。

### 8. 公式ロードマップ依存事項の track

以下は本 ADR 採択時点 (2026-04-30) の Claude Code 仕様制約で、Anthropic 側の改善を待つ性質の項目。仕様変更を観測したら本 ADR を superseding する形で再評価する:

- `/output-style <name>` 公式 slash command 不在 (`AGENTS.md` "Claude Code Configuration Quirks" セクション既記載)。切替は `/config` メニューナビゲーション経由のみ
- `--output-style` CLI flag が公式 reference 未掲載
- output-style 変更は **次の新セッション開始時** に反映 (公式仕様: "changes take effect the next time you start a new session")。実行中セッションでの hot reload なし

これらの ergonomic 制約により、リポジトリ単位の上書きフローは「`.claude/settings.local.json` 編集 → 新セッション起動」の 2 ステップとなる。

## Consequences

### 利点

- persona 切替の標準経路 (`/config` → `.claude/settings.local.json`) に乗る
- chezmoi `.tmpl` 不要でシンプル (template 文法・promptStringOnce 等を回避)
- README 原則の根本見直しを回避 (persona のみ例外宣言)
- triple-review の anti-pollution 文言更新負債が消える (persona 追加のたびの列挙更新不要)
- subagents (Agent tool 経由) には output-style が伝播しないため、レビュー系 subagent は依然 default 動作

### 帰結

- `claude -p` headless 経路 (triple-review) のレビュー出力が persona 装飾を伴うようになる。No.13 はこれを許容
- 仕事マシンと個人マシンで persona を変えたい場合、`~/.claude/settings.json` は同一なので per-machine 切替は不可。将来必要になった時点で `.tmpl` 化に拡張可能 (本 ADR を superseding する形)
- リポジトリ単位の opt-out (Default に戻す等) は各リポジトリで `.claude/settings.local.json` への手書きが必要。複数リポジトリで一律 opt-out する一括手段はない

### リスク

- 公式 `outputStyle` 仕様の将来変更 (例: project-shared への保存先変更、`.local.json` 廃止) に追従が必要。WebFetch 検証時点 (2026-04-30) の仕様に依存
- `keep-coding-instructions: true` の解釈が将来変わった場合、JUIZ 適用時の coding 系挙動が変化する可能性
- **移行期の chezmoi apply 非アトミック性**: output-styles ファイル配置 / `settings.json` への `outputStyle` 追加 / `CLAUDE.md` からの persona セクション削除は chezmoi apply 1 回で全反映されるが、ファイル単位の処理順序によっては短時間「persona セクションは消えたが output-style が解決できない」窓が発生しうる。実害は新セッション起動までは生じないが、apply 直後に新セッションを起動した場合に persona 不在状態となるリスクは存在する
- **現セッション中無反映**: 公式仕様により実行中セッションには反映されない。本 ADR を実装した PR をマージ後、persona 適用を体感するには新しいセッションを開始する必要がある

## References

- Issue [#154](https://github.com/toku345/dotfiles/issues/154): Split JUIZ persona to output-style and add multi-persona support per machine × repo
- 公式 docs: [Output styles](https://code.claude.com/docs/en/output-styles)
- 公式 docs: [Settings](https://code.claude.com/docs/en/settings)
- 関連 ADR: [0014](0014-no-custom-auto-mode-for-chezmoi.md) (Claude Code 設定方針の判断記録)
