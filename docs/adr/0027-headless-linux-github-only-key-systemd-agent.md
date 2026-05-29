# ADR 0027: Headless Linux git auth — GitHub-only key + systemd user ssh-agent, no agent forwarding

## Status

Accepted

## Context

The threat model is "assume credentials will be exfiltrated; minimize post-compromise blast radius." Recent supply-chain attacks (the Shai-Hulud npm worm family) scan `$HOME` for secrets, and the Mini Shai-Hulud variant additionally targets password-manager CLIs.

This repo is deployed across macOS machines and a headless Linux box (aarch64). The headless Linux box is the most-exposed machine — it runs the heaviest dev tooling, which is where npm/supply-chain payloads tend to land. 1Password Desktop and its SSH agent are not available on that platform, so the hardware/biometric-backed agent model used on macOS cannot be reused there.

The prior setup forwarded a macOS SSH agent into the headless box (`ssh -A`). A forwarded agent is a live signing oracle on the remote host for the lifetime of the connection, and it can make a broadly-scoped key — one that authenticates hosts beyond GitHub — reachable from the most-exposed machine. That coupling is the opposite of blast-radius minimization.

A separate operational symptom motivated the change too: HTTPS git pushes from the sandboxed environment failed because the git credential helper could not read its config file. Switching the box's git to SSH removes that dependency.

## Decision

On the headless Linux box, use a dedicated GitHub-only SSH key served by a systemd user ssh-agent, and eliminate SSH agent forwarding to and from that box ("path X").

- A passphrase-protected, GitHub-only ed25519 key lives on the box and authenticates only to github.com, pinned via a `Host github.com` block with `IdentitiesOnly yes` in machine-local `~/.ssh/config.local`.
- A systemd user ssh-agent (`~/.config/systemd/user/ssh-agent.service`) holds the key on a fixed socket. `~/.bashrc` (chezmoi-managed on Linux) always points `SSH_AUTH_SOCK` at that socket when it exists, deliberately ignoring any inherited value — by design, since the box is GitHub-only with no agent forwarding: a stray forwarded or broader-scoped agent is never used, and a stale inherited value cannot silently block git. (On machines without the service the override is a no-op and the inherited value is kept.) Keys are loaded with a bounded `ssh-add -t` timeout, the passphrase is never auto-decrypted, and systemd linger stays disabled.
- Agent forwarding is blocked at both ends: clients set `ForwardAgent no` + `IdentityAgent none` for this host (note: a command-line `-A` overrides config, so the server side is load-bearing), and the box's sshd sets `AllowAgentForwarding no`.
- A broadly-scoped key (one that also authenticates hosts beyond GitHub) is never made reachable on this box.
- Personal repos on the box use SSH remotes so pushes use the GitHub-only key; the HTTPS credential-helper path is no longer used here, and `gh config set git_protocol ssh` makes future clones SSH by default.

## Consequences

- Post-compromise blast radius from the headless box is bounded to GitHub push on the personal account, and no broadly-scoped key is reachable. Forwarding is gone, so there is no forwarded/remote signing oracle — but the local agent is itself a signing oracle while the key is loaded: code running on the box during the `ssh-add -t` TTL window (8h) can authenticate to GitHub without the passphrase. So an active-session compromise within that window is a residual risk; durable abuse beyond it additionally requires capturing the key passphrase, which is never auto-decrypted. The bounded TTL limits, but does not eliminate, this window.
- The setup is per-machine: the key is generated fresh per box and a private key is never copied between machines (per-box isolation is the goal). A clean-install-reproducible runbook is committed at [`docs/headless-linux-auth-setup.md`](../headless-linux-auth-setup.md).
- Non-interactive git on the box — within a login/interactive session and its children, which inherit `SSH_AUTH_SOCK` from `~/.bashrc` — now depends on the agent holding the key (a non-TTY context cannot supply the passphrase), which is why the systemd user agent, not just an interactive convenience, is required. A fresh `ssh box '<cmd>'` runs a non-login shell that does not source `~/.bashrc`, so it must set `SSH_AUTH_SOCK` explicitly.
- macOS machines, which can run a hardware/biometric-backed agent, follow a separate track; this ADR governs only the headless Linux box.
- The end state is a hardware-backed key (FIDO2 `sk-ssh-ed25519`, touch-per-use); this ADR is the interim until that hardware is in place.

## Alternatives considered

- Keep agent forwarding (with or without a resident key): retains a live signing oracle on the most-exposed box, and the safety of a "per-signature prompt" cannot be relied on for forwarded requests. Rejected.
- A broadly-scoped resident key on the box: leaves a portable secret on the most-exposed machine. Rejected in favor of a GitHub-scoped key.
- Disallow git push from the box entirely (push only from other machines or CI): strongest containment, but conflicts with authoring repos directly on the box. Rejected for ergonomics.
- SSH-agent destination constraints (`ssh-add -h`) as the primary guard: brittle against host-list churn and alias changes. Kept only as optional defense-in-depth, not the main control.
