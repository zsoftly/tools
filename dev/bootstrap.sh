#!/usr/bin/env bash
#
# Ansible development environment bootstrap
# Installs Ansible and common automation packages into a Python venv. Run once per machine.
#
# Supports: Linux, macOS, WSL2
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/dev/bootstrap.sh)
#   ./bootstrap.sh [--force]
#
set -euo pipefail

VENV_DIR="${ANSIBLE_DEV_VENV:-$HOME/.ansible-dev/venv}"
MIN_PYTHON="3.10"
FORCE=false

BASE_PACKAGES=(
    ansible
    jmespath
    netaddr
    passlib
    requests
    cryptography
    pyopenssl
    boto3
    botocore
    pynetbox
)

log()  { echo "[INFO] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

version_ge() {
    [ "$(printf '%s\n%s' "$1" "$2" | sort -t. -k1,1n -k2,2n | tail -1)" = "$1" ]
}

detect_os() {
    case "$OSTYPE" in
        darwin*) echo "macos" ;;
        linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

check_prerequisites() {
    local os
    os=$(detect_os)

    if ! command -v git &>/dev/null; then
        case "$os" in
            macos) fail "git not found. Install: brew install git" ;;
            *)     fail "git not found. Install: apt install git" ;;
        esac
    fi

    if ! command -v python3 &>/dev/null; then
        case "$os" in
            macos) fail "python3 not found. Install: brew install python@3.12" ;;
            *)     fail "python3 not found. Install: apt install python3" ;;
        esac
    fi

    local ver
    ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    version_ge "$ver" "$MIN_PYTHON" || fail "Python $ver too old. Need $MIN_PYTHON+."

    log "git $(git --version | awk '{print $3}'), Python $ver [OK]"
}

setup_venv() {
    if [[ "$FORCE" == true && -d "$VENV_DIR" ]]; then
        log "Removing existing venv (--force)..."
        rm -rf "$VENV_DIR"
    fi

    mkdir -p "$(dirname "$VENV_DIR")"

    if [[ ! -d "$VENV_DIR" ]]; then
        log "Creating venv at $VENV_DIR ..."
        python3 -m venv "$VENV_DIR"
    else
        log "Venv already exists at $VENV_DIR"
    fi

    [[ -f "$VENV_DIR/bin/activate" ]] || fail "Venv activation script not found at $VENV_DIR/bin/activate"
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
    python3 -m pip install --quiet --upgrade pip
}

install_packages() {
    log "Installing packages: ${BASE_PACKAGES[*]}"
    python3 -m pip install --quiet --upgrade "${BASE_PACKAGES[@]}"
    log "Ansible $(ansible --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') [OK]"
}

add_to_shell() {
    local marker="# ansible-dev"
    local line="source \"$VENV_DIR/bin/activate\""

    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [[ -f "$rc" ]] || continue
        if grep -qF "$marker" "$rc"; then
            log "Shell activation already configured in $(basename "$rc")"
        else
            printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
            log "Added venv activation to $(basename "$rc")"
        fi
    done
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)   FORCE=true; shift ;;
            --help|-h) echo "Usage: bootstrap.sh [--force]"; exit 0 ;;
            *)         fail "Unknown option: $1" ;;
        esac
    done

    log "Ansible dev environment bootstrap"
    echo ""

    check_prerequisites
    setup_venv
    install_packages
    add_to_shell

    echo ""
    echo "[OK] Bootstrap complete"
    echo ""
    echo "  Activate now:   source $VENV_DIR/bin/activate"
    echo "  New terminals:  venv activates automatically"
    echo ""
    echo "  Per-repo setup (after cloning a repo):"
    echo "    ansible-galaxy collection install -r requirements.yml"
    echo ""
}

main "$@"
