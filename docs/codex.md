# Codex 設定の管理方針

このリポジトリでは `~/.codex` を丸ごと管理しない。

設計判断 (3-file 構成 / hash gate / migration fail-closed) の詳細は [ADR 0024](adr/0024-codex-baseline-hash-state.md) を参照。

## 管理するもの

- `private_dot_codex/AGENTS.md` -> `~/.codex/AGENTS.md`
- `private_dot_codex/private_config.chezmoi.toml` -> `~/.codex/config.chezmoi.toml`
- `private_dot_codex/private_review.config.toml` -> `~/.codex/review.config.toml`
- `private_dot_codex/private_review_deep.config.toml` -> `~/.codex/review_deep.config.toml`
- `private_dot_codex/private_review_audit.config.toml` -> `~/.codex/review_audit.config.toml`
- `private_dot_codex/private_quick.config.toml` -> `~/.codex/quick.config.toml`
- `private_dot_codex/private_work.config.toml` -> `~/.codex/work.config.toml`
- `private_dot_codex/rules/managed.rules` -> `~/.codex/rules/managed.rules`
- `.chezmoiscripts/run_after_check-codex-config.sh`
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
- `~/.codex/.baseline-hash` (chezmoi script が生成する hash state)

## 運用

1. `chezmoi apply` で `~/.codex/config.chezmoi.toml` を配置する
2. `~/.codex/config.toml` が存在しない場合だけ、script が baseline をコピーして初期化する
3. 以後 `~/.codex/config.toml` は live file として残し、Codex が書いた local-only section を保持する
4. baseline を更新したら、`chezmoi apply` が baseline の hash 変化を検出して exit 1 で停止する。`diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml` で baseline 更新分を確認し、local-only section を保ったまま live に取り込む。merge 後、新 baseline を ACK するため `hash=$(sha256sum ~/.codex/config.chezmoi.toml 2>/dev/null || shasum -a 256 ~/.codex/config.chezmoi.toml) && printf '%s\n' "${hash%% *}" > ~/.codex/.baseline-hash && chmod 600 ~/.codex/.baseline-hash` を実行し、再 `chezmoi apply` する。無関係な dotfile を急ぎ apply したい場合は `chezmoi apply <target>` で個別指定すればこの script は trigger されない

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

長い対話で制約や設計判断の理由を保持しやすくするため、以下を baseline に含める。複数端末で継続利用を試す設定として管理する。

```toml
[features.context_management]
experimental_mode = true
```

対応条件（2026-09-12 確認）:

