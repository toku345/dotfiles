# CI/CDセキュリティチェック

## 概要

このドキュメントでは、GitHub Actionsで自動実行されるセキュリティチェックについて説明します。

## セキュリティチェックの目的

このdotfilesリポジトリでは、以下のセキュリティリスクを自動的に検出します:

1. **暗号化ファイルの破損** - Age暗号化ファイルが正しい形式であることを確認
2. **必須ファイルの欠損** - 必要な暗号化ファイルが存在することを確認
3. **平文鍵の誤コミット** - 復号化された秘密鍵が誤ってコミットされていないか検出
4. **公開鍵の不整合** - 暗号化に使用されている公開鍵が一貫しているか確認
5. **シークレットの漏洩** - パスワードやAPIキーなどの機密情報が含まれていないか検出

## GitHub Actions ワークフロー

### トリガー条件

セキュリティチェックは以下のタイミングで自動実行されます:

- Pull Request作成時
- Pull Request更新時（新しいコミットがプッシュされたとき）
- `main` ブランチへの直接プッシュ時

ワークフローファイル: `.github/workflows/security-checks.yml`

### 実行されるチェック項目

#### 1. Age ファイル形式検証

**目的:** 暗号化ファイルが正しいage形式であることを確認

**チェック内容:**
- ファイルが `age-encryption.org/v1` ヘッダーで始まるか
- 対象ファイル: `key.txt.age` および `encrypted_*.age`

**検出できる問題:**
- ファイルが破損している
- 暗号化されていないファイルが `.age` 拡張子を持っている
- 古い暗号化形式が使用されている

#### 2. 必須ファイル存在確認

**目的:** リポジトリに必要な暗号化ファイルがすべて存在することを確認

**チェック対象:**
- `key.txt.age` - Age秘密鍵（パスワード暗号化）
- `private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age` - Google IME辞書

**検出できる問題:**
- 誤ってファイルを削除した
- `.gitignore` で誤って除外している

#### 3. 平文鍵の誤コミット検出

**目的:** 復号化された秘密鍵や他の機密ファイルが誤ってコミットされていないことを確認

**チェックパターン:**
- `key.txt` (復号化されたage秘密鍵)
- `*/key.txt`
- `private_key`
- `*.pem` (SSH秘密鍵など)

**重要性:**
- `~/key.txt` は絶対にリポジトリにコミットしてはいけません
- これは復号化された秘密鍵であり、誰でも復号化できてしまいます
- リポジトリに含めるべきは `key.txt.age`（パスワード保護済み）のみ

#### 4. Age 公開鍵の一貫性チェック

**目的:** すべての暗号化ファイルが同じ公開鍵で暗号化されていることを確認

**チェック内容:**
1. `key.txt.age` から受信者（recipient）を抽出
2. `.chezmoi.toml.tmpl` に記載されている公開鍵と一致するか確認
3. すべての `encrypted_*.age` ファイルが同じ受信者で暗号化されているか確認

**検出できる問題:**
- 異なる鍵で暗号化されたファイルが混在している
- 設定ファイル (`.chezmoi.toml.tmpl`) と実際の暗号化が不一致
- 鍵ローテーション時に一部のファイルが更新されていない

**技術的詳細:**
```bash
# 受信者の抽出例
$ grep "-> X25519" key.txt.age | head -n 1 | awk '{print $2}'
age13nd6rta5xqx4prnsggkmsdrcs3dp6ysszncmshyya67r357gua5s0k8gy7
```

#### 5. git-secrets スキャン

**目的:** パスワード、APIキー、トークンなどの機密情報が含まれていないことを確認

**スキャン対象:**
- AWSアクセスキー（20文字）
- AWSシークレットアクセスキー（40文字）
- AWSアカウントID
- 一般的なパスワード/API キーパターン:
  - `password = "..."`
  - `api_key = "..."`
  - `secret = "..."`
  - `token = "..."`

**スキャン範囲:**
- リポジトリ全体のコミット履歴

**検出時の動作:**
- ワークフローが失敗する
- どのパターンにマッチしたかが表示される
- マージがブロックされる

## チェックの制限事項

### 実際の復号化テストは含まれない

**理由:**
- `key.txt.age` の復号化にはパスワードが必要
- パスワードは1Passwordで管理されており、CI環境には保存していない
- セキュリティリスクを避けるため、GitHub Secretsにもパスワードを保存しない

