# ADR 0040: `cx` 起動入口の採用と Fugu 起動時既定の policy 化

## Status

Accepted (2026-09-29). Extends [ADR 0038](0038-fugu-home-config-policy.md).

## Context

PR #365 は通常版 Codex の起動入口 `cx`（Astra low / high を profile で選ぶ）と、Fugu 用の `cf`（更新チェック抑止・Fast 無効・承認を人間へ・不一致警告）を提案していた。`cf` の中身を現行 main（ADR 0038 の分離、管理ラッパー、config policy）と突き合わせると、次の問題があった。

- `cf` の precheck は `CODEX_HOME` 未設定時に `~/.codex` を見る。分離後は専用 home が `~/.codex-fugu` なので、事前条件が別 home を指す。実際には vanilla `~/.codex` に残る旧 Fugu 設定（`fugu.config.toml` / `.fugu/state`）で偶然通っていた。
- 管理ラッパー `~/.local/bin/codex-fugu` が既に fail-closed（実体が無ければ 127、再帰は 126）なので、`cf` 側の追加検査は冗長。
- `cf` が渡していた 4 つのうち 3 つは config key であり、Fugu home の per-key policy（ADR 0038）で表現できる。実測で `check_for_update_on_startup=false` / `approval_policy="on-request"` / `approvals_reviewer="user"` / `features.fast_mode=false` が 0.154.0 に受理されることを確認した（不正値では config load が失敗する）。
- `cf` の不一致警告は `--no-update` により公式ランチャーの不一致ハンドリングを止めた代償で必要になったもの。ランチャー側の更新確認を残すなら不要になる。

## Decision

1. `cx` を採用する。`dot_local/bin/executable_cx` が `codex --profile quick|work` を exec し、profile（`~/.codex/{quick,work}.config.toml`）は `model` / `model_reasoning_effort` の 2 key だけを持つ。Fugu は `cx` ではなく `codex-fugu` を使う。
2. `cf` は作らない。Fugu の起動時既定はすべて `scripts/codex-config/policy-fugu.toml` の pin に置き、どの起動経路でも常時適用する:
   - `plan_mode_reasoning_effort = "xhigh"`（ADR 0038 から継続）
   - `check_for_update_on_startup = false`（Codex 自身の自己更新プロンプトのみ抑止）
   - `approval_policy = "on-request"` / `approvals_reviewer = "user"`（承認を人間へ。vanilla は `guardian_subagent` のまま）
   - `[pin.features] fast_mode = false`
3. ランチャーと管理ラッパーは変更しない。`--no-update` を注入せず、Fugu の config / CLI 更新は公式ランチャー（bundle の `install.sh` 経由）に一本化する。不一致の扱いもランチャーの TTY 経路に任せる。
4. ADR 0038 の「vanilla の sandbox / features / tui pin を Fugu home へ持ち込まない」原則は維持する。承認と `fast_mode` は Fugu 専用の起動時既定として明示的に追加する。

## Consequences

### Positive

- 起動入口が `cx`（通常版）と `codex-fugu`（Fugu）の 2 つに整理され、`cf` 相当の専用ランチャーとその 18 テストが不要になった。
- Fugu の起動時の挙動が config で宣言され、`git diff` と CI の config policy テストで検証できる。分離前の home に依存しない。
- bundle 検証版から CLI だけがずれる事故（0.154.0 vs 0.155.1）が構造的に起きない。更新は従来どおりランチャーの提案から `install.sh` で行う。

### Negative

- TUI から `features.fast_mode` / 承認設定を変えても次の `apply` で戻る（pin の意図どおり。変えたい場合は `policy-fugu.toml` を編集する）。
- `features list` は `--profile` を受け付けないため、`fast_mode` の実効値の自動確認はできない。手動（Fugu セッション）で確認する。

### Alternatives

- `cf` を残す: 4 挙動のうち 3 つが config で表現でき、残りはランチャーの更新フローを止める副作用と引き換えになるため不採用。
- `cx` を profile だけにして起動入口を作らない: 日常の入口が長くなり、`--profile` の存在を毎回意識する必要があるため、薄いランチャーを採用した。
