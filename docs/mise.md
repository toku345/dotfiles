# mise 運用手順

言語ランタイムと provenance 付き CLI は mise で管理します。方針の根拠は [ADR 0041](adr/0041-mise-for-cli-and-runtime-management.md)、Homebrew 側は [homebrew-update.md](homebrew-update.md) を参照してください。

## 管理ファイル

| source (chezmoi) | target | 内容 |
| --- | --- | --- |
| `private_dot_config/mise/config.toml` | `~/.config/mise/config.toml` | 安全設定と global tools。CLI は `"latest"`、ランタイムは prefix。exact version は書かない |
| `private_dot_config/mise/mise.lock` | `~/.config/mise/mise.lock` | version・checksum・URL・`provenance` (`macos-arm64`, `linux-x64`) |

前提: `gh auth status` が成功すること (attestation 検証と GitHub API rate limit のため。mise は `gh` の token を使います)。

`bats tests/bats/test_mise_policy.bats` は、必須設定、exact version の不在、全 platform の lock、aqua CLI の `provenance` を検査します。

## 更新 (lock の bump)

chezmoi source 側の lock を更新します。`~/.config/mise` を直接編集しないでください。

```sh
SRC="$(chezmoi source-path)/private_dot_config/mise"   # worktree なら worktree のパス
# 更新候補の確認 (書き込みなし)
MISE_CONFIG_DIR="$SRC" mise lock --global --bump --dry-run --json
# lock の更新
MISE_CONFIG_DIR="$SRC" mise lock --global --bump
git -C "$(chezmoi source-path)" diff -- private_dot_config/mise/mise.lock
```

差分のレビューでは次を確認します。

- 既存の `aqua:` CLI から `provenance` が消えていないこと (消えたら更新しない)
- prefix 指定のランタイムが EOL になっていないこと
- 新しい version の release notes

cooldown (`minimum_release_age = "48h"`) は bump 時の新規解決にだけ効きます。lock 済みの version の install には効きません。security fix などで待機を省略する場合は、[When to bypass the cooldown](security.md#when-to-bypass-the-cooldown) の条件に該当するときだけ `--minimum-release-age 0d` を付けて対象ツールを bump します。

レビュー後に commit し、各マシンで `chezmoi apply` → `mise install` を実行します。apply は lock を配置するだけで、ツールは入れ替わりません (`auto_install` は無効)。

## CLI の追加

1. `config.toml` に `"aqua:owner/repo" = "latest"` を追加する
2. 上記の手順で lock を生成し、`macos-arm64` と `linux-x64` の両方に `provenance` があることを確認する
3. `provenance` がなければ追加せず Homebrew で管理する

## 初回移行 (asdf からの切り替え)

macOS で一度だけ行います。shell は mise の shims ディレクトリ (`~/.local/share/mise/shims`) ができるまで asdf を使い続けるため、`chezmoi apply` はどの時点で実行しても runtime は消えません。既存ファイルの退避と apply は live 操作なので、実施前に対象と復元方法を確認してください。

1. `brew install mise` (bootstrap 済みなら不要)
2. `~/.tool-versions` を退避する (例: `mv ~/.tool-versions ~/.tool-versions.asdf-backup`)。残っていると home 配下のディレクトリで旧 exact version が新しい global config より優先されます
3. `chezmoi apply` で `~/.config/mise/` と shell 設定を配置する (shims がまだないので shell は asdf のまま)
4. `mise install` で global のツールを導入する。shims ができるので、以後に開いた shell は mise に切り替わる
5. 普段使うプロジェクトで `mise install` を実行し、要求 version の導入と動作を確認する (mise は asdf の install を再利用しません)
6. 新しい shell で `mise config ls` / `mise ls --current` の解決元が `~/.config/mise/config.toml` (またはプロジェクトの設定) であること、`java -version` と `echo $JAVA_HOME` が一致することを確認する
7. 移行できていないプロジェクトは `asdf exec <tool> ...` で一時的に使う

会社プロジェクトに `mise.lock` がない場合、global の 48h cooldown で同僚と異なる patch が選ばれることがあります。その場合はプロジェクト単位で `mise install --minimum-release-age 0d` を使います。

## 新しいマシン

`chezmoi apply` の run-once script が macOS で mise を導入します。ツールは自動では入らないので、`gh auth login` の後に `mise install` を実行してください。実行するまでは starship などが無く、プロンプトが簡素になります。

Linux の `dot_bashrc` も、mise と shims ディレクトリがそろった時点で mise に切り替わります。Linux の移行手順が決まるまでは `mise install` を実行しないでください。
