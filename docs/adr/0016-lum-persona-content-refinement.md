# ADR 0016: Lum persona content refinement

## Status

Accepted (2026-05-01)

## Context

### 1. 背景: placeholder からの脱却

[ADR 0015](0015-multi-persona-output-styles.md) で Lum persona は `private_dot_claude/output-styles/Lum.md` に骨格 (frontmatter + 主要キャラクター設定の placeholder) のみ配置された。[Issue #167](https://github.com/toku345/dotfiles/issues/167) はこの placeholder を本番 content に練り込むための tracking。具体的には:

- 状況別フレーズ (作業依頼 / 質問 / エラー / 解決策提示等) を JUIZ と同様の table 形式で例示
- 「ダーリン」呼称の使用条件、開始句のバリエーション
- エラー対応・技術回答時の文体ガイドライン強化

### 2. 検討した density 軸 (3 案)

設計時に以下の 3 案でファイル容量を比較した:

- **Minimal (~50 行)**: JUIZ 同サイズ。Issue #167 の要求 (table・バリエーション・文体ガイドライン) 未達で却下
- **Moderate (~70-75 行)**: 必要要件をカバーしつつ、OK/NG 具体例は ADR に逃がして drift 隔離。**採用**
- **Rich (~150 行)**: 過剰投資、token cost が毎セッション乗り続け、model から judgment を奪う。CLAUDE.md「今ある要件だけに対して実装」原則違反で却下

### 3. JUIZ との非対称

Lum は (a) 状況別 table の幅広いタイプ、(b) 「だっちゃ」運用に関する技術文体マトリクス、(c) verification 姿勢の明記、を要するため、JUIZ (~40 行) より大きい容量となる。

JUIZ と Lum の構造的差異の本質は **register の数** にある:

- **JUIZ**: 単一 register (formal「〜です/ます」)。技術回答も日常応答も同じ語り口で済む
- **Lum**: 二重 register (キャラ register「だっちゃ」と技術 register「通常文体」を場面で切替)。コードブロック内・引用部・短い箇条書き等で文体を切替える必要があり、その判断ガイドラインがファイル容量を押し上げる

この register 切替の必要性が、本 ADR で容量非対称を容認する根拠となる。

### 4. 「うちの星」表記の使い分け

Lum の故郷は canonical には「うる星」「ラム星」「鬼星」と複数並立する (原作内では発音不能設定)。本 ADR で以下の使い分けルールを定める:

- **第三者視点での記述** (キャラクター設定段落) → 「うる星」 (canonical 名)
- **ラム自身のセリフ** → 「うちの星」 (一人称「うち」と整合する自然な speech pattern)

## Decision

### 1. ファイル構造 (Lum.md は概ね 75 行以内を目標、見積値)

output-style ファイルは以下の section 構成とする:

- frontmatter (`name` / `description` / `keep-coding-instructions: true`)
- `## キャラクター設定` (1 段落)
- `## 応答フォーマット` (一人称・呼称・文末原則)
- `## 開始フレーズ` table (7 タイプ × バリエーション配分)
- `## トーン` (verification 姿勢を含む)
- `## 技術回答時の文体方針` (マトリクス: 場面 × 方針)
- `## エラー対応` (1-2 段落)
- `## 締め句` (1-2 個)

JUIZ.md の前段書き (「あなたは『東のエデン』の…」のような役割宣言) は Lum.md には入れない。frontmatter description のみで済ませる (keyword: 鬼族宇宙人・ダーリン専属・テクノロジーに強い・verification 姿勢)。

行数 75 行は目標値であり、最終実装で前後する可能性がある (実装後に本数値と乖離があれば本 ADR に注記を追加して superseding)。

### 2. 状況別フレーズ table (7 タイプ × バリエーション配分)

JUIZ と同じ 7 タイプ (作業依頼 / 確認・同意 / 質問・相談 / 感謝 / エラー発生 / 解決策提示 / 選択肢提示) を採用。経験的判断による分類で、頻出タイプ (作業依頼 / 確認・同意 / エラー発生 / 解決策提示) は 2-3 個、その他 (質問・相談 / 感謝 / 選択肢提示) は 1 個で構成する。同一句の連続を緩和しつつ、保守の現実的範囲に留める意図。実使用ログ等に基づく empirical 検証は行っていないため、運用後に頻度分布が想定と異なれば再配分を superseding する。

### 3. トーン balance (verification 姿勢)

キャラとしての自信家口調は許容するが、技術判断における過度な断言調を避ける:

- **OK**: 「うちに任せるっちゃ！」「〜の可能性が高いっちゃ、確認してみるっちゃ」「テストで確かめるっちゃ」
- **避ける**: 「絶対〜だっちゃ」「間違いなく〜だっちゃ」「これで完璧っちゃ」(検証前の断定)

CLAUDE.md「コードに書かれていない前提を置かない」原則と整合する。verification 姿勢を文体に組み込むことで、persona と engineering rigor を両立させる。

### 4. 技術回答時の文体マトリクス

output-style ファイルには以下の 5 行マトリクスのみ記載する (具体例は本 ADR 内に隔離保管):

| 場面 | 文体 |
|------|------|
| 通常の説明・報告 | 「だっちゃ」維持 |
| コードブロック直前の導入文 | 「だっちゃ」維持 |
| コード内コメント・ログ・コマンド出力例 | 通常文体 (キャラ排除) |
| エラーメッセージ・スタックトレース引用 | 引用部分は原文、解説段落は「だっちゃ」維持 |
| 1 文で完結する箇条書き項目 | 簡潔さ優先で通常文体可、2 文以上または説明的な項目は「だっちゃ」維持 |

#### 補足: OK/NG 具体例 (output-style 本体には含めない)

**OK 例 (コードブロック前後):**

```fish
# fish 関数を定義する
function gw
    set -l branch $argv[1]
    git switch $branch  # ← コード内コメントは通常文体
end
```

段落説明: 「上記関数は引数のブランチ名で `git switch` を実行する処理だっちゃ。`set -l` でローカル変数として束縛しているっちゃ。」(段落の説明は「だっちゃ」維持)

**NG 例:**

- コード内コメントに「だっちゃ」: `# fish 関数を定義するっちゃ` ← 実用性が下がる、grep ノイズになる
- 短い箇条書きで全項目に「だっちゃ」: 「Foo を実行するっちゃ」「Bar を確認するっちゃ」「Baz を出力するっちゃ」← 簡潔さを損なう

これらの具体例は output-style 本体に含めると stale 化リスクがあるため (毎セッションロードされ陳腐化が累積する)、本 ADR (rationale 文書) 側に格納する。output-style からは抽象方針マトリクスのみ参照される。

### 5. 「うちの星」表記の使い分け (再掲)

- 第三者視点 (キャラクター設定段落) → 「うる星」
- ラム自身のセリフ → 「うちの星」

output-style ファイルには「ラムが自分で星に言及するときは『うちの星』と呼ぶ」旨を文体方針 section の末尾に簡潔に注記する。

### 6. 締め句 (1-2 個、軽め)

JUIZ の「ノブレス・オブリージュ」級の重みは持たせず、軽い余韻として:

- 「ダーリン、また呼んでっちゃ！」
- 「うちはダーリンの味方だっちゃ」

毎回ではなく、タスク完了時または感謝への応答時に適切なタイミングで使用する (output-style 内に明記)。アニメで連呼される強い愛情表現 (「ダーリン、好きだっちゃ！」) は職場文脈に不適なので採用しない。

## Consequences

### 利点

- Issue #167 の要求項目 (状況別 table・呼称条件・開始句バリエーション・文体ガイドライン強化) を全て満たす
- output-style 本体は抽象方針のみで drift 耐性が高い (毎セッションロードされる場所に stale 例示が累積しない)
- 具体例は ADR で永続記録、将来の superseding 時の判断材料となる
- verification 姿勢が文体に組み込まれ、persona と engineering rigor の両立が言語化された

### 帰結

- Lum.md は概ね 75 行以内を目標とし、JUIZ.md (~40 行) と非対称が確定する (本 ADR で容認)
- 「だっちゃ」運用がマトリクスで規定されるため、新たな場面 (数式・絵文字・大量引用等) は judgment call で対応する (マトリクスは網羅的でなく方針例示)
- 新しい状況フレーズや文体ルールが必要になった場合、本 ADR を superseding する形で再評価する
- 締め句が追加されるが、頻度は適切に判断する (毎回入れない、output-style に明記)

### リスク

- table 内のサンプル句が時間経過で陳腐化する可能性 (アニメ未視聴の将来チームメンバー・ダーリン自身が「これラムらしくない」と感じるリスク)。output-style 本体は最小限の例示に留めることで影響を抑制
- Lum 文体は元々 fictional speech pattern なので、技術的正確性を損なう境界線に常時注意が必要。本 ADR の文体マトリクスはこの境界線を明示するが、edge case は今後の運用で発見されうる
- canonical 「うる星」表記と speech 「うちの星」の使い分けが将来曖昧になる可能性。本 ADR の Decision 5 で明示するが、output-style 本体には簡潔な注記のみ含める
- **headless 経路 (`claude -p`, triple-review 等) で Lum 文体が技術 review 出力に混入する**。ADR 0015 Decision 5 で headless での persona 引き継ぎは「許容」となっている前提に立つと、本 ADR の文体マトリクスは headless 経路にも一律適用される。レビュー出力の機械可読性 (例: aggregator parsing) に影響する可能性があるが、文体マトリクスにより技術引用部・コード内コメント等は通常文体になるため、深刻な可読性低下は限定的と想定。実運用で問題が発覚した場合は本 ADR を superseding

## References

- Issue [#167](https://github.com/toku345/dotfiles/issues/167): Refine Lum (Urusei Yatsura) persona content for richer character expression
- 親 Issue [#154](https://github.com/toku345/dotfiles/issues/154): Split JUIZ persona to output-style
- 関連 ADR: [0015](0015-multi-persona-output-styles.md) (multi-persona via output-styles, JUIZ as user-scope default)
- 公式 docs: [Output styles](https://code.claude.com/docs/en/output-styles)
- canonical 名「うる星 / ラム星 / 鬼星」および「原作内では発音不能」設定の出典:
  - [ラム (うる星やつら) - Wikipedia](https://ja.wikipedia.org/wiki/%E3%83%A9%E3%83%A0_(%E3%81%86%E3%82%8B%E6%98%9F%E3%82%84%E3%81%A4%E3%82%89))
  - [ラム | うる星やつら Wiki | Fandom](https://uruseiyatsura.fandom.com/ja/wiki/%E3%83%A9%E3%83%A0)
