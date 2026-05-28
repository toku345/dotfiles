# Headless Linux Git Auth Setup (DGX Spark / clean-install reproducible)

Reproducible procedure for the "path X" SSH/git authentication on a headless Linux box (e.g. DGX Spark, Ubuntu aarch64), per [Issue #231](https://github.com/toku345/dotfiles/issues/231).

## Goal and threat model

Assume credentials will be exfiltrated; minimize post-compromise blast radius. On a headless Linux dev box (the most-exposed machine):

- Use a **GitHub-only** SSH key, passphrase-protected — so a DGX compromise can at worst push to personal GitHub (gated by passphrase capture), never reach other hosts.
- **No agent forwarding** into or out of the box (a forwarded agent is a live signing oracle). A broadly-scoped key — one that also authenticates hosts beyond GitHub — must never be reachable here.
- A **systemd user ssh-agent** caches the key with a bounded timeout so non-interactive git works without leaving the key decrypted indefinitely.
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
if [[ -z "$SSH_AUTH_SOCK" ]]; then
    _ssh_agent_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
    [[ -S "$_ssh_agent_sock" ]] && export SSH_AUTH_SOCK="$_ssh_agent_sock"
    unset _ssh_agent_sock
fi
```

The `-S` guard makes it a no-op on machines without the service; the `-z` guard never clobbers an already-set (e.g. forwarded) agent. `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}` keeps it working even if `XDG_RUNTIME_DIR` is unset in the session.

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

- Switch personal repos from HTTPS to SSH remotes (`git remote set-url origin git@github.com:<user>/<repo>.git`) so pushes use this key and no HTTPS token is needed.
- Old/vestigial on-disk keys should be quarantined or removed once confirmed unused (`mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.quarantined`; verify git + login still work; restore if anything breaks).
- A broadly-scoped key (one that authenticates hosts beyond GitHub) must never be forwarded here: on the client side use `ForwardAgent no` + `IdentityAgent none` for this host, and on this box `AllowAgentForwarding no` (step 4).
