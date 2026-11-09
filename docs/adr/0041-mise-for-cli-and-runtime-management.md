# ADR 0041: 言語ランタイムと provenance 付き CLI を mise で管理する

## Status

Accepted (2026-11-05). Extends [ADR 0026](0026-development-update-policy.md). Partially supersedes [ADR 0023](0023-asdf-on-linux-via-linuxbrew.md) (asdf は mise への移行完了後に撤去する)。

## Context

- Homebrew の更新は `brew-reviewed-upgrade` / `brew-reviewed-cask-upgrade` (ADR 0026) で保護しているが、ツールごとに手で実行する負担が大きく、将来は AI エージェントに更新作業を任せたい。そのためには、更新候補・検証結果・差分を機械的に扱える経路が必要になる。
- asdf は release age の gate も lock も持たない (ADR 0026)。plugin は第三者の shell script で、インストールのたびに手元で実行される。asdf-java は JDK の URL と checksum を plugin repo の master branch から無固定で取得する。
- Homebrew は version を固定・再現する設計ではない (core/cask は最新定義のみ、`brew bundle` に lock はない)。
- mise 2026.11.0 で次を確認した: `minimum_release_age` (非 exact の request にのみ適用)、`mise lock` による version・checksum・URL・platform ごとの `provenance` の記録、`lockfile_platforms` による複数 platform の lock、`--global` と `MISE_CONFIG_DIR` による global lock の生成先指定、`github.gh_cli_tokens` (既定 true) による gh 認証の利用、`mise lock --json --dry-run` による機械可読な更新候補。
- `mise tool --json` の `security` 欄は全 version・全 asset を横断した宣言であり、選択された version・platform の検証を保証しない (aqua registry に検証定義のない SwiftLint でも `checksum` と表示される)。一方 lock の `provenance` は lock 生成時に対象 version・platform で検証された結果として記録される。checksum のみの CLI は `checksum_source = "mise-versions"` (jdx 運営の metadata) になる。

## Decision

1. 置き場所を役割で分ける。

   | 分類 | macOS | Linux |
   | --- | --- | --- |
   | 言語ランタイム本体 (プロジェクトごとに version を切り替える) | mise | mise (同じ lock) |
   | provenance 付きの単体 CLI | mise | mise |
   | 言語ツールチェーンのマネージャ (rustup, ghcup, opam, uv) | Homebrew | distro package → mise (provenance あり) → 公式 installer |
   | ライブラリ・基盤・provenance のない CLI | Homebrew | apt / pacman |

   macOS では公式 installer があっても Homebrew を優先する (Bottle attestation と reviewed helper の cooldown が効くため)。ツールチェーンのマネージャは自身が compiler や package の version を管理するので、本体はローリングで足りる。
2. CLI を mise に載せる条件は「`mise.lock` の全 platform (`macos-arm64`, `linux-x64`) に `provenance` が記録されること」とする。`aqua:owner/repo` で backend を固定する。checksum のみの CLI は Homebrew に残す。ランタイムは project ごとの切り替えという機能上の必要があるため、この条件の対象外とする (lock の checksum で再取得時の改ざんは検出する)。
3. global config (`~/.config/mise/config.toml`) は chezmoi で管理し、CLI は `"latest"`、ランタイムは prefix (`node = "26"` など) で書く。exact version は書かない (cooldown を素通りするため)。`mise.lock` も chezmoi で commit し、どのマシンも同じ version・checksum を使う。
4. 安全設定: `minimum_release_age = "48h"` (Homebrew reviewed helper の後継経路なので同じ値)、`locked = true` と `locked_scopes = ["global"]` (lock のない既存プロジェクトを壊さない)、`locked_verify_provenance = true`、`auto_install` / `exec_auto_install` / `not_found_auto_install` を false (git hook・sandbox・非対話での暗黙ダウンロードを防ぐ)。`.ruby-version` / `.python-version` / `.nvmrc` 等を使う既存プロジェクトのため `idiomatic_version_file_enable_tools = ["node", "python", "ruby"]` とする。
5. 更新は `MISE_CONFIG_DIR=<source>/private_dot_config/mise mise lock --global --bump` で chezmoi source 側の lock を更新し、lock の差分をレビューして commit する。他マシンは apply で lock を受け取り、`mise install` を明示実行する (chezmoi script では install しない)。lock の差分で既存 CLI の `provenance` が消えた場合は更新を止める。
6. shell は asdf と同じく shims を PATH に prepend する (`mise activate` は使わない)。Homebrew の mise formula は fish の `vendor_conf.d/mise-activate.fish` で `config.fish` より先に `mise activate fish` を実行し、`~/.tool-versions` の有無に関係なく mise のツールを PATH に載せるため、同名の `~/.config/fish/conf.d/mise-activate.fish` で隠し、同じファイルで formula の opt-out 変数 `MISE_FISH_AUTO_ACTIVATE=0` も設定する (どちらか一方が formula 側で変わっても止まるようにするため)。fish と bash は「mise が PATH にある」「mise の shims ディレクトリがある」「`~/.tool-versions` がない」がそろった場合だけ mise に切り替え、それ以外は asdf を使う。`mise install` は shims を作るだけで切り替えにならず、global のツールを入れ終えてから `~/.tool-versions` を退避した時点で切り替わる (途中の apply や部分的な install で runtime が消えないようにするため)。親 shell から引き継いだ、選ばなかった側の shims は PATH から外す。この分岐は asdf の撤去時に削除する。shims は `JAVA_HOME` を設定しないため、対話 shell では fish は `fish_prompt` event、bash は `PROMPT_COMMAND` で `mise which java` から毎回再計算し、asdf-java と同じく既存の値を上書きする。Java を解決できないときは hook 自身が設定した値だけを消す。
7. mise は chezmoi の bootstrap で導入せず、`gh auth login` の後に `brew install mise` で手動導入する。mise は lock の provenance 検証の起点なので、Homebrew の attestation 検証を有効にしたまま入れる (bootstrap は gh 認証前に走りうるため `HOMEBREW_NO_VERIFY_ATTESTATIONS=1` が必要になり、`brew verify` はインストール済みの keg ではなくその時点の bottle を検証するので、事後検証にならない)。
8. Linux は config と lock を共有するが、移行は macOS から行う。Linux の移行手順が決まるまで Linux には mise を導入しない。Linuxbrew の撤去は別途判断する。

