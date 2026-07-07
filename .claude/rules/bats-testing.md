---
paths:
  - "tests/bats/**"
---

# Bats Testing (tests/bats/)

- **`executable_*` は git で mode 0644** (chezmoi apply 時に 0755): PATH 経由で直接実行するテストは `ln -sf` ではなく exec wrapper (`exec bash "$SRC" "$@"`) を使う
- **Source-guard パターン**: `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi` を末尾に置くと bats で `source` して関数単体テスト可能
- **`run bash -c "source '$SRC'; func args"` 形式**: スクリプトの `set -Eeuo pipefail` を bats 本体に漏らさない
- **`run --separate-stderr`**: stderr 単独アサーションに使用。bats 1.5+ (`bats_require_minimum_version 1.5.0` 宣言必須)
- **async プロセステスト**: 固定 `sleep` より polling ループ (`for ((i=0; i<30; i++)); do cond && break; sleep 0.1; done`) が CI (Ubuntu runner) で flakiness を回避
- **PATH-override スタブ内の `command date` は PATH を再参照**: スタブ自身を再帰呼び出して fork 爆発する。`/bin/date` 等の絶対パスを使う
- **macOS ローカル pass の落とし穴**: `~/.local/bin/*` にある chezmoi apply 済みスクリプトが PATH shadow でテスト stub を隠蔽しバグを温存する。Docker Ubuntu で cross-check する
- **OS-specific path の skip パターン**: `[[ "$(uname)" == "Linux" ]] || skip "<production-code-path reason>"`。reason は production gating を引用する (例: "gated by `case Linux)` in `select_sleep_inhibitor_cmd`")。「環境に X が無いから」ではなく「production もそこを通らないから」と書くことで coverage claim の正直さを保つ
- **BW01 警告 + exit 127** in `run` 出力 = `command not found`。診断: PATH-override stub が subshell に伝わっていない、または被テスト関数が呼ぶ transitive dep (例: `timeout`) が host に不在で stub 対象外
- **silent-pass トラップ**: `[ "$status" -ne 0 ]` は real failure (timeout 124, signal 128+N) と command-not-found (127) を**両方とも満たす**。timeout-bounded / signal-bounded 検証では `-eq 124` 等の具体的 exit code を使う (`-ne 0` ではなく) — host に dep が無い時に偽陽 pass しないようにする
- **fixture content-presence check**: `## Section` heading 存在の grep だけだと、heading はあるが body が空の fixture が silently pass する。section ごとに `awk '$0==sec {f=1; next} f && /^## / {f=0} f {print}' file` で切り出し → `grep -qE '^[[:space:]]*-[[:space:]]+\S'` で少なくとも 1 bullet 存在を別 case で gate する (実例: `tests/bats/test_brainstorming_skill.bats`)

## Docker での Ubuntu CI parity 検証

push 前に CI (ubuntu-latest + `apt-get install bats fish`) と同等環境で実走:

```bash
docker run --rm -v "$(pwd):/work" -w /work ubuntu:24.04 bash -c '
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    bats git procps fish jq shellcheck sqlite3 >/dev/null
  bats tests/bats/
'
```

`fish jq shellcheck sqlite3` は省略不可: GitHub Actions の Bats job は `bats fish` を apt で入れ、`ubuntu-latest` runner 側の `jq` / `shellcheck` / `sqlite3` に暗黙依存している。素の `ubuntu:24.04` コンテナで欠けると hook 系テストが silent skip して parity gap を隠す (2026-06-11 実測)。`sqlite3` 欠落の症状は skip ではなく別物: `run_after_setup-agmsg.sh` の `require_command sqlite3` が exit 1 し、`test_agmsg_setup.bats` の installer 系 2 ケースが「`[ "$status" -eq 1 ]` は偶然 pass、message assertion だけ fail」になる (2026-07-07 実測。ubuntu-latest runner と macOS は preinstalled のため実 CI では顕在化しない)。新しい Bats テストが実行時依存を増やした場合は、この recipe と `private_dot_claude/agents/bats-docker-parity-runner.md` の baseline の両方を更新すること。