**代替手段:**
- ローカル環境での完全な復号化テストスクリプトを提供（`scripts/validate-encryption.sh`）
- CI/CDでは形式検証と一貫性チェックのみ実施

### チェックできること vs できないこと

| チェック項目 | CI/CD | ローカルスクリプト |
|------------|-------|------------------|
| Age形式の検証 | ✅ | ✅ |
| 必須ファイル存在確認 | ✅ | ✅ |
| 平文鍵の誤コミット検出 | ✅ | ✅ |
| 公開鍵の一貫性 | ✅ | ✅ |
| git-secretsスキャン | ✅ | ✅ |
| **key.txt.age の復号化** | ❌ | ✅ (パスワード入力) |
| **encrypted_*.age の復号化** | ❌ | ✅ |

## ローカル検証スクリプト

完全な復号化テストを含むローカル検証スクリプトが用意されています。

### 使用方法

```bash
cd ~/.local/share/chezmoi

# 検証スクリプトを実行
./scripts/validate-encryption.sh
```

### スクリプトが実行するチェック

1. **前提条件チェック**
   - `age` コマンドがインストールされているか
   - `~/key.txt` (復号化された秘密鍵) が存在するか
   - `~/key.txt` のパーミッションが 600 であるか

2. **Age形式検証**
   - すべての `.age` ファイルが正しい形式か

3. **復号化テスト**
   - `key.txt.age` の復号化（パスワード入力が必要、オプション）
   - すべての `encrypted_*.age` ファイルの復号化
   - 復号化されたデータのサイズ確認

4. **公開鍵の一貫性チェック**
   - `.chezmoi.toml.tmpl` との一致確認
   - すべてのファイルが同じ受信者で暗号化されているか

### 出力例

```bash
================================
Age暗号化検証スクリプト
================================

リポジトリルート: /Users/username/.local/share/chezmoi

=== 前提条件チェック ===
✅ age コマンドが利用可能です
✅ ~/key.txt が存在します

=== Age ファイル形式検証 ===
✅ key.txt.age の形式は正しいです
✅ ./private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age の形式は正しいです

=== 復号化テスト ===
復号化テスト: ./private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age
✅ ./private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age の復号化に成功しました (サイズ: 12345 bytes)

=== 公開鍵の一貫性チェック ===
検出された受信者: age13nd6rta5xqx4prnsggkmsdrcs3dp6ysszncmshyya67r357gua5s0k8gy7
✅ .chezmoi.toml.tmpl と一致します
✅ ./private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age は正しい受信者を使用しています

================================
検証結果サマリー
================================
✅ すべての検証に合格しました！
```

## トラブルシューティング

### GitHub Actions のセキュリティチェックが失敗する

#### ケース1: Age形式エラー

```
❌ ERROR: key.txt.age is not a valid age encrypted file
```

**原因:**
- ファイルが破損している
- 誤って平文ファイルを `.age` 拡張子で保存した

**対処法:**
```bash
# ファイルの先頭を確認
head -n 1 key.txt.age

# 正しい形式であれば以下が表示されるはず:
# age-encryption.org/v1

# 破損している場合は、再暗号化
age -p -o key.txt.age ~/key.txt
```

#### ケース2: 公開鍵の不一致

```
❌ ERROR: Recipient mismatch between key.txt.age and .chezmoi.toml.tmpl
```

**原因:**
- 鍵をローテーションしたが `.chezmoi.toml.tmpl` を更新していない
- 異なる鍵で暗号化されたファイルが混在している

**対処法:**
```bash
# key.txt.age の受信者を確認
grep "-> X25519" key.txt.age | head -n 1 | awk '{print $2}'

# .chezmoi.toml.tmpl を更新
chezmoi edit .chezmoi.toml.tmpl
# recipient の値を上記の受信者に合わせる
```

#### ケース3: git-secrets でシークレット検出

```
❌ ERROR: git-secrets found potential secrets in commit history
```

**原因:**
- パスワードやAPIキーがコミットされている
- 誤検出（正当なコードがパターンにマッチ）

**対処法:**

