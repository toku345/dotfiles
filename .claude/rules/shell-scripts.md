---
paths:
  - "**/*.sh"
  - "dot_local/bin/executable_*"
  - ".chezmoiscripts/**"
---

# Bash Script Gotchas

- **`shopt -s execfail` + `set -Eeuo pipefail` で `||` fallback が dead code**: `set -e` が exec 失敗時に `||` 分岐より先に shell を終了させる。fallback を実働させるには `set +e` / `set -e` で exec を括る (bash 5.3 実機検証済)
- **ShellCheck SC2093 false positive on execfail sites**: execfail 併用時の exec 後続コードは意図通り。該当行に `# shellcheck disable=SC2093` + 理由コメントを添える (file 全体 disable は避ける)
- **外部 wrapper 経由の self-exec で `execve($0)` は git 上 0644 の `executable_*` で rc=126**: `exec "${wrapper[@]}" "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"` と書いて bash interpreter 経由で再入する。mode に依存しない (caffeinate/systemd-inhibit/setsid 等すべて該当)
- **Deploy skew defense**: chezmoi で deploy される asset (output-styles / themes / 辞書 等) に依存する script は、asset 内に sentinel コメント (例: `<!-- COMPONENT_VX -->`) を埋め込み、script 側 preflight で grep verify する。file 存在のみの check は corrupt / truncated / 古い asset を通してしまう。err 文には `chezmoi apply -v` 復旧手順を併記する
- **Bash tool の cwd は call 間で persist し、失敗した `cd` は `set -e` を確実には trip しない**: cd target が書き込み不可 (例: sandbox write-allowlist 外の `$HOME` 配下) で、その後に `for` 等の structured command が続く場合、subsequent file ops は **前の cwd** で実行される。`cd; touch` で test file を作る verification script は post-cd で `pwd` を verify するか、`touch` に絶対パスを使うかして、前 cwd (例: chezmoi source root) への file leak を防ぐ。PR #216 verification 2026-05-19 でこの罠により `.env` / `id_ed25519` / `foo.key` / `control.txt` が `~/.local/share/chezmoi/` に leak した。
