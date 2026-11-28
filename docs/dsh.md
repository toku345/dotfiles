# 新しい端末で DeepSeek Harness の Web 設定を再現する

**この手順は、存在しないか空の DSH ホーム専用。** 旧設定の移行や既存設定へのマージは対象外。すでにデータがあれば、上書きせずに中断する。新規状態から始め直す場合も、既存のホームは削除せず、必要に応じて手順の外で退避する。chezmoi は DSH の実設定を管理せず、dotfiles の更新も各端末には自動反映されない。

| 項目 | 設定 |
| --- | --- |
| モデルプロバイダー | `openai-codex` と `ollama-cloud`。モデル一覧や接続先は DSH 内蔵カタログに従う |
| Web 検索 | `ollama-cloud-search` |
| ページ取得 | `ollama-cloud-fetch` |

## 1. 対応する fork をビルドする

確認対象は [時雨堂 fork の `910e68d8c1`](https://github.com/shiguredo/deepseek-harness/tree/910e68d8c187f445d6f42d365a578b3bf336d0ed)（DSH `0.2.3-alpha.2`）。同じバージョン番号の[公式版](https://github.com/deepseek-ai/deepseek-harness/tree/4b399c39a6d1479cd84ca591b4d7c88e24d38a96)には Ollama Cloud の検索・取得プロバイダーが登録されていないため、この手順では使わない。

Node.js・pnpm などは [fork の前提条件](https://github.com/shiguredo/deepseek-harness/blob/910e68d8c187f445d6f42d365a578b3bf336d0ed/docs/development.md#prerequisites)に従う。

```sh
git clone https://github.com/shiguredo/deepseek-harness.git
cd deepseek-harness
git switch --detach 910e68d8c187f445d6f42d365a578b3bf336d0ed
pnpm install
pnpm run build
```

## 2. 初回起動前に設定例を配置する

既定の DSH ホームは `~/.dsh`。カスタムホームを使う場合は、親ディレクトリが存在する絶対パス（末尾の `/` や `.`・`..` の要素を含めない）を環境変数 `DSH_HOME` に `export` し、**配置・確認・以後の起動で同じ値**を使う。

下の例は POSIX 互換シェルで実行し、引数を dotfiles チェックアウト内の[設定例](dsh-web.patch.yml)の絶対パスに置き換える。ホーム全体を確認し、旧 `settings.yaml`、共通パッチ、隠しファイルなどが一つでもあれば、何も書き込まずに中断する。シンボリックリンクのホームも対象外。

```sh
sh -s -- '/path/to/dotfiles/docs/dsh-web.patch.yml' <<'SH'
set -euC
umask 077
dsh_home=${DSH_HOME:-"$HOME/.dsh"}
case "$dsh_home/" in
    *//*|*/./*|*/../*) printf '不正な DSH ホーム: %s\n' "$dsh_home" >&2; exit 1 ;;
    /*) ;;
    *) printf 'DSH ホームは絶対パスで指定してください: %s\n' "$dsh_home" >&2; exit 1 ;;
esac
if [ -L "$dsh_home" ] || { [ -e "$dsh_home" ] && ! [ -d "$dsh_home" ]; }; then
    printf '通常のディレクトリではありません: %s\n' "$dsh_home" >&2
    exit 1
fi
if [ -d "$dsh_home" ]; then
    [ -r "$dsh_home" ] && [ -x "$dsh_home" ] || exit 1
    for entry in "$dsh_home"/* "$dsh_home"/.[!.]* "$dsh_home"/..?*; do
        if [ -e "$entry" ] || [ -L "$entry" ]; then
            printf 'DSH ホームが空ではありません。何も変更していません: %s\n' "$dsh_home" >&2
            exit 1
        fi
    done
fi
[ -f "$1" ] && [ -r "$1" ] || { printf '設定例を読めません: %s\n' "$1" >&2; exit 1; }
[ -d "$dsh_home" ] || mkdir "$dsh_home"
mkdir "$dsh_home/profiles"
mkdir "$dsh_home/profiles/web"
cat "$1" > "$dsh_home/profiles/web/cordis.patch.yml"
SH
```

fork のチェックアウトで `pnpm dsh web --dump-config` を実行し、`llm-pi-ai` の両モデルプロバイダーと `web` の検索・取得 ID が表のとおりか確認する。違っていれば起動せず、配置先と `DSH_HOME` を確認する。`chatGptSignIn: true` は[この fork の標準値](https://github.com/shiguredo/deepseek-harness/blob/910e68d8c187f445d6f42d365a578b3bf336d0ed/packages/bundle/base/cordis.patch.yml#L139-L147)を維持するために記載している。

## 3. 起動して端末ごとに認証する

以後は fork のチェックアウト内で起動する。`--patch` は不要。

```sh
pnpm dsh web
```

- **Settings → Models** で `openai-codex`（OpenAI / ChatGPT plan）にサインインする。
- 同じ画面の Ollama Cloud モデル設定で API キーを保存する。キーは端末の認証ストアに保存され、`OLLAMA_CLOUD_API_KEY` の参照をモデル・検索・取得で共有する。UI で保存する場合、環境変数の設定は不要。キーを設定しなければ検索・取得は失敗し、標準の経路には戻らない。
- モデルを選べること、Web 検索とページ取得がそれぞれ Ollama Cloud 経由で動くことを確認する。

API キー、OAuth トークン、DSH の認証ストア、Codex のログイン情報、セッション履歴、端末固有の設定は同期しない。
