# Codex 設定の管理方針

このリポジトリでは `~/.codex` を丸ごと管理しない。

設計判断 (per-key pin/seed/free と `modify_` script) の詳細は [ADR 0037](adr/0037-codex-config-per-key-policy.md) を参照。ADR 0024 の 3-file 構成と hash gate は ADR 0037 が置き換えた。

## Fugu と通常版 CLI の分離

`codex` は Homebrew の通常版（Apple Silicon Mac は `/opt/homebrew/bin/codex`）と `~/.codex` を使う。`codex-fugu` は Bash 5+ の管理ラッパーから、`~/.codex-fugu/bin/codex-fugu`（Fugu 公式ランチャー）と `~/.codex-fugu/bin/codex`（bundle 指定版）を起動する。専用の bin をシェル全体の PATH に追加しない。

管理対象は `~/.local/bin/codex-fugu` と、opt-in したマシンの `~/.codex-fugu/config.toml`（per-key ポリシー）だけ。専用 HOME 内の実行ファイル、キー、Memory、Session、`fugu.config.toml`（公式インストーラーが丸ごと上書きする bundle profile）は chezmoi 非管理とする。公式インストーラーは専用 bin のランチャーを更新するため、管理ラッパーを上書きしない。専用実行ファイルがない場合は停止し、PATH 上の CLI へフォールバックしない。

ラッパーの子プロセスだけに以下を固定する。親シェル、通常版 CLI、Codex アプリの環境は変更しない。

```bash
export CODEX_HOME="$HOME/.codex-fugu"
export CODEX_INSTALL_DIR="$CODEX_HOME/bin"
export CODEX_FUGU_REAL_CODEX="$CODEX_INSTALL_DIR/codex"
export CODEX_SQLITE_HOME="$CODEX_HOME"
export FUGU_ENV_FILE="$CODEX_HOME/.env"
export CODEX_BACKUP_ROOT="$CODEX_HOME/backups"
unset SAKANA_API_KEY
```

API キーは専用 `.env` を使用する。ラッパーは継承キーを除去するだけで `.env` を source せず、読み込みは Codex に任せる。キーの値を引数・ログ・Git に残さない。キー変更には `codex-fugu --set-key` を使う。

専用 CLI の存在確認後、ラッパーの子プロセス内だけ `CODEX_INSTALL_DIR` を PATH の先頭に置く。公式 Codex installer は非対話実行でも shell profile を編集するため、更新時に自身の専用 CLI を最初に見つけさせ、PATH 追記と Homebrew 競合処理を回避する。親シェルの `codex` の解決順は変わらない。

### 初回セットアップ

以下は **Bash 5 の端末**で実施する。Fish からは先に `bash` に入る。開発中は一時 destination の実行可能ファイルを `chezmoi add` して管理元に登録し、既存の live ランチャーを置き換えない。worktree の変更は main に取り込んでから apply する。

1. 通常版のコマンド解決・バージョン、Fugu clone の変更・commit・`configs/bundle.sh` の `BUNDLE_CODEX_VERSION` を再確認する。既存の `~/.codex` の設定・認証は保持する。
2. `~/.codex-fugu` を `0700` で作成する。既に存在する場合は新規環境とみなさず内容と設定の保存先を確認する。既存 `~/.local/bin/codex-fugu` を専用 HOME 内の日時付きバックアップへコピーする。移動やアンインストールはしない。
3. 上記の環境変数をセットした **subshell 内**で以後のインストールを行う。`FUGU_PINNED_VERSION`、`CODEX_RELEASE`、`FUGU_CONFIGS_DIR`、`CODEX_INSTALLER_CMD` の意図しない上書きを除去する。初回は `FUGU_ASSUME_YES=0 FUGU_FORCE=0 FUGU_DRY_RUN=0 FUGU_SKIP_BACKUP=0` とする。
4. 専用 CLI がない場合は、`https://github.com/openai/codex/releases/download/rust-v<VERSION>/install.sh` を一時ファイルへ取得し、内容を確認して `PATH="$CODEX_INSTALL_DIR:/usr/bin:/bin:/usr/sbin:/sbin" CODEX_NON_INTERACTIVE=1 /bin/sh <installer> --release <VERSION>` で導入する。初回は Homebrew CLI を競合検出させず shell profile の編集を防ぐため、この PATH を使う。必要なシステムコマンドがなければ停止する。`<VERSION>` は bundle 指定版。取得失敗時に別バージョンへ進まない。専用 CLI の `--version` が指定版と一致することを確認する。PATH 上に同じ版があるだけでは専用 CLI の導入を省略しない（Fugu installer が早期終了する場合がある）。
5. 専用 CLI の導入後、同じ subshell で `export PATH="$CODEX_INSTALL_DIR:$PATH"` を設定し、 `<fugu-repo>/scripts/install.sh --reconfigure` を Bash 5 で実行し、キーを非表示入力する。通常版の `.env`、`auth.json`、設定、Memory、Session をコピーしない。既存の専用 CLI の版が異なる場合は公式 installer の切り替え確認に従い、完了後に版の一致を再確認する。

