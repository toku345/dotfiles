# Age鍵ローテーション手順

## 概要

このドキュメントでは、age暗号化鍵のローテーション（鍵の更新）に関する方針と手順を説明します。

## 鍵ローテーションポリシー

### 基本方針: 定期的な鍵ローテーションは不要

このdotfilesリポジトリでは、**定期的な鍵ローテーション（例: 90日ごと）は不要**としています。

**理由:**
- 個人用途の設定ファイル管理であり、企業の機密情報ではない
- 鍵は二重に保護されている（age秘密鍵自体がパスワードで暗号化）
- パスワードは1Passwordで安全に管理
- 復号化された秘密鍵(`~/key.txt`)はローカルマシンのみに存在
- ローテーションのコストと利便性のバランスを考慮

### 鍵ローテーションが必要なケース

以下のような**緊急事態**が発生した場合にのみ鍵ローテーションを実施してください:

1. **鍵の漏洩が疑われる場合**
   - マシンが紛失・盗難された
   - マルウェア感染の疑いがある
   - 誤って `~/key.txt` をpublicな場所（GitHub、クラウドストレージなど）にアップロードした
   - 誤って `key.txt.age` のパスワードを漏らした

2. **1Passwordアカウントの侵害**
   - 1Passwordのマスターパスワードが漏洩した可能性がある
   - 1Passwordアカウントへの不正アクセスが検出された

3. **リポジトリの用途変更**
   - 個人用から複数人での共有リポジトリに変更する場合
   - より機密性の高いデータ（業務データなど）を扱うようになった場合

4. **暗号化アルゴリズムの脆弱性発見**
   - ageまたはX25519に重大な脆弱性が発見された場合（現時点では報告なし）

## 緊急時の鍵ローテーション手順

### 前提条件

以下のツールがインストールされていることを確認してください:

```bash
# age のインストール
brew install age

# chezmoi のインストール（既にインストール済みのはず）
brew install chezmoi
```

### ステップ1: 新しい鍵ペアの生成

```bash
# 新しい鍵ペアを生成
age-keygen -o ~/key-new.txt

# 出力例:
# Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**重要:** 表示された公開鍵（`age1...`）をメモしてください。

### ステップ2: 新しい公開鍵の設定

`.chezmoi.toml.tmpl` を編集して、新しい公開鍵に更新します:

```bash
cd ~/.local/share/chezmoi
chezmoi edit .chezmoi.toml.tmpl
```

`recipient` の値を新しい公開鍵に変更:

```toml
[age]
    identity = "~/key.txt"
    recipient = "age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"  # 新しい公開鍵
```

### ステップ3: すべての暗号化ファイルの再暗号化

#### 3.1 既存ファイルの復号化と再暗号化

```bash
cd ~/.local/share/chezmoi

# key.txt.age を再暗号化（新しい鍵自体をパスワードで保護）
age -d -o ~/key-temp.txt key.txt.age  # 既存のパスワードで復号化
cp ~/key-new.txt ~/key-temp.txt       # 新しい鍵の内容をコピー
age -p -o key.txt.age ~/key-temp.txt  # 新しいパスワードで暗号化
rm ~/key-temp.txt                      # 一時ファイルを削除

# 新しいパスワードを1Passwordに保存
# 項目名: "dotfiles age key password"
```

#### 3.2 その他の暗号化ファイルの再暗号化

```bash
# Google IME辞書の再暗号化例
ENCRYPTED_FILE="private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age"

# 古い鍵で復号化
age -d -i ~/key.txt -o /tmp/decrypted.txt "$ENCRYPTED_FILE"

# 新しい鍵で再暗号化
NEW_RECIPIENT=$(grep "public key:" ~/key-new.txt | awk '{print $3}')
age -r "$NEW_RECIPIENT" -o "$ENCRYPTED_FILE" /tmp/decrypted.txt

# 一時ファイルを安全に削除
shred -u /tmp/decrypted.txt  # Linux
# または
rm -P /tmp/decrypted.txt     # macOS
```

**全暗号化ファイルの一覧:**
```bash
# すべての .age ファイルを確認
find ~/.local/share/chezmoi -name "*.age"
```

### ステップ4: 検証

新しい鍵で正しく暗号化・復号化できることを確認します:

```bash
# 新しい鍵を配置
mv ~/key.txt ~/key-old.txt           # 古い鍵をバックアップ
mv ~/key-new.txt ~/key.txt           # 新しい鍵を配置
chmod 600 ~/key.txt

# 検証スクリプトを実行
cd ~/.local/share/chezmoi
./scripts/validate-encryption.sh
```

すべてのチェックが通過することを確認してください。

### ステップ5: 変更のコミットとプッシュ

```bash
cd ~/.local/share/chezmoi

# 変更を確認
chezmoi diff

