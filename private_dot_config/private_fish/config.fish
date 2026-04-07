set -x LC_ALL en_US.UTF-8

## Syntax highlighting theme (fish 4.3+)
fish_config theme choose tomorrow-night-bright

fish_add_path $HOME/.local/bin

## homebrew (OS-specific)
switch (uname)
    case Darwin
        # macOS (Homebrew on Apple Silicon)
        test -e /opt/homebrew/bin/brew; and eval (/opt/homebrew/bin/brew shellenv)
        # WORKAROUND: fix the issue that the $PATH is not set correctly when tmux is started.
        if set -q HOMEBREW_PREFIX
            fish_add_path -m /opt/homebrew/bin /opt/homebrew/sbin
        end
    case Linux
        # Linux (Linuxbrew)
        test -e /home/linuxbrew/.linuxbrew/bin/brew; and eval (/home/linuxbrew/.linuxbrew/bin/brew shellenv)
end

## asdf
set -gx ASDF_CONFIG_FILE $HOME/.config/asdf/.asdfrc

# https://asdf-vm.com/guide/getting-started.html#_2-configure-asdf
if test -z "$ASDF_DATA_DIR"
    set _asdf_shims "$HOME/.asdf/shims"
else
    set _asdf_shims "$ASDF_DATA_DIR/shims"
end

# Do not use fish_add_path (added in Fish 3.2) because it
# potentially changes the order of items in PATH
if not contains $_asdf_shims $PATH
    set -gx --prepend PATH $_asdf_shims
end
set --erase _asdf_shims

## starship
type -q starship; and starship init fish | source

## iTerm2
if test -e $HOME/.config/iterm2/shell_integration.fish
    source $HOME/.config/iterm2/shell_integration.fish
end

## Rust
# https://www.rust-lang.org/tools/install
fish_add_path $HOME/.cargo/bin
## Enable tab completion for Fish
# https://rust-lang.github.io/rustup/installation/index.html?highlight=fish#enable-tab-completion-for-bash-fish-zsh-or-powershell

## go
fish_add_path $HOME/go/bin

## java
if test -e $HOME/.asdf/plugins/java/set-java-home.fish
    . $HOME/.asdf/plugins/java/set-java-home.fish
end

## Scala (OS-specific path)
switch (uname)
    case Darwin
        fish_add_path "$HOME/Library/Application Support/Coursier/bin"
    case Linux
        fish_add_path "$HOME/.local/share/coursier/bin"
end

## OCaml
if test -e $HOME/.opam/opam-init/init.fish
    source $HOME/.opam/opam-init/init.fish >/dev/null 2>/dev/null; or true
end

## Haskell
fish_add_path $HOME/.ghcup/bin
fish_add_path $HOME/.cabal/bin

## mysql (macOS only - Homebrew path)
if test (uname) = Darwin
    fish_add_path /opt/homebrew/opt/mysql-client/bin
end

## direnv
# https://github.com/direnv/direnv/blob/master/docs/hook.md#fish
type -q direnv; and direnv hook fish | source

## shadowenv
# https://shopify.github.io/shadowenv/getting-started/#add-to-your-shell-profile
type -q shadowenv; and shadowenv init fish | source

## fzf
function fzf_select_history
    if test (count $argv) = 0
        set fzf_flags --layout=reverse --scheme=history
    else
        set fzf_flags --layout=reverse --scheme=history --query "$argv"
    end

    history | fzf $fzf_flags | read selected

    if [ $selected ]
        commandline $selected
    else
        commandline ''
    end
end

# set key bindings
function fish_user_key_bindings
    bind \cr 'fzf_select_history (commandline -b)'
end

function fzf_cd
    if test (count $argv) = 0
        set fzf_flags --layout=reverse
    else
        set fzf_flags --layout=reverse --query "$argv"
    end

    fd -t d -I -H -E ".git" | fzf $fzf_flags | read selected

    if [ $selected ]
        cd $selected
    else
        commandline ''
    end
end

## OrbStack
# Added by OrbStack: command-line tools and integration
# This won't be added again if you remove it.
test -e $HOME/.orbstack/shell/init2.fish; and source $HOME/.orbstack/shell/init2.fish

## Windsurf
fish_add_path $HOME/.codeium/windsurf/bin

