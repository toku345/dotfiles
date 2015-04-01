
# PATH
# PATH=/usr/local/Cellar/perl/5.14.4/bin:$PATH
# PATH=/usr/local/bin:$PATH
# PATH=/usr/local/sbin:$PATH
# PATH=$PATH:$HOME/android-sdk-macosx/tools:$HOME/android-sdk-macosx/platform-tools

# PATH=$PATH:/usr/local/share/npm/bin
# PATH=$PATH:$HOME/play/play-2.1.1
# PATH=/Applications/Postgres93.app/Contents/MacOS/bin:$PATH
# PATH=$PATH:/Applications/Postgres.app/Contents/MacOS/bin

# PATH=$HOME/.nodebrew/current/bin:$PATH

PATH=/Applications/Emacs.app/Contents/MacOS/bin:$PATH
# PATH=/Applications/Emacs.app/Contents/MacOS:$PATH

# PATH=/usr/local/opt/coreutils/libexec/gnubin:$PATH
# MANPATH=/usr/local/opt/coreutils/libexec/gnuman:$MANPATH

## anyenv
if [ -d $HOME/.anyenv ]; then
    export PATH="$HOME/.anyenv/bin:$PATH"
    eval "$(anyenv init -)"
    eval "$(pyenv virtualenv-init -)"

    for D in `ls $HOME/.anyenv/envs`
    do
        export PATH="$HOME/.anyenv/envs/$D/shims:$PATH"
    done
fi

# 補完機能追加
autoload -U compinit
compinit

# 環境変数
export LANG=ja_JP.UTF-8
export EDITOR=nano
# export EDITOR='emacsclient -nw'
export JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8
export JSTESTDRIVER_HOME=~/bin
export ARDUINO_DIR=/Applications/Arduino.app/Contents/Resources/Java
export ARDMK_DIR=/usr/local
# export PYTHONPATH=/usr/local/lib/python2.7/site-packages:$PYTHONPATH
export ANDROID_HOME=/usr/local/opt/android-sdk

export JAVA_HOME=$(/usr/libexec/java_home -v 1.7)

# alias
# alias ls='ls --color=auto'
alias ls='ls -G'
#alias ll='ls -alFG'
alias ll='ls -lFG'
alias lla='ls -alFG'
alias la='ls -AG'
alias l='ls -CFG'

alias rm="rm -i"
alias cp="cp -i"
alias mv="mv -i"

# alias emacs='/Applications/Emacs.app/Contents/MacOS/Emacs'
# alias E='/Applications/Emacs.app/Contents/MacOS/bin/emacsclient -c'
# alias kill-emacs="/Applications/Emacs.app/Contents/MacOS/bin/emacsclient -e '(kill-emacs)'"

alias ctags-jp="/Users/toku345/bin/bin/ctags"

alias grep="grep --color=auto"

alias be='bundle exec'

function gi() { curl https://www.gitignore.io/api/$@ ;} # -> .gitconfig でもgitのサブコマンドとして設定中!
function git() { hub "$@" }

alias gs='git status '
alias ga='git add '
alias gb='git branch '
alias gc='git commit'
alias gd='git diff'
alias go='git checkout '
alias gk='gitk --all&'
# alias gx='gitx --all'
alias gh='git hist'

alias r='bin/rails'
alias gu='bundle exec guard'

fpath=(/usr/local/share/zsh-completions $fpath)

export PATH="$(brew --prefix homebrew/php/php55)/bin:$PATH"

# --- zsh Customize --- #

## 履歴の共有化
HISTFILE=$HOME/.zsh-history # 履歴の保存先
HISTSIZE=100000             # メモリに展開する履歴の数
SAVEHIST=100000             # 保存する履歴の数
setopt share_history        # 同一ホストで動いているzshで履歴を共有

## ディレクトスタックを保存
setopt auto_pushd

## 補完機能をカーソルで選択可能に
zstyle ':completion:*:default' menu select=1

## コマンドのスペルチェック
setopt correct

# # vcs_infoロード
# autoload -Uz vcs_info
# # PROMPT変数内で変数参照する
# setopt prompt_subst

# # vcsの表示
# zstyle ':vcs_info:*' formats '%s][* %F{green}%b%f'
# zstyle ':vcs_info:*' actionformats '%s][* %F{green}%b%f(%F{red}%a%f)'
# # プロンプト表示直前にvcs_info呼び出し
# precmd() { vcs_info }
# # プロンプト表示
# # PROMPT='[${vcs_info_msg_0_}]:%~/%f '
# # PROMPT='%~%f ${vcs_info_msg_0_}: '
# PROMPT='[${vcs_info_msg_0_}]:%f '

autoload -Uz vcs_info
zstyle ':vcs_info:*' enable git svn
zstyle ':vcs_info:*' max-exports 6 # formatに入る変数の最大数
zstyle ':vcs_info:git:*' check-for-changes true
zstyle ':vcs_info:git:*' formats '%b@%r' '%c' '%u'
zstyle ':vcs_info:git:*' actionformats '%b@%r|%a' '%c' '%u'
setopt prompt_subst
function vcs_echo {
    local st branch color
    STY= LANG=en_US.UTF-8 vcs_info
    st=`git status 2> /dev/null`
    if [[ -z "$st" ]]; then return; fi
    branch="$vcs_info_msg_0_"
    if   [[ -n "$vcs_info_msg_1_" ]]; then color=${fg[green]} #staged
    elif [[ -n "$vcs_info_msg_2_" ]]; then color=${fg[red]} #unstaged
    elif [[ -n `echo "$st" | grep "^Untracked"` ]]; then color=${fg[blue]} # untracked
    else color=${fg[cyan]}
    fi
    echo "%{$color%}(%{$branch%})%{$reset_color%}" | sed -e s/@/"%F{yellow}@%f%{$color%}"/
}
PROMPT='
%F{yellow}[%~]%f `vcs_echo`
%(?.$.%F{red}$%f) '
### Added by the Heroku Toolbelt
export PATH="/usr/local/heroku/bin:$PATH"

