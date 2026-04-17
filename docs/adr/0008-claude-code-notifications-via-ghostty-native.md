# ADR 0008: Use Ghostty native notifications for Claude Code instead of Stop hook afplay

## Status

Accepted

## Context

Claude Code's global `settings.json` had a `Stop` hook that played `Glass.aiff`
via `afplay` on every turn end. In practice, this hook fires for every subagent
completion as well as for main-agent turn ends, which produced audible noise
during sessions that delegate heavily to subagents.

The actual signal the user wants is "Claude is now waiting for my input" — either
for a prompt or for a permission approval. Claude Code exposes this as a separate
`Notification` event (`idle_prompt`, `permission_prompt`), which is distinct from
`Stop`.

Per Claude Code's [terminal configuration docs](https://code.claude.com/docs/en/terminal-config#terminal-notifications),
Ghostty and Kitty support Claude Code desktop notifications natively — the client
emits OSC escape sequences that the terminal surfaces as macOS notifications, with
no additional configuration required. The local environment already satisfies the
prerequisites:

- Ghostty is the primary terminal (native OSC notification support)
- tmux has `allow-passthrough on` (escape sequences reach the outer terminal)
- macOS grants Ghostty notification permission

Notifications also flow through SSH to a remote Linux host that runs Claude Code
inside tmux, provided the remote tmux also has `allow-passthrough on`. mosh is
incompatible because it reconstructs the screen as a character grid and drops
display-irrelevant OSC sequences.

## Decision

- Remove the `Stop` hook (and its `afplay` command) from `~/.claude/settings.json`.
- Rely on Ghostty's native handling of Claude Code's `Notification` event for
  both `idle_prompt` and `permission_prompt` signals.
- Do not add a `Notification` hook. The native desktop notification is sufficient
  and respects macOS Focus / Do Not Disturb settings.

## Consequences

- **Positive**: Subagent completions no longer trigger audio. Audio is gone
  entirely, eliminating noise.
- **Positive**: Notifications are delivered through the macOS notification center,
  which participates in Focus mode, notification grouping, and Do Not Disturb —
  behavior the raw `afplay` bypassed.
- **Positive**: Works transparently for remote Claude Code over SSH, as long as
  the remote tmux has `allow-passthrough on`.
- **Negative**: No signal reaches the user while the Claude Code window itself is
  focused — macOS suppresses notifications for the foreground app. In practice,
  the user is already looking at the window, so the signal is redundant.
- **Negative**: Incompatible with mosh. Not relevant to the current workflow.
- **Risk**: If Ghostty ever changes its OSC notification handling, the signal
  disappears silently. Mitigated by the fact that Claude Code's docs formally
  support this integration.
