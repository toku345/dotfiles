# Issue #418：人が編集できる計画レビュー往復の試行

## 対象・状態

- 対象は [#418](https://github.com/toku345/dotfiles/issues/418) 自体の実装計画。親は [#416](https://github.com/toku345/dotfiles/issues/416)。
- 試行時の source は `main`、HEAD `833a4e78ed5fabf2c814f277034a6f90d5ea61e4`、clean。以降の実装は専用ブランチ `feat/418-plan-review-handoff` に分離した。
- 両方向の準備・新規セッションでのレビュー・元の作成元での採否判断まで実施した。元の Codex が両方向の判断を統合した。
- ユーザーは Plan Mode から通常モードへ切り替えて「Implement the plan.」と依頼した。その承認を維持し、両方向の判断が戻ってから実装を開始した。
- このファイルは観察メモとユーザーが戻した結果の要約。会話の生ログは保存しない。

## 第1往復：Codex → Claude Code → 元の Codex

| 段階 | 実施内容 |
| --- | --- |
| prepare | 元の Codex が元 Issue・コード・対話の制約・計画・根拠・未確認を編集可能な Markdown にまとめた |
| review | ユーザーが新規 Claude セッションへ渡し、Claude が Issue とリポジトリを調査して結果と観察メモを本文で返した |
| assess | ユーザーが元の Codex へ戻し、Codex が根拠を調べて採否を判断した |

ユーザーは依頼文・返却結果とも無編集で渡したと明示した。両方に編集機会があった。

| 指摘 | 採否・有用な変化 |
| --- | --- |
| project scope の検証だけでは user scope の探索経路を証明できない | 採用。過去の 0.130.0 の実測と対象クライアントを区別し、配置先の選定根拠と新 Skill の本文読み込みを分けた |
| 入口共有の対象が曖昧 | 明確化は採用。入口全体を include する (a) に固定し、共通 name/description と相対参照だけを入口へ置いた |
| 入口をそれぞれ手書きする (b) を推奨 | 不採用。ツール固有部分を共有入口に入れなければ、非互換の実証なしに二重管理する必要はない |
| 既存ガイダンスからの参照 | 採用。`codex-usage` に短い案内を足し、通常の自動レビューと手動往復を分けた |
| chezmoi の source / destination 等を明示する | 採用。隔離の具体手順を逆方向で詳細化した |

依頼文から調査を開始できた一方、過去の配置先実測を含む設計資料が調査入口から欠け、Claude が自分で探した。入口全体を共有する方針の明示も不足していたため、次の依頼文へ追加した。

## 第2往復：Claude Code → 新規 Codex → 元の Claude Code

第1往復の Claude セッションを、ユーザーが計画作成元へ明示的に切り替えた。Claude は配置・呼び出し・失敗時検証を具体化し、新規 Codex 向け依頼文を用意した。ユーザーが新規 Codex へ渡し、結果を元 Claude へ返した後、Claude が採否と修正版の計画・観察メモを返した。

実際には、Claude の準備結果と新規 Codex のレビュー結果を一度ずつ元の Codex へ戻し、転送用ファイルを作ってから次へ渡した。元の Codex が Claude の採否を代行したわけではない。

ユーザーは第2往復の依頼文・返却結果もすべて無編集だったと明示した。元の Claude は第1往復の文脈を持つため、独立したモデル品質比較ではない。

| 指摘 | 元 Claude の採否・変化 |
| --- | --- |
| 最後の `execute-template` だけ隔離オプションが外れる | 採用。構文確認まで同じ source / destination / config / state / cache に統一した |
| ローカルで CI の全テンプレート検証も行う場合の `--init` | 全体ループの実施は採用しなかった。未レビューの既存テンプレートを評価せず、新規3つと確認済みの `.chezmoiignore` に限定した |
| 将来の実ホーム apply 前に実対象の diff・dry-run がない | 採用。関連設定・hooks、manifest、dangling symlink を含む存在確認、退避／復元、diff・dry-run、別承認を組み込んだ |
| 参照欠落・採否・実装承認の判定補足 | 採用。未確認の制限と理由付きの採否を明示し、レビューを新しい実装承認と扱わない |
| Draft PR と gate の順序 | 採用。別途承認された Draft PR とユーザーの gate 実行を、ローカル実装の後続作業として分けた |

元 Claude は修正をセルフレビューし、設計を変えない最小修正であることから新規 Codex の修正確認は不要と判断した。元 Codex も統合時に要求・修正内容を照合した。

## 実行環境と権限

| 場面 | 観測・申告された環境 | 範囲・制約 |
| --- | --- | --- |
| 元 Codex と手動の新規 Codex | 正確な実行モデル ID とホストクライアント version は非開示／不明。新規側が確認した CLI は 0.163.0 | Git・資料の読み取り、Issue は GitHub connector、Web。手動の新規側は昇格・編集・apply・再委譲なし |
| 手動 Claude の review / prepare / assess | `claude-opus-5-5[1m]`、Claude Code 2.1.305。確認した codex-cli 0.163.0、chezmoi v2.73.2 | 主に sandbox 内の読み取りと公式資料。第1 review の `gh issue view` のみ sandbox 外。編集・配置・別 AI 起動なし |
| 事前の自動計画レビュー | sandbox 内の Claude 呼び出しは認証エラー、sandbox 外の新規プロセスで初回と修正確認が完了 | plan 権限を維持。手動試行の成功には数えない |

環境の申告を、元 Codex がすべて再実測したわけではない。Claude は私的 rollout の `cli_version`・`originator`・Skill root/path を抽出したと開示し、TUI 0.163.0 で両 user root の一覧表示を報告した。元 Codex と新規レビュアーは、その確認のために私的記録を追加探索していない。一覧表示と新 Skill の本文読み込みは別の証拠として扱う。

初回依頼の「CLI 起動禁止」は version/help 確認との区別が広すぎた。Claude が `codex --version` の実行を開示したため、以降は metadata 確認を許可し、新規 AI セッション起動・再委譲を禁止すると区別した。Claude は hook による agmsg 監視指示に従わず、off 方針を維持したと申告した。

## 人の作業と次回の判断

- フロー上、依頼ファイルの参照を別セッションへ渡す操作が4回、結果本文と観察メモを元 Codex へ貼り戻す操作が4回あった。各クライアント内の追加操作や所要時間は未測定。
- ユーザーが依頼文を要約する必要はなかったが、無編集でもセッション切り替えと転記は残った。
- 次回も手動手順を維持する。依頼文に「作成元」「返却先」を明記し、レビュー結果を計画作成元へ直接戻せるようにする。中継セッションでの再要約や追加転送を既定にしない。
- 現時点では自動配送・新 UI・汎用 orchestrator の追加や専用 follow-up Issue は不要と判断した。実際に繰り返す転記負担が残れば、その観測を基に限定した改善を検討する。

## 保存した再利用可能な成果物

- [共通手順と依頼文](../plan-review-handoff.md)を正本とし、`plan-review-handoff` の薄い入口全体と両方の references を include で共有する。
- Codex の新規配置先は公式の `~/.agents/skills`。TUI 0.163.0 の一覧表示の報告と[公式仕様](https://learn.chatgpt.com/docs/build-skills)を選定根拠にする。既存 `~/.codex/skills` の移行はしない。
- Claude の配置先は `~/.claude/skills`。ツール別の呼び出し例は手順側へ置き、入口をツール非依存に保つ。

## ローカル実装の検証

以下は実装後の隔離検証であり、上記の人による往復とは別に記録する。

- 専用 worktree の source・HEAD・tracked/non-ignored untracked の集合、type・mode・SHA-256・symlink 先・missing を、source 外の manifest へ記録した。
- 新規管理ファイル4つは隔離 destination から `chezmoi add`（3つは `--template`）で取り込んだ。
- `--source`・`--destination`・`--config`・`--persistent-state`・`--cache` を全評価で明示した。新規3テンプレートと `.chezmoiignore` の描画は成功。
- `target-path` が期待する4ファイルへ解決し、Skill ディレクトリ2つの dry-run・隔離 apply・読み返し・diff は成功。生成された入口／両手順は正本と byte 一致、4ファイル以外なし、file mode は0644、frontmatter は先頭だった。
- Skill Creator の `quick_validate.py` は生成後の両 Skill で成功。PyYAML は一時 uv cache のみへ取得した。
- 新規 Claude Code 2.1.305（plan）と Codex CLI 0.163.0（非対話・read-only・ephemeral）で、project scope の入口／共通手順／fixture の実際の読み取りと prepare 後の停止を観測した。Claude では Skill 一覧への掲載も観測した。
- prepare の観測を受け、転送用テンプレート内にも結果形式を1行明記し、依頼文単体で完結させた。
- `codex review --uncommitted` の静的レビューは終了0で、修正が必要な具体的な不具合なしと報告した。これは組み込みレビューであり、PR gate や実環境への適用検証ではない。
- 両ツールの新規セッションで review / assess を実行した。問題のない計画には重要な指摘なし、欠落した元依頼は未確認、期待 OID と unborn HEAD の不一致は対象を確認できないと報告した。assess は自動公開の削除を採用し、好みの形式変更と未承認の要件変更を不採用にして停止した。追加のユーザー判断事項はなしと判断し、分類を埋めるための指摘は作らなかった。
- 全6回の fixture セッションは完了した。Claude は各回 plan 権限で新 Skill が一覧に載り、入口・共通手順の読み込みを報告した。prepare では Read の path も直接観測した。Codex は非対話の read-only / ephemeral で、実際の読み取りコマンドと結果を観測した。追加の review / assess 検証前後で fixture の実ファイルの SHA-256 が一致した。実際の手動転送の成功とは分けて扱う。

実コマンドから分かった計画の補正:
- config を置くディレクトリ配下の destination は、`chezmoi add` の自己管理防止で拒否された。config/state/cache と destination を兄弟の別ルートへ分けて取り込んだ。
- 取り込み時の state のまま destination を空にすると、既存変更の競合確認が必要になる。空の適用先の試験には新しい隔離 state を使った。
- 親のない空 destination へ leaf file だけを apply すると失敗した。共通親を fixture に用意し、Skill ディレクトリ2つを対象に適用して4ファイルだけが作られることを確認した。

隔離検証のオプションの形（`W` はレビューした worktree、`T` と `D` は別々の一時ルート）:

```bash
CZ=(chezmoi --source "$W" --destination "$D" --config "$T/chezmoi.toml"
    --persistent-state "$T/state-apply.boltdb" --cache "$T/cache")
targets=("$D/.agents/skills/plan-review-handoff"
         "$D/.claude/skills/plan-review-handoff")
# raw diff・関連設定と manifest を確認し、共通の親を fixture に用意した後:
"${CZ[@]}" apply --dry-run --verbose --exclude=scripts "${targets[@]}"
"${CZ[@]}" apply --exclude=scripts "${targets[@]}"
"${CZ[@]}" diff "${targets[@]}"
# 構文確認も同じ CZ と、レビュー済みの各 tmpl の絶対パスを使う。
"${CZ[@]}" execute-template --file "$tmpl"
```

## 対話クライアントでの追加確認

ユーザーの確認継続依頼を受け、同じ project scope の fixture を、通常の認証用 HOME を維持して新規の対話セッションから確認した。認証のため外側の sandbox 外で起動し、Codex CLI 0.163.0 は read-only / approval never、Claude Code 2.1.305 は plan mode を維持した。

- Codex TUI の `/skills` → List skills で `plan-review-handoff` が表示され、選択して prepare を依頼できた。実際の読み取りコマンドが `.agents/skills/plan-review-handoff/SKILL.md` と同じディレクトリ内の `references/procedure.md` を参照した。
- Claude Code の `/skills` で同 Skill が `project` と表示された。`/plan-review-handoff` に prepare の依頼を添え、Read が `.claude/skills/plan-review-handoff/SKILL.md` と同じディレクトリ内の `references/procedure.md` を読み込むことを確認した。
- 両方とも task.md・README・Git 状態を確認し、元の作成元への返却先を含む編集可能な依頼文と観察メモを本文で返し、転送待ちで停止した。編集・実装・送信・監視・再委譲は行わなかった。起動した両プロセスは終了した。
- 実行前後で fixture の実ファイル7つの集合と SHA-256 が一致した。unborn HEAD は commit ID を取得できないと扱った。Claude の HEAD 読み取りコマンドは exit 128 となったが、成功した revision 確認とは扱わなかった。
- 対話画面の一時フォルダ信頼確認は内容をレビューして続行し、テスト後に戻した。Codex config は信頼追加以外の差分がないことを確認して元の bytes に復元した。Claude は今回新規に作られた fixture の project 項目だけを削除し、通常起動に伴う利用統計・cache 更新は保持した。通常のセッション履歴は残る。
- 実ホームの3候補に新 Skill が存在しないことを再確認した。この追加確認も自動で操作した fixture テストであり、人によるレビュー往復や user scope の実配置とは別の証拠である。

## 未検証・後続作業

- 実ホームへの apply は未実施。新 Skill の user scope での発見・本文読み込みは未検証。将来の適用時は [リポジトリの apply 規約](../../AGENTS.md#chezmoi-operations)に従い、実 config/hooks と対象状態、同じ source の diff・dry-run、退避／復元を確認して別途承認を得る。
- project scope の Codex TUI と Claude Code は上記のとおり確認済み。Desktop、Fugu は未検証。
- fixture は unborn HEAD の一時 Git repo。実履歴のある2 commit 間の revision 変化は別途の検証になる。
- 検証完了時点ではコミット・push・Draft PR・PR gate は未実施。ローカル差分と検証結果を渡し、PR 作成の承認後に既存 gate を使う。
- 計画本文を引用した返答に `pr-review` Skill が添付されたが、実装前の `main` に PR/base がないため前提確認で停止した。専門レビュー0件・gate 未実施を、計画レビューの成功と混同しない。以降、同じ前提で不要な再実行はしなかった。
