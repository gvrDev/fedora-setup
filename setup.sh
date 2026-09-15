#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '\n==> %s\n' "$1"
}

if [[ $EUID -eq 0 ]]; then
    echo "Don't run this script as root."
    exit 1
fi

log "Authenticating sudo"
sudo -v

# Keep sudo timestamp updated in background until script exits
while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT INT TERM

log "Configuring DNF"
DNF_CONF="/etc/dnf/dnf.conf"
if [[ ! -f "$DNF_CONF" ]]; then
    sudo mkdir -p "$(dirname "$DNF_CONF")"
    printf '[main]\nmax_parallel_downloads=10\n' | sudo tee "$DNF_CONF" >/dev/null
elif grep -qE '^[[:space:]]*max_parallel_downloads[[:space:]]*=[[:space:]]*10([[:space:]]*$|[[:space:]]+#)' "$DNF_CONF"; then
    : # Already configured
elif grep -qE '^[[:space:]]*max_parallel_downloads[[:space:]]*=' "$DNF_CONF"; then
    sudo sed -i --follow-symlinks -E 's/^[[:space:]]*max_parallel_downloads[[:space:]]*=.*/max_parallel_downloads=10/' "$DNF_CONF"
elif grep -qE '^[[:space:]]*\[main\]' "$DNF_CONF"; then
    sudo sed -i --follow-symlinks -E '/^[[:space:]]*\[main\]/a max_parallel_downloads=10' "$DNF_CONF"
else
    printf '\n[main]\nmax_parallel_downloads=10\n' | sudo tee -a "$DNF_CONF" >/dev/null
fi

log "Updating Fedora"
sudo dnf upgrade -y

log "Installing repositories"
# RPM Fusion
sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1
if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    sudo dnf install -y \
        https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
fi

if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
    sudo dnf install -y \
        https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
fi

#Flatpak
sudo dnf install -y flatpak
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

log "Installing script dependencies"
sudo dnf install -y \
    git \
    curl \
    wget \
    unzip \
    zip \
    jq \
    cmake \
    ninja-build \
    pkg-config \
    openssl \
    openssl-devel \
    shellcheck 

log "Installing development tools"
sudo dnf -y install @development-tools

log "Generating ssh keys"
FEDORA_SCRIPT_GITHUB_USER="${FEDORA_SCRIPT_GITHUB_USER:-${FEDORA_SCRIPT_SSH_USERNAME:-}}"
if [[ -z "${FEDORA_SCRIPT_GITHUB_USER:-}" ]]; then
    read -rp "GitHub username: " FEDORA_SCRIPT_GITHUB_USER
fi
if [[ -z "${FEDORA_SCRIPT_GIT_NAME:-}" ]]; then
    read -rp "Git author name [$FEDORA_SCRIPT_GITHUB_USER]: " FEDORA_SCRIPT_GIT_NAME
    FEDORA_SCRIPT_GIT_NAME="${FEDORA_SCRIPT_GIT_NAME:-$FEDORA_SCRIPT_GITHUB_USER}"
fi
if [[ -z "${FEDORA_SCRIPT_SSH_EMAIL:-}" ]]; then
    read -rp "SSH & Git email: " FEDORA_SCRIPT_SSH_EMAIL
fi
if [[ -z "${FEDORA_SCRIPT_SSH_PASSPHRASE:-}" ]]; then
    read -rsp "SSH key passphrase (empty for none): " FEDORA_SCRIPT_SSH_PASSPHRASE
    echo
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

# Pre-seed GitHub host keys to prevent interactive host verification prompts
if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    ssh-keyscan -t ed25519,rsa github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
    chmod 600 "$HOME/.ssh/known_hosts"
fi

if ! grep -q "Host github.com" "$HOME/.ssh/config"; then
    cat >> "$HOME/.ssh/config" <<EOF

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/github
    IdentitiesOnly yes
    AddKeysToAgent yes
    StrictHostKeyChecking accept-new
EOF
fi

generate_ssh_key() {
    local key_path="$1"

    if [[ -f "$key_path" ]]; then
        echo "Skipping existing key: $key_path"
        return
    fi

    ssh-keygen \
        -t ed25519 \
        -f "$key_path" \
        -C "$FEDORA_SCRIPT_SSH_EMAIL" \
        -N "$FEDORA_SCRIPT_SSH_PASSPHRASE"
}

generate_ssh_key "$HOME/.ssh/github"
generate_ssh_key "$HOME/.ssh/skey"

