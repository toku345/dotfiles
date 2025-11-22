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

### age鍵のバックアップ

age暗号鍵（`~/key.txt`）は暗号化されたファイルを復号するために必須です。この鍵を紛失すると、暗号化されたファイルにアクセスできなくなります。

#### 推奨される保管方法

1. **物理的なバックアップ（最優先）**
   ```bash
   # 鍵を安全なUSBドライブにコピー
   cp ~/key.txt /Volumes/SecureUSB/backups/age-key-$(date +%Y%m%d).txt
   ```
   - 複数のUSBドライブに保存することを推奨
   - 物理的に異なる場所に保管（自宅、オフィス、実家など）
   - 耐火性・防水性のある保管容器の使用を検討

2. **パスワードマネージャー**
   ```bash
   # 鍵の内容を表示してコピー
   cat ~/key.txt
   ```
   - 1Password、Bitwarden、LastPassなどに保存
   - セキュアノートとして保存することを推奨
   - 必ず2FAを有効化すること

3. **暗号化したクラウドストレージ（補助的）**
   ```bash
   # 鍵自体をさらに暗号化してバックアップ
   age -p ~/key.txt > ~/key.txt.encrypted
   # 暗号化されたファイルをクラウドにアップロード
   # 例: Dropbox, Google Drive, iCloud
   ```
   - パスワード保護を必ず使用
   - 強力なパスフレーズを使用し、別途安全に保管

#### バックアップの確認

定期的にバックアップが有効であることを確認してください：

```bash
# バックアップした鍵で復号テスト
age -d -i /path/to/backup/key.txt key.txt.age
```

### dotfilesのバックアップ

dotfilesはGitリポジトリで管理されているため、基本的にGitHub上にバックアップされています。

#### 追加のバックアップ方法

1. **ローカルバックアップ**
   ```bash
   # chezmoi管理下のファイルをアーカイブ
   cd ~/.local/share/chezmoi
   tar czf ~/dotfiles-backup-$(date +%Y%m%d).tar.gz .
   ```

2. **リモートリポジトリのミラー**
   ```bash
   # 別のGitホスティングサービスにミラーリング
   cd ~/.local/share/chezmoi
   git remote add backup git@gitlab.com:username/dotfiles.git
   git push backup main
   ```

3. **特定の設定ファイルのエクスポート**
   ```bash
   # 重要な設定ファイルを別途保存
   chezmoi archive --output=~/dotfiles-$(date +%Y%m%d).tar.gz
   ```

### バックアップの頻度

| 項目 | 推奨頻度 | 理由 |
|------|----------|------|
| age鍵 | 初回作成時および変更時 | 鍵は滅多に変更されないが、紛失時の影響が大きい |
| dotfiles（Git push） | 変更のたびに | GitHubへのpushで自動的にバックアップされる |
| ローカルアーカイブ | 月次または大きな変更後 | オフラインバックアップとして有用 |
| バックアップの確認 | 四半期ごと | バックアップが実際に使用可能であることを確認 |

## 復元手順

### 新しいマシンへのセットアップ

#### 前提条件の確認

- [ ] age鍵のバックアップにアクセス可能
- [ ] GitHubアカウントへのアクセス権限
- [ ] SSH鍵の準備（または新規作成）

#### セットアップ手順

1. **必要なツールのインストール**
   ```bash
   # Homebrewのインストール（macOS）
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

   # chezmoiとageのインストール
   brew install chezmoi age
   ```

2. **age鍵の復元**
   ```bash
   # バックアップから鍵を復元
   cp /path/to/backup/key.txt ~/key.txt
   chmod 600 ~/key.txt

   # または、暗号化されたバックアップから復元
   age -d -o ~/key.txt ~/key.txt.encrypted
   chmod 600 ~/key.txt
   ```

