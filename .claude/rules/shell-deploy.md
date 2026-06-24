---
paths:
  - "**/*.fish"
  - "dot_bash*"
---

# Shell config の OS 別 deploy（非対称）

shell config の runtime OS 判定（`config.fish` の `switch (uname)`、[fish-gotchas.md](fish-gotchas.md) 参照）は config **内容**のレイヤー。deploy **時**の取捨は別レイヤーで、`.chezmoiignore` が **Linux で `.config/fish/**` を除外・macOS で `.bashrc`/`.bash_profile` を除外**する。つまり Linux 機の shell 配線 (PATH / `SSH_AUTH_SOCK` 等) は chezmoi 管理の `dot_bashrc` に置く（fish 設定は Linux 非管理）、macOS は fish 側。Linux box で「fish に書く」と deploy されず無効になる罠。
