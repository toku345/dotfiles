# ADR 0018: auto-mode における CLAUDE.md 上書き例外を非対話コンテキストに限定する

## Status

Accepted (2026-05-07)

## Context

### 1. ADR 0014 が確立した carve-out の経緯

[ADR 0014](0014-no-custom-auto-mode-for-chezmoi.md) の Follow-on changes は、`private_dot_claude/CLAUDE.md` の「初回指示の受領フォーマット」配下に **2 種類の適用除外** を 1 つの bullet 群として束ねて追記した (PR #159):

- `auto-mode active 時`: harness が `Make reasonable assumptions and proceed on low-risk work` を注入するため、CLAUDE.md の「曖昧さは質問で埋める」原則を上書きし、仮定宣言型で進める
- `headless 起動 (claude -p)`: 対話チャネル不在のため、同じく仮定宣言型で進める

ADR 0014:192-194 はこの 2 つを束ねた根拠として「harness の "Make reasonable assumptions" 注入および対話チャネル不在環境で「質問で埋める」原則が silent failure / aggregation 汚染を起こすため」と一文に圧縮した。

### 2. ADR 0017 による headless 部分の supersede

[ADR 0017](0017-triple-review-headless-output-style.md) は `claude -p` 経由で起きていた persona 汚染を `triple-review` 専用 `outputStyle` + sentinel preflight で source 抑制する設計に切り替え、ADR 0014 の **headless 部分のみ** を supersede した。ADR 0014 Status header にも「auto-mode 関連の `着手前ゲート` セクション置換 bullet は維持」と明記し、auto-mode 側の carve-out は残置すると合意していた。

ただし ADR 0017 採択直後の review fix (`35945db`, 2026-05-04) で、headless 例外は **完全削除ではなく triple-review 非依存の一般 envelope/aggregator ガイダンスとして再導入** された (CLAUDE.md には残るが、文言から `triple-review` 言及を削除し汎用化)。この経緯は ADR 0017 本文には反映されておらず、ADR 0018 で別途整理する (本 ADR は auto-mode 側のみを扱う)。

### 3. 残置された auto-mode carve-out の問題

PR `refactor/claude-md-augment-mindset` のレビュー (Adversarial 側) で以下の論点が提起された:

- ADR 0014 が想定した「silent failure / aggregation 汚染」は **対話チャネル不在環境** (headless pipe / 長時間バッチ) で発生するモード
- **対話 auto-mode** では対話チャネルが構造的に存在し、CLAUDE.md が指示する「曖昧さは質問で埋める」を発火させても silent stall は起き得ない
- 一方で対話 auto-mode 中も harness は `Make reasonable assumptions` を注入し続けるため、CLAUDE.md と harness が衝突する設計

ADR 0014 はこの 2 つのモードを 1 bullet にまとめて carve-out したが、両者は **silent stall リスクの観点では非対称** であり、carve-out の範囲を見直す余地がある。

### 4. auto-mode 分類器の動作モデル (公式 docs に基づく確認)

公式 docs (<https://code.claude.com/docs/en/auto-mode-config>) より:

- auto-mode は **分類器ベース** で tool call を auto-approve / soft-deny / require confirmation に振り分ける
- CLAUDE.md 内の **具体的な指示は hard override ではなく**、Claude 自身の意思決定と分類器の双方への入力として作用する (公式表現: `steers both Claude and the classifier`)
- すなわち CLAUDE.md は **ガイダンス層** であり、harness 注入と排他関係にはない (両者は重み付きで合流する)

この性質により、対話 auto-mode で「曖昧さは質問で埋める」を残しても tool call は auto-approve され続けるため、auto-mode の介入頻度低減効果は維持される。失われるのは「**曖昧な要件下での沈黙的な仮定推定**」のみで、これは ユーザー が望まない挙動である (memory `feedback_verify_claude_code_internals` および本リポジトリの過去 incident と整合)。

## Decision

**ADR 0014 Follow-on changes の auto-mode carve-out を、対話 auto-mode を含む全コンテキスト適用から、非対話コンテキスト (`claude -p` headless / `claude --append-system-prompt-file` 経由のバッチ) のみに限定する。**

実装は `private_dot_claude/CLAUDE.md` `### auto-mode に対する優先順位` セクションで行い、以下の 3 区分を明示する:

1. **対話 auto-mode**: CLAUDE.md の「曖昧さは質問で埋める」を維持。auto-mode は介入頻度低減のシグナルであり、判断責任の委譲ではない
2. **headless 起動 (`claude -p`)**: 対話チャネル不在のため、仮定宣言型または機械的固定フォーマットで進める (詳細は別 ADR で扱う「headless strict-envelope 一般規定」を参照)
3. **`--append-system-prompt-file` バッチ**: 専用 CLAUDE.md を明示注入した自律実行コンテキスト。注入された CLAUDE.md の指示が優先

### Why

- **silent stall リスクの構造的非対称性**: 対話チャネルの有無が決定的な分岐点であり、ADR 0014 が 1 bullet にまとめた根拠は非対話側にしか厳密には当てはまらない
- **auto-mode 分類器の steering モデル**: CLAUDE.md は hard override ではなく入力ガイダンスのため、対話 auto-mode で「質問で埋める」を残しても harness の auto-approve 効果は維持される
- **既知 failure mode との整合**: ユーザー の memory (`feedback_verify_claude_code_internals`) は「auto-mode の振る舞いを falsification なく前提しない」を求めており、対話 auto-mode で曖昧な仮定推定を黙認することはこの方針と矛盾する
- **YAGNI**: auto-mode 全コンテキスト carve-out は ADR 0014 の bundling 都合で設定された幅であり、対話側の利益は薄い

### 受容したトレードオフ

- 対話 auto-mode で介入頻度がわずかに増える (曖昧な要件下のみ)。harness 設計者の「介入頻度を下げたい」シグナルと部分的に衝突するが、**判断責任は ユーザー が保持する** という本リポジトリの基本姿勢を優先する
- 非対話 carve-out の運用詳細 (envelope / 固定 format) は別 ADR (headless strict-envelope 一般規定) で扱うため、本 ADR の scope 外で 1 件 follow-up が必要

## Consequences

### Positive

- **ADR 0014 の合意との整合**: silent stall 根拠は非対話側で維持。対話側は `feedback_verify_claude_code_internals` および本リポジトリ基本姿勢と整合
- **CLAUDE.md ガイダンスの一貫性**: 対話セッションでは常に「曖昧さは質問で埋める」が最上位、auto-mode はその例外ではなくなる (例外は非対話コンテキストのみ)
- **harness モデルとの整合**: auto-mode が Claude を hard override しない steering モデルに従い、CLAUDE.md と排他関係を持たないことが明文化される

### Negative / Risks

- **対話 auto-mode で「曖昧」判定が過剰発火する可能性**: CLAUDE.md の「妥当な仮定で進めると曖昧さやリスクが残る場合のみ質問で埋める」条件で十分絞られる想定だが、過剰発火を観測した場合は条件文言の精緻化で対応 (carve-out 復活ではない)
- **slash command 内の判断再調整**: 本 ADR で対話 auto-mode の question fallback が復活するため、`### 適用除外` 内の slash command 節 (`副作用が限定的な command では確認ループを最小化`) と整合維持に注意。slash command は `Goal 宣言を内包` するため曖昧 trigger が発火しにくく、衝突リスクは低い

### Follow-on changes

- `private_dot_claude/CLAUDE.md` `### auto-mode に対する優先順位` を 3 区分明示形に書き換える (本 PR `refactor/claude-md-augment-mindset` で同梱)
- ADR 0014 Status header の追記: `auto-mode active 時 carve-out` は本 ADR (0018) で対話/非対話を分離する形に refine された旨
- ADR 0017 の amendment は別 ADR (headless strict-envelope 一般規定) で扱う

## Migration

1. ADR 0014 Status header に supersede note (`auto-mode active 時 carve-out` 部分のみ ADR 0018 で refine) を追記
2. `private_dot_claude/CLAUDE.md` `### auto-mode に対する優先順位` セクションで対話 / `claude -p` / `--append-system-prompt-file` の 3 区分を明示
3. `chezmoi apply -v` で `~/.claude/CLAUDE.md` を更新し、新規 Claude Code session で挙動を確認 (対話 auto-mode で曖昧な要件を投げ、質問が発火することを観測)

## Related ADRs

- [ADR 0014](0014-no-custom-auto-mode-for-chezmoi.md): auto-mode classifier rule の設計判断 (本 ADR は Follow-on changes の auto-mode carve-out を refine)
- [ADR 0017](0017-triple-review-headless-output-style.md): triple-review 専用 output-style (headless 部分を supersede 済、本 ADR は auto-mode 部分のみ扱う)

## 影響ファイル

- `private_dot_claude/CLAUDE.md` (`### auto-mode に対する優先順位` セクション)
- `docs/adr/0014-no-custom-auto-mode-for-chezmoi.md` (Status header に supersede note 追記)
- `docs/adr/0018-restrict-auto-mode-override-to-non-interactive.md` (本 ADR)
