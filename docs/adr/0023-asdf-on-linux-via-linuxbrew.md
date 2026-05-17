# ADR 0023: Add asdf to Linux via Linuxbrew (coexisting with uv/bun/rustup)

## Status

Accepted (supersedes ADR 0013 §4 "asdf" exclusion and §6 "No brew/apt entries for language managers on Linux")

## Context

- ADR 0013 §4 は Linux で asdf を除外し、§6 では uv/bun/rustup の native installer のみ使う方針だった。
- その後、Linux SSH host でも `.tool-versions` driven な project の version pinning を行いたいケースが出てきた (macOS との parity)。
- asdf は既に macOS で Homebrew 経由で運用中。`private_dot_config/asdf/dot_asdfrc` (`legacy_version_file = yes`) も存在し、両 OS で共有可能。
- asdf v0.16+ (current brew formula) は Go binary で `asdf.sh` を提供しない。公式 [Getting Started](https://asdf-vm.com/guide/getting-started.html) は `export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"` を prepend し、completion は `. <(asdf completion bash)` (process substitution) で取得する方式 (fish config `private_dot_config/private_fish/config.fish` lines 22-37 が同じ shim PATH pattern を既に実装済み)。`ASDF_CONFIG_FILE` は [configuration reference](https://asdf-vm.com/manage/configuration.html) で引き続きサポート、未設定時は `$HOME/.asdfrc`。

## Decision

1. Linuxbrew で `asdf` を install (`.chezmoiscripts/run_once_before_install-minimum-packages.sh` の Linux 分岐に追加)。macOS と同じ formula で統一。
2. uv/bun/rustup の native installer は撤去せず併用。`dot_bashrc` の `~/.cargo/bin`, `~/.bun/bin`, `~/.local/bin` PATH エントリも温存。Project ごとに使い分け。
3. `dot_bashrc` で `asdf` を shim PATH prepend 方式で初期化 (`asdf.sh` は source しない)。bash completion は公式どおり `. <(asdf completion bash)` で binary から動的取得。Linuxbrew shellenv の直後・starship/direnv より前に配置 (fish 側と順序を揃える)。`command -v asdf` で gating し、未 install 時に completion 行が壊れないようにする。
4. `~/.config/asdf/.asdfrc` を Linux でも deploy (`.chezmoiignore` の `.config/asdf` 除外を解除)。

## Consequences

### Positive

- macOS / Linux 間で `.tool-versions` driven project がそのまま動く。
- `dot_asdfrc` が両 OS で同じ source of truth。
- asdf v0.16+ の official Getting Started に完全準拠。

### Negative / Trade-offs

- `dot_bashrc` に asdf init block (7 行) が追加される。
- Rust/Python/JavaScript で asdf と uv/bun/rustup が overlap する。Project ごとに使い分ける運用を `docs/linux-setup.md` に明記。

### Risks

- asdf v0.16+ の init UX (shim PATH のみ) に依存する。将来の major version で init 方法が変わった場合は ADR 再検討。
- `. <(asdf completion bash)` は bash 固有の process substitution。`dot_bashrc` 全体が既に bash 専用 (shebang `#!/usr/bin/env bash`、`[[ ... ]]` 多用) のため互換性問題なし。

## Follow-ups

- なし