- [公式モデル説明](https://learn.chatgpt.com/docs/models#experimental-context-management) の対象は Astra。同じタスク内のメモと履歴検索を利用する機能で、別セッションへの自動引き継ぎは前提にしない。他モデルでの対応は未確認。
- [公式設定リファレンス](https://learn.chatgpt.com/docs/config-file/config-reference) では既定はオフで、ChatGPT Plus / Pro / Pro Lite のサインインが必要。モデル説明は Plus / Pro のみを挙げ、開始時点の Business / Enterprise / API キー認証を対象外としている。Pro Lite は資料間に記載差があり、実機での有効性は未検証。
- [公式 changelog](https://learn.chatgpt.com/docs/changelog) の CLI 0.154.0 に activation 追加の記載があり、このバージョンを確認対象とする。対応クライアント全体の一覧と最低バージョンは未確認。

利用開始: main への merge 後、[運用](#運用)のマージ・ACK 手順で live に反映し、ChatGPT サインインした CLI で `codex --model gpt-6-astra` を実行して新規タスクを開始する。

新規タスク開始時に設定読み込みエラーがないことを確認する。エラーがないだけでは当該設定の受理や機能動作を確認したことにはせず、確認できなかった部分は未検証として記録する。

無効化: live の同じキーを `false` にして新規タスクを開始する（[公式設定手順](https://learn.chatgpt.com/docs/config-file/config-basic)）。端末単位の無効化では baseline の ACK 更新は不要。全端末向けに取り消す場合は baseline も `false` に変更し、通常の運用手順で反映する。

## agmsg writable roots

agmsg installer は Codex bridge / monitor beta 用に、`~/.codex/config.toml`
の `[sandbox_workspace_write].writable_roots` へ以下の絶対パスを追加する:

- `~/.agents/skills/agmsg/db`
- `~/.agents/skills/agmsg/teams`
- `~/.agents/skills/agmsg/run`

この repo では Codex monitor beta を通常運用の対象外とし、Codex delivery
mode は `off` で使うが、agmsg runtime state の書き込み先として同じ
3ディレクトリを許可する。これらは
`~/.codex/config.chezmoi.toml` ではなく installer-managed local entry として
live config に保持する。baseline 更新時は他の local-only section と同様に残す。

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

この section は `~/.codex/config.chezmoi.toml` ではなく installer-managed local entry として live config に保持する。baseline 更新時は他の local-only section と同様に残す。

managed install は `${CARGO_INSTALL_ROOT:-${CARGO_HOME:-$HOME/.cargo}}/bin/cc-session-finder` (CARGO_INSTALL_ROOT → CARGO_HOME → `~/.cargo` の順で解決) を優先する。通常の `chezmoi apply` は既存 binary の revision を判定せず、`CC_SESSION_FINDER_REINSTALL=1 chezmoi apply -v` のときだけ pinned revision を managed path へ強制再インストールする。`CC_SESSION_FINDER_REF` の reviewed bump 手順は [docs/claude-code-plugins.md の定期更新チェックリスト](claude-code-plugins.md#定期更新チェックリスト) を参照。

## rules

`~/.codex/rules/default.rules` は Codex の承認 UI が書き換えるため chezmoi 管理しない。安全側の上書きが必要なものだけ `~/.codex/rules/managed.rules` で管理する。Codex は複数 rule を merge し最も制限的な decision を採用するため、`default.rules` に広い `allow` が追加されても `managed.rules` の `prompt` で外部副作用や履歴作成を再確認できる。この most-restrictive-wins は Codex CLI 0.142.0 で確認済み（`requirements.toml` に `allow` を書くと "Codex merges these rules with other config and uses the most restrictive result (use 'prompt' or 'forbidden')" で拒否される）。再検証は `strings (command -v codex) | grep 'most restrictive result'`。

現在 `managed.rules` では以下を prompt に戻す。

- `gh api graphql`: query と mutation を prefix rule だけでは区別できないため
- `git add`: secret や無関係ファイルの staging を避けるため
- `git commit`: 履歴作成と commit trailer の確認を挟むため（prefix match のため `-m` / `-F` / `--amend` / editor 形を一律 prompt。ただし `git -C <path> commit` のように subcommand 前に flag が入る形は prefix 不一致で対象外）

## status line

Codex CLI の TUI footer は baseline で最小限の常時表示にする。

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

`used-tokens` は長時間セッションの診断には有用だが、常時表示ではノイズになりやすいため baseline には入れない。必要な時は `/status` または `/statusline` で確認する。

## review profile

managed baseline と `$pr-review` 用 profile は `gpt-5.6-sol` を使う。通常作業の `cx` は上記の Astra profile を選ぶ。レビュー用途では、直接 chezmoi 管理する独立 profile で reasoning effort だけを切り替える。

- `review.config.toml`: `gpt-5.6-sol` / `medium`
- `review_deep.config.toml`: `gpt-5.6-sol` / `high`
- `review_audit.config.toml`: `gpt-5.6-sol` / `xhigh`

これらの profile は `multi_agent` を有効にし、現在の model metadata が選ぶ V2 runtime で動作する。`approval_policy = "on-request"`、`sandbox_mode = "workspace-write"`、`sandbox_workspace_write.network_access = false`、`features.network_proxy = true` は managed baseline から継承し、review profile 側では上書きしない。`~/.codex/config.toml` の local-only section は持たず、`~/.codex/<profile>.config.toml` として直接管理するため、profile の更新は `config.chezmoi.toml` の hash gate 対象ではない。通常 session の baseline と `run_after_check-codex-config.sh` による live config 保護は従来どおり維持する。static verifier は checked-in の継承構造を固定し、Codex CLI が実際に layer した値は isolated smoke の turn context で確認する。

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

`model_reasoning_effort = "xhigh"` は監査には有用だが、通常の反復レビューでは過剰になりやすい。通常 session の baseline は `high` とし、review用途では profile を明示的に切り替える。

- `review`: 通常レビュー・dogfood iteration 用
- `review_deep`: 複雑な PR や main pre-merge review 用
- `review_audit`: security / release / cutover audit 用

`xhigh` の出力は自動修正キューではなく triage input として扱う。反復修正ループは通常 `medium` か `high` で 1-2 周に抑える。

## commit attribution

Codex CLI 0.131 系で `codex_git_commit` feature flag と `commit_attribution` config は削除された。baseline ではこれらの削除済み config は使わず、個人 preference として `~/.codex/AGENTS.md` に実行時の model ID を含む Co-authored-by trailer 指示を置く。

## 通知

macOS の desktop notification は今後の検討事項。`notify = [...]` は helper の存在や OS 差分に依存するため、baseline へ固定値として入れる前に template / opt-in / availability check の方針を決める。
