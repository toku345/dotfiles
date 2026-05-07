# ADR 0019: headless `claude -p` strict-envelope ガイダンスを汎用規定として CLAUDE.md に残す

## Status

Accepted (2026-05-07)。`35945db` (2026-05-04) の review fix によって既に実装済みであり、本 ADR は当該決定の事後文書化 + 正当化として位置付ける。

## Context

### 1. ADR 0017 の意図と Migration step 6

[ADR 0017](0017-triple-review-headless-output-style.md) は `triple-review` の `claude -p` spawn における persona 汚染を、専用 `outputStyle` + sentinel preflight で source 抑制する設計を採択した。Migration step 6 は明示的に以下を要求していた:

> 6. `private_dot_claude/CLAUDE.md` から `headless 起動 (claude -p)` バレット削除

CLAUDE.md (user-global) からの当該バレット削除は、ADR 0017 が「triple-review 専用ガイダンスを output-style に移管したため CLAUDE.md 側の規定は不要」と判断したことに基づく。

### 2. ADR 0017 適用直後の review fix (`35945db`)

ADR 0017 の実装は commit `5beeed5` (2026-05-04) で行われ、そのレビュー fix `35945db` (同日) は CLAUDE.md headless バレットを **削除ではなく汎用化して再導入** する判断を採った。コミットメッセージ抜粋:

> Generalize the headless strict-envelope exception in user-global CLAUDE.md to "headless 起動 (claude -p) で機械的に検証・抽出される固定形式が要求された場合", covering JSON/YAML/Markdown envelope/fixed prefix automation across projects without project-specific references (no triple-review mention).

すなわち triple-review 言及を削除した上で、envelope/aggregator/固定プレフィクス系 headless 自動化 **全般** に適用される一般ガイダンスとして再導入した。

### 3. ADR 0017 本文と現実装の乖離

`35945db` は ADR 0017 本文を更新しなかったため、ADR 0017 Migration step 6 の文面と現状 CLAUDE.md の記述が表面上不整合である。`refactor/claude-md-augment-mindset` ブランチの adversarial レビューで「ADR 0017 を反故にする」と指摘された (実体は ADR 0017 が想定しなかった汎用化判断であり、反故ではなく拡張)。

### 4. CLAUDE.md ガイダンスと output-style 防御の役割分離

両者は別レイヤーで動作する:

- **output-style + sentinel + validator (ADR 0017 範囲)**: persona 汚染防止の **source-side technical defense**。機械的 enforcement
- **CLAUDE.md headless ガイダンス (本 ADR 範囲)**: 新規 headless pipeline 設計時の **AI 行動指針**。仮定宣言を省略して raw format を出力するなど、output-style が未配備の段階でも AI 自身が適切に振る舞えるようにする

ADR 0017 は前者を扱い、後者を意図的に削除しようとしたが、`35945db` の判断で後者は別目的の安全網として残置された。

## Decision

**`private_dot_claude/CLAUDE.md` `### 適用除外` の headless `claude -p` バレットを、triple-review 非依存の汎用 strict-envelope ガイダンスとして維持する**。本 ADR で正当化する文面の核は以下:

> headless 起動 (`claude -p`) で機械的に検証・抽出される固定形式が要求された場合: envelope marker / 固定 prefix / 構造化フォーマット (JSON / YAML / Markdown 見出し envelope 等) で aggregator やパイプライン入力に渡される出力では、仮定宣言も省略し要求された生フォーマットのみを返す (envelope 破壊を避けるため)

### Why

- **新規 headless pipeline の安全側 default**: 将来 triple-review 以外の `claude -p` 利用が追加された際、output-style + sentinel + validator の三点セットを構築する前段階で、AI 行動指針として CLAUDE.md ガイダンスが下支えになる
- **ADR 0017 の防御モデルと補完関係**: output-style は source 抑制 (機械的)、CLAUDE.md は AI 自身の行動選択 (推論的)。両者は競合せず、別レイヤーで重複安全網として作用する (defense-in-depth)
- **既存実装が既に依存している事実**: `35945db` 以降、本ガイダンスは triple-review 以外の文脈 (`claude -p` を pipe/aggregator に流す任意のケース) で AI 行動を steering する前提で運用されてきた。撤回すると未文書化の挙動変更となる
- **ユーザー の文書化方針との整合**: `feedback_no_local_adr_refs_in_user_global` および本リポジトリの「accepted ADR との合意逆転を docs-only 修正で済ませない」原則に従い、`35945db` の事実上の決定を ADR として正式記録する

### 受容したトレードオフ

- ADR 0017 本文 Migration step 6 と CLAUDE.md 現状の表面的不整合は残る。本 ADR が両者を橋渡しする pointer として機能する (ADR 0017 Status header に本 ADR への refine note を追記)
- 将来 headless pipeline が再度 triple-review 専用に縮退する設計判断が下された場合、本 ADR と ADR 0017 の両方を superseding する別 ADR が必要

## Consequences

### Positive

- **設計判断の追跡可能性回復**: `35945db` の commit message 内の意図が ADR 層に昇格し、今後同種の review で「ADR 0017 を反故にしている」誤認を防ぐ
- **新規 headless pipeline の参照点明確化**: `claude -p` を新規導入する際、ADR 0017 (技術的防御) + 本 ADR (AI 行動指針) の両方を参照すれば設計が完結する
- **CLAUDE.md ガイダンスの正当化**: 「triple-review 専用」と誤読されがちだったバレットが、汎用ガイダンスとして明示的に位置付けられる

### Negative / Risks

- **将来の headless pipeline で output-style/validator を整備せず CLAUDE.md ガイダンスのみに依存するリスク**: CLAUDE.md は推論的 steering のため、persona 汚染や envelope 破壊の機械的防御にはならない。新規 pipeline 設計時は ADR 0017 パターンの三点セット (output-style + sentinel + validator) を必ず併用すること
- **ADR 0017 本文との表面的不整合が ADR 0017 を読む人を混乱させる可能性**: ADR 0017 Status header への refine note 追記で緩和

### Follow-on changes

- ADR 0017 Status header に本 ADR への refine note を追記 (本 PR `refactor/claude-md-augment-mindset` で同梱)

## Related ADRs

- [ADR 0017](0017-triple-review-headless-output-style.md): triple-review 専用 output-style (本 ADR は ADR 0017 Migration step 6 を refine し、CLAUDE.md headless バレットの汎用化として残置を正当化)
- [ADR 0014](0014-no-custom-auto-mode-for-chezmoi.md): auto-mode + headless intake format の bundle carve-out (headless 部分は ADR 0017 + 本 ADR で扱う、auto-mode 部分は [ADR 0018](0018-restrict-auto-mode-override-to-non-interactive.md) で扱う)
- [ADR 0018](0018-restrict-auto-mode-override-to-non-interactive.md): auto-mode CLAUDE.md 上書き例外を非対話コンテキストに限定 (本 ADR と並行で ADR 0014 を refine)

## 影響ファイル

- `private_dot_claude/CLAUDE.md` (`### 適用除外` headless バレット維持の正当化)
- `docs/adr/0017-triple-review-headless-output-style.md` (Status header に本 ADR への refine note)
- `docs/adr/0019-headless-strict-envelope-general-rule.md` (本 ADR)
