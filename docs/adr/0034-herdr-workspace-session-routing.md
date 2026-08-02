# ADR 0034: Route Git checkouts to Herdr named sessions

## Status

Accepted

## Context

Ghostty tabs are used as the outer boundary for repositories and linked Git worktrees. Herdr clients attached to the same session share the focused workspace, tab, and pane, so opening the same session in multiple Ghostty tabs makes their visible state move together. This differs from the previous tmux workflow, where each checkout had an independent session.

Herdr's default workflow is one persistent default session containing project-level workspaces. Named sessions are also supported through `herdr --session <name>`. Closing the outer terminal detaches the client while the Herdr server and pane processes continue running; stopping the server explicitly ends the session.

The existing shell configuration is asymmetric across operating systems: Fish configuration is deployed on macOS but not on Linux. A Fish-only launcher would therefore fail the Linux portability requirement.

## Decision

Add a Bash launcher named `hw`, deployed as `~/.local/bin/hw`, that maps the current Git checkout to a Herdr named session.

- Install the `herdr` formula from Homebrew in both the macOS and Linux bootstrap branches. Homebrew-managed installations are updated through Homebrew rather than Herdr's self-updater.
- `hw` resolves the checkout with `git rev-parse --show-toplevel`, so invoking it from any nested directory selects the same session.
- The Git top-level basename is the session name when it contains only ASCII letters, digits, `.`, `_`, and `-`, is at most 40 characters, and is not Herdr's reserved `default` name.
- A basename containing other characters, exceeding 40 characters, or equal to `default` is converted to an ASCII slug and suffixed with the full decimal POSIX `cksum` of the original basename. The slug is truncated as needed so the final name is at most 40 characters. If the slug is empty, `session` is used as its readable prefix.
- The checksum reduces avoidable collisions between different basenames that normalize to the same slug, but does not guarantee uniqueness. It intentionally does not include the full checkout path: two checkouts with the same basename still select the same session, matching the previous tmux convention and requiring checkout directory names to be unique in normal use.
- `hw` forwards ordinary Herdr arguments to the derived named session, but rejects `--session`, `--no-session`, `--remote`, and the leading `session` management subcommand. Arguments after `--` are payload and are not inspected.
- Before launching Herdr, `hw` removes inherited `HERDR_ENV`, `HERDR_SESSION`, and `HERDR_SOCKET_PATH` so an enclosing Herdr pane cannot trigger the nested-session guard or override the checkout-derived route.
- With its required commands available, `hw` fails outside a Git checkout and directs the operator to run `herdr`. There is no implicit fallback to the default session.
- Running `herdr` directly from `$HOME` remains the machine-operations workflow and uses the default session.

Keep the tmux-derived Herdr keybindings in `~/.config/herdr/config.toml`. `prefix+q` and `prefix+d` detach the client. `prefix+shift+q` runs `"${HERDR_BIN_PATH:-herdr}" server stop`; Herdr supplies custom shell commands with the active `HERDR_SOCKET_PATH`, so this stops the current named session rather than assuming the default session.

## Consequences

### Positive

- Each Ghostty tab can attach to an independent repository or worktree session without synchronized focus changes in another tab.
- The same `hw` command works from Fish on macOS and Bash on Linux.
- Fresh macOS and Linux machines receive Herdr through the existing Homebrew bootstrap path.
- The launcher fails loudly when it cannot derive a Git checkout instead of silently attaching to an unrelated default session.
- Invalid and long directory names remain usable without creating avoidable normalization collisions.

### Negative / Trade-offs

- Checkout directory basenames must remain unique when independent sessions are required. Two identical basenames intentionally attach to one session.
- The finite checksum can collide, and a valid basename can equal another basename's generated slug-and-checksum form. The scheme reduces likely normalization collisions rather than providing a uniqueness proof.
- `hw` is not a general replacement for every Herdr invocation. Default-session, remote, no-session, and cross-session management commands use `herdr` directly.
- Session names derived from invalid or long basenames include a numeric checksum and are less minimal than the original directory name.
- A universal fixed session length cannot guarantee Unix socket-path capacity for arbitrarily long `XDG_CONFIG_HOME` values. The 40-character cap is conservative for the managed macOS and Linux environments; Herdr still reports a loud error if an unusual configuration path exceeds the platform limit.

## Alternatives Considered

1. **Use one default Herdr session with one workspace per checkout.** Rejected because multiple Ghostty clients attached to that session share visible focus state.
2. **Create one named session per full checkout path hash.** Rejected because opaque names lose the repository/worktree naming convention and make manual session management harder.
3. **Implement `hw` as a Fish function.** Rejected because this repository intentionally does not deploy Fish configuration on Linux.
4. **Normalize invalid characters without a checksum.** Rejected because different names such as `foo bar` and `foo@bar` would silently attach to the same session.

## Verification

- Validate the managed Herdr configuration with `herdr config check` before and after applying it.
- Exercise `hw` with Bats against real temporary Git repositories and linked worktrees while stubbing Herdr.
- Run the Bats suite on macOS and in the Ubuntu 24.04 CI-parity container.
