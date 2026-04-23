# Linux Setup Guide

このリポジトリは Linux ホスト（テスト済み: Ubuntu, DGX OS）での利用をサポートします。主な用途は SSH 接続先の開発サーバーです。

詳細な設計判断は [ADR 0013](adr/0013-linux-support-hybrid-apt-brew.md) を参照してください。

## 前提条件

- ターゲットホストで **sudo** が使える（`sudo apt-get install ...`）
- **インターネット接続**（apt, Homebrew, 各言語マネージャーの installer が必要）
- Linuxbrew が `/home/linuxbrew/.linuxbrew` に配置可能（ユーザー単位の `~/.linuxbrew` 構成は本リポジトリでは非サポート）

## Bootstrap 手順

### Step 1: apt で前提パッケージを導入

```bash
sudo apt-get update
sudo apt-get install -y build-essential curl file git procps
```

`build-essential` 以降は Linuxbrew および後続インストールの依存関係です。

### Step 2: Linuxbrew をインストール

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

### Step 3: Bootstrap ツール (chezmoi, age) を導入

```bash
brew install chezmoi age
```

chezmoi と age は `chezmoi init` の実行に必須なため、chezmoi 管理下の install script **ではなく**手動で導入します。

### Step 4: chezmoi init --apply を実行

```bash
chezmoi init --apply toku345
```

このコマンドが以下を自動で行います:

1. `key.txt.age` を 1Password のパスワードで復号 (`run_once_before_decrypt-private-key.sh`)
2. apt と Linuxbrew で CLI アプリ群をインストール (`run_once_before_install-minimum-packages.sh` の Linux 分岐)
3. macOS 専用設定を [`.chezmoiignore`](../.chezmoiignore) の OS 分岐でスキップ（除外対象の正確な一覧は同ファイルを参照）
4. `~/.bashrc`, `~/.bash_profile`, `~/.config/starship.toml` などを配置

### Step 5: ログインシェルを bash に切り替え (optional)

Ubuntu などは既定で bash ですが、別のシェルが既定の場合は切り替えます:

```bash
chsh -s /bin/bash
```

SSH 接続時には login shell として `~/.bash_profile` 経由で `~/.bashrc` が source されます。

## Post-setup (optional)

### 言語マネージャーの導入

本リポジトリの Linux 構成では **asdf を使いません**。各言語を個別のインストーラーで管理します。`dot_bashrc` が `~/.cargo/bin`, `~/.bun/bin`, `~/.local/bin` を自動で PATH に追加するため、以下を実行するだけで有効化されます。

- **Rust (rustup)**:
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

- **JavaScript (bun)**:
  ```bash
  curl -fsSL https://bun.sh/install | bash
  ```

- **Python (uv)**:
  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```

導入後は `source ~/.bashrc` でシェルをリロードしてください。

## Verification (PR 前のローカル検証)

Linux に影響する変更を PR 化する前に、Docker で再現テストを実行します:

```bash
docker run --rm -it ubuntu:24.04 bash -c '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        sudo curl git file build-essential procps
    # sudo 権限を持つ非 root ユーザーで本番 SSH ホストを模倣
    useradd -m -s /bin/bash dev
    echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
    su - dev -c "
        /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
        eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"
        brew install chezmoi age
        chezmoi init --apply toku345 --verbose
    "
'
```

期待される結果:

- install script が Linux 分岐を実行し、apt + Linuxbrew でツール群が揃う
- `~/.bashrc`, `~/.bash_profile`, `~/.config/starship.toml` が生成される
- macOS 専用ファイル群は[`.chezmoiignore`](../.chezmoiignore) の Linux 分岐に列挙されたパスが**生成されない**
- `~/.config/iterm2/shell_integration.fish` は iTerm2 script の OS guard により作成されない

AGENTS.md の「Docker での Ubuntu CI parity 検証」節も併せて参照してください。

## Troubleshooting

### `Error: Linuxbrew not found at /home/linuxbrew/.linuxbrew`

`chezmoi init --apply` の install script がこのエラーで停止する場合、Step 2 の Linuxbrew インストールが失敗しているか、非標準のプレフィックスにインストールされています。`/home/linuxbrew/.linuxbrew` 固定が前提です。

### `chsh: PAM authentication failed`

DGX OS などの管理下ホストで `chsh` が拒否される場合は、既定シェルの変更を諦め、SSH 接続時に `bash -l` を明示的に起動するか、ssh config の `RemoteCommand` で bash を起動してください。

### Nerd Font グリフが読めない

Linux 側の starship プロンプトは **Bracketed Segments preset** (Unicode 罫線文字使用、Nerd Font グリフ非依存) を使っているため、Nerd Font なしでも正しく描画されます。接続元ターミナル (macOS 側の Ghostty 等) の Nerd Font は Linux 側の表示に影響しません。

## 関連ドキュメント

- [ADR 0013: Linux support via hybrid apt + Linuxbrew with Bash](adr/0013-linux-support-hybrid-apt-brew.md)
- [AGENTS.md - Repository guidance](../AGENTS.md)
- [docs/backup-restore.md - バックアップ・復元戦略](backup-restore.md)