### 入口を切り替える前の検証

未適用の `dot_local/bin/executable_codex-fugu` を Bash 5 の絶対パスで実行する（source ファイルは実行可能 mode とは限らない）。専用公式ランチャーを環境指定なしで直接起動すると通常版 HOME を使うため、必ず管理ラッパーを経由する。

- `--status` で専用 HOME、専用 bin、実体、bundle 指定版、repo/branch を確認する。status 成功だけでは設定や認証の正常性を証明しない。
- 専用設定・profile 内に通常版を指す `sqlite_home` や catalog 参照がないこと、専用 `.env` が `0600` であることを確認する。キーの内容は表示しない。
- `--no-update exec --sandbox read-only --skip-git-repo-check 'Reply with FUGU_ISOLATION_OK only. Do not use tools.'` をラッパーに渡し、実際の API 応答と専用 HOME 内の新規 Session を確認する。失敗時は入口を切り替えない。この確認には Sakana API の利用が発生する。

成功後、main の source から **対象を限定**して適用する。

```bash
chezmoi diff "$HOME/.local/bin/codex-fugu"
chezmoi apply --dry-run "$HOME/.local/bin/codex-fugu"
chezmoi apply -v "$HOME/.local/bin/codex-fugu"
codex-fugu --status
```

Mac Fish / Linux Bash で `codex` が通常版、`codex-fugu` が管理ラッパーに解決されることを確認する。通常版設定が変わっていないことも確認する。失敗時はバックアップした旧ランチャーと管理元の変更を戻す。これは従来の共有環境への復帰であり、専用 HOME は調査用に残す。

### base config の管理（マシン単位の opt-in）

分離した Fugu home で Codex が読む base layer は `~/.codex-fugu/config.toml` だけ（`fugu.config.toml` は公式インストーラーが上書きする bundle profile）。この base layer を chezmoi の `modify_` target として管理する。マージは通常版と同じ `scripts/codex-config/merge.py` を使い、`--policy policy-fugu.toml` で Fugu 用ポリシーを選ぶ。

