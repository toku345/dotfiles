# Claude Code Hooks

このリポジトリの検証ループ用 hook スクリプト群と、その配線方法・トラブルシューティングをまとめる。AGENTS.md の "Claude Code Hooks" セクションから移設したリファレンスドキュメント。

## 配置原則

- **スクリプト本体**: `.claude/hooks/` 配下に置きコミット対象とする (プロジェクト共有 asset)
- **配線**: `.claude/settings.local.json` (gitignored / machine-local) で行う
- `.claude/settings.json` (プロジェクト共有) には書かない — hook 実行は machine-specific 依存 (bats / shellcheck / fish) を持つため、AGENTS.md の配置原則に従い local 限定とする

各スクリプトは対象ツール (bats / shellcheck / fish) が未インストールの環境では no-op で抜けるため、複数マシンで安全に共有できる。

## 提供されている hooks

### `.claude/hooks/verify-on-stop.sh`

Stop event hook。`git diff HEAD` と untracked を走査し、`tests/bats/`・`dot_local/bin/executable_*`・`.chezmoiscripts/*.sh`・`*.fish` のいずれかが変更されている時のみ対応する gate (bats / shellcheck / `fish -n`) を実行する。

- 失敗時は exit 2 + stderr で Claude に feedback を返す
- 連続ブロック上限は 3 回 (`.claude/.stop-hook-block-count`) で、超えたら自動許可しユーザーが復旧できるようにする

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
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/verify-on-stop.sh",
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
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/fish-syntax-check.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

## トラブルシューティング

- **Stop hook で意図せず無限ループに陥った**: `rm .claude/.stop-hook-block-count` で counter をリセット
- **hook が動かない**: Claude Code 起動後 `/hooks` で読み込み状態を確認
- **bats が macOS で pass / Ubuntu CI で fail する**: `bats-docker-parity-runner` subagent を呼び出して Docker Ubuntu 24.04 で再走させる
