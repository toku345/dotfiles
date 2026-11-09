# mise 運用手順

言語ランタイムと provenance 付き CLI は mise で管理します。方針の根拠は [ADR 0041](adr/0041-mise-for-cli-and-runtime-management.md)、Homebrew 側は [homebrew-update.md](homebrew-update.md) を参照してください。

## 管理ファイル

| source (chezmoi) | target | 内容 |
| --- | --- | --- |
| `private_dot_config/mise/config.toml` | `~/.config/mise/config.toml` | 安全設定と global tools。CLI は `"latest"`、ランタイムは prefix。exact version は書かない |
| `private_dot_config/mise/mise.lock` | `~/.config/mise/mise.lock` | version・checksum・URL・`provenance` (`macos-arm64`, `linux-x64`) |

前提: `gh auth status` が成功すること (attestation 検証と GitHub API rate limit のため。mise は `gh` の token を使います)。

`bats tests/bats/test_mise_policy.bats` は、必須設定、exact version の不在、全 platform の lock、config と lock の request の一致、ランタイム以外のツールの `provenance`、shell の切り替え条件、`JAVA_HOME` hook、fish での Homebrew の自動 `mise activate` の停止を検査します。

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

macOS で一度だけ行います。shell は「mise が PATH にある」「mise の shims ディレクトリ (`~/.local/share/mise/shims`) がある」「`~/.tool-versions` がない」の 3 つがそろうまで asdf を使い続けます。そのため `chezmoi apply` や `mise install` をどの時点で実行しても runtime は消えず、手順 4 の退避が切り替えになります。既存ファイルの退避と apply は live 操作なので、実施前に対象と復元方法を確認してください。

1. `gh auth status` が成功する状態で `brew install mise` を実行する (Homebrew の attestation 検証が有効なまま入ります)
2. `chezmoi apply` で `~/.config/mise/` と shell 設定を配置する (`~/.tool-versions` が残っているので shell は asdf のまま)
3. home で global のツールを導入し、不足がないことを確認する (fish / bash 共通の書き方です)。

   ```sh
   cd ~
   MISE_IGNORED_CONFIG_PATHS="$HOME/.tool-versions" mise install
   MISE_IGNORED_CONFIG_PATHS="$HOME/.tool-versions" mise ls --missing   # 何も表示されなければ成功
   ```

   home で実行するのは、プロジェクト内だと mise がそのプロジェクトの設定を読み、global のツールが入らないまま成功しうるためです。asdf が使う `~/.tool-versions` はこの時点では残し、mise にだけ無視させます (読ませると旧 exact version や mise で管理しない tmux / poetry まで導入しようとします)。失敗したら asdf のまま止めます (shell は切り替わっていません)
4. 成功したら `~/.tool-versions` を退避する (例: `mv ~/.tool-versions ~/.tool-versions.asdf-backup`)。以後に開いた shell は mise に切り替わります
5. 普段使うプロジェクトで `mise install` を実行し、要求 version の導入と動作を確認する (mise は asdf の install を再利用しません)
6. 新しい shell で `mise config ls` / `mise ls --current` の解決元が `~/.config/mise/config.toml` (またはプロジェクトの設定) であること、`java -version` と `echo $JAVA_HOME` が一致すること、fish で `functions -q __mise_env_eval` が失敗する (Homebrew の自動 `mise activate` が止まっている) ことを確認する
7. 移行できていないプロジェクトは `asdf exec <tool> ...` で一時的に使う

asdf に戻すには `mv ~/.tool-versions.asdf-backup ~/.tool-versions` を実行し、shell を開き直します。

会社プロジェクトに `mise.lock` がない場合、global の 48h cooldown で同僚と異なる patch が選ばれることがあります。その場合はプロジェクト単位で `mise install --minimum-release-age 0d` を使います。

## 新しいマシン

chezmoi は mise を導入しません。`chezmoi apply` → `gh auth login` → `brew install mise` → `cd ~` → `mise install` の順に実行してください。gh は bootstrap が Homebrew で導入済みです (mise の gh とは別。bootstrap に必要なので Homebrew の gh は残します)。apply で `~/.homebrew/brew.env` が配置されるので、mise は attestation 検証付きで入ります。`~/.tool-versions` のないマシンでは、`mise install` で shims ができた時点で shell が mise に切り替わります。途中で失敗しても切り替わるため、`mise ls --missing` で何も表示されないことを確認してください。

Linux の移行手順が決まるまでは、Linux で mise を導入しないでください。
