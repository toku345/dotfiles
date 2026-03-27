# バックアップ・復元戦略

このドキュメントでは、dotfilesとage暗号鍵のバックアップ・復元手順を説明します。データ損失のリスクを軽減し、新しいマシンへの移行をスムーズに行うための重要な情報です。

## 目次

- [バックアップ戦略](#バックアップ戦略)
  - [age鍵のバックアップ](#age鍵のバックアップ)
  - [dotfilesのバックアップ](#dotfilesのバックアップ)
  - [バックアップの頻度](#バックアップの頻度)
- [復元手順](#復元手順)
  - [新しいマシンへのセットアップ](#新しいマシンへのセットアップ)
  - [age鍵を紛失した場合の対処法](#age鍵を紛失した場合の対処法)
  - [暗号化ファイルの再暗号化](#暗号化ファイルの再暗号化)
- [ロールバック手順](#ロールバック手順)
- [チェックリスト](#チェックリスト)

## バックアップ戦略

### このリポジトリの構成

このリポジトリでは、age暗号鍵自体もパスワード保護されてリポジトリに含まれています：

```
key.txt.age (リポジトリに保存)
    ↓ パスワードで復号
~/key.txt (ローカルの秘密鍵)
    ↓ 他の暗号化ファイルを復号
encrypted_*.age (SSH設定、Google IME辞書など)
```

**重要**: 災害復旧に必要なのは以下の3つだけです：
1. GitHubアカウントへのアクセス（リポジトリをclone）
2. 1Passwordへのアクセス（パスワードを取得）
3. key.txt.ageのパスワード（1Passwordに保存）

### 本当に重要なバックアップ（必須）

#### 1. 1Passwordのリカバリー情報

**Single Point of Failure を避ける最重要タスク：**

- **Emergency Kit（リカバリーコード）の保管**
  - 1Passwordアカウント作成時に発行されるPDFを印刷
  - 耐火金庫や銀行の貸金庫に保管
  - 信頼できる家族に預けることも検討

- **マスターパスワードの管理**
  - 絶対に忘れないこと
  - パスワードマネージャーに頼らず記憶する
  - 必要に応じて紙に書いて別の安全な場所に保管

- **2FAのバックアップ**
  - 複数の認証デバイスを登録
  - リカバリーコードを印刷して保管

#### 2. GitHubアカウントのリカバリー

- **2FAのリカバリーコード保存**
  - GitHubの2FAリカバリーコードをダウンロード
  - 1Passwordに保存 + 印刷して保管

- **複数の認証方法を設定**
  - 認証アプリ + ハードウェアキー（YubiKeyなど）

#### 3. key.txt.age のパスワードのバックアップ（推奨）

1Passwordが使えなくなった場合の保険として：

```bash
# パスワードを紙に書いて保管（推奨）
# - 耐火金庫に保管
# - 信頼できる家族に預ける
# - 銀行の貸金庫を利用
```

**注意**: パスワードは絶対にリポジトリにコミットしないこと

### dotfilesのバックアップ

dotfiles（設定ファイル）と暗号化された秘密鍵（key.txt.age）は **GitHubリポジトリに保存されています**。

#### GitHubへのpush（必須）

```bash
# 変更のたびにGitHubにpush
cd ~/.local/share/chezmoi
git add .
git commit -m "Update dotfiles"
git push
```

これだけで、全ての設定ファイルと暗号化された秘密鍵がバックアップされます。

#### 追加のバックアップ（オプション）

冗長性を高めたい場合のみ：

```bash
# リモートリポジトリのミラー（GitLabなど）
cd ~/.local/share/chezmoi
git remote add backup git@gitlab.com:username/dotfiles.git
git push backup main
```

### バックアップの頻度

| 項目 | 推奨頻度 | 理由 |
|------|----------|------|
| 1Passwordリカバリー情報確認 | 初回セットアップ時 | 失うと全てにアクセスできなくなる |
| dotfiles（Git push） | 変更のたびに | GitHubへのpushで自動的にバックアップされる |
| GitHubリカバリーコード確認 | 初回セットアップ時 + 年次 | 2FA紛失時のリカバリーに必要 |
| バックアップテスト | 年次または新マシン購入時 | 実際にリカバリーできることを確認 |

## 復元手順

### 新しいマシンへのセットアップ

#### 前提条件の確認

- [ ] 1Passwordへのアクセス権限（マスターパスワード + 2FA）
- [ ] GitHubアカウントへのアクセス権限（パスワード + 2FA）
- [ ] key.txt.ageのパスワード（1Passwordに保存されています）

#### セットアップ手順

1. **必要なツールのインストール**
   ```bash
   # Homebrewのインストール（macOS）
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

   # chezmoiとageのインストール
   brew install chezmoi age
   ```

2. **SSH鍵の設定**
   ```bash
   # 新規作成
   ssh-keygen -t ed25519 -C "your_email@example.com"

   # 生成された公開鍵をGitHubに追加
   cat ~/.ssh/id_ed25519.pub
   # → GitHubの Settings > SSH and GPG keys で追加
   ```

3. **リポジトリのクローンとage鍵の復元**
   ```bash
   # リポジトリをクローン
   chezmoi init toku345

   # key.txt.ageからage鍵を復元
   # 1Passwordからパスワードを取得して入力
   cd ~/.local/share/chezmoi
   age -d -o ~/key.txt key.txt.age
   # パスワードを入力: [1Passwordから取得したパスワード]

   chmod 600 ~/key.txt
   ```

4. **dotfilesの適用**
   ```bash
   # 変更内容を確認
   chezmoi diff

   # 問題がなければ適用（暗号化ファイルも自動的に復号されます）
   chezmoi apply

   # verboseモードで詳細を確認する場合
   chezmoi apply -v
   ```

5. **追加セットアップ**
   - [README.md](../README.md)の「Additional Setup」セクションを参照
   - iTerm2の設定
   - Nerd Fontのインストール

### age鍵を紛失した場合の対処法

**重要**: age鍵を紛失した場合、既存の暗号化ファイルを復号することはできません。

#### 対処手順

1. **新しいage鍵を生成**
   ```bash
   # 新しい鍵ペアを生成
   age-keygen -o ~/key.txt
   chmod 600 ~/key.txt

   # 公開鍵を確認
   age-keygen -y ~/key.txt
   ```

2. **暗号化ファイルの再作成**

   暗号化されていたファイルを再作成する必要があります：

   ```bash
   # 例: SSH設定を再暗号化
   cd ~/.local/share/chezmoi

   # 元のファイルを削除
   rm encrypted_*.age

   # まず平文ファイルを作成（エディタで編集）
   vim temp_ssh_config

   # 公開鍵を取得
   AGE_PUBLIC_KEY=$(age-keygen -y ~/key.txt)

   # 新しい鍵で暗号化
   # ファイル名の命名規則: encrypted_private_dot_ssh_config.age
   # → encrypted_ プレフィックス + chezmoi のターゲットパス
   age -r $AGE_PUBLIC_KEY -o encrypted_private_dot_ssh_config.age temp_ssh_config

   # 平文ファイルを削除
   # 注: macOSのSSD/APFS環境では安全な削除は技術的に困難です
   # FileVault を有効化することで、ファイルシステム全体が暗号化されます
   rm temp_ssh_config
   ```

3. **バックアップの作成**

   新しい鍵を必ずバックアップしてください（上記のバックアップ手順を参照）

4. **変更をコミット**
   ```bash
   cd ~/.local/share/chezmoi
   git add .
   git commit -m "Re-encrypt files with new age key"
   git push
   ```

### 暗号化ファイルの再暗号化

鍵のローテーションやセキュリティ上の理由で、暗号化ファイルを再暗号化する場合：

```bash
cd ~/.local/share/chezmoi

# 既存の暗号化ファイルを復号
age -d -i ~/old-key.txt encrypted_file.age > decrypted_file

# 新しい鍵で再暗号化
age -r $(age-keygen -y ~/key.txt) -o encrypted_file.age decrypted_file

# 一時ファイルを削除
# 注: macOSのSSD/APFS環境では、shredやrm -Pは効果がありません
# セキュリティのため、FileVault を有効化することを強く推奨します
rm decrypted_file

# 変更をコミット
git add encrypted_file.age
git commit -m "Re-encrypt with new key"
git push
```

## ロールバック手順

### 特定のコミットに戻す

```bash
cd ~/.local/share/chezmoi

# 変更履歴を確認
git log --oneline

# 特定のコミットの状態を確認
git show <commit-hash>

# 特定のファイルを以前の状態に戻す
git checkout <commit-hash> -- path/to/file

# または、コミット全体を戻す
git revert <commit-hash>

# 変更を適用
chezmoi apply
```

### 適用前の状態に戻す

```bash
# 最後の適用を取り消す
cd ~/.local/share/chezmoi

# 警告: git reset --hard は危険なコマンドです
# 未コミットの変更は完全に失われます
# まずは git stash で変更を退避することを推奨します
git stash

# それでも必要な場合のみ実行
git reset --hard HEAD^

# または、特定のファイルだけを戻す
chezmoi forget <file>
```

### 緊急時の対処

システムが不安定になった場合：

```bash
# chezmoiの適用を一時的に停止
cd ~
mv .local/share/chezmoi .local/share/chezmoi.backup

# 問題のあるファイルを手動で修正
# 例: Fish設定が問題の場合
mv ~/.config/fish/config.fish ~/.config/fish/config.fish.broken

# 作業可能なシェルで問題を調査
bash

# 修正後、chezmoiを復元
mv .local/share/chezmoi.backup .local/share/chezmoi
```

## チェックリスト

### 初回セットアップチェックリスト

#### バックアップ準備（最重要）
- [ ] 1Password Emergency Kitを印刷して金庫に保管
- [ ] 1Passwordのマスターパスワードを確実に記憶
- [ ] 1Passwordの2FAリカバリーコードを保存
- [ ] GitHubの2FAリカバリーコードを保存（1Password + 印刷）
- [ ] key.txt.ageのパスワードを紙に書いて金庫に保管（推奨）

#### リポジトリ設定
- [ ] key.txt.ageがリポジトリにコミットされていることを確認
- [ ] GitHubリポジトリへのpushを確認
- [ ] .chezmoiignoreの設定を確認

### 新しいマシンへの移行チェックリスト

#### 事前準備
- [ ] 1Passwordにログイン可能（マスターパスワード + 2FA）
- [ ] GitHubにログイン可能（パスワード + 2FA）
- [ ] key.txt.ageのパスワードを1Passwordから取得可能

#### セットアップ
- [ ] Homebrewをインストール
- [ ] chezmoi、ageをインストール
- [ ] SSH鍵を生成してGitHubに追加
- [ ] `chezmoi init toku345` を実行
- [ ] `age -d -o ~/key.txt key.txt.age` で秘密鍵を復元
- [ ] `chmod 600 ~/key.txt` で権限設定
- [ ] `chezmoi diff` で変更を確認
- [ ] `chezmoi apply` でdotfilesを適用

#### 検証
- [ ] シェル設定が正しく読み込まれることを確認
- [ ] 各種ツール（asdf、direnvなど）の動作確認
- [ ] iTerm2の設定を手動で設定
- [ ] Nerd Fontがインストールされていることを確認

### リカバリーチェックリスト

#### key.txt.ageのパスワード紛失時
- [ ] 1Passwordから再取得を試みる
- [ ] 紙のバックアップを確認
- [ ] どちらも失敗した場合は「age鍵紛失時の対処法」を参照

#### age鍵紛失時（key.txt.ageのパスワードも不明な場合）
- [ ] 新しいage鍵を生成
- [ ] 暗号化されていたファイルを再作成
- [ ] 新しい鍵でファイルを再暗号化
- [ ] 新しい key.txt.age を作成してリポジトリにpush
- [ ] 新しいパスワードを1Passwordに保存

#### システム不具合時
- [ ] 問題のあるファイルを特定
- [ ] git logで変更履歴を確認
- [ ] 問題のあるコミットを特定
- [ ] git revertまたはgit checkoutで修正
- [ ] chezmoi diffで変更内容を確認
- [ ] chezmoi applyで適用
- [ ] システムの動作を検証

### 定期メンテナンスチェックリスト

#### 日常
- [ ] dotfilesの変更をGitHubにpush（変更のたびに）

#### 年次
- [ ] 1Password Emergency Kitが安全に保管されていることを確認
- [ ] GitHubの2FAリカバリーコードを更新
- [ ] key.txt.ageのパスワードバックアップを確認
- [ ] 新しいマシンでのセットアップテスト（可能であれば）
- [ ] age鍵のローテーションを検討（セキュリティ要件に応じて）
- [ ] 使用していない設定ファイルの削除

## トラブルシューティング

### よくある問題と解決方法

#### 暗号化ファイルが復号できない

```bash
# 鍵のパーミッションを確認
ls -l ~/key.txt
# 600である必要があります

# 正しい鍵を使用しているか確認
age-keygen -y ~/key.txt
# 出力された公開鍵が暗号化時に使用したものと一致するか確認
```

#### chezmoi applyがエラーになる

```bash
# 詳細なエラーメッセージを確認
chezmoi apply -v

# ドライランで確認
chezmoi apply --dry-run --verbose

# 特定のファイルだけを適用
chezmoi apply ~/.config/fish/config.fish
```

#### GitHubへのpushができない

```bash
# SSH接続を確認
ssh -T git@github.com

# リモートURLを確認
cd ~/.local/share/chezmoi
git remote -v

# SSH鍵がGitHubに登録されているか確認
```

## 参考リンク

- [chezmoi公式ドキュメント](https://www.chezmoi.io/)
- [age暗号化ツール](https://github.com/FiloSottile/age)
- [GitHubでのSSH鍵の使用](https://docs.github.com/ja/authentication/connecting-to-github-with-ssh)
- [リポジトリのREADME](../README.md)
- [CLAUDE.md - リポジトリガイド](../CLAUDE.md)
