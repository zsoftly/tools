#!/bin/bash
# Wazuh Agent Setup Script - macOS/Linux
# Usage: ./install.sh --manager <address> [--group <group>] [--password <authd_password>]
set -e

# Configuration
WAZUH_VERSION="4.14.1-1"
WAZUH_MANAGER="${WAZUH_MANAGER:-}"
WAZUH_PORT="1514"
WAZUH_ENROLLMENT_PORT="1515"
AGENT_GROUP="${WAZUH_AGENT_GROUP:-}"
AUTH_PASSWORD=""

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
        --manager|-m)
            WAZUH_MANAGER="$2"
            shift 2
            ;;
        --group|-g)
            AGENT_GROUP="$2"
            shift 2
            ;;
        --password|-p)
            AUTH_PASSWORD="$2"
            shift 2
            ;;
        --version|-v)
            WAZUH_VERSION="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Prompt for password if not provided
prompt_for_password() {
    echo ""
    echo "============================================================"
    echo "  WAZUH ENROLLMENT PASSWORD"
    echo "============================================================"
    echo ""
    echo "You need the enrollment password from your IT admin."
    echo "This is used to register your device with the Wazuh manager."
    echo ""
    read -sp "Enter enrollment password: " AUTH_PASSWORD
    echo ""
    echo ""
}

# Validate required manager address
if [ -z "$WAZUH_MANAGER" ]; then
    error "Manager address required. Use --manager <address> or set WAZUH_MANAGER environment variable."
fi

# Detect OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"
info "Detected OS: $OS ($ARCH)"
info "Wazuh Manager: $WAZUH_MANAGER"
[ -n "$AGENT_GROUP" ] && info "Agent Group: $AGENT_GROUP"

# Check if Wazuh is already installed
if [ -f /var/ossec/bin/wazuh-control ]; then
    success "Wazuh agent is already installed"
    INSTALLED=true
else
    INSTALLED=false
fi

if [ "$INSTALLED" = false ]; then
    info "Installing Wazuh agent v${WAZUH_VERSION}..."

    case "$OS" in
        Darwin)
            # macOS
            if [ "$ARCH" = "arm64" ]; then
                PKG_ARCH="arm64"
            else
                PKG_ARCH="intel64"
            fi

            info "Downloading Wazuh agent for macOS ($PKG_ARCH)..."
            PKG_URL="https://packages.wazuh.com/4.x/macos/wazuh-agent-${WAZUH_VERSION}.${PKG_ARCH}.pkg"
            TMP_PKG=$(mktemp /tmp/wazuh-agent-XXXXXX.pkg)

            curl -fsSL "$PKG_URL" -o "$TMP_PKG" || error "Failed to download package"

            info "Installing package..."
            sudo installer -pkg "$TMP_PKG" -target / || error "Failed to install package"
            rm -f "$TMP_PKG"
            ;;
        Linux)
            # Linux - detect distro
            if [ -f /etc/debian_version ]; then
                # Debian/Ubuntu
                GPG_KEY="/usr/share/keyrings/wazuh-archive-keyring.gpg"
                if [ ! -f "$GPG_KEY" ] || [ ! -s "$GPG_KEY" ]; then
                    info "Installing GPG key..."
                    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
                        sudo gpg --dearmor -o "$GPG_KEY" || error "Failed to install GPG key"
                else
                    info "GPG key already installed"
                fi

                info "Adding repository..."
                echo "deb [signed-by=/usr/share/keyrings/wazuh-archive-keyring.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | \
                    sudo tee /etc/apt/sources.list.d/wazuh.list > /dev/null

                info "Installing wazuh-agent..."
                sudo apt-get update -qq
                sudo apt-get install -y wazuh-agent="${WAZUH_VERSION}" || error "Failed to install package"

            elif [ -f /etc/redhat-release ]; then
                # RHEL/CentOS/Fedora
                info "Adding repository..."
                sudo rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

                cat << EOF | sudo tee /etc/yum.repos.d/wazuh.repo > /dev/null
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-\$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF

                info "Installing wazuh-agent..."
                sudo yum install -y wazuh-agent-"${WAZUH_VERSION}" || error "Failed to install package"
            else
                error "Unsupported Linux distribution. Install manually from https://documentation.wazuh.com"
            fi
            ;;
        *)
            error "Unsupported OS: $OS. Use Windows PowerShell script for Windows."
            ;;
    esac

    success "Wazuh agent installed"
fi

# Configure manager address
info "Configuring manager address..."
OSSEC_CONF="/var/ossec/etc/ossec.conf"

if [ -f "$OSSEC_CONF" ]; then
    # Update manager address in config
    sudo sed -i.bak "s|<address>.*</address>|<address>${WAZUH_MANAGER}</address>|g" "$OSSEC_CONF" 2>/dev/null || \
    sudo sed -i '' "s|<address>.*</address>|<address>${WAZUH_MANAGER}</address>|g" "$OSSEC_CONF"
fi

# Check if already enrolled
if [ -f /var/ossec/etc/client.keys ] && [ -s /var/ossec/etc/client.keys ]; then
    success "Agent is already enrolled"
else
    # Prompt for password if not provided
    if [ -z "$AUTH_PASSWORD" ]; then
        prompt_for_password
    fi

    if [ -z "$AUTH_PASSWORD" ]; then
        warn "No password provided. Agent will not be enrolled automatically."
        warn "Enroll manually: sudo /var/ossec/bin/agent-auth -m $WAZUH_MANAGER"
    else
        info "Enrolling agent with manager..."
        ENROLL_CMD="sudo /var/ossec/bin/agent-auth -m $WAZUH_MANAGER -p $WAZUH_ENROLLMENT_PORT"
        [ -n "$AGENT_GROUP" ] && ENROLL_CMD="$ENROLL_CMD -G $AGENT_GROUP"
        ENROLL_CMD="$ENROLL_CMD -P $AUTH_PASSWORD"
        eval "$ENROLL_CMD" || error "Enrollment failed. Check password and network connectivity."
        success "Agent enrolled"
    fi
fi

# Start service
info "Starting Wazuh agent service..."
case "$OS" in
    Darwin)
        sudo /var/ossec/bin/wazuh-control start
        ;;
    Linux)
        if command -v systemctl &>/dev/null; then
            sudo systemctl daemon-reload
            sudo systemctl enable wazuh-agent
            sudo systemctl start wazuh-agent
        else
            sudo /var/ossec/bin/wazuh-control start
        fi
        ;;
esac

# Verify agent status
info "Verifying agent status..."
sleep 3

if sudo /var/ossec/bin/wazuh-control status 2>/dev/null | grep -q "is running"; then
    success "Wazuh agent is running"
    # Check connection in logs (informational only)
    if grep -q "Connected to the server" /var/ossec/logs/ossec.log 2>/dev/null; then
        success "Connected to Wazuh manager!"
    else
        info "Agent running. Connection to manager may take a few seconds..."
    fi
else
    warn "Agent may not be running. Check: sudo /var/ossec/bin/wazuh-control status"
fi

echo ""
success "Wazuh agent setup complete!"
echo ""
echo "Useful commands:"
echo "  Status:  sudo /var/ossec/bin/wazuh-control status"
echo "  Logs:    sudo tail -f /var/ossec/logs/ossec.log"
echo "  Restart: sudo /var/ossec/bin/wazuh-control restart"
echo ""