- 宣言する値は `scripts/codex-config/policy-fugu.toml` に置く。現在は `plan_mode_reasoning_effort = "xhigh"` の **pin** のみ。Fugu モデルの catalog は `high` / `xhigh`（`fugu-ultra-v1.1` は `max`）しか宣言せず、CLI の Plan mode 既定 `medium` は Sakana API が拒否する。pin なので live に別の値が保存されていても `apply` ごとに戻す。
- 前提は通常版と同じ `sh scripts/codex-config/setup.sh`（[初回準備・依存更新](#初回準備依存更新)）。venv がない場合、Fugu 側の target も適用前に停止する。
- 有効化はマシン単位の opt-in。`chezmoi init` を実行し、`codexFugu` のプロンプトに `yes` と答える。既存の `[data]` は再利用され、他のキーは再質問されない。`.chezmoi.toml.tmpl` が変わると chezmoi は `run chezmoi init to regenerate config file` と警告し続けるため、data への手動追記だけで済ませず `chezmoi init` で config file を再生成する。非対話で有効化する場合は `[data]` に `codexFugu = true` を先に追記してから `chezmoi init` を実行する（`promptBoolOnce` は TTY を要求し、`--promptBool` では埋まらない）。無効のマシンでは `.chezmoiignore` が Fugu source 一式を除外するため `~/.codex-fugu` を作らない。**`~/.codex-fugu` を持つマシンでのみ有効化する**。有効にすると専用 HOME がまだ無い machine でも skeleton を作るため、Fugu を使わない machine では無効のままにする。
- 反映は main への merge 後: `chezmoi diff ~/.codex-fugu/config.toml` で確認し、`chezmoi apply ~/.codex-fugu/config.toml` を実行する。installer のマーカーブロック、Codex が書く `[projects.*]` / `[hooks.state]`、未知キーは保持される。
- 収束確認: `chezmoi status ~/.codex-fugu/config.toml` が空。pin は最初のテーブルより前の top-level に置かれる。
- 実機確認: `codex-fugu` の新規セッションで Plan mode を 1 往復し、`grep -o '"mode":"plan".\{0,120\}' ~/.codex-fugu/sessions/**/rollout-*.jsonl` が `"reasoning_effort":"xhigh"` を示すことを確認する。bundle 更新で `fugu.config.toml` が plan effort を宣言した場合は profile 層が優先されるため、更新後に再確認する。

### 更新と Memory の扱い

通常起動の公式更新機能は維持する。更新や `--set-key` の子プロセスにも専用環境が渡るため、公式の配置・環境変数の契約が変わらない限り、Fugu や対応 CLI の更新でラッパー編集・chezmoi 再適用は不要。検証時だけ `--no-update` を使う。clone にローカル変更がある場合は更新による破棄を承認せず、先に変更を保護する。

標準の生成 Memory は `CODEX_HOME/memories` に保存されるため、リポジトリに関する記憶も分離対象。リポジトリ内の `AGENTS.md` や文書は引き続き共有する。これは保存先の分離であり、Fugu で Memory の生成・利用が正常に動作することは別途検証する。Memory をこの作業で有効化したり既存状態を移行したりしない。[公式 Memory 説明](https://learn.chatgpt.com/docs/customization/memories) / [環境変数](https://learn.chatgpt.com/docs/config-file/environment-variables)。

fast/service tier は [#366](https://github.com/toku345/dotfiles/issues/366)、auto-review は [#367](https://github.com/toku345/dotfiles/issues/367) で扱う。通常版 HOME に残る Fugu 設定の整理も分離成功後の別作業。旧アンインストーラーは記録済みの `~/.local/bin/codex-fugu` を削除する場合があるため、そのまま実行しない。新旧 CLI の交互利用で Memory が破損すると確認されたわけではなく、分離は未確認の互換性への依存を避けるために行う。

## 管理するもの

- `private_dot_codex/AGENTS.md` -> `~/.codex/AGENTS.md`
- `private_dot_codex/modify_private_config.toml` -> `~/.codex/config.toml` の per-key 更新（chezmoi の `modify_` target）
- `private_dot_codex/private_review.config.toml` -> `~/.codex/review.config.toml`
- `private_dot_codex/private_review_deep.config.toml` -> `~/.codex/review_deep.config.toml`
- `private_dot_codex/private_review_audit.config.toml` -> `~/.codex/review_audit.config.toml`
- `private_dot_codex/private_quick.config.toml` -> `~/.codex/quick.config.toml`
- `private_dot_codex/private_work.config.toml` -> `~/.codex/work.config.toml`
- `private_dot_codex/rules/managed.rules` -> `~/.codex/rules/managed.rules`
- `.chezmoiscripts/run_after_setup-agmsg.sh`
- `.chezmoiscripts/run_after_setup-cc-session-finder-mcp.sh`

## 管理しないもの

- `~/.codex/auth.json`
- `~/.codex/history.jsonl`
- `~/.codex/sessions/`
- `~/.codex/state_*.sqlite`
- `~/.codex/logs_*.sqlite*`
- `~/.codex/cache/`
- `~/.codex/rules/default.rules` (Codex UI が更新する user-local allow rules)
- `~/.codex/config.toml` の `free` キー: `plugins` / `mcp_servers` / `projects` / `notice` / `hooks.state` / `notify` / `service_tier` / `sandbox_workspace_write.writable_roots`

## 運用

`~/.codex/config.toml` は chezmoi の `modify_` target として管理する。`private_dot_codex/modify_private_config.toml` は stdin の live TOML を、同じ source checkout 内の Python 更新処理へ渡す。結果の検証が成功した場合だけ chezmoi が書き戻す。

### 初回準備・依存更新

Homebrew で uv を用意し、初回の `status` / `diff` / `apply` **より前**に source directory で次を実行する（例は POSIX shell / Bash）。asdf の Python プラグインや Python のビルド依存は不要。

```sh
sh scripts/codex-config/setup.sh
```

setup は `scripts/codex-config/.python-version` の系列（現在は 3.14）を使う。初回だけ uv が Python を取得し、`${XDG_DATA_HOME:-$HOME/.local/share}/codex-config-policy/python` に配置する。専用 venv は同じ親ディレクトリの `venv` に置く。グローバルの PATH、asdf の選択、他用途の Python は変更しない。別プロジェクトの `.python-version` や activate 済み venv にも依存しない。

通常の再実行は既存 venv の Python を再利用し、`uv sync --locked --no-python-downloads` で依存だけを同期する。Python のパッチ版を自動更新せず、正常な venv を退避・再作成しない。依存更新が失敗したら、原因を解消して同じ setup を再実行する。この経路では依存の自動ロールバックは行わない。

TOML Kit は `pyproject.toml` と `uv.lock` で管理する。Dependabot の `uv` ecosystem による更新 PR を確認・取り込んだ後も、同じ setup を実行する。通常更新の cooldown は7日間で、セキュリティ更新は対象外。uv 本体は [Homebrew 更新手順](homebrew-update.md) で更新する。取得可能な Python の版は uv に組み込まれているため、新しいパッチを取得するには uv の更新が必要な場合がある。

通常の `status` / `diff` / `apply` は専用 venv を直接使い、uv の呼び出し・通信・依存導入はしない。環境がない、または TOML Kit の版が lock と異なる場合は停止して setup を案内する。

### GitHub plugin の初回導入

plugin は端末ごとの local-only 設定として管理する。このリポジトリの policy は GitHub plugin を新規環境で自動的に有効化しない。既存の `plugins` 設定は、有効・無効の選択を含めて保持する。

GitHub plugin を使う場合は、Codex CLI を起動して `/plugins` を開き、GitHub を選択してインストールする。表示される接続・認証手順を完了し、新しいセッションを開始して利用する。詳細は [公式の plugin 導入手順](https://learn.chatgpt.com/docs/plugins#install-and-use-a-plugin) を参照する。

### Python の更新・既存環境からの移行

Python の最新パッチへの更新、外部 Python を使う旧 venv からの移行、壊れた venv の再作成には次を使う。

```sh
sh scripts/codex-config/setup.sh --upgrade-python
```

uv は宣言された系列内の最新パッチを専用ディレクトリに取得する。選択した interpreter が変わる、または既存 venv の Python が起動不能な場合だけ、旧 venv を `venv.backup` に退避して元の配置先で再作成する。Python が同じで venv も正常なら依存同期だけを行う。通常の setup は、外部 Python・異なる系列・起動不能を検出しても黙って切り替えず、この更新コマンドを案内する。

新しい Python の取得・起動確認は退避前に行う。再作成後の interpreter・依存・設定更新処理の検証が成功したら退避 venv を削除する。再作成・検証の失敗や捕捉可能な中断では旧 venv を元の場所へ戻し、非ゼロ終了する。Python 本体の旧版は自動削除しない。

復元するのは旧 venv の内容であり、ソースの lock が変更済みの場合や旧環境が元から壊れていた場合に、modifier の動作まで復旧するとは限らない。setup と `chezmoi status/diff/apply` は並行実行しない。

CI・互換性検証では `sh scripts/codex-config/setup.sh /absolute/path/to/python` も使える。この経路は Python 3.11 以上を受け付け、Python を取得しない。既存 venv と interpreter が異なる場合は停止するため、別の XDG ディレクトリで検証する。`--upgrade-python` との併用はできない。

### 強制終了後の復旧

setup 同士の二重実行は `setup.lock` ディレクトリで拒否する。強制終了で残ったロック・退避データは自動削除しない。

1. setup が動いていないことを確認する。
2. エラーに表示された専用ディレクトリの `venv` と `venv.backup` を確認する。退避があれば、作成途中の `venv` を別名へ移して保護し、`venv.backup` を元の `venv` へ戻す。退避した位置では venv を実行しない。
3. 復元が済んだら空の `setup.lock` を `rmdir` で除去し、setup を再実行する。旧環境が壊れている、または移行が必要なら `--upgrade-python` を付ける。

復元自体に失敗した場合も両方のパスとロックを残す。内容を確認する前に削除しない。

### 設定の変更

- 編集先は `scripts/codex-config/policy.toml`（通常版 `~/.codex/config.toml`）。分離した Fugu home 用は `scripts/codex-config/policy-fugu.toml`（前述の「base config の管理」）。`[pin]` / `[pin.features]` 等は毎回再適用する値、`[seed]` は未設定時だけ投入する初期値。宣言されていないすべてのキーは free。
- seed の現在値が宣言と異なる場合は保持し、stderr にキー名だけ警告する。宣言値が現在値とは限らない。
- main への merge 後、`chezmoi diff ~/.codex/config.toml` で確認し、`chezmoi apply ~/.codex/config.toml` で反映する。hash gate・ACK・手動 merge は不要。
- 旧 baseline / hash state が残る場合は、内容を確認して `rm -f ~/.codex/config.chezmoi.toml ~/.codex/.baseline-hash` で削除する。

TOML Kit で構文を解析し、値と型で比較する。出力前に再解析し、pin の値、既存 seed と全 free キーの保持、installer のマーカーブロック不変性を確認する。構文不正・ポリシー衝突・構造衝突は非ゼロ終了し、stdout に部分的な設定を出さない。変更不要なら入力をそのまま返す。未設定の root キーはファイル先頭に追加し、installer が所有するブロックの内側へは入れない。コメントと配列の書式は保持するが、TOML Kit が一部の array-of-tables の配置を正規化するため、変更時のファイル全体のバイト一致は保証しない。

### 隔離した検証

実端末の venv を更新しないよう、一時ディレクトリで依存を準備する。

```sh
policy_test_root=$(mktemp -d)
export UV_CACHE_DIR="$policy_test_root/cache"
XDG_DATA_HOME="$policy_test_root/data" sh scripts/codex-config/setup.sh
export CODEX_CONFIG_TEST_PYTHON="$policy_test_root/data/codex-config-policy/venv/bin/python"
"$CODEX_CONFIG_TEST_PYTHON" -B tests/codex/test_config_policy.py
"$CODEX_CONFIG_TEST_PYTHON" -B tests/codex/test_config_setup.py
bats tests/bats/test_codex_config_policy.bats
bats tests/bats/test_codex_fugu_config_policy.bats
```

Python テストには `chezmoi` が必要。Bats は依存未準備を skip せず失敗として扱う。テスト内の HOME・XDG・chezmoi source/destination/state はすべて一時領域を使う。

## local-only とする section

- `[projects."..."]`
- `[mcp_servers.*]`
- `[notice.*]`
- `[plugins.*]`
- `[marketplaces.*]`
- `[desktop]`

必要に応じて、ローカル provider や一時的な実験設定も `~/.codex/config.toml` 側にのみ置く。

## ターミナルの起動入口: cx / cf

`dot_local/bin/executable_cx` / `executable_cf` を `~/.local/bin/cx` / `cf` に配置する。既存の fish / Bash の PATH を使い、shell ごとの function は追加しない。

| 入口 | 選び方 | 通常モード |
| --- | --- | --- |
| `cx quick` | 方針・範囲・検証方法が明確で、やり直しやすい作業 | `gpt-6-astra` / `low` |
| `cx work` | 不確実な作業、迷う場合 | `gpt-6-astra` / `high` |
| `cf` | Fugu を使う作業 | installer / user が管理する既存 Fugu profile |

quick は変更行数の少なさや Fast モードを意味しない。通常側の Fast・承認・UI は共通設定を継承し、Plan は共通の `plan_mode_reasoning_effort = "xhigh"` を使う。profile 選択は Plan への切替ではない。`deep`、自動選択、自動昇格、独自の選択メニューは提供しない。

```bash
cx quick '確認済みの方針で修正して'
cx work 'Issue を確認して'
cx work resume <known-openai-session-id>
cf 'Issue を確認して'
cf resume <known-sakana-session-id>
cx --help
cf --help
```

対応対象は対話起動・初期プロンプト・同じ provider の既知のセッションIDによる resume。元の起動先が分かるIDを Codex の終了表示などから控えて使う。picker / `--last` は未検証で、provider が同じとは仮定しない。provider 間の履歴移行や自動引き継ぎは行わない。

### 設定レイヤーと対応範囲

通常側の profile は `model` / `model_reasoning_effort` の2キーだけを持つ。独立環境ではなく、同じ CODEX_HOME の共通設定・認証・履歴を利用する。既存 review profile と同じ直接管理方式なので、baseline の hash gate 対象ではない。

関係する優先順位は共通設定 → 選択 profile → trusted project config → CLI override。`cx` は profile を選ぶだけで、project の model / effort や明示的な Codex 引数による上書きを防がない。管理者の requirements は別途適用される。[公式 profile 仕様](https://learn.chatgpt.com/docs/config-file/config-advanced)

`cf` は `codex-fugu --no-update -- ...` を実行する。Fugu の model / provider / effort / catalog は既存 profile に任せ、追加の profile を合成しない。次の値だけをプロセス限定で指定する。

- `check_for_update_on_startup=false`: Codex 本体の更新確認も抑止。
- `features.fast_mode=false`: `fast` / `priority` を実効 tier から除く。任意の tier 全部を解除する設定ではない。
- `approvals_reviewer="user"` / `approval_policy="on-request"`: 必要時に人間へ承認を求める。

sandbox / network 制約は上書きしない。承認依頼を有効にしても、管理者ポリシー等で禁止された操作が許可されるとは限らない。

Fugu と矛盾する model / effort / catalog / tier を project config に指定した環境、別 profile / provider、互換設定への明示的な上書き（`--approve-for-me` を含む）はサポート対象外。project config は Fugu profile より優先されるため、例えば Astra / low の project 設定は `cf` でも継承され得る。ラッパーは独自の設定解析・競合検出をしない。任意のサブコマンドへの完全対応も提供しない。

`CODEX_HOME` を明示した場合はその配置を尊重するが、profile を自動コピーしない。通常の chezmoi 配置先は `~/.codex`。

### Fugu のバージョン警告と更新

`cf` は同じランチャーの読み取り専用 `--status` で installed version / deployed_target を比較する。探索処理は複製せず、status や state を shell として source しない。一致時は無表示、不一致時は毎回 stderr に英語で警告して継続する。

```text
cf: warning: Codex is 0.155.0; the installed Fugu configuration targets 0.154.0.
Compatibility is unverified. Continuing without checking for updates.
Run codex-fugu directly to review the mismatch and update options.
```

status 失敗・形式変更・不明なバージョンは確認不能の警告になる。一致は互換性保証、不一致は非互換の断定とは扱わない。profile または `.fugu/state` 不在はセットアップエラーで停止する。実機ランチャーでは `--no-update` 判定前に adoption が走るため、状態不在のまま起動しない。

更新・キー管理は `cf` へ透過させない。まず `codex-fugu --status` で確認し、更新を確認すると決めたときにターミナルで `codex-fugu --check`、再設定時は公式 installer を直接使う。提示されるバージョン変更・設定再配置の内容を確認して選択する。更新後は status と下記の手動確認を再実施する。[公式 Fugu ランチャー](https://github.com/SakanaAI/fugu)

### 導入・検証・ロールバック

main への反映後、対象4ファイルだけを確認して配置する。導入前に利用する shell で `type -a cx cf` を実行し、既存 function / alias / command と衝突しないことを確認する。以下は手動の導入コマンドで、実装・テストからは実行しない。

```bash
chezmoi diff ~/.codex/quick.config.toml ~/.codex/work.config.toml ~/.local/bin/cx ~/.local/bin/cf
chezmoi apply --dry-run ~/.codex/quick.config.toml ~/.codex/work.config.toml ~/.local/bin/cx ~/.local/bin/cf
chezmoi apply -v ~/.codex/quick.config.toml ~/.codex/work.config.toml ~/.local/bin/cx ~/.local/bin/cf
```

baseline / live config の上書き・ACK や CLI の更新は不要。Fugu は公式セットアップ済みであることを前提とする。

自動テストは `bats tests/bats/test_codex_launchers.bats`。公式ランチャーを事前に読み取り確認した環境では、次で一時 HOME と偽 Codex を使う接続テストも実行できる。実機認証・モデル・更新処理は使わない。

```bash
CODEX_FUGU_TEST_LAUNCHER="$(command -v codex-fugu)" bats tests/bats/test_codex_launchers.bats
```

接続テストは `CODEX_FUGU_ASSUME_TTY=1` で非対話時の自動スキップを避け、`--no-update` なしなら repository check に到達する負の対照も持つ。偽コマンドの成功は、実 CLI の実効設定やモデル動作の証明ではない。

手動確認（モデル呼び出しを行う場合は利用枠を消費する）:

1. Ghostty 上の fish / Bash で `cx quick` と `cx work` を起動し、model / effort、Fast、承認、Plan の xhigh を確認する。初期プロンプト、日本語・引用符、Ctrl-C、終了コードも確認する。
2. `cf` で警告、Fugu model / effort、Fast 抑止、人間への承認依頼、sandbox / network 制約の維持を確認する。更新チェックが発生しないことは表示の不在だけでなく、実効設定・診断でも確認する。
3. provider が分かる既知のIDで再開し、quick → work の high と、Fugu の承認・tier override の再適用を確認する。競合する project 設定がある場合は通常側の優先順位と Fugu の対象外条件を照合する。

2026-09-18 の検証範囲: Codex CLI 0.155.0、Fugu launcher revision `0e04afcc10d8fb7f82cdbe903b83666dc0fe51ec` / 配置済み target 0.154.0。ラッパーの引数・警告・終了コード・更新抑止は偽コマンドで検証する。実 CLI の診断は隔離 HOME の `debug prompt-input` で行い、profile / project / CLI の読み込み順と人間承認用の指示を確認する。モデル・effort・tier の全実効値、Ghostty / fish、承認画面、モデル接続、resume は未検証。resume は引数転送のみの確認であり、対応を検証済み・完了とは扱わない。

ロールバックは、追加した2つの profile と2つのラッパーについて、source 側の管理定義と上記4つの配置先を除去する。配置先だけの削除では次の apply で復活する。`config.toml`、Fugu installer 管理ファイル、認証・履歴は削除しない。従来の `codex` / `codex-fugu` を直接使う。

### 途中で難しくなった場合

同じ失敗の反復、未確認の前提の増加、変更範囲の拡大を手動切替の判断材料にする。同一 provider 内では作業を止めてセッションIDを控え、work での resume 後に effort を確認する。provider を変える場合は新規セッションにする。目的・制約・確認済み事実・差分・テスト結果・未解決点を引き継ぎ、仮説を確認済み事実として扱わない。

## 実験的コンテキスト管理

長い対話で制約や設計判断の理由を保持しやすくするため、以下を `pin` に含める。複数端末で継続利用を試す設定として管理する。

```toml
[features.context_management]
experimental_mode = true
```

対応条件（2026-09-12 確認）:

- [公式モデル説明](https://learn.chatgpt.com/docs/models#experimental-context-management) の対象は Astra。同じタスク内のメモと履歴検索を利用する機能で、別セッションへの自動引き継ぎは前提にしない。他モデルでの対応は未確認。
- [公式設定リファレンス](https://learn.chatgpt.com/docs/config-file/config-reference) では既定はオフで、ChatGPT Plus / Pro / Pro Lite のサインインが必要。モデル説明は Plus / Pro のみを挙げ、開始時点の Business / Enterprise / API キー認証を対象外としている。Pro Lite は資料間に記載差があり、実機での有効性は未検証。
- [公式 changelog](https://learn.chatgpt.com/docs/changelog) の CLI 0.154.0 に activation 追加の記載があり、このバージョンを確認対象とする。対応クライアント全体の一覧と最低バージョンは未確認。

利用開始: main への merge 後、[運用](#運用)の準備・diff・apply 手順で live に反映し、ChatGPT サインインした CLI で `codex --model gpt-6-astra` を実行して新規タスクを開始する。

新規タスク開始時に設定読み込みエラーがないことを確認する。エラーがないだけでは当該設定の受理や機能動作を確認したことにはせず、確認できなかった部分は未検証として記録する。

無効化: live の同じキーを `false` にして新規タスクを開始する（[公式設定手順](https://learn.chatgpt.com/docs/config-file/config-basic)）。これは一時的な無効化で、次回 `chezmoi apply` で pin の `true` に戻る。全端末向けに取り消す場合は `pin` の値を `false` に変更し、`chezmoi apply` で反映する。

## agmsg writable roots

agmsg installer は Codex bridge / monitor beta 用に、`~/.codex/config.toml`
の `[sandbox_workspace_write].writable_roots` へ以下の絶対パスを追加する:

- `~/.agents/skills/agmsg/db`
- `~/.agents/skills/agmsg/teams`
- `~/.agents/skills/agmsg/run`

この repo では Codex monitor beta を通常運用の対象外とし、Codex delivery
mode は `off` で使うが、agmsg runtime state の書き込み先として同じ
3ディレクトリを許可する。これらは
`free` キーとして扱い、installer-managed local entry のまま live config に保持する。ポリシー変更時も残る。

`.chezmoiscripts/run_after_setup-agmsg.sh` は install/update 前後の
`~/.codex/config.toml` diff を確認し、この3ディレクトリの writable roots 追加
以外の変更が入った場合は fail loud する。

## cc-session-finder MCP

`.chezmoiscripts/run_after_setup-cc-session-finder-mcp.sh` は `cc-session-finder` を pinned revision で install し、Claude Code と Codex の両方に user-local MCP server として登録する。Codex 側は `~/.codex/config.toml` の `[mcp_servers.cc-session-finder]` に以下を保持する:

```toml
[mcp_servers.cc-session-finder]
command = "/absolute/path/to/cc-session-finder"
args = ["mcp"]
```

この section は `free` キーとして installer-managed local entry のまま live config に保持する。ポリシー変更時も残る。

managed install は `${CARGO_INSTALL_ROOT:-${CARGO_HOME:-$HOME/.cargo}}/bin/cc-session-finder` (CARGO_INSTALL_ROOT → CARGO_HOME → `~/.cargo` の順で解決) を優先する。通常の `chezmoi apply` は既存 binary の revision を判定せず、`CC_SESSION_FINDER_REINSTALL=1 chezmoi apply -v` のときだけ pinned revision を managed path へ強制再インストールする。`CC_SESSION_FINDER_REF` の reviewed bump 手順は [docs/claude-code-plugins.md の定期更新チェックリスト](claude-code-plugins.md#定期更新チェックリスト) を参照。

## rules

`~/.codex/rules/default.rules` は Codex の承認 UI が書き換えるため chezmoi 管理しない。安全側の上書きが必要なものだけ `~/.codex/rules/managed.rules` で管理する。Codex は複数 rule を merge し最も制限的な decision を採用するため、`default.rules` に広い `allow` が追加されても `managed.rules` の `prompt` で外部副作用や履歴作成を再確認できる。この most-restrictive-wins は Codex CLI 0.142.0 で確認済み（`requirements.toml` に `allow` を書くと "Codex merges these rules with other config and uses the most restrictive result (use 'prompt' or 'forbidden')" で拒否される）。再検証は `strings (command -v codex) | grep 'most restrictive result'`。

現在 `managed.rules` では以下を prompt に戻す。

- `gh api graphql`: query と mutation を prefix rule だけでは区別できないため
- `git add`: secret や無関係ファイルの staging を避けるため
- `git commit`: 履歴作成と commit trailer の確認を挟むため（prefix match のため `-m` / `-F` / `--amend` / editor 形を一律 prompt。ただし `git -C <path> commit` のように subcommand 前に flag が入る形は prefix 不一致で対象外）

## status line

Codex CLI の TUI footer は `pin` で最小限の常時表示にする。

- `model-with-reasoning`
- `current-dir`
- `git-branch`
- `context-remaining`
- `five-hour-limit`
- `codex-version`
- `pull-request-number`
- `branch-changes`
- `run-state`
- `task-progress`

status line の項目ごとの色表示は `status_line_use_colors = true` で有効にする。

`used-tokens` は長時間セッションの診断には有用だが、常時表示ではノイズになりやすいため `pin` には入れない。必要な時は `/status` または `/statusline` で確認する。

## review profile

managed baseline と `$pr-review` 用 profile は `gpt-5.6-sol` を使う。通常作業の `cx` は上記の Astra profile を選ぶ。レビュー用途では、直接 chezmoi 管理する独立 profile で reasoning effort だけを切り替える。

- `review.config.toml`: `gpt-5.6-sol` / `medium`
- `review_deep.config.toml`: `gpt-5.6-sol` / `high`
- `review_audit.config.toml`: `gpt-5.6-sol` / `xhigh`

これらの profile は `multi_agent` を有効にし、現在の model metadata が選ぶ V2 runtime で動作する。`approval_policy = "on-request"`、`sandbox_mode = "workspace-write"`、`sandbox_workspace_write.network_access = false`、`features.network_proxy = true` は `~/.codex/config.toml` の `pin` から継承し、review profile 側では上書きしない。`~/.codex/config.toml` の local-only section は持たず、`~/.codex/<profile>.config.toml` として直接管理するため、profile の更新は pin/seed ポリシーの対象ではない。通常 session のポリシーは `scripts/codex-config/policy.toml` が管理する。static verifier は checked-in の継承構造を固定し、Codex CLI が実際に layer した値は isolated smoke の turn context で確認する。

multi-agent version は session 開始時に固定されるため、既存 session 内で model や profile を切り替えず、新しい Codex process として起動する。`$pr-review` は実際に公開された tool schema を検査し、V1/V2 のどちらにも対応する。

V2 scheduler は canonical `FINAL_ANSWER` に加え、明示的な `completed` または qualified retirement lifecycle evidence を要求する。qualified retirement は、成功した full-tree snapshot から canonical task が消え、かつ事前に running を観測済み、またはその canonical sender の有効 FINAL を記録済みの場合だけ成立する。退役が FINAL より先行した場合は60秒以内に FINAL が届かなければ fail-closed とし、running と有効 FINAL のどちらもない task の消失・error/interrupted・conflicting FINAL は許容しない。

レビューは Stage 1 の specialist 群、条件付き Stage 2 `code-simplifier`、Stage 3 `finding-verifier` の順に進む。Stage 3 は正規化済み Critical/Important 候補を1件ずつ同じ immutable scope と packet hash で検証し、`confirmed` / `refuted` / `needs-verification` のいずれかを返す。新しい finding の探索や severity の再分類は行わない。期待した candidate ID が欠落・重複した場合や結果 JSON が契約不一致の場合は partial aggregation せず fail-closed する。`confirmed` / `refuted` の citation は verdict 適用前に同梱 validator が immutable `HEAD_REF` の Git tree/blob へ照合し、path 不在・非通常ファイル・binary・行範囲外を fail-closed にする。current worktree は証拠境界に使わない。

```bash
codex exec --profile review -C <repo> '$pr-review --base <base>'
```

base を省略した auto-PR 経路では、`gh pr view` と fresh fetch をまず通常 sandbox で試す。sandbox/network policy や保護された `.git/FETCH_HEAD` に拒否された場合だけ、同一 command を approval 付きの scoped escalation で1回再試行する。profile 全体の network access や sandbox 権限は広げず、通常の Git/auth/ref error は昇格しない。offline または approval なしで実行する場合は immutable commit OID を `--base` に指定する。

checked-in の legacy V1 profile は置かない。V2 runtime に互換性問題が再発した場合は、次の one-shot command で `gpt-5.5` / V1 に退避する。

```bash
codex \
  -c 'features.multi_agent=true' \
  -c 'features.multi_agent_v2=false' \
  -c 'model_reasoning_effort="medium"' \
  exec --model gpt-5.5 \
  -C '<repo-root>' \
  '$pr-review --base <base>'
```

runtime smoke は credentials と server-side model catalog に依存するため CI ではなく手動で行う。merge 前は isolated `CODEX_HOME` と `/tmp` の fixture を使い、live config や chezmoi target を変更しない。`chezmoi apply` は変更を main に merge した後だけ実行する。

`model_reasoning_effort = "xhigh"` は監査には有用だが、通常の反復レビューでは過剰になりやすい。このリポジトリの初回設定値は `medium` で、seed のため既存の値は保持する。review 用途では profile を明示的に切り替える。

- `review`: 通常レビュー・dogfood iteration 用
- `review_deep`: 複雑な PR や main pre-merge review 用
- `review_audit`: security / release / cutover audit 用

`xhigh` の出力は自動修正キューではなく triage input として扱う。反復修正ループは通常 `medium` か `high` で 1-2 周に抑える。

## commit attribution

Codex CLI 0.131 系で `codex_git_commit` feature flag と `commit_attribution` config は削除された。ポリシー表ではこれらの削除済み config は扱わず、個人 preference として `~/.codex/AGENTS.md` に実行時の model ID を含む Co-authored-by trailer 指示を置く。

## 通知

macOS の desktop notification は今後の検討事項。`notify = [...]` は helper の存在や OS 差分に依存するため、`pin` として固定する前に template / opt-in / availability check の方針を決める。