3. **SSH鍵の設定**
   ```bash
   # 既存のSSH鍵がある場合
   cp /path/to/backup/id_ed25519 ~/.ssh/
   cp /path/to/backup/id_ed25519.pub ~/.ssh/
   chmod 600 ~/.ssh/id_ed25519
   chmod 644 ~/.ssh/id_ed25519.pub

   # または新規作成
   ssh-keygen -t ed25519 -C "your_email@example.com"
   # 生成された公開鍵をGitHubに追加
   cat ~/.ssh/id_ed25519.pub
   ```

4. **chezmoiの初期化**
   ```bash
   # リポジトリをクローン
   chezmoi init toku345

   # 変更内容を確認
   chezmoi diff

   # 問題がなければ適用
   chezmoi apply
   ```

5. **設定の確認**
   ```bash
   # 暗号化ファイルの復号テスト
   age -d -i ~/key.txt ~/.local/share/chezmoi/key.txt.age

   # または、chezmoiで暗号化ファイルを確認
   chezmoi cat ~/key.txt

   # 適用されたファイルの確認
   chezmoi diff

   # 問題がなければ適用
   chezmoi apply -v
   ```

6. **追加セットアップ**
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

#### バックアップ準備
- [ ] age鍵をUSBドライブにバックアップ
- [ ] age鍵をパスワードマネージャーに保存
- [ ] age鍵の暗号化バックアップをクラウドに保存
- [ ] バックアップした鍵で復号テストを実施
- [ ] SSH鍵のバックアップを作成
- [ ] dotfilesのローカルアーカイブを作成

#### リポジトリ設定
- [ ] GitHubリポジトリへのpushを確認
- [ ] リモートリポジトリのミラーを検討（オプション）
- [ ] .chezmoiignoreの設定を確認

### 新しいマシンへの移行チェックリスト

#### 事前準備
- [ ] age鍵のバックアップを確認
- [ ] GitHubへのアクセス権限を確認
- [ ] SSH鍵を準備（既存または新規作成）

#### セットアップ
- [ ] Homebrewをインストール
- [ ] chezmoiをインストール
- [ ] ageをインストール
- [ ] age鍵を復元（~/key.txt）
- [ ] age鍵のパーミッションを設定（chmod 600）
- [ ] SSH鍵を設定
- [ ] SSH公開鍵をGitHubに追加
- [ ] chezmoi init --apply を実行

#### 検証
- [ ] 暗号化ファイルの復号テスト
- [ ] chezmoi diff で差分を確認
- [ ] chezmoi apply -v で適用
- [ ] シェル設定が正しく読み込まれることを確認
- [ ] 各種ツール（asdf、direnvなど）の動作確認
- [ ] iTerm2の設定を手動で設定
- [ ] Nerd Fontがインストールされていることを確認

### リカバリーチェックリスト

#### age鍵紛失時
- [ ] 新しいage鍵を生成
- [ ] 新しい鍵の公開鍵を確認
- [ ] 暗号化されていたファイルをリスト化
- [ ] 各暗号化ファイルを再作成
- [ ] 新しい鍵でファイルを暗号化
- [ ] 新しい鍵をバックアップ（複数箇所）
- [ ] 変更をGitにコミット・プッシュ
- [ ] 他のマシンで新しい鍵に更新

#### システム不具合時
- [ ] 問題のあるファイルを特定
- [ ] git logで変更履歴を確認
- [ ] 問題のあるコミットを特定
- [ ] git revertまたはgit checkoutで修正
- [ ] chezmoi diffで変更内容を確認
- [ ] chezmoi applyで適用
- [ ] システムの動作を検証

### 定期メンテナンスチェックリスト

#### 月次
- [ ] dotfilesの変更をGitHubにpush
- [ ] ローカルアーカイブを作成
- [ ] 不要な設定ファイルを整理

#### 四半期ごと
- [ ] age鍵のバックアップを確認
- [ ] バックアップから復号テストを実施
- [ ] SSH鍵のバックアップを確認
- [ ] 暗号化ファイルの整合性を確認
- [ ] ドキュメントの更新を確認

#### 年次
- [ ] age鍵のローテーションを検討
- [ ] バックアップ戦略の見直し
- [ ] 暗号化ファイルの再暗号化を検討
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
