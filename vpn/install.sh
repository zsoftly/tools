#!/bin/bash
# Headscale VPN Setup Script - macOS/Linux
# Usage: HEADSCALE_URL=https://your-headscale-server ./install.sh [john.d] [--key AUTH_KEY]
#
# Required environment variable:
#   HEADSCALE_URL  - URL of your Headscale server
set -e

# Configuration
MAX_DAEMON_WAIT_SECONDS=30
FULL_NAME=""
AUTH_KEY=""

if [ -z "${HEADSCALE_URL:-}" ]; then
    echo "[ERROR] HEADSCALE_URL environment variable is required."
    echo "  Export it before running: export HEADSCALE_URL=https://your-headscale-server"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user|-u)
            FULL_NAME="$2"
            shift 2
            ;;
        --key|-k)
            AUTH_KEY="$2"
            shift 2
            ;;
        *)
            # Accept positional name argument (e.g. john.d)
            if [[ -z "$FULL_NAME" && "$1" != -* ]]; then
                FULL_NAME="$1"
            fi
            shift
            ;;
    esac
done

# Prompt for name if not provided
if [ -z "$FULL_NAME" ]; then
    echo ""
    read -p "Enter your name (e.g. john.d): " FULL_NAME
    echo ""
    if [ -z "$FULL_NAME" ]; then
        error "Name is required to set the device hostname."
    fi
fi

# Detect OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin) HOSTNAME="${FULL_NAME}-mac" ;;
    Linux)  HOSTNAME="${FULL_NAME}-linux" ;;
    *)      HOSTNAME="${FULL_NAME}-device" ;;
esac

info "Detected OS: $OS ($ARCH)"

# macOS requires GUI steps - show instructions and confirm
macos_setup_instructions() {
    echo ""
    echo "============================================================"
    echo "  macOS SETUP INSTRUCTIONS"
    echo "============================================================"
    echo ""
    echo "macOS requires GUI steps to complete setup. Please read carefully:"
    echo ""
    echo "STEP 1: Allow Network Extension"
    echo "  - Follow the prompt to allow Tailscale network extension"
    echo "  - Or go to System Settings > Privacy & Security > scroll down > click 'Allow'"
    echo ""
    echo "STEP 2: Enable CLI (optional but recommended)"
    echo "  - Click Tailscale menu bar icon > Settings"
    echo "  - Go to 'CLI' tab"
    echo "  - Click 'Enable CLI'"
    echo ""
    echo "STEP 3: Connect to VPN"
    echo "  - Hold OPTION key and click the Tailscale menu bar icon"
    echo "  - Click 'Log in to a different tailnet...'"
    echo "  - Enter: $HEADSCALE_URL"
    echo "  - A browser window will open — log in with your company SSO credentials via Authentik."
    echo ""
    echo "STEP 4: Verify"
    echo "  - Click menu bar icon - should show 'Connected'"
    echo "  - If CLI enabled: tailscale status"
    echo ""
    echo "============================================================"
    echo ""
    read -p "Do you understand these instructions? Type 'yes' to continue: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Setup cancelled. Re-run the script when ready."
        exit 1
    fi
    echo ""
}

# Check if Tailscale is actually installed and working
tailscale_installed=false
if command -v tailscale &>/dev/null; then
    # Verify it actually works (not a stale wrapper)
    if tailscale version &>/dev/null 2>&1; then
        tailscale_installed=true
        success "Tailscale is already installed"
    else
        info "Found broken tailscale installation, reinstalling..."
        # Clean up stale wrappers
        sudo rm -f /usr/local/bin/tailscale 2>/dev/null || true
        rm -f /opt/homebrew/bin/tailscale 2>/dev/null || true
    fi
fi

if [ "$tailscale_installed" = false ]; then
    info "Installing Tailscale VPN client..."

    case "$OS" in
        Darwin)
            # macOS - install GUI app via homebrew cask
            if command -v brew &>/dev/null; then
                info "Installing Tailscale app via Homebrew..."
                brew install --cask tailscale-app
            else
                info "Installing via official PKG..."
                tmp_pkg=$(mktemp /tmp/tailscale-XXXXXX.pkg)
                curl -fsSL https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg -o "$tmp_pkg"
                sudo installer -pkg "$tmp_pkg" -target /
                rm -f "$tmp_pkg"
            fi
            ;;
        Linux)
            # Linux - use official install script
            info "Installing via official Tailscale script..."
            curl -fsSL https://tailscale.com/install.sh | sh
            ;;
        *)
            error "Unsupported OS: $OS. Use Windows PowerShell script for Windows."
            ;;
    esac

    success "Tailscale installed"
fi

# OS-specific setup
case "$OS" in
    Darwin)
        # macOS requires GUI setup - show instructions and get confirmation first
        macos_setup_instructions

        info "Opening Tailscale app..."
        open -a Tailscale 2>/dev/null || true

        echo ""
        success "Tailscale app opened. Follow the steps above to complete setup."
        echo ""
        exit 0
        ;;
    Linux)
        # Linux - use systemd
        info "Starting Tailscale service..."
        if command -v systemctl &>/dev/null; then
            sudo systemctl enable --now tailscaled
        else
            error "systemd not found. Please start tailscaled manually."
        fi

        # Wait for daemon to be ready
        info "Waiting for Tailscale daemon..."
        for i in $(seq 1 $MAX_DAEMON_WAIT_SECONDS); do
            if status_output=$(tailscale status 2>&1); then
                break
            elif echo "$status_output" | grep -q "Logged out"; then
                break
            fi
            if [ "$i" -eq "$MAX_DAEMON_WAIT_SECONDS" ]; then
                error "Tailscale daemon not responding after ${MAX_DAEMON_WAIT_SECONDS}s."
            fi
            sleep 1
        done

        # Connect to Headscale
        echo ""
        info "Connecting to VPN (hostname: $HOSTNAME)..."

        if [ -n "$AUTH_KEY" ]; then
            sudo tailscale up --login-server="$HEADSCALE_URL" --hostname="$HOSTNAME" --authkey="$AUTH_KEY" --accept-routes --reset
        else
            sudo tailscale up --login-server="$HEADSCALE_URL" --hostname="$HOSTNAME" --accept-routes --reset
            echo ""
            info "A browser window will open — log in with your company SSO credentials via Authentik."
        fi
        echo ""
        success "VPN setup complete!"
        echo ""
        echo "Verify connection with: tailscale status"
        echo "Your VPN IP: $(tailscale ip -4 2>/dev/null || echo 'pending...')"
        echo ""
        ;;
esac
