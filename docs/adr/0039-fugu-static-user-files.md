# ADR 0039: Fugu home の静的ユーザーファイルを symlink 共有する

## Status

Accepted (2026-09-27). Extends [ADR 0038](0038-fugu-home-config-policy.md).

## Context

`~/.codex-fugu` を分離した結果、専用 HOME には user-global の `AGENTS.md`、`agents/` のロール、`rules/managed.rules` が存在せず、Fugu セッションでは次が効かなかった。

- user-global の応答・レビュー・ツール由来データに関する指示
- `spawn_agent` のロール定義（`agents/*.toml`）
- `gh api graphql` / `git add` / `git commit` を prompt に戻す managed rules

分離の目的は「runtime state と installer-owned files を chezmoi に触らせない」ことであって、ユーザーが書いた静的ファイルを Fugu 側で失うことではない。一方で同じ内容を両側にコピーすると、片側だけ更新されて drift する。

実測で Codex は symlink を辿る。隔離 home の `AGENTS.md` を vanilla への symlink にした状態で `codex debug prompt-input` を実行すると、symlink 経由の内容がモデル可視プロンプトに含まれた（2026-09-27）。

## Decision

静的ユーザーファイルは vanilla `~/.codex` への **相対 symlink** で共有し、コピーを作らない。

| target | symlink 先 |
|---|---|
| `~/.codex-fugu/AGENTS.md` | `../.codex/AGENTS.md` |
| `~/.codex-fugu/agents` | `../.codex/agents` |
| `~/.codex-fugu/rules/managed.rules` | `../../.codex/rules/managed.rules` |

- 対象をこの 3 つに限定する。`rules/default.rules`（Codex UI が更新する）、`skills/.system`、`skills/pr-review`、sessions、SQLite、Memory、installer-owned files は共有しない。
- `skills/pr-review` を共有しない理由: skill は互換ドリフト時に `codex exec --profile review`（vanilla の `gpt-5.6-sol` を前提）へ退避する。Fugu home にはその profile も model provider も無いため、共有すると壊れた経路を持つことになる。Fugu で `$pr-review` を有効化する変更は本 ADR の範囲外。
- 配布は ADR 0038 の `codexFugu` gate に乗る。`.chezmoiignore` が `.codex-fugu` と `.codex-fugu/**` を除外するため、opt-in していない machine には何も作られない。
- mode は vanilla を踏襲する: `~/.codex-fugu` 0700、`~/.codex-fugu/rules/` 0755、共有した `managed.rules`（解決後）0644。symlink 自体は mode を持たない。

## Consequences

### Positive

- Fugu セッションでも user-global 指示、agent ロール、managed rules が使える。
- コピーが無いため、片側だけ更新されて drift する事故が起きない。vanilla を更新すれば Fugu 側も同じ内容になる。
- 既存の real file や directory は置換せず、`run_before_check-codex-fugu-static-conflicts.sh` が apply を停止して内容の保全を強制する。`rules/` と 3 つの symlink はその後に新規作成される。

### Negative

- Fugu home が vanilla のファイルに依存する。vanilla 側を削除すると dangling になる（`~/.codex` の該当 target は常に管理対象なので通常は起きない）。
- 反映は常に full apply（`.codex` → `.codex-fugu` の順）を使う。`~/.codex-fugu/AGENTS.md` だけを target 限定 apply すると一時的に dangling になり得るほか、`config.toml` だけの apply では 3 つの symlink が作られず、`run_before_` script も実行されない。
- `agents/` と `rules/managed.rules` は `debug prompt-input` のような自動確認面が無く、実セッションでの手動確認に頼る。`AGENTS.md` は `codex debug prompt-input` で自動確認できる。

### Alternatives

- コピー配置: 内容が二重管理になり drift するため不採用。
- `~/.codex-fugu/skills/pr-review` の共有 + Fugu 用 review profile の追加: model provider と profile の二重管理になり、本 ADR の目的（静的ユーザーファイルの欠落解消）を超えるため不採用。
- 共有しない: 分離の副作用を放置することになり、Fugu セッションが user-global 指示を失ったままになるため不採用。