付録 (2026-11-05 時点の判定): mise に載せた CLI は gh, jq, actionlint, lefthook, pinact, biome (github-attestations), trivy (cosign)。checksum のみで Homebrew に残した CLI は ripgrep, fzf, starship, gitleaks, peco, pre-commit, stripe, swiftlint, tfsec。ランタイムの lock 上の provenance は python と ruby が github-attestations、node・java・zig・bun・deno は checksum のみ。

## Consequences

### Positive

- ランタイムで第三者 plugin のコード実行がなくなり、cooldown と lock が適用される。
- 更新が lock の差分として残り、マシン間で一致する。エージェントは `mise lock --json --dry-run` で候補を取得できる。
- 会社プロジェクトの `mise.toml` (terraform 等) をそのまま使える。
- Linux の Linuxbrew 依存を減らす前提ができる。

### Negative / Trade-offs

- 条件 2 により mise に移る CLI は少なく、Homebrew 側の reviewed helper の対象は大きく減らない。上流が署名を始めれば bump 時に lock に `provenance` が現れるので、その時点で移行候補にする。
- 既存ランタイムは mise で入れ直す必要がある (asdf の install は再利用されない)。
- 更新経路が Homebrew と mise の 2 系統になる。横断的な更新はエージェント側で扱う。

### Risks

- 新しい version を解決するとき (bump 時) は mise-versions / mise-java (jdx 運営) を信頼する。asdf も plugin repo の metadata を無固定で取得し plugin コードを実行していたため、リスクの形が変わったものとして受け入れる。再取得は lock の checksum で守られる。
- aqua registry は mise に同梱されるため、mise の更新で検証定義が弱まる可能性がある。lock の `provenance` 消失で検知する。
- cargo / opam / ghcup が取得する中身には cooldown がない (現状と同じ。範囲外)。
- `gh auth` を前提とする (attestation 検証と GitHub API rate limit のため。Homebrew helper と同じ)。
- prefix 指定のランタイムが EOL になっても気づけない (例: node の奇数版)。更新時に EOL を確認する。
- global の `auto_install = false` と 48h cooldown は project の解決にも効く。lock のない会社プロジェクトでは同僚と異なる patch が選ばれうる。必要なら project 単位で `--minimum-release-age` を上書きする。

## Alternatives considered

- **ランタイムだけ mise に移す**: CLI 更新の負担が残る。
- **mise で入るものはすべて移す (cargo / github / vfox backend 含む)**: backend ごとに検証基準がばらつき、Homebrew より弱い経路が混ざる。
- **CLI の移行条件を registry 定義の目視確認にする / checksum があれば可とする**: 前者は override 構造の読み違いと bump ごとの再確認が重い。checksum ファイルは同じ release に置かれるため release 乗っ取りに効かない。後者は Homebrew より弱い。
- **version を config に固定して Renovate で更新する**: Renovate の mise lock 連携に既知の不具合があり、新規導入も必要。更新忘れが問題になったら再検討する。
- **chezmoi `run_onchange_` で apply 時に `mise install`**: apply がネットワーク取得とバイナリ導入を伴い、`--exclude=scripts` 運用で状態がずれる。
- **`mise activate`**: git hook や非対話環境で PATH が揃わない。
- **Nix (nix-darwin)**: CLI とライブラリには強いが、GUI アプリは結局 Cask に頼り、移行コストが大きい。
- **aqua 単体**: CLI 専用でランタイムを管理しない。

## Related

- [ADR 0026](0026-development-update-policy.md) / [ADR 0023](0023-asdf-on-linux-via-linuxbrew.md) / [ADR 0013](0013-linux-support-hybrid-apt-brew.md)
- [docs/mise.md](../mise.md)
