#!/bin/bash
# ZCP Employee Desktop Deployer (Tutorial 3). Deploys a full Ubuntu KDE remote desktop
# inside an EXISTING private tier (zcp/build-private-network.sh), with a named cloud-init
# login. RDP is never exposed publicly, reached only over the tier.
#
# Usage:
#   ./deploy-employee-desktop.sh --name jane-doe-desktop --tier-name my-workspace-tier \
#     --username janedoe --ssh-key my-key [options]
#
# Requires: zcp CLI (authenticated), jq, ssh, curl
set -e
set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
step() { echo "" >&2; echo -e "${CYAN}==>${NC} $1" >&2; }

usage() {
  cat <<EOF
ZCP Employee Desktop Deployer

Usage: $0 --name <vm-name> --tier-name <tier-name> --username <login> --ssh-key <name> [options]

Required:
  --name NAME       Exact name for the desktop VM.
  --tier-name NAME  Existing private tier from build-private-network.sh. Not auto-discovered.
  --username NAME   Desktop login (cloud-init). Must match ^[a-z][a-z0-9_]*\$, max 32 chars.
  --ssh-key NAME    Name of an existing 'zcp ssh-key' entry.

Options:
  --region REGION / --project PROJECT   zcp region/project (or \$ZCP_REGION/\$ZCP_PROJECT)
  --password PASSWORD       Desktop login's password (default: generated, printed once)
  --my-ip CIDR              Your public IP, scopes admin access (default: auto-detected /32)
  --vm-template SLUG        ubuntukde template slug (default: auto, must be >=1.0.2)
  --vm-plan SLUG             Compute plan (default: smallest >=4 vCPU/16GB)
  --network-plan SLUG        Network plan for the public IP (default: auto)
  --storage-category SLUG    Root disk storage category (default: auto)
  --billing-cycle CYCLE      hourly or monthly (default: hourly)
  --ssh-wait SECONDS          Wait for SSH (default: 180)
  --cloud-init-wait SECONDS   Wait for desktop provisioning (default: 1800)
  --adopt-existing            Modify a pre-existing --name match instead of erroring
  -y, --yes                   Skip the confirmation prompt
  -h, --help                  Show this help

See the "Deploy Ubuntu Employee Desktops" tutorial for full details on each option.
EOF
}

require_value() { [[ -z "${2:-}" || "$2" == -* ]] && error "$1 requires a value."; :; }

VM_NAME="" TIER_NAME="" DESKTOP_USERNAME="" DESKTOP_PASSWORD="" PASSWORD_PROVIDED="false"
VM_ALREADY_EXISTED="false" ADOPT_EXISTING="false" SSH_KEY="" MY_IP="" VM_TEMPLATE=""
VM_PLAN="" NETWORK_PLAN="" STORAGE_CATEGORY="" BILLING_CYCLE="hourly" AUTO_YES="false"
SSH_WAIT_SECONDS=180 CLOUD_INIT_WAIT_SECONDS=1800 TIER_NIC_WAIT_SECONDS=300

while [[ $# -gt 0 ]]; do
  case $1 in
    --region) require_value "$1" "${2:-}"; ZCP_REGION="$2"; shift 2 ;;
    --project) require_value "$1" "${2:-}"; ZCP_PROJECT="$2"; shift 2 ;;
    --name) require_value "$1" "${2:-}"; VM_NAME="$2"; shift 2 ;;
    --tier-name) require_value "$1" "${2:-}"; TIER_NAME="$2"; shift 2 ;;
    --username) require_value "$1" "${2:-}"; DESKTOP_USERNAME="$2"; shift 2 ;;
    --password) require_value "$1" "${2:-}"; DESKTOP_PASSWORD="$2"; PASSWORD_PROVIDED="true"; shift 2 ;;
    --ssh-key) require_value "$1" "${2:-}"; SSH_KEY="$2"; shift 2 ;;
    --my-ip) require_value "$1" "${2:-}"; MY_IP="$2"; shift 2 ;;
    --vm-template) require_value "$1" "${2:-}"; VM_TEMPLATE="$2"; shift 2 ;;
    --vm-plan) require_value "$1" "${2:-}"; VM_PLAN="$2"; shift 2 ;;
    --network-plan) require_value "$1" "${2:-}"; NETWORK_PLAN="$2"; shift 2 ;;
    --storage-category) require_value "$1" "${2:-}"; STORAGE_CATEGORY="$2"; shift 2 ;;
    --billing-cycle) require_value "$1" "${2:-}"; BILLING_CYCLE="$2"; shift 2 ;;
    --ssh-wait) require_value "$1" "${2:-}"; SSH_WAIT_SECONDS="$2"; shift 2 ;;
    --cloud-init-wait) require_value "$1" "${2:-}"; CLOUD_INIT_WAIT_SECONDS="$2"; shift 2 ;;
    --adopt-existing) ADOPT_EXISTING="true"; shift ;;
    -y|--yes) AUTO_YES="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1 (see --help)" ;;
  esac
done

# Single shared trap: bash traps replace rather than stack, so every file that needs
# cleanup on exit sets a variable here rather than registering its own trap.
cleanup() { [ -n "${LIB_TMP:-}" ] && rm -rf "$LIB_TMP"; [ -n "${USERDATA_FILE:-}" ] && rm -f "$USERDATA_FILE"; }
trap cleanup EXIT

# Phase files: fetched from the same repo this script itself came from, unless
# DEPLOY_LIB_DIR points at a local checkout (used for development/testing).
LIB_BASE="${DEPLOY_LIB_DIR:-https://raw.githubusercontent.com/zsoftly/tools/main/zcp/lib/deploy-employee-desktop}"
LIB_TMP="$(mktemp -d)"
for f in 01-validate.sh 02-resolve.sh 03-create.sh 04-finish.sh; do
  if [[ "$LIB_BASE" == http* ]]; then
    curl -fsSL "$LIB_BASE/$f" -o "$LIB_TMP/$f" || error "Could not fetch $f from $LIB_BASE"
  else
    cp "$LIB_BASE/$f" "$LIB_TMP/$f" || error "Could not read $f from $LIB_BASE"
  fi
  # shellcheck disable=SC1090
  source "$LIB_TMP/$f"
done

validate_inputs
resolve_resources
create_or_adopt_vm
info "Locking down SSH to your own IP..."
lock_down_ssh "$IP_SLUG" "$VM_NAME"
wait_for_ssh "$VM_IP" "$SSH_WAIT_SECONDS" "$VM_USER"
setup_tier_nic
wait_for_cloud_init_user
print_summary
