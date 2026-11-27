# DeepSeek Harness の Web 設定を別端末で再現する

[共有パッチ](dsh-web.patch.yml)には、標準の `web` プロファイルに対する次の変更だけを置く。DSH `0.2.3-alpha.2` の構成を基準とし、起動時に明示的に読み込む。

| 項目 | 変更内容 |
| --- | --- |
| モデルプロバイダー | `openai-codex` と `ollama-cloud` を追加。モデル一覧や接続先は DSH 内蔵カタログに従う |
| Web 検索 | `ollama-cloud-search` を指定 |
| ページ取得 | `ollama-cloud-fetch` を指定 |

`chatGptSignIn: true` は標準値。Cordis のパッチは `config` 全体を置換するため、標準の動作を維持する目的で明記している。Ollama のキーが未設定なら検索・取得はエラーになり、DSH 標準の経路には戻らない。

## 新しい端末で使う

1. [DSH](https://github.com/deepseek-ai/deepseek-harness) をインストールする。
2. Ollama Cloud の API キーは、端末ごとのシークレット管理から **DSH を起動するプロセスの環境変数 `OLLAMA_CLOUD_API_KEY`** に渡す。モデル・検索・ページ取得で同じキーを使う。パッチには環境変数名だけを置き、値は書かない。
3. dotfiles のチェックアウトからパッチを指定して起動する。

   ```sh
   dsh web --patch "$(chezmoi source-path)/docs/dsh-web.patch.yml"
   ```

4. DSH の **Settings → Models** から `openai-codex`（OpenAI / ChatGPT plan）にその端末でサインインする。モデル選択と Ollama Cloud 経由の Web 検索・ページ取得を確認する。

パッチは起動時に指定した場合だけ有効。chezmoi は既存の DSH プロファイルを上書きしない。パッチを使って起動すると、そのプロファイルの同じ `llm-pi-ai` と `web` の設定より優先される。既存の別プロバイダーも併用する場合は、それらの設定を含む別のパッチを用意する。

API キーの値、OAuth トークン、DSH の認証ストア、Codex のログイン情報、セッション履歴は同期しない。
