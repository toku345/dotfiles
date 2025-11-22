#!/bin/bash

# validate-encryption.sh
# ローカル環境での完全な暗号化検証スクリプト
#
# 必要条件:
#   - ~/key.txt が存在すること（age秘密鍵）
#   - age コマンドがインストールされていること

set -euo pipefail

# 色設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# エラーカウンター
ERROR_COUNT=0

# ログ関数
log_info() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ ERROR: $1${NC}"
    ((ERROR_COUNT++))
}

log_warning() {
    echo -e "${YELLOW}⚠️  WARNING: $1${NC}"
}

echo "================================"
echo "Age暗号化検証スクリプト"
echo "================================"
echo ""

# スクリプトのディレクトリに移動
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "リポジトリルート: $REPO_ROOT"
echo ""

# 前提条件チェック
echo "=== 前提条件チェック ==="

# age コマンドの確認
if ! command -v age &> /dev/null; then
    log_error "age コマンドが見つかりません。インストールしてください: brew install age"
    exit 1
fi
log_info "age コマンドが利用可能です"

# ~/key.txt の確認
if [ ! -f "$HOME/key.txt" ]; then
    log_error "~/key.txt が見つかりません"
    echo ""
    echo "以下のコマンドで復号化してください:"
    echo "  cd $REPO_ROOT"
    echo "  age -d -o ~/key.txt key.txt.age"
    echo "  chmod 600 ~/key.txt"
    exit 1
fi
log_info "~/key.txt が存在します"

# ~/key.txt のパーミッションチェック
PERMISSIONS=$(stat -f "%Lp" "$HOME/key.txt" 2>/dev/null || stat -c "%a" "$HOME/key.txt" 2>/dev/null)
if [ "$PERMISSIONS" != "600" ]; then
    log_warning "~/key.txt のパーミッションが 600 ではありません (現在: $PERMISSIONS)"
    echo "  修正するには: chmod 600 ~/key.txt"
fi

echo ""

# Age形式検証
echo "=== Age ファイル形式検証 ==="

if [ ! -f "key.txt.age" ]; then
    log_error "key.txt.age が見つかりません"
else
    if grep -a -m 1 "^age-encryption.org/v1" key.txt.age > /dev/null; then
        log_info "key.txt.age の形式は正しいです"
    else
        log_error "key.txt.age は正しい age 形式ではありません"
    fi
fi

# 全ての暗号化ファイルの形式チェック
while IFS= read -r -d '' file; do
    if grep -a -m 1 "^age-encryption.org/v1" "$file" > /dev/null; then
        log_info "$file の形式は正しいです"
    else
        log_error "$file は正しい age 形式ではありません"
    fi
done < <(find . -path ./.git -prune -o \( -name "encrypted_*.age" -o -name "key.txt.age" \) -type f -print0)

echo ""

# 復号化テスト
echo "=== 復号化テスト ==="

# key.txt.age の復号化テスト（パスワード必要）
echo ""
echo "【注意】key.txt.age の復号化にはパスワードが必要です"
echo "このテストをスキップする場合は Ctrl+C を押してください"
echo "パスワードは 1Password から取得してください"
echo ""
read -p "key.txt.age の復号化テストを実行しますか？ (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    TEMP_KEY=$(mktemp)
    if age -d -o "$TEMP_KEY" key.txt.age; then
        log_info "key.txt.age の復号化に成功しました"

        # 復号化した鍵と ~/key.txt の比較
        if diff -q "$TEMP_KEY" "$HOME/key.txt" &> /dev/null; then
            log_info "復号化した鍵は ~/key.txt と一致します"
        else
            log_warning "復号化した鍵は ~/key.txt と異なります"
        fi

        rm -f "$TEMP_KEY"
    else
        log_error "key.txt.age の復号化に失敗しました"
    fi
    echo ""
fi

# その他の暗号化ファイルの復号化テスト
while IFS= read -r -d '' file; do
    echo "復号化テスト: $file"
    TEMP_OUTPUT=$(mktemp)

    if age -d -i "$HOME/key.txt" -o "$TEMP_OUTPUT" "$file" 2>/dev/null; then
        FILE_SIZE=$(wc -c < "$TEMP_OUTPUT")
        log_info "$file の復号化に成功しました (サイズ: $FILE_SIZE bytes)"
    else
        log_error "$file の復号化に失敗しました"
    fi

    rm -f "$TEMP_OUTPUT"
done < <(find . -path ./.git -prune -o -name "encrypted_*.age" -type f -print0)

echo ""

# 公開鍵の一貫性チェック
echo "=== 公開鍵の一貫性チェック ==="

RECIPIENT=$(grep -a "-> X25519" key.txt.age | head -n 1 | awk '{print $2}')

if [ -z "$RECIPIENT" ]; then
    log_error "key.txt.age から受信者を抽出できませんでした"
else
    echo "検出された受信者: $RECIPIENT"

    # .chezmoi.toml.tmpl との一致確認
    if [ -f ".chezmoi.toml.tmpl" ]; then
        if grep -q "$RECIPIENT" .chezmoi.toml.tmpl; then
            log_info ".chezmoi.toml.tmpl と一致します"
        else
            log_error ".chezmoi.toml.tmpl に同じ受信者が見つかりません"
        fi
    fi

    # 全ての暗号化ファイルの受信者チェック
    while IFS= read -r -d '' file; do
        FILE_RECIPIENT=$(grep -a "-> X25519" "$file" | head -n 1 | awk '{print $2}')
        if [ "$FILE_RECIPIENT" = "$RECIPIENT" ]; then
            log_info "$file は正しい受信者を使用しています"
        else
            log_error "$file は異なる受信者を使用しています: $FILE_RECIPIENT"
        fi
    done < <(find . -path ./.git -prune -o -name "*.age" -not -name "key.txt.age" -type f -print0)
fi

echo ""

# サマリー
echo "================================"
echo "検証結果サマリー"
echo "================================"

if [ $ERROR_COUNT -eq 0 ]; then
    log_info "すべての検証に合格しました！"
    exit 0
else
    log_error "$ERROR_COUNT 件のエラーが見つかりました"
    exit 1
fi
