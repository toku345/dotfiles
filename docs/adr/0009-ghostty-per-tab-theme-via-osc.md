# ADR 0009: Switch Ghostty color theme per surface via OSC sequences from fish

## Status

Accepted

## Context

Ghostty exposes color theme configuration only at the global level: there
is no built-in mechanism to assign a different theme to each tab. Upstream
tracks this as Discussions #2353 and #4817, neither of which has landed.

In this environment, multiple projects share a single Ghostty instance,
and visually distinguishing a work-project tab from a personal-project
tab is useful for context. iTerm2 supports per-profile themes; Ghostty
does not yet.

**Ghostty's surface model.** Ghostty uses the term "surface" for a single
terminal view. A tab contains one surface by default; splitting a tab
creates additional surfaces within that same tab. Ghostty's
surface-specific operations, including OSC sequence handling, target only
the receiving surface — they do not fan out across splits or tabs.
Whatever approach is taken therefore naturally has per-surface
granularity; whether it also behaves as "per-tab" depends on whether
splits are used in a given tab.

Two implementation strategies were considered:

1. **Rewrite the Ghostty config file, then reload via `kill -SIGUSR2 <pid>`.**
   Rejected. Reload applies globally — every surface picks up the new
   theme, which defeats the isolation goal. It also forces serialization
   of rapid theme switches through the filesystem.

2. **Emit OSC escape sequences directly from the shell to the current
   surface.** Ghostty's terminal parser reads OSC 4 (palette), OSC 10
   (foreground), OSC 11 (background), OSC 12 (cursor), OSC 17
   (selection background), and OSC 19 (selection foreground). These
   sequences mutate state on the receiving surface only. The lifecycle
   of that state matches the surface, which in the common non-split case
   is the tab.

Approach 2 was chosen. Since the everyday usage pattern here is one
surface per tab, per-surface isolation delivers the per-tab experience
that motivated this work.

Ghostty ships a large bundle of theme files at
`/Applications/Ghostty.app/Contents/Resources/ghostty/themes/` in a simple
key=value format (e.g. `palette = 0=#15161e`, `background = #1a1b26`).
Rather than inventing a custom theme format, the plan is to parse these
bundled files and translate the relevant keys into OSC sequences on the
fly. This keeps the theme catalog in sync with whatever Ghostty ships —
new themes appear automatically, existing themes pick up upstream color
tweaks on next invocation, and there is no separate registry to
maintain.

Not every theme key has an OSC counterpart. In particular, every one of
the 463 bundled themes declares a `cursor-text` value (the foreground
color used for characters drawn underneath the cursor), and there is no
standard OSC sequence for that attribute — xterm does not define one,
and Ghostty has not invented a proprietary one. Any approach that only
streams OSC sequences must therefore leave `cursor-text` unchanged. This
is a real, user-visible limitation of the OSC approach, not a transient
bug; it is recorded explicitly below.

A PWD-change auto-apply hook was considered and rejected for the initial
version. It adds state (per-shell or per-surface flags to avoid
clobbering an explicitly chosen theme), ambiguity about precedence
between auto and manual switches, and a second failure surface to debug.
Manual switching via `ghostty-theme` is sufficient for current needs; an
auto-switch layer can be added later if manual use proves inconvenient.

## Decision

Provide a `ghostty-theme` fish function that emits OSC sequences to the
current surface based on a Ghostty bundled theme file.

- User-facing function:
  `private_dot_config/private_fish/functions/ghostty-theme.fish`
  (chezmoi source; no `__` prefix).
- Private fzf preview helper:
  `private_dot_config/private_fish/functions/__ghostty_theme_preview.fish`
  (renders each theme color as an ANSI truecolor block so hex values
  are not the only visual cue when browsing the picker).
- Companion completion:
  `private_dot_config/private_fish/completions/ghostty-theme.fish`.
- Themes directory is hardcoded to
  `/Applications/Ghostty.app/Contents/Resources/ghostty/themes/`.
  Parameterization is deferred until a concrete second install path
  exists.

Behavior:

- `ghostty-theme <name>` — read `<themes_dir>/<name>`, translate each
  recognized key to its OSC sequence, and `printf` the sequences to
  stdout so the current surface applies them.
- `ghostty-theme` (no argument) — launch `fzf` over `ls <themes_dir>`
  with a preview pane that calls `__ghostty_theme_preview` to render
  each theme value (palette, background, foreground, cursor-color,
  cursor-text, selection-*) as an ANSI truecolor block alongside the
  hex value. Cancellation returns 0.
- `ghostty-theme <name-that-does-not-exist>` — write an error to
  stderr and return non-zero.
