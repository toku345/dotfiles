# PATH
PATH=$PATH:$HOME/.rvm/bin # Add RVM to PATH for scripting
[[ -s "$HOME/.rvm/scripts/rvm" ]] && . "$HOME/.rvm/scripts/rvm"
#[[ -s "$HOME/.rvm/scripts/rvm" ]] && . "$HOME/.rvm/scripts/rvm"
PATH=/usr/local/bin:$PATH

# PATH=/Applications/Emacs.app/Contents/MacOS/bin:$PATH
# PATH=/Applications/Emacs.app/Contents/MacOS:$PATH

# 補完機能追加
autoload -U compinit
compinit

# 環境変数
export LANG=ja_JP.UTF-8

# alias
#alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

alias emacs='/Applications/Emacs.app/Contents/MacOS/Emacs' 
alias E='/Applications/Emacs.app/Contents/MacOS/bin/emacsclient -c'
alias kill-emacs="/Applications/Emacs.app/Contents/MacOS/bin/emacsclient -e '(kill-emacs)'"