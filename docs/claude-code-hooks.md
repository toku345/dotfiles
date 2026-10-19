# Claude Code Hooks

このリポジトリの検証ループ用 hook スクリプト群と、その配線方法・トラブルシューティングをまとめる。AGENTS.md の "Claude Code Hooks" セクションから移設したリファレンスドキュメント。

## 配置原則

- **runtime の入口**: `.claude/hooks/` と `.codex/hooks/` に置き、Stop の共通処理は `scripts/hooks/verify-on-stop-common.sh` に置く (プロジェクト共有 asset)
- **配線**: `.claude/settings.local.json` (gitignored / machine-local) で行う
- `.claude/settings.json` (プロジェクト共有) には書かない — hook 実行は machine-specific 依存 (bats / shellcheck / fish) を持つため、AGENTS.md の配置原則に従い local 限定とする

各スクリプトは対象ツール (bats / shellcheck / fish) が未インストールの環境では no-op で抜けるため、複数マシンで安全に共有できる。

## 提供されている hooks

### `.claude/hooks/verify-on-stop.sh`

Stop event hook。`git diff HEAD` と untracked を走査し、`tests/bats/`・`dot_local/bin/executable_*`・`.chezmoiscripts/*.sh`・`.claude/hooks/*.sh`・`.codex/hooks/*.sh`・`scripts/hooks/*.sh`・`dot_local/lib/**/*.sh`・`*.fish` のいずれかが変更されている時のみ対応する gate (shellcheck / `fish -n`) を実行する。

- **Bats suite と補助スクリプトは hook 自身が実行しない**: Stop は turn 終了時に自動発火し、通常のツール呼び出しの permission / sandbox を経由しない。検証はエージェントが最終報告前に `bats tests/bats/` を通常コマンドとして実行する。
- **Bats は非ブロッキング通知**: `tests/bats/` の変更 (追跡済み・未追跡・削除を含む) と Bats の存在を検出した場合、通常の終了許可経路で stdout に `systemMessage` だけを持つ JSON を出し、exit 0 で終わる。追加ターンは要求せず、テスト成否も判定しない。条件を満たす Stop ごとに短い通知を表示し、receipt・通知 counter・重複抑制の状態は作らない。Bats 未インストール時は従来の skip 診断のみを出す。
- **実行する検査の挙動は維持する**: ShellCheck / `fish -n` の失敗は exit 2 + stderr で返し、検査 counter `stop-hook-block-count.<repo-key>` で連続 3 回までブロックする。上限時は検査前に counter を削除して自動許可する。counter を保存できない場合は検査失敗を診断に残して fail open とする。これらの経路や Git enumeration 失敗を通知が上書きすることはない。

最終報告には変更内容、検証コマンドと範囲、結果、skip / 未実行の理由、commit / push 状態、残作業を残す。ユーザー向けの Stop 通知は、エージェントに検証を実行させたり、作成済みの最終報告を修正させたりする仕組みではない。hook の exit 0 は Bats 成功を意味しない。

通知形式は [Codex の共通出力仕様](https://learn.chatgpt.com/docs/hooks#common-output-fields) と [Claude Code の JSON 出力仕様](https://code.claude.com/docs/en/hooks#json-output) に従う。自動テストによる JSON / exit code の確認と、各 runtime の実際の通知表示・追加ターンの有無の確認は区別する。

Stop の共通処理は両 runtime の入口から読み込む。Claude は `CLAUDE_PROJECT_DIR` (未設定なら cwd)、Codex は cwd の Git toplevel を project root とする。検査状態はそれぞれ `claude/project-hooks/` と `codex/project-hooks/` に保持する。stdin は読み捨て、通知用の会話解析は行わない。

旧 `stop-hook-bats-reminder-count.<repo-key>` は存在していても読み書き・自動削除しない。移行処理は不要であり、残存ファイルや不正な値が通知や検査に影響することはない。必要な場合だけ下記の手順で旧 reminder ファイルを清掃する。

CI の ShellCheck は `scripts/hooks/lint-shell-all.sh` で全対象を検査し、Stop は変更対象だけを検査する。両方とも shebang のない hook・共通 helper・Bats helper を検査対象とする。Stop は Bats と補助スクリプトを実行しない。共通回帰 assertion は `tests/bats/test_helper_hooks.bash` に置き、両 runtime suite から各入口を通して検証する。

### `.claude/hooks/fish-syntax-check.sh`

PostToolUse `Edit|Write` hook。編集対象が `*.fish` の時だけ `fish -n` を実行し、構文エラー時は `decision: block` JSON を返す。

## 配線方法

`.claude/settings.local.json` に以下を追加 (既存キーは保持):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "PATH=\"/opt/homebrew/opt/bash/bin:/usr/local/opt/bash/bin:/home/linuxbrew/.linuxbrew/opt/bash/bin:$PATH\" \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/verify-on-stop.sh",
            "timeout": 300
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "PATH=\"/opt/homebrew/opt/bash/bin:/usr/local/opt/bash/bin:/home/linuxbrew/.linuxbrew/opt/bash/bin:$PATH\" \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/fish-syntax-check.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

## トラブルシューティング

- **Stop hook の検査 counter を手動リセットする**: repo root で `repo_key=$(printf '%s' "$(pwd -P)" | cksum | awk '{print $1}')` を計算し、Claude は `rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/claude/project-hooks/stop-hook-block-count.$repo_key"`、Codex は同じパスの `claude` を `codex` に置き換えて実行する。Bats 通知のためにこの検査 counter をリセットする必要はない。
- **旧 Bats reminder ファイルを任意清掃する**: 同じ repo key を使い、Claude は `rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/claude/project-hooks/stop-hook-bats-reminder-count.$repo_key"`、Codex は `claude` を `codex` に置き換える。ワイルドカードやディレクトリの再帰削除を使わず、検査側 counter を残す。旧パスがディレクトリなら削除を強行せず、そのまま残してよい。これらの例は `HOME` が絶対パスで、`XDG_STATE_HOME` が未設定または絶対パスの場合。相対 `XDG_STATE_HOME` は hook が無視するため、清掃時も `$HOME/.local/state` を使う。
- **hook が動かない**: Claude Code 起動後 `/hooks` で読み込み状態を確認
- **bats が macOS で pass / Ubuntu CI で fail する**: `bats-docker-parity-runner` subagent を呼び出して Docker Ubuntu 24.04 で再走させる
