#!/bin/bash

set -e  # Exit on error

echo "🚀 Starting bootstrap setup..."

# 1. Set up history search/autocomplete using arrow keys
echo "📜 Setting up history search with arrow keys..."

# Detect shell
SHELL_NAME=$(basename "$SHELL")

if [ "$SHELL_NAME" = "zsh" ]; then
    # Zsh configuration
    ZSH_RC="$HOME/.zshrc"
    
    # Check if configuration already exists
    if ! grep -q "# Bootstrap: History search with arrow keys" "$ZSH_RC" 2>/dev/null; then
        cat >> "$ZSH_RC" << 'EOF'

# Bootstrap: History search with arrow keys
# Search history with up/down arrows
autoload -U up-line-or-beginning-search
autoload -U down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey "^[[A" up-line-or-beginning-search   # Up arrow
bindkey "^[[B" down-line-or-beginning-search # Down arrow

# Enable history search
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_IGNORE_SPACE
EOF
        echo "✅ Zsh history search configured in ~/.zshrc"
    else
        echo "ℹ️  Zsh history search already configured"
    fi
elif [ "$SHELL_NAME" = "bash" ]; then
    # Bash configuration
    BASH_RC="$HOME/.bashrc"
    if [ ! -f "$BASH_RC" ]; then
        BASH_RC="$HOME/.bash_profile"
    fi
    
    # Check if configuration already exists
    if ! grep -q "# Bootstrap: History search with arrow keys" "$BASH_RC" 2>/dev/null; then
        cat >> "$BASH_RC" << 'EOF'

# Bootstrap: History search with arrow keys
# Search history with up/down arrows
bind '"\e[A": history-search-backward'   # Up arrow
bind '"\e[B": history-search-forward'    # Down arrow

# Enable history
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoredups:erasedups
shopt -s histappend
EOF
        echo "✅ Bash history search configured in $BASH_RC"
    else
        echo "ℹ️  Bash history search already configured"
    fi
else
    echo "⚠️  Unsupported shell: $SHELL_NAME. Skipping history search setup."
fi

# 2. Set up SSH public key
echo "🔑 Setting up SSH public key..."

SSH_DIR="$HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCKcJnbrvAWsq1X5rqQaAsIvgEKTeOlMqLBPOYZqNXc5CYRwPmyPC+wxb0leADhRgcuB1nB+gk5JCiBk4X+IK54h6mSmPyRBbALyt7l5FYjVrFsPXxmrRLHgQTR2ewz4xRXBpWKWHyA4Gri0ewiF3FDopLAZJraVRZz3ORgxRqmJi1QeadO/qM99EdU6AzIQFplcEwPVmTckG3QRKKO25n304tA6UDIV9lOjGKlBva8t48QQdA2Rn6E8yXqWsXtJH0fkMBatQGKbIf4Ia9tFqiCTaL+zX8PaIqNo+JhlkI8Jpb3nx3zkRppydaOZ7EmYlQLJyNKf1+00r33cx7O0IFN guntanis"

# Create .ssh directory if it doesn't exist
if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    echo "✅ Created ~/.ssh directory"
fi

# Add public key to authorized_keys if it doesn't already exist
if [ ! -f "$AUTHORIZED_KEYS" ]; then
    touch "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
fi

# Check if key already exists
if grep -q "guntanis" "$AUTHORIZED_KEYS" 2>/dev/null; then
    echo "ℹ️  SSH public key already exists in authorized_keys"
else
    echo "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    echo "✅ SSH public key added to ~/.ssh/authorized_keys"
fi

# 3. Set vim as default editor on Debian/Ubuntu
echo "📝 Setting up default editor..."

