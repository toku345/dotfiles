---
paths:
  - "**/*.fish"
  - "private_dot_config/fish/**"
---

# Fish Shell Gotchas

- `test -n (command substitution)` with empty output becomes `test -n` (no args), which returns **true** in fish. Always capture into a variable first: `set -l val (cmd); test -n "$val"`
- `$pipestatus` is available after command substitution (`set x (a | b)` still exposes `$pipestatus[1..N]`). Branch on individual pipe stages instead of a single `$status` to avoid misclassifying left-side failures as right-side cancellations.
- `ls` is an embedded fish function that adds `--color=auto`/`-F`. In pipelines whose consumer needs raw filenames (e.g. fzf input), use `command ls -1 --` to bypass the function and any future user override (eza/lsd/icon wrappers).
- `return ""` (empty arg from an unset variable) fails with `invalid integer` and exits 2. Guard with `test -n "$v"; and return $v; or return 1`.
- fzf exit codes: `0`=selection, `1`=no match, `2`=error, `126`/`127`=become-action errors, `130`=Ctrl-C/Esc. Treat `1` and `130` as user cancel; everything else fail-loud.
- `fish -c` subprocesses source `config.fish` by default. If the parent prepended a dir to `PATH`, `fish_add_path` inside `config.fish` may reorder via `fish_user_paths` and push the new dir behind system binaries. Use `fish --no-config -c` whenever a test stub or PATH-override must win in the child.
- `set -l out (cmd)` splits multi-line stdout into a fish list, one element per line. Passing a bare `$out` as an argument then expands to that many positional args. Capture with `| string collect` (trims trailing newlines, preserves internal ones) or explicitly join before passing.
- In `set -l x (cmd | string collect)`, `$status` reflects `string collect`'s exit (1 if no input, 0 otherwise), not `cmd`'s. Use `$pipestatus[1]` immediately on the next line before any other command resets it.
- `fish_add_path` (フラグなし) は **prepend** で BSD `date`/`sed`/`cp` 等を GNU 版で shadow する罠あり。gap-fill だけ欲しい場合は `-a` (append) を使う。例: macOS で GNU `timeout` が必要な場合 `fish_add_path -a /opt/homebrew/opt/coreutils/libexec/gnubin` (`brew install coreutils` 後でも unprefixed binary は PATH 未登録、`brew link coreutils` も g-prefix 版のみ生成)。`fish_user_paths` universal var の更新は新規 fish session のみ反映、現在実行中の Claude Code subprocess には Claude 再起動まで届かない

## OS Detection in Config Files

`config.fish` 等 shell config では runtime OS 判定を使う。fish 公式仕様に従い `switch (uname)` が canonical:

```fish
switch (uname)
    case Darwin
        # macOS
    case Linux
        # Linux
end
```

deploy **時**の OS 別取捨（`.chezmoiignore` による非対称 deploy）は config 内容とは別レイヤー。[shell-deploy.md](shell-deploy.md) を参照（`*.fish` / `dot_bash*` 編集時に自動ロード）。
