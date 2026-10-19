#!/usr/bin/env bash
# ==============================================================================
# Fedora Workstation Automated Setup
# ==============================================================================
# Single-file installer for Fedora Workstation.
#
# Flags (Environment variables or CLI arguments):
#   DEVELOPMENT=1 | --dev | --development   Install developer toolchains & config
#   GAMING=1      | --gaming                Install Steam & gaming flatpaks
#   --all                                   Install Core + Development + Gaming
#
# Usage:
#   Local:
#     ./setup.sh                       # Core only
#     ./setup.sh --dev                 # Core + Development
#     ./setup.sh --gaming              # Core + Gaming
#     ./setup.sh --all                 # Core + Development + Gaming
#     DEVELOPMENT=1 GAMING=1 ./setup.sh
#
#   Remote (via curl):
#     bash <(curl -fsSL https://raw.githubusercontent.com/gvrDev/fedora-setup/main/setup.sh) --dev
# ==============================================================================

set -euo pipefail

# ==============================================================================
# 1. HELPERS & FLAG PARSING
# ==============================================================================

log() {
    printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"
}

warn() {
    printf '\n\033[1;33m[!] WARNING:\033[0m %s\n' "$1"
}

is_true() {
    local val="${1,,}"
    [[ "$val" == "1" || "$val" == "true" || "$val" == "yes" || "$val" == "y" ]]
}

# Read input safely even when script is piped via curl
prompt_input() {
    local prompt_msg="$1"
    local var_name="$2"
    local default_val="${3:-}"
    local val=""

    if [[ -t 0 ]]; then
        read -rp "$prompt_msg" val
    elif [[ -e /dev/tty ]]; then
        read -rp "$prompt_msg" val < /dev/tty
    fi

    if [[ -z "$val" && -n "$default_val" ]]; then
        val="$default_val"
    fi
    printf -v "$var_name" '%s' "$val"
}

prompt_secret() {
    local prompt_msg="$1"
    local var_name="$2"
    local val=""

    if [[ -t 0 ]]; then
        read -rsp "$prompt_msg" val
        echo
    elif [[ -e /dev/tty ]]; then
        read -rsp "$prompt_msg" val < /dev/tty
        echo
    fi
    printf -v "$var_name" '%s' "$val"
}

# Initialize flags from environment variables (default: false)
DEVELOPMENT="${DEVELOPMENT:-false}"
GAMING="${GAMING:-false}"

# Parse CLI arguments (override environment variables)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev|--development)
            DEVELOPMENT="true"
            shift
            ;;
        --gaming)
            GAMING="true"
            shift
            ;;
        --all)
            DEVELOPMENT="true"
            GAMING="true"
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --dev, --development   Include developer tools, runtimes, git config & SSH
  --gaming               Include Steam, game launchers & gaming flatpaks
  --all                  Include all configurations (Core, Dev, Gaming)
  -h, --help             Show this help message

Environment variables:
  DEVELOPMENT=1|true     Enable development tools
  GAMING=1|true          Enable gaming tools
EOF
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            shift
            ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this script as root." >&2
    exit 1
fi

# ==============================================================================
# 2. SUDO AUTHENTICATION & KEEPALIVE
# ==============================================================================

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

# ==============================================================================
# 3. CORE: DNF CONFIGURATION & REPOSITORIES
# ==============================================================================

log "(core) Configuring DNF"
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

log "(core) Updating system"
sudo dnf upgrade -y

log "(core) Enabling repositories"
# OpenH264
sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

# RPM Fusion (Free & Nonfree)
if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    sudo dnf install -y \
        https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
fi

if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
    sudo dnf install -y \
        https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
fi