git config --global user.name "$FEDORA_SCRIPT_GIT_NAME"
git config --global user.email "$FEDORA_SCRIPT_SSH_EMAIL"
git config --global gpg.format ssh
git config --global user.signingkey "$HOME/.ssh/skey.pub"
git config --global commit.gpgsign true

log "Starting SSH Agent and adding keys"

eval "$(ssh-agent -s)" >/dev/null

if [[ -n "${FEDORA_SCRIPT_SSH_PASSPHRASE:-}" ]]; then
    askpass="$(mktemp)"
    chmod 700 "$askpass"

    # Unquote EOF so the passphrase value is written directly into the file
    cat >"$askpass" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$FEDORA_SCRIPT_SSH_PASSPHRASE"
EOF

    trap 'rm -f "$askpass"' EXIT

    SSH_ASKPASS="$askpass" \
    SSH_ASKPASS_REQUIRE=force \
    DISPLAY=:0 \
        ssh-add "$HOME/.ssh/github"

    SSH_ASKPASS="$askpass" \
    SSH_ASKPASS_REQUIRE=force \
    DISPLAY=:0 \
        ssh-add "$HOME/.ssh/skey"
else
    ssh-add "$HOME/.ssh/github"
    ssh-add "$HOME/.ssh/skey"
fi

log "Authenticating GitHub"
sudo dnf install -y gh
if ! gh auth status 2>&1 | grep -qE "admin:public_key|admin:ssh_signing_key"; then
    gh auth login --web --skip-ssh-key --git-protocol ssh --hostname github.com --clipboard -s admin:public_key,admin:ssh_signing_key
fi

log "Uploading GitHub SSH key"
HOST_TAG="${HOSTNAME:-$(uname -n)}"

upload_ssh_key() {
    local key_path="$1"
    local title="$2"
    local type="$3"

    if gh ssh-key list 2>/dev/null | grep -qF "$title"; then
        echo "Key '$title' already exists on GitHub, skipping."
        return 0
    fi

    if ! gh ssh-key add "$key_path" --title "$title" --type "$type"; then
        echo "Warning: Could not add key '$title' to GitHub (it may already be registered)."
    fi
}

upload_ssh_key "$HOME/.ssh/github.pub" "$HOST_TAG-github" "authentication"
upload_ssh_key "$HOME/.ssh/skey.pub" "$HOST_TAG-signing" "signing"

log "Installing desktop tools"
sudo dnf install -y \
    kitty \
    neovim \
    fish \
    chromium
flatpak install -y --noninteractive flathub \
    org.mozilla.thunderbird \
    com.bitwarden.desktop \
    com.brave.Browser


log "Installing CLI tools"
# mise
if ! command -v mise >/dev/null 2>&1; then
    curl https://mise.run | sh
fi

# CLI
~/.local/bin/mise use -g ripgrep@latest
~/.local/bin/mise use -g fzf@latest
~/.local/bin/mise use -g fd@latest
~/.local/bin/mise use -g chezmoi@latest

# JS
~/.local/bin/mise use -g node@lts
~/.local/bin/mise use -g yarn@latest
~/.local/bin/mise use -g pnpm@latest
~/.local/bin/mise use -g bun@latest
~/.local/bin/mise use -g nub@latest

# OTHER
~/.local/bin/mise use -g go@latest
~/.local/bin/mise use -g rust@stable
~/.local/bin/mise use -g odin@latest

log "Cloning dotfiles"
if ! ~/.local/bin/mise exec chezmoi@latest -- chezmoi init --apply "git@github.com:$FEDORA_SCRIPT_GITHUB_USER/dotfiles.git"; then
    echo "Warning: Failed to clone/apply dotfiles from git@github.com:$FEDORA_SCRIPT_GITHUB_USER/dotfiles.git"
    echo "Verify the repository exists and your SSH key is authorized."
fi

log "Installing multimedia codecs"
sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
sudo dnf group upgrade -y multimedia --setopt=install_weak_deps=false --exclude=PackageKit-gstreamer-plugin

log "Setup gaming"
sudo dnf install -y steam
flatpak install -y --noninteractive flathub \
    com.heroicgameslauncher.hgl \
    com.discordapp.Discord \
    com.usebottles.bottles \
    com.github.tchx84.Flatseal \
    it.mijorus.gearlever \
    com.vysp3r.ProtonPlus \
    com.github.Matoking.protontricks

log "Setup Niri and DMS"
sudo dnf copr enable avengemedia/dms
sudo dnf install -y niri dms
systemctl --user add-wants niri.service dms

log "Done"

echo
echo "Fedora setup complete."
echo "Restart your shell or log out/in to apply changes."
