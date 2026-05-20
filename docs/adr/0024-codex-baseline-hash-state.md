# ADR 0024: Codex baseline drift detection via separate hash state file

## Status

Accepted (2026-05-20)

## Context

### baseline / live / state を分ける必要性

このリポジトリは `~/.codex/config.toml` を chezmoi 直接管理下に置かない。Codex CLI は対話セッション中に `[projects."/absolute/path"]` / `[mcp_servers.<name>]` / `[notice.*]` などの local state を `config.toml` に書き足すため、chezmoi 管理下に置くと `chezmoi apply` 毎にそれらが失われる。

代わりに、stable defaults を `~/.codex/config.chezmoi.toml` に baseline として配置し、`.chezmoiscripts/run_after_check-codex-config.sh` が live `~/.codex/config.toml` を初回のみ bootstrap copy する設計を導入した (PR #223 元 commit `ae99b98`)。

### 初期 drift gate の致命的バグ

triple-review (PR / SEC / ADV) は「baseline 更新が既存 host の live に伝播しない」(ADV [high]) を flag した。初期修正は `cmp -s "$managed" "$live"` (byte-level identical) で drift を判定し、不一致時に `exit 1` で `chezmoi apply` を blocking する fail-loud にした。

しかし Codex 自身による self-review で、この設計が **`[projects.*]` の存在で永久 drift 判定する** ことが判明した。Codex が live に local-only section を一度でも書き加えると、live と baseline は **設計上 byte-identical にならない** ため、drift gate は `chezmoi apply` を **永続的に red にする**。

byte 比較は「baseline と live が完全に同一か」を見ているが、本来必要だったのは「baseline 更新が live に取り込まれたか」の判定だった。

## Decision

### 3-file 構成

| file | role | reader / writer |
|---|---|---|
| **managed** (`~/.codex/config.chezmoi.toml`) | repo が定める baseline | chezmoi が配置 / Codex CLI は読まない |
| **live** (`~/.codex/config.toml`) | Codex CLI の実運用 config | Codex が読み書き / ユーザーが baseline merge |
| **state** (`~/.codex/.baseline-hash`) | 前回 ACK 時の baseline sha256 | script (Case 1/2) と ユーザー (ACK) が書く |

### hash gate での drift 検出

drift 判定は **baseline file の sha256 hash 変化** のみで行う。live の内容は比較しない。これにより Codex が live に書き加える local-only section が gate に干渉しない。

`sha256sum` を優先し、存在しない環境では `shasum -a 256` に fallback する。Ubuntu / DGX OS では coreutils の `sha256sum` が第一想定で、手元の macOS でも `/sbin/sha256sum` が利用可能だった。hash command failure が空 state として記録される fail-open を防ぐため、script は pipeline の終了ステータスに依存せず、hash command の失敗と空 hash を明示的に reject する。

### migration を fail-closed に

state 不在 + live 存在の migration ケース (既存 host で hash gate 版が初到達) は 2 分岐:

- **`live == baseline` (byte-identical)**: silent seed + exit 0
- **`live ≠ baseline`**: **exit 1 で blocking**、operator に diff 確認 + 手動 ACK を要求

script は `live ≠ baseline` の差分が「Codex の local-only section 追加」か「miss された baseline 更新」かを判別できない。fail-open (WARNING + exit 0) では operator が後者を見落とすと hardening 伝播が永久 miss するため (本 ADR の主目的を bypass する)、fail-closed を採用する。

### ACK 手順

```sh
hash=$(sha256sum ~/.codex/config.chezmoi.toml 2>/dev/null || shasum -a 256 ~/.codex/config.chezmoi.toml) &&
printf '%s\n' "${hash%% *}" > ~/.codex/.baseline-hash &&
chmod 600 ~/.codex/.baseline-hash
```

operator が baseline 更新を live に merge した後、または migration で「差分は local-only section のみ」と確認した後に実行する。

## Consequences

### Positive

- baseline 更新が deploy された hash gate 経路で確実に operator notification を発火する (ADV [high] の本来意図を達成)
- Codex CLI の live への自由書き込み (`[projects.*]` 等) が drift gate に干渉しない
- TOML parser 依存ゼロ (`sha256sum` / `shasum` のみ)
- Codex CLI と非干渉 (`.baseline-hash` は Codex が touch する path に該当しない)

### Negative

- host あたり最大 2 種の手動 ACK が発生する:
  1. 初回 migration (`live ≠ baseline` の場合) — host 毎に一度限り
  2. baseline 更新後の drift 解決 — baseline が更新されるたび
- ACK は短い shell snippet だが、覚える必要あり (docs/codex.md step 4 + drift advisory + migration advisory に明示)

### Trade-offs accepted

- **「1 回の手動 ACK」のコスト < 「hardening miss を許容するリスク」**: 個人 dotfiles 程度の運用規模であれば、baseline 更新時の operator 関与は許容範囲
- Codex follow-up review で migration fail-open が High 評価を受けたため、fail-closed を選択

### Known limitations

- `install -m 600` は **mode-atomic だが file-atomic ではない**。SIGKILL / disk-full 等で bootstrap 中断時、partial / zero-byte file が残存する可能性。recovery は `rm ~/.codex/config.toml && chezmoi apply`。follow-up issue で `tmp + mv -f` 化を検討する
- hash gate は **baseline file の変化のみ検出**。live が外部要因で破損した場合の検出はしない (Codex CLI と人間の責任範囲)

## References

- PR #223
- triple-review feedback (PR / SEC / ADV reviewers)
- Codex self-review (2 rounds: initial review caught Lane 1 High `cmp -s` bug; follow-up caught migration fail-open High)