1. **シークレットが実際に含まれている場合:**
   ```bash
   # 推奨: BFG Repo-Cleaner を使用（最も簡単で安全）
   # https://rtyley.github.io/bfg-repo-cleaner/
   brew install bfg
   bfg --delete-files secret-file.txt
   bfg --replace-text passwords.txt  # パスワードを置換

   # または git-filter-repo を使用（高度な操作が必要な場合）
   # https://github.com/newren/git-filter-repo
   pip install git-filter-repo
   git filter-repo --invert-paths --path path/to/secret/file

   # 注意: git filter-branch は非推奨です。上記のツールを使用してください
   ```

2. **誤検出の場合:**
   - `.gitallowed` ファイルで除外パターンを設定
   - または、該当行を修正してパターンにマッチしないようにする

#### ケース4: 必須ファイルが見つからない

```
❌ ERROR: Required file not found: key.txt.age
```

**原因:**
- ファイルが削除された
- ファイルパスが変更された
- `.gitignore` で除外されている

**対処法:**
```bash
# .gitignore を確認
cat .gitignore

# ファイルが存在するか確認
ls -la key.txt.age

# 存在しない場合は再作成または復元
git checkout main -- key.txt.age
```

### ローカル検証スクリプトのエラー

#### ~/key.txt が見つからない

```
❌ ERROR: ~/key.txt が見つかりません
```

**対処法:**
```bash
# key.txt.age を復号化
cd ~/.local/share/chezmoi
age -d -o ~/key.txt key.txt.age
# 1Passwordからパスワードを入力

# パーミッション設定
chmod 600 ~/key.txt
```

#### 復号化に失敗する

```
❌ ERROR: ./private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age の復号化に失敗しました
```

**原因:**
- `~/key.txt` が正しくない（古い鍵、または破損）
- ファイルが異なる鍵で暗号化されている
- ファイルが破損している

**対処法:**
```bash
# 公開鍵の一貫性を確認
grep "-> X25519" key.txt.age
grep "-> X25519" private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age

# 受信者が異なる場合は、正しい鍵で再暗号化
# 詳細は docs/key-rotation.md を参照
```

## セキュリティベストプラクティス

### DO (推奨)

✅ **定期的にローカル検証スクリプトを実行する**
```bash
# 重要な変更をコミットする前に実行
./scripts/validate-encryption.sh
```

✅ **Pull Request作成前にセキュリティチェックを確認**
```bash
# ローカルでgit-secretsスキャンを実行
git secrets --scan
```

✅ **1Passwordで鍵のパスワードを安全に管理**
- パスワードをコード内にハードコードしない
- 環境変数にも保存しない（履歴に残る可能性）

✅ **~/key.txt のパーミッションを600に保つ**
```bash
chmod 600 ~/key.txt
```

### DON'T (避けるべき)

❌ **~/key.txt をリポジトリにコミットしない**
```bash
# 絶対にコミットしてはいけない
git add ~/key.txt  # ❌
```

❌ **パスワードをGitHub Secretsに保存しない**
- 個人用リポジトリでは1Passwordで十分
- 漏洩リスクを最小化

❌ **暗号化せずに機密ファイルをコミットしない**
```bash
# 機密ファイルは必ず暗号化
age -r age13nd6... -o encrypted_secret.txt.age secret.txt
git add encrypted_secret.txt.age  # ✅
```

❌ **セキュリティチェックの失敗を無視しない**
- エラーが出た場合は必ず原因を調査
- 誤検出であることを確認してから除外設定

## GitHub Actions の設定確認

### ワークフローの状態を確認

```bash
# GitHub CLIでワークフロー実行履歴を確認
gh run list --workflow=security-checks.yml

# 最新の実行詳細を表示
gh run view

# 失敗した実行のログを表示
gh run view <run-id> --log-failed
```

### ワークフローの再実行

```bash
# 失敗したワークフローを再実行
gh run rerun <run-id>

# すべての失敗したジョブを再実行
gh run rerun <run-id> --failed
```

## 参考資料

### 関連ドキュメント

- [key-rotation.md](./key-rotation.md) - 鍵ローテーション手順
- [backup-restore.md](./backup-restore.md) - バックアップと復旧
- [CLAUDE.md](../CLAUDE.md) - リポジトリ全体のガイド

### 外部リンク

- [age - A simple, modern and secure encryption tool](https://github.com/FiloSottile/age)
- [git-secrets - Prevents you from committing secrets](https://github.com/awslabs/git-secrets)
- [chezmoi - Manage your dotfiles across multiple machines](https://www.chezmoi.io/)
- [GitHub Actions - Security hardening](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)

## 変更履歴

- 2025-11-22: 初版作成
