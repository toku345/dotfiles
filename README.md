# toku345/dotfiles

toku345's dotfiles managed by chezmoi.

## Setup

Every machine runs the same bootstrap; the Codex and Fugu steps are optional
and per machine.

### 1. Install prerequisites

- [chezmoi](https://www.chezmoi.io/install/)
- age, Bash 5+, and uv

   ```sh
   brew install age bash uv
   ```

   Managed tools such as `brew-reviewed-upgrade` and `ghostty-theme` require
   Homebrew Bash 5 or newer on both macOS and Linux. POSIX sh, pre-Homebrew
   bootstrap commands, and the OS login shell are outside this runtime policy.
   Linux uses apt and Linuxbrew; see [docs/linux-setup.md](docs/linux-setup.md).
   For existing machines, see [Bash runtime migration](docs/linux-setup.md#managed-bash-runtime).

### 2. Bootstrap the dotfiles

```sh
chezmoi init toku345
cd "$(chezmoi source-path)"
sh scripts/codex-config/setup.sh
chezmoi apply
```

`setup.sh` installs a dedicated Python with uv and prepares the locked config
dependencies before the first status/diff/apply; see
[runtime setup and updates](docs/codex.md#初回準備依存更新). `chezmoi apply`
installs the remaining packages, deploys the dotfiles, applies the
`~/.codex/config.toml` per-key policy, and places the `codex-fugu` wrapper at
`~/.local/bin/codex-fugu` (it exits with an error until the isolated home of
step 5 exists).

For validation from a linked or unmerged worktree, explicitly select that source with `chezmoi --source <worktree-path>` for target-path resolution, diff, dry-run, apply, and read-back checks. Follow the canonical [Chezmoi Operations policy](AGENTS.md#chezmoi-operations), including review before evaluation and source-manifest verification. Live apply requires explicit approval, backup/restore planning, script exclusion unless separately approved, and read-back verification. Merge and live-apply approvals are separate; merging is not a prerequisite for validation. After `.chezmoi.toml.tmpl` changes, `chezmoi init` must be re-run to regenerate the config file.

### 3. Answer the per-machine prompts

`chezmoi init` asks these once per machine and stores the answers in
`~/.config/chezmoi/chezmoi.toml`. A stored answer is never asked again: to
change one, set the value in that file (or delete the key to be asked again)
and re-run `chezmoi init` so the config file is regenerated. `chezmoi init
--prompt` forces the questions and needs an interactive terminal.

| Key | Default | Enables |
| --- | --- | --- |
| `vpn_check` | no | VPN status in the starship prompt |
| `codexFugu` | no | Management of the isolated Fugu home base config (`~/.codex-fugu/config.toml`) |

Answer yes to `codexFugu` only on machines that already have the isolated Fugu
home (step 5). While it is off, the whole Fugu source tree is ignored and
`~/.codex-fugu` is never created.

### 4. Install the Codex CLI (optional)

```sh
brew install codex          # or: npm install -g @openai/codex
codex login
```

`~/.codex/config.toml` is managed per key by
`scripts/codex-config/policy.toml` (pin / seed / free). `auth.json`, history,
and sessions are never managed; see [Codex 設定の管理方針](docs/codex.md).

### 5. Set up the isolated Fugu home (optional)

`codex-fugu` runs a separate home (`~/.codex-fugu`) with its own Codex install,
API key, sessions, and memory, launched through the managed wrapper
`~/.local/bin/codex-fugu`. The authoritative procedure is
[docs/codex.md](docs/codex.md#初回セットアップ) (base config policy:
[ADR 0038](docs/adr/0038-fugu-home-config-policy.md)). Order matters:

1. Clone the Fugu repository and read `configs/bundle.sh`
   (`BUNDLE_CODEX_VERSION`).
2. Create `~/.codex-fugu` with mode `0700`, then — in a subshell with the
   dedicated environment — install the bundle-specified Codex into
   `~/.codex-fugu/bin`.
3. Run `<fugu-repo>/scripts/install.sh --reconfigure` and set the Sakana API
   key. Never copy `~/.codex`'s `.env`, `auth.json`, settings, memory, or
   sessions.
4. Verify with `--status` plus one read-only isolated smoke turn, per
   [入口を切り替える前の検証](docs/codex.md#入口を切り替える前の検証).
5. `chezmoi apply -v ~/.local/bin/codex-fugu`, then check `codex-fugu --status`.
   On a machine that already ran the standalone Fugu installer, first copy the
   existing `~/.local/bin/codex-fugu` to a dated backup (see `docs/codex.md`);
   never move or uninstall it.
6. Enable `codexFugu`: set it to `true` in `~/.config/chezmoi/chezmoi.toml`
   (a stored answer is not asked again) and re-run `chezmoi init`, or run
   `chezmoi init --prompt` and answer yes. Then run
   `chezmoi diff --exclude=scripts` and a full `chezmoi apply -v`; applying
   only `~/.codex-fugu/config.toml` would leave the three shared-file
   symlinks uncreated. If an existing
   `~/.codex-fugu/AGENTS.md`, `agents/`, or `rules/managed.rules` is a real
   file or directory, back it up outside the target and remove it before the
   apply. `chezmoi status ~/.codex-fugu` must be empty afterwards.
7. In a new `codex-fugu` session, one Plan mode turn must record
   `"reasoning_effort":"xhigh"`; the Fugu catalog rejects the CLI default.

The installer-owned `fugu.config.toml`, `.env`, `bin/`, `packages/`,
sessions, and `*.sqlite*` files stay outside chezmoi. Keep the Fugu bundle's
verified Codex version unless upstream ships configs for a newer one.

### 6. Restore and updates

- Recovery needs GitHub access, 1Password access, and the `key.txt.age`
  password: [docs/backup-restore.md](docs/backup-restore.md).
- Update policy for Codex and Fugu: [docs/codex.md](docs/codex.md).
- DSH の Web 設定を別端末で再現する: [時雨堂 fork のビルドと初回セットアップ](docs/dsh.md)。

## Additional Setup

### Herdr App layout (macOS)

The managed `bottom-tabs` layout places the tab bar below the terminals and
above the status bar. It is a clone of Herdr App 0.1.15's `main` layout;
the shipped `main` layout remains unchanged. Herdr does not update clones
automatically, so review upstream layout changes when upgrading the app.

After deploying the dotfiles, select it in the running Herdr App:

```sh
herdr-app do layout.switch '{"name":"bottom-tabs"}'
```

To restore the standard layout, switch to `main` with the same command.
The selected layout and other runtime state in `shared.json` remain local
to each machine and are not managed by chezmoi.

The window follows the active space's color. A small `space-theme` mod
switches to one of six `space-ansi1` to `space-ansi6` themes when the
active space changes; the shipped panels stay unmodified, so they receive
Herdr updates. Each theme is the built-in `moss` theme with its `chrome`,
`canvas`, and `raised` colors mixed 15% toward the space color
(`ansi6` `#22a99a`, `ansi3` `#e3814f`, `ansi4` `#5b8def`, `ansi5` `#8b7cf6`,
`ansi2` `#3fae6a`, `ansi1` `#d9649a`, matching the space icons). Terminal
colors stay `moss`. Only dark themes are provided.

Colors come from Herdr's local `space.colors` assignments. Spaces with a
picked hex color, and windows without an active space, use plain `moss`.
The six automatic colors can repeat, and colors follow space IDs, so a
recreated space or another machine may get a different color. A theme
chosen in the theme picker lasts until the next space switch, app
restart, or layout reload.

The theme files copy `moss`'s values from Herdr App 0.1.16 and do not
follow later changes to it. When upgrading Herdr, compare `moss` (read it
with `themes()` from a mod) and regenerate the six files if it changed.
The selected theme is recorded in Herdr's own layout state, not in the
managed files. To turn the colors off, remove the `space-theme` block from
the layout, or switch to `main`, which has no such block, without closing
terminals. Either way the last space theme stays applied, so pick `moss`
in the theme picker afterwards.

The `space-*` themes and the `bottom-tabs` layout are derived from Herdr
App's built-in `moss` theme and `main` layout
([herdrdev/herdr-app](https://github.com/herdrdev/herdr-app), Apache
License 2.0).

### Herdr App shortcuts (macOS)

タブの誤閉じを防ぐため `Cmd+W` を解除し、New Space を `Cmd+N` から `Cmd+Shift+N` に移します。タブを閉じるときは File → Close Tab を使います。キーマップは chezmoi では配布しません。Herdr はカスタマイズ済みのキーマップをアップデート後も保持するため、新しい既定の割り当ては更新後に確認します。

このリポジトリを開いた Claude Code や Codex CLI への依頼例：

> README の「Herdr App shortcuts」に従って、Herdr の初回キー設定を確認して。書き込む前に差分を見せて。

> README の「Herdr App shortcuts」に従って、更新後の既定ショートカットを確認して。衝突した箇所は聞いて、書き込む前に差分を見せて。

1. **対象を確認する。** `herdr-app --version` と、実際に動いている Herdr App が読む `keys.json` の絶対パスを確認する。通常は `~/.config/herdr-app/keys.json`。`HERDR_APP_HOME` や `XDG_CONFIG_HOME` の影響を受ける場合は、端末とアプリで同じ環境変数が見えると仮定しない。版やパスを特定できない、または設定を解釈できない場合は書き込まない。
2. **初回設定：** Herdr が生成したキーマップを起点に上記の3キーだけ変更する案を作る。まだファイルがなければ先に Herdr に生成させる。対象キーに想定外の割り当てがあればユーザーに確認する。現行版を比較元に記録できるのは、その版で生成した設定だと確認できるか、同版の公式既定値と照合して既存の差分をすべてユーザーが把握・了承した場合に限る。既存ファイルを版不明のまま現行版の既定値由来とみなさない。
3. **アップデート後：** 各 Mac の `~/.local/state/herdr-keymap/reviewed-version` を読む。1行目が対象キーマップの絶対パス、2行目が確認済みの版。パスが違う、版が不明、または旧版・現行版いずれかの公式既定値を取得できない場合は、推測でマージしない。[公式リポジトリ](https://github.com/herdrdev/herdr-app) の各リリースタグ `v<版>` にある `defaults/keys.macos.json` をデータとして読む。通常の割り当てはセクションとキーの組で比較する。旧既定値と手元が一致する場合だけ新版の追加・変更・削除を取り込む。上流が変わっていない場合や、手元がすでに新版と一致する場合は変更しない。上流と手元が異なる形で変わった場合はユーザーに判断を求める。3キーはこの規則の対象外とし、上記の意図を明示的に維持する。New Space の移動は一組で確認し、上流や手元で対象キーに別用途の割り当てが見つかったら勝手に上書きしない。
4. **承認を得て適用・確認する。** 対象パス、差分、バックアップ先と復元方法、確認済みの版を更新するかどうかを提示し、書き込み前に明示承認を得る。承認後、Herdr の版と対象ファイルがレビュー時点から変わっていないことを確認する。変わっていたら差分を作り直して再承認を得る。変更がある場合は内容と権限を保ったバックアップを取り、候補の JSON を検証してから書き込む。復元先は最初に確認した実際の設定パスを使う。書き込み結果と再読み込み結果は分けて報告し、`herdr-app status` の `keys.error` を確認する。ユーザーは使い捨てのスペースで `Cmd+W`、`Cmd+N`、`Cmd+Shift+N` を試す。
5. **比較元を更新する。** 確認が完了したら、承認された版を上記の Git 管理外の記録先へ保存する。「変更なし」や「現状維持で合意」の場合、キーマップ自体は書き換えない。未解決の衝突や確認失敗があれば比較元は据え置く。

### Starship

A [Nerd Font](https://www.nerdfonts.com/) installed and enabled in your terminal.

- <https://starship.rs/guide/#prerequisites>

### Claude Code Plugins

`~/.claude/settings.json` contains only environment-agnostic plugins shared across all machines. Language-specific plugins (e.g., `typescript-lsp`, `pyright-lsp`) should be added per-project in each repository's `.claude/settings.json`.

Setup and usage notes for Claude Code plugins and agmsg are documented in [docs/claude-code-plugins.md](docs/claude-code-plugins.md).

Note: `outputStyle` (persona) is an exception — set as a personal preference at user scope. Per-repo overrides via `<repo>/.claude/settings.local.json` still take precedence over the user-scope default. See [docs/adr/0015-multi-persona-output-styles.md](docs/adr/0015-multi-persona-output-styles.md) for rationale.
