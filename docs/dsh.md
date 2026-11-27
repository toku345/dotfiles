# DeepSeek Harness の Web 設定を別端末で再現する

[設定例](dsh-web.patch.yml)を端末ごとの `web` プロファイルに初回だけ取り込む。chezmoi は DSH の実設定を管理せず、dotfiles の更新も各端末には自動反映されない。

| 項目 | 変更内容 |
| --- | --- |
| モデルプロバイダー | `openai-codex` と `ollama-cloud` を追加。モデル一覧や接続先は DSH 内蔵カタログに従う |
| Web 検索 | `ollama-cloud-search` を指定 |
| ページ取得 | `ollama-cloud-fetch` を指定 |

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

## 2. プロファイルに初回マージする

対象は `$DSH_HOME/profiles/web/cordis.patch.yml`（`DSH_HOME` を指定しなければ `~/.dsh/profiles/web/cordis.patch.yml`）。フォルダーやファイルがなければ作成し、[設定例](dsh-web.patch.yml)の2項目（`id: llm-pi-ai` と `id: web`）を取り込む。既存ファイルがあれば先に控えを取り、ファイル全体を置き換えない。

- `llm-pi-ai` が既にある場合は、`config.providers` に不足しているプロバイダーだけを追加する。既存の `openai-codex` と `ollama-cloud` の設定、他のプロバイダーやキーは残す。`llm-pi-ai` を新しく追加する場合の `chatGptSignIn: true` は fork の標準値を保つための記載で、既存の値は変更しない。
- `web` が既にある場合は、`config.searchProvider` と `config.fetchProvider` の2つだけを設定例の値に変更する。他のキーや行は残し、同じ `id` の行を重複させない。

DSH の設定レイヤーは、同じ `id` の `config` をキー単位でマージせず、後から読むレイヤーの値で丸ごと置き換える。`$DSH_HOME` 直下に共通の `cordis.patch.yml` があり、同じ行を設定している場合、共通パッチがプロファイルより優先される。共通パッチはこの手順では変更しない。

fork のチェックアウトで `pnpm dsh web --dump-config` を実行し、有効な `llm-pi-ai` に `openai-codex` と `ollama-cloud` があり、`web` が `ollama-cloud-search` と `ollama-cloud-fetch` を選んでいることを確認する。期待と違う場合は、起動前に共通パッチの同じ行を確認する。既存の設定値を含む出力なので、結果をそのまま公開しない。

## 3. 起動して端末ごとに認証する

以後は fork のチェックアウト内で起動する。`--patch` は不要。

```sh
pnpm dsh web
```

- **Settings → Models** で `openai-codex`（OpenAI / ChatGPT plan）にサインインする。
- Ollama Cloud のモデル設定で API キーをローカル認証ストアに保存する。検索・取得は `OLLAMA_CLOUD_API_KEY` という認証参照を固定で使う。既存のモデル設定が別の `apiKeyEnv` を指定している場合は、その参照を黙って変更せず、端末側のシークレット管理から起動環境に `OLLAMA_CLOUD_API_KEY` を別途渡す。設定に書くのは参照名だけで、キー本体は書かない。
- モデルを選べること、Web 検索とページ取得がそれぞれ Ollama Cloud 経由で動くことを確認する。`OLLAMA_CLOUD_API_KEY` が解決できなければ検索・取得は失敗し、標準経路には戻らない。

API キー、OAuth トークン、DSH の認証ストア、Codex のログイン情報、セッション履歴、端末固有の設定は同期しない。
