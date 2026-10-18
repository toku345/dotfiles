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

- **bats suite は hook 自身が実行しない**: Stop hook は turn 終了時に自動発火し、permission system も Bash tool の sandbox も経由しない。`bats tests/bats/` は検出した `.bats` と、それらが load / source する shell helper を実行するため、auto-approve されがちな `tests/bats/` への write が無確認のコマンド実行に化ける。`tests/bats/` 変更時は「`bats tests/bats/` を通常のコマンドとして (= permission-gated な経路で) 自分で実行せよ」という指示付きで stop をブロックする
  - この reminder は変更が enumeration (`git diff HEAD` + untracked) に載っている間ずっと出る。commit すれば enumeration から外れて止まる。**この出口を stderr のメッセージ側には書いていない** — 「commit すれば黙る」と agent に直接教えると、スイートを実行せずに gate を回避する手段を教えることになるため。人間が trade-off を判断できるこの docs 側にのみ記載する
  - `bats` 未インストール時は reminder を出さずに skip する。実行手段が無い環境で従えない指示を出しても reminder budget を消費するだけで、検証は CI に委ねる方が筋が通るため (`tests/bats/test_hooks.bats` で固定)
- 失敗時は exit 2 + stderr で Claude に feedback を返す
- 連続ブロック上限は 3 回。**counter は 2 系統に分かれている**: 実際に実行される gate (shellcheck / `fish -n`) は `stop-hook-block-count.<repo-key>`、bats reminder は `stop-hook-bats-reminder-count.<repo-key>` (いずれも `${XDG_STATE_HOME:-$HOME/.local/state}/claude/project-hooks/` 配下)。reminder は `tests/bats/` が dirty な間は中身の正否に関わらず毎回発火するため、budget を共有すると本物の shellcheck 失敗が reminder に巻き込まれて早期に自動許可されてしまう
  - **reminder の auto-allow は counter を削除せず 3 のまま残す** (sentinel)。削除すると次の stop で 0 に戻って再武装し、dirty な間ずっと「3 回ブロック → 1 回許可」を繰り返す無限ループになる。エージェント側にこれを解消する手段は無い (hook は tool call を観測できない)。counter は reminder が適用されなくなる箇所 — `tests/bats/` が clean に戻った時と bats 未インストール時 — でのみ削除される。つまり 1 つの dirty エピソードにつき 3 回だけ止め、以降は block と実行指示の再掲を止める。上限到達を示す auto-allow diagnostic はその後も出力する
  - counter を永続化できない場合は、上限のない stop loop を避けるため fail loud + open とする。ただし executing gate の counter を保存できた後に bats reminder counter だけが失敗した場合は、reminder のみ unenforced とし、shellcheck / `fish -n` failure は引き続き block する

Stop の共通処理は両 runtime の入口から読み込む。Claude は `CLAUDE_PROJECT_DIR` (未設定なら cwd)、Codex は cwd の Git toplevel を project root とし、状態はそれぞれ `claude/project-hooks/` と `codex/project-hooks/` に保持する。stdin の読み捨てと exit 2 / stderr の契約も維持する。

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

- **Stop hook で意図せず無限ループに陥った**: repo root で `repo_key=$(printf '%s' "$(pwd -P)" | cksum | awk '{print $1}')` を実行し、`rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/claude/project-hooks/stop-hook-"*".$repo_key"` で counter をリセット (block-count と bats-reminder-count の 2 ファイルが対象)
- **hook が動かない**: Claude Code 起動後 `/hooks` で読み込み状態を確認
- **bats が macOS で pass / Ubuntu CI で fail する**: `bats-docker-parity-runner` subagent を呼び出して Docker Ubuntu 24.04 で再走させる
