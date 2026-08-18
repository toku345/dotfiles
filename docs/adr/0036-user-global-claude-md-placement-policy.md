# ADR 0036: user-global CLAUDE.md の記載内容を「常時ロード予算 × 分類器ポリシー面」の二重制約で判断する

## Status

Accepted (2026-08-17)

## Context

### 1. 常時ロード予算という当初の問題設定

`private_dot_claude/CLAUDE.md` (→ `~/.claude/CLAUDE.md`) は **全プロジェクト・全セッションで無条件にロードされる**。2026-08-17 時点で 17,623 bytes / 212 行。加えて `output-styles/JUIZ.md` (73 行) がシステムプロンプトを置換する形で常駐する。

[PR #3572827](https://github.com/toku345/dotfiles/commit/3572827) は同じ問題意識で `AGENTS.md` を path-scoped rule (`.claude/rules/**`) へ移設し、AGENTS.md を ~17.8KB → ~15.3KB に削減した。しかし user-global CLAUDE.md には同じ手当てが未適用のまま残っていた。

当初の設計方針は素朴に「冗長な記述を削る」だった。特に Opus 5 が既に訓練済みの内容 (YAGNI/KISS、prompt injection 耐性、「事実で検証する」等) は削減候補として妥当に見えた。

### 2. 設計途中で判明した前提の反転

Claude Code v2.1.233 で `autoMode` 設定ブロックが導入され、公式 docs ([Configure auto mode](https://code.claude.com/docs/en/auto-mode-config)) が次を明示した:

> The classifier reads the same CLAUDE.md content Claude itself loads, so an instruction like "never force push" in your project's CLAUDE.md steers both Claude and the classifier at the same time.

つまり CLAUDE.md は **トークンコストであると同時に、auto-mode 分類器のポリシー入力面** である。制約・禁止事項の記述を削ると、Claude の挙動だけでなく **分類器の判断も緩む**。

この事実は当初方針を部分的に無効化した。「Opus 5 が既に知っているから冗長」という判断基準は、分類器 steering としての価値を評価していなかった。具体例として `## 未信頼データと共有リソース操作` セクションは、prompt injection 耐性が訓練済み挙動であることを理由に圧縮候補としていたが、exfiltration に対する分類器 steering として機能しうるため撤回した。

### 3. 併せて確認した分類器の実態 (live tool)

`claude auto-mode defaults` / `claude auto-mode config` (v2.1.233) および公式 docs より:

- soft_deny は 66 件、hard_deny は 1 件 (Data Exfiltration)、allow 17 件、environment 20 件
- soft_deny に `Self-Modification` (`.claude/settings*.json` / `CLAUDE.md` / `.claude/rules/` 等への guard 弱体化編集)、`Instruction Poisoning` (エージェントが読み戻す instruction ファイルへの permission grant / BLOCK-rule bypass 内容の書き込み)、`Safety Bypass Flag` (`DANGEROUSLY_*` 系)、`Auto-Mode Bypass` が存在する
- `permissions.ask` の content-scoped rule は **分類器より前に評価され、auto mode でも必ずプロンプトする**。すなわち CLAUDE.md の「着手前ゲート」は steering であり、実効的な gate は `permissions.ask` 側にある
- **v2.1.211 で Default / protected branches の既定が撤廃**され、working repo の任意ブランチ (main 含む) への push が既定で許可になった。本リポジトリで main への直接 push を止めているのは `permissions.ask` の `Bash(git push:*)` のみである

実際、本 ADR の設計中に `~/.claude/settings.local.json` への probe 書き込みが `Blocked by classifier` で拒否された。`Self-Modification` が期待どおり機能していることの empirical な確認になった ([ADR 0014](0014-no-custom-auto-mode-for-chezmoi.md) Test 3 の meta-finding と一致)。

## Decision

**user-global `CLAUDE.md` の記載内容は、常時ロード予算と分類器ポリシー面という二重の制約で判断する。**

適用する基準:

1. **参照時にだけ必要な gotcha は外に出す** — 特定ツール・特定環境の運用詳細は `docs/**`、skill、path-scoped rule (`.claude/rules/**`) へ移し、CLAUDE.md にはポインタのみ残す。これはトークン予算の観点
2. **制約・禁止事項は冗長性だけを理由に削らない** — 分類器 steering として機能するため、Claude が訓練済みであることは削除の十分条件にならない。これはポリシー面の観点
3. **削除判断の順序**: 「これは分類器に読ませたい制約か」を先に問う。Yes なら残す。No で、かつ参照時ロードで足りるなら外に出す。No で、参照もされないなら削る

### 併せて確定した個別判断

**sandbox セクションを「harness 既定への上乗せ」構造に変える。** 従来の文言は「あらゆる再実行前にユーザー承認を得る」であり、harness 既定 (「sandbox 起因の失敗が明らかなら即座に `dangerouslyDisableSandbox` で再試行せよ、聞くな」) と正面から矛盾していた。競合する指示は双方のコンプライアンスを弱める。切り分け手順は harness に委ね、書き込み・破壊的操作・未信頼データ由来のコマンドと恒久的 allowlist 追加にのみ承認要件を課す形に改める。

**この際、許可付与形ではなく制限スコープ定義形で書く。** 「読み取り専用は harness 手順に従ってよい」と書くと、分類器が読み戻したときに permission grant として機能し `Instruction Poisoning` に該当しうる。「本セクションの承認要件の適用範囲は以下に限る」という制限の定義として書くことで、同じ運用結果を得ながらその risk を回避する。

**`autoMode.classifyAllShell` は採用しない。** narrow shell allow rule が分類器より先に解決して起動オプションを評価させない問題は、該当 rule (`Bash(codex exec:*)`) の外科的削除で対処する。`classifyAllShell` は全 Bash コマンドにレイテンシと分類器呼び出しを課すため、現状の問題規模に対して過剰である。`Bash(npm run:*)` / `Bash(cargo run:*)` は同種の性質を持つが日常頻度が高く、リスクとのバランスから今回は維持する。将来これらが問題化した場合の再検討余地として記録する。

**`autoMode` キーは再導入しない。** [ADR 0014](0014-no-custom-auto-mode-for-chezmoi.md) が「`autoMode` キーを完全に削除し Anthropic 既定のみで運用する」を Accepted で決定済みであり、再開条件を「今後の friction 観測時のみ」と明示している。本 ADR の設計過程で `autoMode.environment` の追加を一度検討したが、**friction は一切観測されていない**ため再開条件を満たさない。加えて `Source control: github.com/toku345 and all repos under it` のような entry は user-global 設定であるため会社リポジトリを含む全セッションに影響し、影響範囲が意図より広い。ADR 0014 の決定を**覆さず再確認する**。将来 friction を観測した場合は、その実測を添えて ADR 0014 を supersede する形で再提案する。

## Consequences

### Positive

- **削除判断に再現性のある基準ができる** — 「Opus 5 が知っているか」ではなく「分類器に読ませたい制約か」で判断するため、今後の CLAUDE.md 編集で同じ議論を繰り返さずに済む
- **harness との指示競合が解消される** — sandbox セクションが「対立」から「上乗せ」になり、どちらに従うかの非決定性がなくなる
- **`Instruction Poisoning` を意識した文言設計が明文化される** — instruction ファイルに permission grant 形の文を書かない指針が残る
- **既存 ADR との整合** — ADR 0014 を実測なしに覆さない姿勢を明示的に記録した

### Negative / Risks

- **削減幅は限定的** — 本方針適用後の実測削減は約 1,840 bytes (約 10%) にとどまり、うち 73% が agmsg gotcha の移設と実装ノートの圧縮の 2 項目に集中する。トークン削減自体を目的にすると期待外れになる。本方針の主たる価値は正確性・ポリシー整合・知見固定にある
- **「分類器に読ませたい制約か」の判定は主観を含む** — 明確な線引きではないため、判断が揺れた場合は残す側に倒す
- **公式仕様への依存** — 分類器が CLAUDE.md を読むという性質は Anthropic 側の実装であり、将来変更されうる。変更を検知したら本 ADR を再検討する
- **`npm run` / `cargo run` の narrow-allow リスクを残した** — 意図的な受容であり、問題化したら `classifyAllShell` を再検討する

## Related ADRs

- [ADR 0014](0014-no-custom-auto-mode-for-chezmoi.md): auto-mode customization を行わない決定。本 ADR は**覆さず再確認する**
- [ADR 0018](0018-restrict-auto-mode-override-to-non-interactive.md): auto-mode における CLAUDE.md 上書き例外の適用範囲。§4 に分類器の steering モデルを記録済みで、CLAUDE.md 側の重複記述は本 ADR の方針に従い同 §4 への参照に置換した
- [ADR 0015](0015-multi-persona-output-styles.md): output-style persona。JUIZ は user-global default であり常時ロード予算に含まれる

## 影響ファイル

- `private_dot_claude/CLAUDE.md` (agmsg gotcha の移設、実装ノートの圧縮、sandbox セクションの書き換え、stale な参照の除去)
- `private_dot_claude/settings.json` (`permissions.allow` から `Bash(codex exec:*)` を削除)
- `private_dot_claude/skills/codex-usage/SKILL.md` (上記の挙動変化を注記)
- `private_dot_claude/agents/rich-hickey-reviewer.md` (常駐 description の短縮)
- `docs/claude-code-plugins.md` (agmsg gotcha の移設先)
- `.claude/rules/claude-code-config.md` (`permissions.ask` の load-bearing 性、`autoMode` の読み取り元、`agentPushNotifEnabled` の default 矛盾を記録)
- `docs/adr/0036-user-global-claude-md-placement-policy.md` (本 ADR)
