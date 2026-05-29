# Headless Linux Git Auth Setup (DGX Spark / clean-install reproducible)

Reproducible procedure for the "path X" SSH/git authentication on a headless Linux box (e.g. DGX Spark, Ubuntu aarch64), per [Issue #231](https://github.com/toku345/dotfiles/issues/231).

## Goal and threat model

Assume credentials will be exfiltrated; minimize post-compromise blast radius. On a headless Linux dev box (the most-exposed machine):

- Use a **GitHub-only** SSH key, passphrase-protected — so a DGX compromise can at worst push to personal GitHub, never reach other hosts. Durable theft of the key is gated by passphrase capture (the key never leaves the box usable without it); an active session within the agent's TTL window can still push without the passphrase (see ADR 0027 Consequences).
- **No agent forwarding** into or out of the box (a forwarded agent is a live signing oracle). A broadly-scoped key — one that also authenticates hosts beyond GitHub — must never be reachable here.
- A **systemd user ssh-agent** caches the key with a bounded timeout so non-interactive git — within a login/interactive session and its child processes, which inherit `SSH_AUTH_SOCK` from `~/.bashrc` — works without leaving the key decrypted indefinitely. (A fresh `ssh box '<cmd>'` runs a non-login non-interactive shell that does not source `~/.bashrc`, so it has no `SSH_AUTH_SOCK` unless it is set explicitly.)
- End state is YubiKey FIDO2 (touch-per-auth); this is the interim.

## Prerequisites

- `chezmoi apply` has run, deploying `~/.ssh/config` (which `Include`s `~/.ssh/config.local` and sets a `Host *` block).
- `gh` is installed or you have browser access to <https://github.com/settings/keys>.

## 1. Generate a GitHub-only key

```bash
ssh-keygen -t ed25519 -C "<user>-<host>-github-only" -f ~/.ssh/id_ed25519_github
# set a passphrase (do NOT leave empty)
```

## 2. Register the public key on GitHub

Prefer the web UI to avoid granting this box's `gh` token the sticky `admin:public_key` scope (least privilege):

```bash
cat ~/.ssh/id_ed25519_github.pub   # copy this
```

Paste at <https://github.com/settings/keys> → **New SSH key** → type **Authentication key**.

(CLI alternative, increases the box's gh token scope: `gh auth refresh -h github.com -s admin:public_key && gh ssh-key add ~/.ssh/id_ed25519_github.pub --title "<host> github-only"`.)

## 3. Route github.com to the github-only key (machine-local)

`~/.ssh/config` is chezmoi-managed and `Include`s `~/.ssh/config.local` first. Put host-specific, machine-local config there so `chezmoi apply` never clobbers it:

```bash
printf '%s\n' \
  'Host github.com' \
  '  HostName github.com' \
  '  User git' \
  '  IdentityFile ~/.ssh/id_ed25519_github' \
  '  IdentitiesOnly yes' \
  >> ~/.ssh/config.local
chmod 600 ~/.ssh/config.local
```

`IdentitiesOnly yes` makes github.com SSH use only this key and ignore any (forwarded) agent identities.

Verify (interactive — prompts for the passphrase until the agent is set up):

```bash
ssh -T git@github.com   # "Hi <user>! ..." (exit 1 is normal for GitHub)
```

## 4. Block agent forwarding at this box (defense in depth)

```bash
echo 'AllowAgentForwarding no' | sudo tee /etc/ssh/sshd_config.d/10-no-agent-forward.conf
sudo sshd -t && sudo systemctl reload ssh
sudo sshd -T 2>/dev/null | grep -i allowagentforwarding   # -> allowagentforwarding no
```

If the main `/etc/ssh/sshd_config` has an explicit `AllowAgentForwarding yes`, comment it out (the drop-in wins by first-match since `Include` is near the top, but removing the contradiction avoids a footgun):

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo sed -i 's|^AllowAgentForwarding yes|#AllowAgentForwarding yes (disabled; see sshd_config.d/10-no-agent-forward.conf)|' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```

## 5. systemd user ssh-agent

```bash
mkdir -p ~/.config/systemd/user
printf '%s\n' \
  '[Unit]' \
  'Description=SSH key agent' \
  '' \
  '[Service]' \
  'Type=simple' \
  'Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket' \
  'ExecStartPre=/usr/bin/rm -f %t/ssh-agent.socket' \
  'ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK' \
  '' \
  '[Install]' \
  'WantedBy=default.target' \
  > ~/.config/systemd/user/ssh-agent.service

systemctl --user daemon-reload
systemctl --user enable --now ssh-agent.service
```

`%t` resolves to `$XDG_RUNTIME_DIR` (e.g. `/run/user/1000`). Linger is intentionally left **disabled** — the agent stops when all your sessions close, so the decrypted key never outlives your presence. (A long-lived tmux/cmux session keeps it alive across SSH reconnects.)

## 6. Point the shell at the agent (bash)

On Linux this repo manages `~/.bashrc` (`.chezmoiignore` excludes the bash configs only on macOS) and `~/.bash_profile` sources it on SSH login. **This block already lives in chezmoi source `dot_bashrc`, so `chezmoi apply` deploys it automatically — on a new box there is nothing to add here.** For reference:

```bash
_ssh_agent_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
if [[ -S "$_ssh_agent_sock" ]]; then
    export SSH_AUTH_SOCK="$_ssh_agent_sock"
fi
unset _ssh_agent_sock
```

The `-S "$_ssh_agent_sock"` test makes it a no-op on machines without the service. When the systemd socket exists this box always points `SSH_AUTH_SOCK` at it, deliberately ignoring any inherited value — by design, since the box is GitHub-only with no agent forwarding (step 4 / ADR 0027): a stray forwarded or broader-scoped agent is never used, and a stale inherited value (e.g. from a reconnected tmux/cmux session) cannot silently block git. `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}` keeps it working even if `XDG_RUNTIME_DIR` is unset in the session. If the systemd socket is absent, `SSH_AUTH_SOCK` keeps its inherited value (empty on a forwarding-free login), so git prompts for the passphrase or fails loudly rather than using a hidden agent. (`-S` is a type test, not a liveness probe: if the agent crashed but left a stale socket inode, `SSH_AUTH_SOCK` is pointed at it and git fails loudly with a connection error — still no hidden agent.)

(On a fish-based Linux box you would use a `~/.config/fish/conf.d/*.fish` snippet with equivalent logic — but note this repo excludes `~/.config/fish` on Linux, so that path is not chezmoi-managed here.)

## 7. Load the key (once per session lifecycle)

In a new shell (so `SSH_AUTH_SOCK` is set), or after exporting it manually:

```bash
ssh-add -t 28800 ~/.ssh/id_ed25519_github   # 8h timeout; enter the passphrase once
ssh-add -l                                    # confirm only the github-only key is loaded
```

Never load with no `-t` (indefinite signing oracle) and never wire up auto-decryption of the passphrase.

## Verification

```bash
ssh -T git@github.com                                   # greets <user>, no passphrase prompt (agent serves it)
git ls-remote git@github.com:<user>/<repo>.git HEAD     # returns a hash
ssh-add -l                                              # only id_ed25519_github
```

## Notes

- **Per-machine items** (redo on each new box — not chezmoi-synced): the github-only key (generate a fresh key per box; never copy a private key between machines), the `~/.ssh/config.local` github.com block, the sshd drop-in, the systemd unit, `gh auth login`, and `gh config set git_protocol ssh` (gh config lives in `~/.config/gh`, which is not chezmoi-managed; `hosts.yml` holds the secret token).
- **Cloning**: on a fresh box, clone via SSH from the start — `gh repo clone <user>/<repo>` (uses SSH once `git_protocol=ssh` is set) or `git clone git@github.com:<user>/<repo>.git`. The `git remote set-url origin git@github.com:<user>/<repo>.git` conversion is only for migrating pre-existing HTTPS clones.
- Old/vestigial on-disk keys should be quarantined or removed once confirmed unused (`mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.quarantined`; verify git + login still work; restore if anything breaks).
- A broadly-scoped key (one that authenticates hosts beyond GitHub) must never be forwarded here: on the client side use `ForwardAgent no` + `IdentityAgent none` for this host, and on this box `AllowAgentForwarding no` (step 4).
