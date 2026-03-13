#!/bin/sh

if [ "$CHEZMOI_OS" = "darwin" ]; then
    # === macOS: Homebrew ===
    brew update
    brew install coreutils git git-secrets git-delta starship fzf eza bat fd ripgrep
    brew install tmux direnv shadowenv asdf age gpg fish nano aspell
    brew install --cask karabiner-elements
    brew install --cask font-fira-code-nerd-font font-fira-mono-nerd-font font-hack-nerd-font

elif [ "$CHEZMOI_OS" = "linux" ]; then
    # === Linux (DGX OS / Ubuntu): apt ===
    sudo apt-get update
    sudo apt-get install -y git tmux fish nano aspell gnupg ripgrep fzf curl wget unzip fontconfig

    # bat (Ubuntuでは batcat としてインストールされる)
    sudo apt-get install -y bat 2>/dev/null || sudo apt-get install -y batcat
    if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
        mkdir -p ~/.local/bin
        ln -sf "$(command -v batcat)" ~/.local/bin/bat
    fi

    # fd-find (Ubuntuでは fdfind としてインストールされる)
    sudo apt-get install -y fd-find
    if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
        mkdir -p ~/.local/bin
        ln -sf "$(command -v fdfind)" ~/.local/bin/fd
    fi

    # starship (公式インストーラ)
    if ! command -v starship >/dev/null 2>&1; then
        curl -sS https://starship.rs/install.sh | sh -s -- --yes
    fi

    # eza (Ubuntu 24.04+は標準リポジトリにある)
    if ! command -v eza >/dev/null 2>&1; then
        sudo apt-get install -y eza 2>/dev/null || {
            sudo mkdir -p /etc/apt/keyrings
            wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
            echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | sudo tee /etc/apt/sources.list.d/gierens.list
            sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
            sudo apt-get update
            sudo apt-get install -y eza
        }
    fi

    # age (暗号化ツール) - 最新版を取得
    if ! command -v age >/dev/null 2>&1; then
        sudo apt-get install -y age 2>/dev/null || {
            AGE_VERSION=$(curl -sL https://api.github.com/repos/FiloSottile/age/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')
            wget -qO /tmp/age.tar.gz "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz"
            sudo tar -xzf /tmp/age.tar.gz -C /usr/local/bin --strip-components=1 age/age age/age-keygen
            rm /tmp/age.tar.gz
        }
    fi

    # git-delta (GitHub Release) - 最新版を取得
    if ! command -v delta >/dev/null 2>&1; then
        DELTA_VERSION=$(curl -sL https://api.github.com/repos/dandavison/delta/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
        wget -qO /tmp/delta.deb "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_amd64.deb"
        sudo dpkg -i /tmp/delta.deb
        rm /tmp/delta.deb
    fi

    # direnv (公式インストーラ)
    if ! command -v direnv >/dev/null 2>&1; then
        curl -sfL https://direnv.net/install.sh | bash
    fi

    # asdf (git clone) - 最新版を取得
    if [ ! -d "$HOME/.asdf" ]; then
        ASDF_VERSION=$(curl -sL https://api.github.com/repos/asdf-vm/asdf/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
        git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch "$ASDF_VERSION"
    fi

    # Nerd Fonts (デスクトップ利用) - 最新版を取得
    FONT_DIR="$HOME/.local/share/fonts"
    mkdir -p "$FONT_DIR"
    NERD_FONTS_VERSION=$(curl -sL https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    for font in FiraCode FiraMono Hack; do
        if [ ! -f "$FONT_DIR/${font}NerdFont-Regular.ttf" ]; then
            wget -qO /tmp/${font}.zip "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_VERSION}/${font}.zip"
            unzip -qo /tmp/${font}.zip -d "$FONT_DIR"
            rm /tmp/${font}.zip
        fi
    done
    fc-cache -f "$FONT_DIR"
fi