# Detect Debian/Ubuntu
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ]; then
        echo "   Detected $PRETTY_NAME"
        
        # Check if vim is installed
        if command -v vim >/dev/null 2>&1; then
            # Set vim as default editor using update-alternatives (requires sudo)
            if command -v update-alternatives >/dev/null 2>&1; then
                if [ "$EUID" -eq 0 ]; then
                    # Running as root
                    update-alternatives --set editor /usr/bin/vim.basic 2>/dev/null || \
                    update-alternatives --set editor /usr/bin/vim 2>/dev/null || \
                    echo "⚠️  Could not set vim via update-alternatives (may need to configure manually)"
                    echo "✅ Vim set as default editor via update-alternatives"
                else
                    # Not running as root, try with sudo
                    if sudo -n true 2>/dev/null; then
                        sudo update-alternatives --set editor /usr/bin/vim.basic 2>/dev/null || \
                        sudo update-alternatives --set editor /usr/bin/vim 2>/dev/null || \
                        echo "⚠️  Could not set vim via update-alternatives (may need sudo password)"
                        echo "✅ Vim set as default editor via update-alternatives"
                    else
                        echo "⚠️  Need sudo to set system-wide default editor"
                        echo "   Run: sudo update-alternatives --set editor /usr/bin/vim.basic"
                    fi
                fi
            fi
            
            # Set EDITOR and VISUAL in shell config (works without sudo)
            if [ "$SHELL_NAME" = "zsh" ]; then
                if ! grep -q "# Bootstrap: Set vim as default editor" "$ZSH_RC" 2>/dev/null; then
                    cat >> "$ZSH_RC" << 'EOF'

# Bootstrap: Set vim as default editor
export EDITOR=vim
export VISUAL=vim
EOF
                    echo "✅ EDITOR and VISUAL set to vim in ~/.zshrc"
                fi
            elif [ "$SHELL_NAME" = "bash" ]; then
                if ! grep -q "# Bootstrap: Set vim as default editor" "$BASH_RC" 2>/dev/null; then
                    cat >> "$BASH_RC" << 'EOF'

# Bootstrap: Set vim as default editor
export EDITOR=vim
export VISUAL=vim
EOF
                    echo "✅ EDITOR and VISUAL set to vim in $BASH_RC"
                fi
            fi
        else
            echo "⚠️  Vim is not installed. Install with: sudo apt-get install vim"
        fi
    else
        echo "ℹ️  Not Debian/Ubuntu, skipping default editor setup"
    fi
    else
        echo "ℹ️  Could not detect OS, skipping default editor setup"
    fi

# 4. Set passwordless sudo for sudo group on Debian/Ubuntu
echo "🔐 Setting up passwordless sudo for sudo group..."

# Detect Debian/Ubuntu
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ]; then
        # Check if user is in sudo group
        if groups | grep -q "\bsudo\b" || [ "$EUID" -eq 0 ]; then
            SUDOERS_FILE="/etc/sudoers.d/99-passwordless-sudo"
            
            # Check if already configured
            if [ -f "$SUDOERS_FILE" ] && grep -q "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" "$SUDOERS_FILE" 2>/dev/null; then
                echo "ℹ️  Passwordless sudo already configured"
            else
                # Create sudoers file
                SUDOERS_CONTENT="%sudo ALL=(ALL:ALL) NOPASSWD: ALL"
                
                if [ "$EUID" -eq 0 ]; then
                    # Running as root
                    echo "$SUDOERS_CONTENT" > "$SUDOERS_FILE"
                    chmod 440 "$SUDOERS_FILE"
                    echo "✅ Passwordless sudo configured for sudo group"
                else
                    # Need sudo to create the file
                    if sudo -n true 2>/dev/null; then
                        echo "$SUDOERS_CONTENT" | sudo tee "$SUDOERS_FILE" > /dev/null
                        sudo chmod 440 "$SUDOERS_FILE"
                        echo "✅ Passwordless sudo configured for sudo group"
                    else
                        echo "⚠️  Need sudo to configure passwordless sudo"
                        echo "   Run: echo '$SUDOERS_CONTENT' | sudo tee $SUDOERS_FILE"
                        echo "   Then: sudo chmod 440 $SUDOERS_FILE"
                    fi
                fi
            fi
        else
            echo "ℹ️  Current user is not in sudo group, skipping passwordless sudo setup"
        fi
    else
        echo "ℹ️  Not Debian/Ubuntu, skipping passwordless sudo setup"
    fi
else
    echo "ℹ️  Could not detect OS, skipping passwordless sudo setup"
fi

echo ""
echo "✨ Bootstrap complete!"
echo ""
echo "📝 Next steps:"
echo "   - Restart your terminal or run: source ~/.${SHELL_NAME}rc"
echo "   - Test history search by pressing Up/Down arrows after typing a command"
echo "   - Your SSH key is ready to use"