## git workflow commands
function gw --description "Create gtr worktree and cd to it (-c to checkout existing branch)"
    git rev-parse --is-inside-work-tree >/dev/null 2>/dev/null
    or begin; echo "Error: not in a git repository" >&2; return 1; end

    if test "$argv[1]" = -c; or test "$argv[1]" = --checkout
        __gw_checkout $argv[2..]
        return $status
    end

    set -l base
    if set -q argv[1]; and test -n "$argv[1]"
        set base $argv[1]
    else
        set base (__detect_default_branch)
        or return 1
    end

    set -l branch "wip/gw-"(date "+%Y%m%d-%H%M%S")
    git gtr new $branch --from $base --yes
    and begin
        set -l d (git gtr go $branch)
        test $status -eq 0; and test -n "$d"; and cd "$d"
        or begin; echo "Error: failed to navigate to worktree" >&2; return 1; end
    end
end

## abbreviations
abbr -a cm chezmoi

## alias functions
function l --description 'eza -ahl --git'
    eza -ahl --git $argv
end

function ll --description 'ls -ahl'
    ls -ahl $argv
end

function tree --description 'alterative tree command: eza -T'
    eza -T $argv
end

function gp --description 'alias: git push'
    git push $argv
end

function gd --description 'alias: git diff with delta pager'
    git diff-delta $argv
end

function gst --description 'alias: git status'
    git status $argv
end

function gb --description 'git checkout or cd to worktree (fzf branch selector)'
    git rev-parse --is-inside-work-tree >/dev/null 2>/dev/null
    or begin; echo "Error: not in a git repository" >&2; return 1; end

    set -l selected (git for-each-ref \
        --format='%(if)%(HEAD)%(then)current'\t'* %(refname:short)%(else)%(if)%(worktreepath)%(then)worktree'\t'+ %(refname:short)%(else)regular'\t'  %(refname:short)%(end)%(end)' \
        refs/heads/ | fzf --delimiter=\t --with-nth=2 --layout=reverse $argv)

    test -n "$selected"; or return 0

    set -l parts (string split \t -- $selected)
    set -l type $parts[1]
    set -l branch (string sub -s 3 $parts[2])

    switch $type
        case current
            return 0

        case worktree
            set -l wt_path (__worktree_path_for_branch $branch)
            if test -n "$wt_path"
                cd "$wt_path"
                or begin; echo "Error: failed to cd to worktree '$wt_path'" >&2; return 1; end
            else
                echo "Error: worktree path not found for '$branch'" >&2
                return 1
            end

        case regular
            set -l default_branch (__detect_default_branch)
            or return 1
            set -l main_repo (git worktree list --porcelain | awk 'NR==1{print substr($0,10); exit}')
            if test -z "$main_repo"
                echo "Error: failed to determine main repo path" >&2
                return 1
            end
            set -l current_repo (git rev-parse --show-toplevel)

            # Inside worktree → confirm and cd to main repo first
            if test "$main_repo" != "$current_repo"
                read -l -P "Switch to main repo and checkout '$branch'? [y/N] " confirm
                string match -qir '^y' -- "$confirm"; or return 0
                cd "$main_repo"
                or begin; echo "Error: failed to cd to main repo" >&2; return 1; end
            end

            # Worktree protection: block non-default branch checkout when worktrees exist
            set -l wt_lines (git worktree list)
            if test (count $wt_lines) -ge 2; and test "$branch" != "$default_branch"
                echo "Error: worktree が存在するため、main repo では default ブランチ以外に checkout できません。" >&2
                echo "  → worktree で作業: gw -c $branch" >&2
                echo "  → 一時的な作業:   gw" >&2
                return 1
            end

            git checkout $branch
    end
end

function d --description 'alias: docker'
    docker $argv
end

function dc --description 'alias: docker-compose'
    docker compose $argv
end

function be --description 'alias: bundle exec'
    bundle exec $argv
end

function rd --description 'alias: git diff --diff-filter=ACMR --name-only | xargs bundle exec rubocop -R'
    git diff --diff-filter=ACMR --name-only | xargs bundle exec rubocop -R $argv
end

function gbd --description 'delete merged git branches'
    set -l base (__detect_default_branch)
    or return 1

    set -l branches (git for-each-ref \
        --merged="$base" \
        --format='%(if)%(HEAD)%(then)%(else)%(if)%(worktreepath)%(then)%(else)%(refname:short)%(end)%(end)' \
        refs/heads/ | string match -rv '^$' | string match -rv "^$base\$")

    if test (count $branches) -eq 0
        echo "No merged branches to delete." >&2
        return 0
    end

    for b in $branches
        git branch -D $b
    end
end

## Local configuration (machine-specific)
test -e $HOME/.config/fish/config.fish.local; and source $HOME/.config/fish/config.fish.local