# gitで変更を確認
git status
git diff

# コミット
git add .chezmoi.toml.tmpl key.txt.age private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age
git commit -m "security: rotate age encryption keys

- Generate new age key pair
- Re-encrypt all sensitive files with new key
- Update recipient in .chezmoi.toml.tmpl

Reason: [鍵ローテーションの理由を記載]"

# プッシュ
git push origin main
```

### ステップ6: 他のマシンでの更新

他のマシンを使用している場合、それらでも鍵を更新します:

```bash
# リポジトリを更新
cd ~/.local/share/chezmoi
chezmoi update

# 古い鍵をバックアップ
mv ~/key.txt ~/key-old.txt

# 新しい key.txt.age を復号化（新しいパスワードを使用）
age -d -o ~/key.txt key.txt.age
chmod 600 ~/key.txt

# 検証
chezmoi diff
chezmoi apply -v
```

### ステップ7: 古い鍵の安全な削除

すべてのマシンで新しい鍵が正常に動作することを確認したら、古い鍵を削除します:

```bash
# 古い鍵を安全に削除
shred -u ~/key-old.txt  # Linux
# または
rm -P ~/key-old.txt     # macOS
```

## ロールバック手順

鍵ローテーション後に問題が発生した場合のロールバック手順です。

### 前提条件

- 古い鍵 (`~/key-old.txt`) がまだ削除されていないこと
- Gitの履歴が残っていること

### ロールバック手順

```bash
cd ~/.local/share/chezmoi

# 変更を取り消し
git revert HEAD
# または、コミット前であれば
git reset --hard HEAD^

# リポジトリを前の状態に戻す
git push origin main

# 古い鍵を復元
mv ~/key.txt ~/key-new.txt    # 新しい鍵を保持（念のため）
mv ~/key-old.txt ~/key.txt
chmod 600 ~/key.txt

# 検証
./scripts/validate-encryption.sh

# 他のマシンも同様に更新
chezmoi update
```

## テストとチェックリスト

鍵ローテーション実施時のチェックリストです。

### 実施前チェックリスト

- [ ] バックアップが最新であることを確認
- [ ] 1Passwordのマスターパスワードを確認できる
- [ ] すべての暗号化ファイルをリストアップ済み
- [ ] 他のマシンのリスト作成済み
- [ ] ロールバック手順を理解している

### 実施中チェックリスト

- [ ] 新しい鍵ペアを生成
- [ ] 新しい公開鍵をメモ
- [ ] `.chezmoi.toml.tmpl` を更新
- [ ] `key.txt.age` を再暗号化（新しいパスワード）
- [ ] 新しいパスワードを1Passwordに保存
- [ ] すべての `encrypted_*.age` ファイルを再暗号化
- [ ] 検証スクリプト実行（合格）
- [ ] 変更をコミット・プッシュ

### 実施後チェックリスト

- [ ] GitHub Actionsのセキュリティチェック合格
- [ ] 他のマシンで鍵更新完了
- [ ] すべてのマシンで `chezmoi apply` 成功
- [ ] 古い鍵を安全に削除
- [ ] インシデントログに記録（任意）

## トラブルシューティング

### Q: 復号化に失敗する

**症状:** `age -d` コマンドでエラーが発生する

**原因と対処:**
1. パスワードが間違っている → 1Passwordで確認
2. 鍵ファイルが破損している → Gitから復元
3. 間違った鍵を使用している → `~/key.txt` の内容を確認

### Q: chezmoi apply が失敗する

**症状:** `chezmoi apply` でエラーが発生

**対処:**
```bash
# 詳細ログで確認
chezmoi apply -v

# 鍵の設定を確認
chezmoi data | grep age

# 手動で復号化テスト
age -d -i ~/key.txt -o /tmp/test.txt private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age
```

### Q: 古い鍵を削除してしまった

**対処:**
1. Gitの履歴から復元できる場合:
   ```bash
   git log --all -- key.txt.age
   git show <commit-hash>:key.txt.age > key.txt.age.old
   ```

2. 他のマシンにまだ古い鍵がある場合:
   ```bash
   # 他のマシンから
   scp ~/key.txt user@newmachine:~/key-recovered.txt
   ```

3. どうしても復元できない場合:
   - 新しい鍵ペアを生成して、すべてのファイルを再暗号化
   - バックアップから復号化済みファイルを復元

## 参考資料

- [age公式ドキュメント](https://github.com/FiloSottile/age)
- [chezmoi暗号化ガイド](https://www.chezmoi.io/user-guide/encryption/)
- [backup-restore.md](./backup-restore.md) - バックアップと復旧手順
- [security-ci-cd.md](./security-ci-cd.md) - CI/CDセキュリティチェック

## 変更履歴

- 2025-11-22: 初版作成