- `ghostty-theme` with a missing themes directory — same loud
  failure (error to stderr, non-zero return).
- Theme files are re-read on every invocation. No caching.

Recognized keys and their OSC mappings:

| Theme file line                         | OSC sequence                     |
|-----------------------------------------|----------------------------------|
| `palette = N=#RRGGBB`                   | `ESC ] 4 ; N ; #RRGGBB ESC \`    |
| `background = #RRGGBB`                  | `ESC ] 11 ; #RRGGBB ESC \`       |
| `foreground = #RRGGBB`                  | `ESC ] 10 ; #RRGGBB ESC \`       |
| `cursor-color = #RRGGBB`                | `ESC ] 12 ; #RRGGBB ESC \`       |
| `selection-background = #RRGGBB`        | `ESC ] 17 ; #RRGGBB ESC \`       |
| `selection-foreground = #RRGGBB`        | `ESC ] 19 ; #RRGGBB ESC \`       |

The `palette` line uses `N=#RRGGBB` (no whitespace around the inner
`=`); other keys use `key = #RRGGBB`. Parsing tolerates leading and
trailing whitespace around tokens.

Any key without an entry in the table above is skipped silently. This
covers both truly unknown keys and keys that exist in the theme file
but have no OSC representation — most notably `cursor-text`, which every
bundled theme declares. Skipping these silently is an intentional
design choice: logging a warning on every invocation for a value we
cannot possibly apply would be noise, and failing loudly would block
legitimate themes from being applied. The limitation is surfaced in
Consequences rather than at runtime.

Inline comments are not supported. A scan of all 463 bundled themes
(10,186 key lines) confirmed zero inline-comment occurrences, so the
extra parsing logic is unnecessary.

Out of scope for this ADR (explicitly not addressed):

- PWD-triggered auto-switching and shell-startup initial apply.
- zsh/bash portability.
- Linux or Windows support.
- cmux or other libghostty-embedded consumers.
- tmux passthrough correctness for the selection OSCs inside multiplexed
  sessions.
- Upstreaming per-tab (or `cursor-text` OSC) support to Ghostty itself.

## Consequences

**Positive**

- Each surface gets an independent theme without touching Ghostty's
  global config and without any restart. In the common case of one
  surface per tab, this delivers per-tab theme switching.
- No invariant to maintain between a custom theme registry and
  Ghostty-bundled themes; new themes appear in completion and picker
  automatically, and upstream color tweaks land on next invocation.
- `fzf` + `__ghostty_theme_preview` picker removes the need to remember
  theme names, which matters because Ghostty ships hundreds of themes
  with free-form names that include spaces.
- Loud failure on the cases most likely to indicate user error:
  missing theme file and missing themes directory both emit a stderr
  message and return non-zero.

**Negative / constraints**

- **Split tabs are not per-tab.** OSC sequences apply only to the
  receiving surface. When a tab is split, each split is its own
  surface, so applying a theme in one split does not propagate to the
  others in the same tab. Users who split heavily should expect to
  run `ghostty-theme` once per split.
- **`cursor-text` is not applied.** There is no OSC sequence for the
  foreground color of characters drawn under the cursor, and every
  bundled theme defines one. The value therefore stays at whatever
  the Ghostty global config specifies. With `cursor-style = block`
  (the repo's current setting) this is the most visible discrepancy:
  block cursors show their text in the global value rather than the
  theme's value. The fzf preview does render `cursor-text` so users
  can still see the theme's intended value before picking.
- Silent skip for keys without an OSC counterpart (or unrecognized
  entirely) means a future Ghostty theme format addition could be
  ignored without warning. Acceptable trade-off versus runtime noise.
- The change is only visible on the surface that received the OSC.
  Surfaces opened after an upstream theme file update still start
  from Ghostty's global theme until `ghostty-theme` is invoked.
- There is a brief visual moment at new-surface startup where the
  global theme is shown before the user (or a future auto-hook)
  switches.
- The themes directory is hardcoded. If Ghostty is installed outside
  `/Applications/`, the function errors loudly rather than
  discovering the alternative path. Acceptable trade-off for the
  primary use case.
- Manual-only switching requires a conscious action per surface. If
  this proves tedious, a follow-up ADR can reintroduce a PWD or
  per-project auto-hook on top of this foundation.
- OSC 17 and OSC 19 handling for selection colors is not explicitly
  documented in the local Ghostty man pages; if a future Ghostty
  version drops or changes them, selection colors would silently stay
  on the previous value. Acceptable because palette/background/
  foreground carry the bulk of the theme signal.
