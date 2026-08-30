#!/bin/bash
# Headscale VPN Setup Script - macOS/Linux
# Usage: HEADSCALE_URL=https://your-headscale-server ./install.sh [john.d] [--key AUTH_KEY]
#
# Server URL input:
#   HEADSCALE_URL   Preferred
#   --server|-s     Optional override
set -e

# Configuration
MAX_DAEMON_WAIT_SECONDS=30
MAX_MACOS_READY_WAIT_SECONDS=60
MAX_MACOS_CONNECT_RETRY_SECONDS=15
FULL_NAME=""
AUTH_KEY=""
SERVER_URL=""
TAILSCALE_CLI=""

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
        --server|-s)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                error "--server requires a URL value. Usage: HEADSCALE_URL=https://your-headscale-server ./install.sh [john.d] [--key AUTH_KEY]"
            fi
            SERVER_URL="$2"
            shift 2
            ;;
        --user|-u)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                error "--user requires a name value. Usage: HEADSCALE_URL=https://your-headscale-server ./install.sh [john.d] [--key AUTH_KEY]"
            fi
            FULL_NAME="$2"
            shift 2
            ;;
        --key|-k)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                error "--key requires an auth key value."
            fi
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

if [ -n "$SERVER_URL" ]; then
    HEADSCALE_URL="$SERVER_URL"
fi

if [ -z "${HEADSCALE_URL:-}" ]; then
    echo "[ERROR] Headscale server URL is required."
    echo "  Use --server https://your-headscale-server"
    echo "  Or export HEADSCALE_URL=https://your-headscale-server"
    exit 1
fi

# Prompt for name if not provided
if [ -z "$FULL_NAME" ]; then
    echo ""
    read -r -p "Enter your name (e.g. john-d): " FULL_NAME
    echo ""
    if [ -z "$FULL_NAME" ]; then
        error "Name is required to set the device hostname."
    fi
fi

# Detect OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin) SUFFIX="-mac" ;;
    Linux)  SUFFIX="-lin" ;;
    *)      SUFFIX="-device" ;;
esac

# Headscale requires the node name to be a valid DNS label: lower case, only
# letters, digits and dashes, no leading or trailing dash, 63 characters max.
# Anything else makes it log "breaks map generation" and drop the node from
# map responses. Lower case the name, replace every character outside
# [a-z0-9-] with a dash, collapse runs, then trim to leave room for the suffix.
DNS_LABEL_MAX=63
SAFE_NAME="$(printf '%s' "$FULL_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
SAFE_NAME="$(printf '%s' "$SAFE_NAME" | cut -c "1-$((DNS_LABEL_MAX - ${#SUFFIX}))" | sed -E 's/-$//')"

if [ -z "$SAFE_NAME" ]; then
    error "Name must contain at least one letter or digit."
fi

HOSTNAME="${SAFE_NAME}${SUFFIX}"

if [ "$SAFE_NAME" != "$FULL_NAME" ]; then
    info "Device name normalised to '$SAFE_NAME' (lower case, only letters, digits and dashes, ${DNS_LABEL_MAX} characters max including the '${SUFFIX}' suffix)."
fi

info "Detected OS: $OS ($ARCH)"

# macOS requires at least one approval step before the app can register
macos_setup_instructions() {
    echo ""
    echo "============================================================"
    echo "  macOS SETUP INSTRUCTIONS"
    echo "============================================================"
    echo ""
    echo "macOS may require one manual approval step before VPN enrollment can finish."
    echo ""
    echo "STEP 1: Allow Network Extension"
    echo "  - Follow the prompt to allow Tailscale network extension"
    echo "  - Or go to System Settings > Privacy & Security > scroll down > click 'Allow'"
    echo ""
    echo "STEP 2: Wait while this script finishes enrollment"
    echo "  - The script will open Tailscale and try to register this Mac automatically"
    echo "  - Headscale server: $HEADSCALE_URL"
    if [ -n "$AUTH_KEY" ]; then
        echo "  - Auth key mode: enabled"
    else
        echo "  - Auth key mode: not provided, browser SSO may open"
    fi
    echo ""
    echo "STEP 3: Verify"
    echo "  - The script will report success only after the Mac is actually connected"
    echo "  - If it reports a macOS approval block, approve the extension and re-run the same command"
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

find_macos_cli() {
    local candidates=(
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        "/Applications/Tailscale.app/Contents/MacOS/tailscale"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -x "$candidate" ]; then
            TAILSCALE_CLI="$candidate"
            return 0
        fi
    done
    return 1
}

macos_tailscale() {
    TAILSCALE_BE_CLI=1 "$TAILSCALE_CLI" "$@"
}

wait_for_macos_cli_ready() {
    local i
    local status_output
    for i in $(seq 1 "$MAX_MACOS_READY_WAIT_SECONDS"); do
        if status_output=$(macos_tailscale status 2>&1); then
            return 0
        fi
        if echo "$status_output" | grep -Eq "Logged out|Stopped|NeedsLogin"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

verify_macos_connection() {
    local backend_state
    backend_state=$(macos_tailscale status --json 2>/dev/null | awk -F'"' '/"BackendState"/ {print $4; exit}')
    [ "$backend_state" = "Running" ]
}

# Check if Tailscale is actually installed and working
tailscale_installed=false
if [ "$OS" = "Darwin" ]; then
    if find_macos_cli; then
        tailscale_installed=true
        success "Tailscale is already installed"
    fi
else
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
        if ! find_macos_cli; then
            error "Tailscale was installed but the macOS app CLI was not found under /Applications/Tailscale.app."
        fi

        macos_setup_instructions

        info "Opening Tailscale app..."
        open -a Tailscale 2>/dev/null || true

        info "Waiting for Tailscale on macOS to become ready..."
        if ! wait_for_macos_cli_ready; then
            error "Tailscale on macOS is not ready yet. Approve the network extension in System Settings > Privacy & Security, then re-run the same command."
        fi

        echo ""
        info "Connecting to VPN (hostname: $HOSTNAME)..."
        if [ -n "$AUTH_KEY" ]; then
            if ! macos_tailscale up --login-server="$HEADSCALE_URL" --hostname="$HOSTNAME" --authkey="$AUTH_KEY" --accept-routes --reset; then
                error "Tailscale could not complete macOS enrollment. If macOS showed a system extension approval prompt, approve it and re-run the same command."
            fi
        else
            if ! macos_tailscale up --login-server="$HEADSCALE_URL" --hostname="$HOSTNAME" --accept-routes --reset; then
                error "Tailscale did not complete macOS login. Finish any browser SSO or macOS approval prompts, then re-run the same command."
            fi
            echo ""
            info "If prompted, complete the browser SSO flow via Authentik."
        fi

        connected=false
        for i in $(seq 1 "$MAX_MACOS_CONNECT_RETRY_SECONDS"); do
            if verify_macos_connection; then
                connected=true
                break
            fi
            sleep 1
        done

        if [ "$connected" = false ]; then
            error "Tailscale app is installed, but this Mac is not connected yet. If macOS showed a system extension approval prompt, approve it and re-run the same command."
        fi

        echo ""
        success "VPN setup complete!"
        echo ""
        echo "Verify connection with: TAILSCALE_BE_CLI=1 \"$TAILSCALE_CLI\" status"
        echo "Your VPN IP: $(macos_tailscale ip -4 2>/dev/null || echo 'pending...')"
        echo ""
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