# Flatpak Flathub
sudo dnf install -y flatpak
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Enable NVIDIA repo if GPU is detected
# Checks sysfs PCI vendor ID 0x10de natively (doesn't require pciutils pre-installed) or lspci
NVIDIA_DETECTED=false
NVIDIA_NEED_REBOOT=false
if grep -qs "0x10de" /sys/bus/pci/devices/*/vendor 2>/dev/null || \
   (command -v lspci >/dev/null 2>&1 && lspci | grep -iE 'vga|3d|nvidia' | grep -iq 'nvidia'); then
    NVIDIA_DETECTED=true
    log "(core) NVIDIA GPU detected, ensuring driver repository is enabled"
    if dnf repolist all 2>/dev/null | grep -q 'rpmfusion-nonfree-nvidia-driver'; then
        sudo dnf config-manager setopt rpmfusion-nonfree-nvidia-driver.enabled=1 2>/dev/null || true
    fi
    # Enable rpmfusion-nonfree-tainted for akmod-nvidia-open
    if ! rpm -q rpmfusion-nonfree-release-tainted >/dev/null 2>&1; then
        sudo dnf install -y rpmfusion-nonfree-release-tainted
    fi
fi
sudo dnf makecache

# ==============================================================================
# 4. PACKAGE SELECTION & INSTALLATION
# ==============================================================================

# Core utilities and Wayland desktop environment
PACKAGES=(
    pciutils
    wl-clipboard
    xdg-desktop-portal-gnome
    brightnessctl
    playerctl
    wireplumber
    curl
    wget
    tar
    gzip
    bzip2
    xz
    unzip
    zip
    fuse
    fuse-libs
    fuse3
    lsof
    pkg-config
    openssl
    openssl-devel
    ca-certificates
    chromium
    niri
    dms
    acl
    gnome-keyring-pam
)
# NVIDIA proprietary drivers
if [[ "$NVIDIA_DETECTED" == "true" ]]; then
    PACKAGES+=(
        akmod-nvidia-open
        xorg-x11-drv-nvidia-cuda
        xorg-x11-drv-nvidia-libs.i686
        libva-nvidia-driver
        libva-utils
    )
    # xorg-x11-drv-nvidia-power (nvidia-powerd) is strictly for laptops with Dynamic Boost (Max-Q)
    if [[ "$(hostnamectl chassis 2>/dev/null)" =~ ^(laptop|convertible|tablet)$ ]]; then
        PACKAGES+=( xorg-x11-drv-nvidia-power )
    fi
fi

# Development packages
if is_true "$DEVELOPMENT"; then
    PACKAGES+=(
        @development-tools
        tmux
        clang
        clang-devel
        clang-tools-extra
        fastfetch
        tree
        procs
        cmake
        ninja-build
        podman
        podman-machine
        podman-compose
        kitty
        zsh
        git
        gh
        neovim
        tree-sitter-cli
        fira-code-fonts
        btop
    )
fi

# Gaming packages
if is_true "$GAMING"; then
    PACKAGES+=(
        steam
    )
fi

log "Installing DNF packages"
# Exclude nodejs RPMs to keep neovim/tree-sitter-cli from pulling in system Node 22 (managed by mise)
sudo dnf install -y --exclude='nodejs*,ripgrep' "${PACKAGES[@]}"

# ==============================================================================
# 5. CORE: MULTIMEDIA CODECS & DESKTOP FLATPAKS
# ==============================================================================

log "(core) Installing multimedia codecs"
sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
# Modern DNF5 / RPM Fusion multimedia group installation
sudo dnf install -y @multimedia \
    --setopt=install_weak_deps=false \
    --exclude=PackageKit-gstreamer-plugin,libheif-freeworld \
    --allowerasing

log "(core) Installing core Flatpak applications"
CORE_FLATPAKS=(
    org.mozilla.thunderbird
    com.brave.Browser
)
flatpak install -y --noninteractive flathub "${CORE_FLATPAKS[@]}"

# If NVIDIA GPU is detected, ensure matching Flatpak GL runtimes are installed
if [[ "$NVIDIA_DETECTED" == "true" ]]; then
    NVIDIA_VER="$(modinfo -F version nvidia 2>/dev/null || cat /sys/module/nvidia/version 2>/dev/null || rpm -q --qf '%{VERSION}' xorg-x11-drv-nvidia 2>/dev/null || true)"
    if [[ -n "$NVIDIA_VER" ]]; then
        NVIDIA_FLATPAK_TAG="${NVIDIA_VER//./-}"
        for ext in "org.freedesktop.Platform.GL.nvidia-$NVIDIA_FLATPAK_TAG" "org.freedesktop.Platform.GL32.nvidia-$NVIDIA_FLATPAK_TAG"; do
            if ! flatpak info "$ext" >/dev/null 2>&1; then
                log "(core) Installing Flatpak NVIDIA GL runtime: $ext"
                flatpak install -y --noninteractive flathub "$ext" 2>/dev/null || true
            fi
        done
    fi
fi

# Configure hardware acceleration & Wayland VSync flags for Flatpak Brave
BRAVE_CONFIG_DIR="$HOME/.var/app/com.brave.Browser/config"
BRAVE_FLAGS_FILE="$BRAVE_CONFIG_DIR/brave-flags.conf"
mkdir -p "$BRAVE_CONFIG_DIR"
if [[ ! -f "$BRAVE_FLAGS_FILE" ]] || ! grep -q "enable-gpu-rasterization" "$BRAVE_FLAGS_FILE" 2>/dev/null; then
    log "(core) Configuring Brave Wayland & GPU rasterization flags"
    cat > "$BRAVE_FLAGS_FILE" <<'EOF'
--ozone-platform-hint=auto
--ignore-gpu-blocklist
--enable-gpu-rasterization
--enable-zero-copy
--enable-features=VaapiVideoDecodeLinuxGL,VaapiVideoDecoder,CanvasOopRasterization
EOF
fi

# Core systemd services
systemctl --user add-wants niri.service dms

log "(core) Configuring TTY1 autologin & auto-starting Niri"
ACTUAL_USER="${SUDO_USER:-$USER}"

sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\\\u' --noclear --autologin $ACTUAL_USER %I \$TERM
Type=idle
EOF

# Disable graphical display managers in favor of direct TTY1 autologin
sudo systemctl disable gdm.service greetd.service 2>/dev/null || true

# Idempotently configure ~/.bash_profile to launch Niri on TTY1
BASH_PROFILE="$HOME/.bash_profile"
touch "$BASH_PROFILE"
if ! grep -q "niri-session" "$BASH_PROFILE"; then
    cat >> "$BASH_PROFILE" <<'EOF'

# Auto-start Niri on TTY1 login
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    if ! systemctl --user -q is-active niri.service; then
        exec niri-session -l
    fi
fi
EOF
else
    # Update legacy 'exec niri-session' without -l to prevent login loop
    sed -i -E 's/exec niri-session([[:space:]]*)$/exec niri-session -l/' "$BASH_PROFILE"
fi

log "(core) Setting up passwordless default keyring"
KEYRING_DIR="$HOME/.local/share/keyrings"
KEYRING_FILE="$KEYRING_DIR/Default_keyring.keyring"
DEFAULT_FILE="$KEYRING_DIR/default"

mkdir -p "$KEYRING_DIR"

if [[ ! -f "$KEYRING_FILE" ]]; then
    cat > "$KEYRING_FILE" <<EOF
[keyring]
display-name=Default keyring
ctime=$(date +%s)
mtime=0
lock-on-idle=false
lock-after=false
EOF
fi

if [[ ! -f "$DEFAULT_FILE" ]]; then
    cat > "$DEFAULT_FILE" <<EOF
Default_keyring
EOF
fi

chmod 700 "$KEYRING_DIR"
chmod 600 "$KEYRING_FILE"
chmod 644 "$DEFAULT_FILE"

log "(core) Installing phinger-cursors theme"
ICONS_DIR="$HOME/.local/share/icons"
mkdir -p "$ICONS_DIR"
if [[ ! -d "$ICONS_DIR/phinger-cursors-dark" || ! -d "$ICONS_DIR/phinger-cursors-light" ]]; then
    wget -cO- https://github.com/phisch/phinger-cursors/releases/latest/download/phinger-cursors-variants.tar.bz2 | tar xfj - -C "$ICONS_DIR"
fi

# NVIDIA post-install configuration
if [[ "$NVIDIA_DETECTED" == "true" ]]; then
    log "(core) Configuring NVIDIA power management & kernel modules"
    for svc in nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service; do
        if ! systemctl is-enabled "$svc" >/dev/null 2>&1; then
            sudo systemctl enable "$svc" 2>/dev/null || true
        fi
    done

    # Manage nvidia-powerd: only enable on laptops, disable on desktops to avoid errors
    if [[ "$(hostnamectl chassis 2>/dev/null)" =~ ^(laptop|convertible|tablet)$ ]]; then
        if ! systemctl is-enabled nvidia-powerd.service >/dev/null 2>&1; then
            sudo systemctl enable nvidia-powerd.service 2>/dev/null || true
        fi
    elif systemctl is-enabled nvidia-powerd.service >/dev/null 2>&1; then
        sudo systemctl disable --now nvidia-powerd.service 2>/dev/null || true
    fi

    # Protect akmod-nvidia-open from accidental dnf autoremove cleanup (DNF5 & DNF4)
    sudo dnf mark user akmod-nvidia-open 2>/dev/null || sudo dnf mark install akmod-nvidia-open 2>/dev/null || true

    # Fix high VRAM usage leak on niri with NVIDIA drivers (official niri recommendation)
    NVIDIA_APP_PROFILE="/etc/nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json"
    if [[ ! -f "$NVIDIA_APP_PROFILE" ]]; then
        sudo mkdir -p "$(dirname "$NVIDIA_APP_PROFILE")"
        sudo tee "$NVIDIA_APP_PROFILE" >/dev/null <<'JSON'
{
    "rules": [
        {
            "pattern": {
                "feature": "procname",
                "matches": "niri"
            },
            "profile": "Limit Free Buffer Pool On Wayland Compositors"
        }
    ],
    "profiles": [
        {
            "name": "Limit Free Buffer Pool On Wayland Compositors",
            "settings": [
                {
                    "key": "GLVidHeapReuseRatio",
                    "value": 0
                }
            ]
        }
    ]
}
JSON
    fi

    # Only build kernel modules if they are not already built for the current kernel
    KERNEL_VER="$(uname -r)"
    if ! modinfo -k "$KERNEL_VER" nvidia >/dev/null 2>&1 && ! modinfo -k "$KERNEL_VER" nvidia-open >/dev/null 2>&1; then
        log "(core) Compiling NVIDIA kernel modules for kernel $KERNEL_VER"
        sudo akmods --kernels "$KERNEL_VER"
        NVIDIA_NEED_REBOOT=true
    else
        log "(core) NVIDIA kernel modules already present for $KERNEL_VER - skipping rebuild"
    fi
fi

log "(core) Configuring Bluetooth in initramfs for LUKS unlock"
sudo mkdir -p /etc/dracut.conf.d
sudo tee /etc/dracut.conf.d/bt.conf >/dev/null <<'EOF'
add_dracutmodules+=" bluetooth "
EOF

log "(core) Rebuilding initramfs with dracut"
sudo dracut --force

# ==============================================================================
# 6. DEVELOPMENT: TOOLCHAINS, GIT & SSH (IF ENABLED)
# ==============================================================================

if is_true "$DEVELOPMENT"; then
    log "(development) Setting up dev-utils"
    mkdir -p "$HOME/dev-utils"
    if [[ ! -f "$HOME/dev-utils/global-bundle.pem" ]]; then
        curl -sS "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem" > "$HOME/dev-utils/global-bundle.pem"
    fi

    log "(development) Installing AWS Session Manager plugin"
    if ! command -v session-manager-plugin >/dev/null 2>&1; then
        case "$(uname -m)" in
            x86_64)  sudo dnf install -y "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" ;;
            aarch64) sudo dnf install -y "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_arm64/session-manager-plugin.rpm" ;;
        esac
    fi

    log "(development) Setting up mise (runtime & tool version manager)"
    if ! command -v mise >/dev/null 2>&1; then
        curl https://mise.run | sh
    fi

    ~/.local/bin/mise settings set go.set_gobin false
    ~/.local/bin/mise set -g GOBIN="$HOME/.local/bin"

    log "(development) Installing mise tools & runtimes"
    MISE_PACKAGES=(
        go
        rust@stable
        odin
        pipx
        postgres
        # JavaScript / Node
        node@lts
        yarn
        pnpm
        bun
        nub
        # CLI Utilities
        ripgrep
        ast-grep
        fzf
        fd
        chezmoi
        just
        jq
        yq
        mongosh
        shellcheck
        semgrep
        betterleaks
        hyperfine
        eza
        bat
        zoxide
        duf
        dust
        bottom
        awscli
        delta
        atuin
        # TUI
        lazygit
        opencode
        github:can1357/oh-my-pi
        cargo:raine/workmux
    )
    ~/.local/bin/mise use --jobs 6 -g "${MISE_PACKAGES[@]}"

    log "(development) Configuring SSH keys & GitHub integration"
    SSH_KEY_GITHUB="$HOME/.ssh/github"
    SSH_KEY_SKEY="$HOME/.ssh/skey"
    SSH_KEYS_EXIST=false

    if [[ -f "$SSH_KEY_GITHUB" && -f "$SSH_KEY_SKEY" ]]; then
        SSH_KEYS_EXIST=true
        log "(development) Existing SSH keys detected (~/.ssh/github, ~/.ssh/skey) - skipping key creation & prompts"
    fi

    # Auto-resolve or prompt for GitHub username
    FEDORA_SCRIPT_GITHUB_USER="${FEDORA_SCRIPT_GITHUB_USER:-${FEDORA_SCRIPT_SSH_USERNAME:-}}"
    if [[ -z "${FEDORA_SCRIPT_GITHUB_USER:-}" ]]; then
        FEDORA_SCRIPT_GITHUB_USER="$(gh api user -q .login 2>/dev/null || true)"
    fi

    if ! $SSH_KEYS_EXIST; then
        if [[ -z "${FEDORA_SCRIPT_GITHUB_USER:-}" ]]; then
            prompt_input "GitHub username: " FEDORA_SCRIPT_GITHUB_USER
        fi
        if [[ -z "${FEDORA_SCRIPT_GIT_NAME:-}" ]]; then
            DEFAULT_GIT_NAME="${FEDORA_SCRIPT_GITHUB_USER:-$(git config --global user.name 2>/dev/null || true)}"
            prompt_input "Git author name [${DEFAULT_GIT_NAME}]: " FEDORA_SCRIPT_GIT_NAME "$DEFAULT_GIT_NAME"
        fi
        if [[ -z "${FEDORA_SCRIPT_SSH_EMAIL:-}" ]]; then
            DEFAULT_SSH_EMAIL="$(git config --global user.email 2>/dev/null || true)"
            prompt_input "SSH & Git email [${DEFAULT_SSH_EMAIL}]: " FEDORA_SCRIPT_SSH_EMAIL "$DEFAULT_SSH_EMAIL"
        fi
        if [[ -z "${FEDORA_SCRIPT_SSH_PASSPHRASE:-}" ]]; then
            prompt_secret "SSH key passphrase (leave empty for none): " FEDORA_SCRIPT_SSH_PASSPHRASE
        fi
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
    AddKeysToAgent 8h
    StrictHostKeyChecking accept-new
EOF
    fi

    if ! $SSH_KEYS_EXIST; then
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

        generate_ssh_key "$SSH_KEY_GITHUB"
        generate_ssh_key "$SSH_KEY_SKEY"
    fi

    # Ensure public keys exist if private keys are present
    if [[ -f "$SSH_KEY_GITHUB" && ! -f "$SSH_KEY_GITHUB.pub" ]]; then
        ssh-keygen -y -f "$SSH_KEY_GITHUB" > "$SSH_KEY_GITHUB.pub"
    fi
    if [[ -f "$SSH_KEY_SKEY" && ! -f "$SSH_KEY_SKEY.pub" ]]; then
        ssh-keygen -y -f "$SSH_KEY_SKEY" > "$SSH_KEY_SKEY.pub"
    fi

    log "(development) Configuring global .gitconfig"
    if [[ -n "${FEDORA_SCRIPT_GIT_NAME:-}" ]]; then
        git config --global user.name "$FEDORA_SCRIPT_GIT_NAME"
    fi
    if [[ -n "${FEDORA_SCRIPT_SSH_EMAIL:-}" ]]; then
        git config --global user.email "$FEDORA_SCRIPT_SSH_EMAIL"
    fi
    if [[ -f "$SSH_KEY_SKEY.pub" ]]; then
        git config --global gpg.format ssh
        git config --global user.signingkey "$SSH_KEY_SKEY.pub"
        git config --global commit.gpgsign true
        git config --global tag.gpgsign true
    fi
    git config --global core.editor nvim
    git config --global core.pager delta
    git config --global interactive.diffFilter 'delta --color-only'
    git config --global delta.navigate true
    git config --global delta.dark true
    git config --global merge.conflictStyle zdiff3
    git config --global diff.algorithm histogram
    git config --global diff.colorMoved default
    git config --global diff.mnemonicPrefix true
    git config --global rerere.enabled true
    git config --global rerere.autoupdate true

    log "(development) Enabling systemd SSH agent and session environment"
    systemctl --user enable --now ssh-agent.socket
    export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"

    mkdir -p "$HOME/.config/environment.d"
    cat > "$HOME/.config/environment.d/10-ssh-agent.conf" <<'EOF'
SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"
EOF

    is_key_in_agent() {
        local pubkey="$1"
        [[ -f "$pubkey" ]] || return 1
        local fp
        fp="$(ssh-keygen -lf "$pubkey" 2>/dev/null | awk '{print $2}')"
        [[ -n "$fp" ]] && ssh-add -l 2>/dev/null | grep -qF "$fp"
    }

    log "(development) Adding keys to SSH Agent (8h lifetime)"
    if [[ -n "${FEDORA_SCRIPT_SSH_PASSPHRASE:-}" ]]; then
        askpass="$(mktemp)"
        chmod 700 "$askpass"
        cat >"$askpass" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$FEDORA_SCRIPT_SSH_PASSPHRASE"
EOF
        SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 ssh-add -t 8h "$SSH_KEY_GITHUB" 2>/dev/null || true
        SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 ssh-add -t 8h "$SSH_KEY_SKEY" 2>/dev/null || true
        rm -f "$askpass"
    else
        if ! is_key_in_agent "$SSH_KEY_GITHUB.pub"; then
            ssh-add -t 8h "$SSH_KEY_GITHUB" 2>/dev/null || true
        fi
        if ! is_key_in_agent "$SSH_KEY_SKEY.pub"; then
            ssh-add -t 8h "$SSH_KEY_SKEY" 2>/dev/null || true
        fi
    fi

    log "(development) Authenticating GitHub CLI"
    if ! gh auth status 2>&1 | grep -qE "admin:public_key|admin:ssh_signing_key"; then
        gh auth login --web --skip-ssh-key --git-protocol ssh --hostname github.com --clipboard -s admin:public_key,admin:ssh_signing_key
    fi

    log "(development) Uploading GitHub SSH keys"
    HOST_TAG="${HOSTNAME:-$(uname -n)}"

    upload_ssh_key() {
        local key_path="$1"
        local title="$2"
        local type="$3"

        if [[ ! -f "$key_path" ]]; then
            warn "Key file not found: $key_path"
            return 0
        fi

        # Check by title
        if gh ssh-key list 2>/dev/null | grep -qF "$title"; then
            echo "Key '$title' already exists on GitHub, skipping."
            return 0
        fi

        # Check by key content to avoid duplicate key errors
        local key_body
        key_body="$(awk '{print $2}' "$key_path")"
        if [[ -n "$key_body" ]] && gh ssh-key list 2>/dev/null | grep -qF "$key_body"; then
            echo "Key from '$key_path' is already registered on GitHub, skipping."
            return 0
        fi

        if ! gh ssh-key add "$key_path" --title "$title" --type "$type"; then
            echo "Warning: Could not add key '$title' to GitHub (it may already be registered)."
        fi
    }

    upload_ssh_key "$SSH_KEY_GITHUB.pub" "$HOST_TAG-github" "authentication"
    upload_ssh_key "$SSH_KEY_SKEY.pub" "$HOST_TAG-signing" "signing"

    log "(development) Setting up antidote (zsh plugin manager)"
    ANTIDOTE_DIR="${ZDOTDIR:-$HOME}/.antidote"
    if [[ ! -d "$ANTIDOTE_DIR" ]]; then
        git clone --depth=1 https://github.com/mattmc3/antidote.git "$ANTIDOTE_DIR"
    fi

    log "(development) Cloning dotfiles via chezmoi"
    if [[ -z "${FEDORA_SCRIPT_GITHUB_USER:-}" ]]; then
        FEDORA_SCRIPT_GITHUB_USER="$(gh api user -q .login 2>/dev/null || true)"
    fi
    if [[ -z "${FEDORA_SCRIPT_GITHUB_USER:-}" ]]; then
        prompt_input "GitHub username for dotfiles: " FEDORA_SCRIPT_GITHUB_USER
    fi

    if [[ -n "${FEDORA_SCRIPT_GITHUB_USER:-}" ]]; then
        if ! ~/.local/bin/mise exec chezmoi@latest -- chezmoi init --apply "git@github.com:$FEDORA_SCRIPT_GITHUB_USER/dotfiles.git"; then
            warn "Failed to clone/apply dotfiles from git@github.com:$FEDORA_SCRIPT_GITHUB_USER/dotfiles.git"
            echo "Verify the repository exists and your SSH key is authorized."
        fi
    else
        warn "No GitHub username specified; skipping chezmoi dotfiles clone."
    fi
fi

# ==============================================================================
# 7. GAMING: FLATPAKS (IF ENABLED)
# ==============================================================================

if is_true "$GAMING"; then
    log "(gaming) Installing gaming Flatpaks"
    GAMING_FLATPAKS=(
        com.heroicgameslauncher.hgl
        com.discordapp.Discord
        com.usebottles.bottles
        com.github.tchx84.Flatseal
        it.mijorus.gearlever
        com.vysp3r.ProtonPlus
        com.github.Matoking.protontricks
    )
    flatpak install -y --noninteractive flathub "${GAMING_FLATPAKS[@]}"
fi

# ==============================================================================
# 8. FINISH
# ==============================================================================

log "Setup Complete!"
echo
echo "Installed components:"
echo "  [x] Core system, Wayland (niri/dms), codecs, and baseline flatpaks"
if is_true "$DEVELOPMENT"; then
    echo "  [x] Development toolchains, runtimes, SSH & Git config"
else
    echo "  [ ] Development toolchains (skipped, run with --dev to install)"
fi
if is_true "$GAMING"; then
    echo "  [x] Steam and gaming flatpaks"
else
    echo "  [ ] Gaming packages (skipped, run with --gaming to install)"
fi
if [[ "$NVIDIA_DETECTED" == "true" ]]; then
    echo "  [x] NVIDIA proprietary drivers and CUDA"
fi

echo
echo "================================================================"
if [[ "$NVIDIA_DETECTED" == "true" ]] && is_true "$NVIDIA_NEED_REBOOT"; then
    echo "⚠️  IMPORTANT: New NVIDIA kernel drivers built. Please reboot your system."
    echo "    Command: sudo reboot"
elif [[ "$NVIDIA_DETECTED" == "true" ]] && ! lsmod | grep -q '^nvidia '; then
    echo "⚠️  IMPORTANT: NVIDIA driver not yet loaded. Please reboot your system."
    echo "    Command: sudo reboot"
else
    echo "Restart your shell or log out/in to apply all changes."
fi
echo "================================================================"
