#!/bin/bash
# ZCP Private Network + Headscale Mesh: Teardown
# Removes the subnet router, the Headplane VM, and the VPC (which removes the
# tier automatically) for a given --name prefix. Each VM's --network-plan deploy
# also creates its own standalone network that instance delete never touches.
# This script detects one left behind but can't safely delete it automatically
# (the zcp CLI has no way to resolve that network by ID to a deletable slug) -
# it reports what's left and where to find it instead.
#
# Usage:
#   ./destroy-private-network.sh --name my-workspace [--region ...] [--project ...]
#
# Requires: zcp CLI (authenticated), jq
set -e
set -o pipefail

NAME_PREFIX=""
DELETE_WAIT_SECONDS=180
DELETED_COUNT=0

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
step() { echo "" >&2; echo -e "${CYAN}==>${NC} $1" >&2; }

usage() {
  cat <<EOF
ZCP Private Network + Headscale Mesh: Teardown

Usage: $0 --name PREFIX [options]

Required:
  --name PREFIX    Same prefix you passed to build-private-network.sh.

Options:
  --region REGION   zcp region slug (or \$ZCP_REGION)
  --project PROJECT zcp project slug (or \$ZCP_PROJECT)
  -h, --help          Show this help

Example:
  ./destroy-private-network.sh --name acme-workspace --region yul-1 --project default-9
EOF
}

require_value() {
  if [[ -z "${2:-}" || "$2" == -* ]]; then
    error "$1 requires a value."
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --region) require_value "$1" "${2:-}"; ZCP_REGION="$2"; shift 2 ;;
    --project) require_value "$1" "${2:-}"; ZCP_PROJECT="$2"; shift 2 ;;
    --name) require_value "$1" "${2:-}"; NAME_PREFIX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1 (see --help)" ;;
  esac
done

command -v zcp >/dev/null 2>&1 || error "zcp CLI not found."
command -v jq >/dev/null 2>&1 || error "jq not found."
zcp auth validate >/dev/null 2>&1 || error "zcp CLI is not authenticated."
[ -n "${ZCP_REGION:-}" ] || error "--region (or \$ZCP_REGION) is required."
[ -n "${ZCP_PROJECT:-}" ] || error "--project (or \$ZCP_PROJECT) is required."
[ -n "$NAME_PREFIX" ] || error "--name is required (same prefix used with build-private-network.sh)."

export ZCP_REGION ZCP_PROJECT
zcp() { command zcp --region "$ZCP_REGION" --project "$ZCP_PROJECT" "$@"; }

VPC_NAME="$NAME_PREFIX"
HEADSCALE_NAME="${NAME_PREFIX}-headscale"
ROUTER_NAME="${NAME_PREFIX}-subnet-router"

wait_for_gone() {
  # Returns non-zero on timeout instead of hard-exiting, so a single slow or
  # stuck deletion doesn't abort the rest of the teardown.
  local name="$1" waited=0
  while zcp instance get "$name" >/dev/null 2>&1; do
    waited=$((waited + 5))
    if [ "$waited" -ge "$DELETE_WAIT_SECONDS" ]; then
      warn "'$name' did not finish deleting within ${DELETE_WAIT_SECONDS}s. Continuing with the rest of the teardown. Check manually: zcp instance get $name"
      return 1
    fi
    sleep 5
  done
  return 0
}

# Captures the standalone network each VM's own --network-plan deploy created,
# before the instance is deleted (the association may not be queryable after).
capture_vm_network_id() {
  local vm_name="$1"
  zcp ip list -o json | jq -r --arg vm "$vm_name" '.[] | select(.vm==$vm) | .network_id // empty' | head -1
}

step "Capturing per-VM network references before deletion"
ROUTER_NETWORK_ID="$(capture_vm_network_id "$ROUTER_NAME")"
HEADSCALE_NETWORK_ID="$(capture_vm_network_id "$HEADSCALE_NAME")"

step "Deleting instances"

if zcp instance get "$ROUTER_NAME" >/dev/null 2>&1; then
  zcp instance delete "$ROUTER_NAME" --yes
  info "Waiting for '$ROUTER_NAME' to finish deleting..."
  if wait_for_gone "$ROUTER_NAME"; then
    success "'$ROUTER_NAME' deleted"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  fi
else
  warn "'$ROUTER_NAME' not found, skipping."
fi

if zcp instance get "$HEADSCALE_NAME" >/dev/null 2>&1; then
  zcp instance delete "$HEADSCALE_NAME" --yes
  info "Waiting for '$HEADSCALE_NAME' to finish deleting..."
  if wait_for_gone "$HEADSCALE_NAME"; then
    success "'$HEADSCALE_NAME' deleted"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  fi
else
  warn "'$HEADSCALE_NAME' not found, skipping."
fi

step "Deleting VPC (removes the private tier automatically)"

if zcp vpc list -o json | jq -e --arg n "$VPC_NAME" '.[] | select(.name==$n)' >/dev/null 2>&1; then
  VPC_SLUG="$(zcp vpc list -o json | jq -r --arg n "$VPC_NAME" '.[] | select(.name==$n) | .slug' | head -1)"
  zcp vpc delete "${VPC_SLUG:-$VPC_NAME}" --yes
  success "'$VPC_NAME' deleted"
  DELETED_COUNT=$((DELETED_COUNT + 1))
else
  warn "'$VPC_NAME' not found, skipping."
fi

step "Checking for a leftover standalone network"

# zcp instance create --network-plan gives each VM its own isolated network,
# separate from the VPC/tier. instance delete releases the VM's IP but never
# touches this network, and the source-NAT IP pinned to it can't be released
# directly. The platform refuses that. The IP has to go with its network.
#
# The zcp CLI has no reliable way to automate deleting it. 'network list' does
# not expose an ID field to cross-reference against the network_id captured
# above, and 'network get'/'network delete' only accept a slug, not the raw
# ID. There's no safe way to guess which network is the right one, especially
# on a shared account where other resources may share naming patterns.
#
# What we CAN do reliably is detect whether the leftover still exists, using
# the network_id captured before deletion (matching on .vm is unreliable here
# since that field goes empty once the VM is gone).
LEFTOVER=""
for net_id in "$ROUTER_NETWORK_ID" "$HEADSCALE_NETWORK_ID"; do
  [ -n "$net_id" ] || continue
  found="$(zcp ip list -o json | jq -r --arg id "$net_id" '.[] | select(.network_id==$id) | .slug' | head -1)"
  [ -n "$found" ] && LEFTOVER="${LEFTOVER}${found} (network id: ${net_id})"$'\n'
done

if [ -n "$LEFTOVER" ]; then
  warn "Left behind: a standalone network 'instance delete' doesn't clean up, and its pinned IP(s):"
  echo "$LEFTOVER" >&2
  warn "Find and remove these from the CMP web portal (search by the network ID above), or ask platform"
  warn "support. The zcp CLI can't resolve or delete a network by ID today."
else
  success "No leftover network tied to what this run created"
fi

step "Done"
if [ "$DELETED_COUNT" -eq 0 ]; then
  warn "Nothing matched --name '$NAME_PREFIX'. No resources were found or deleted. If you expected something here, check the actual prefix with: zcp vpc list"
else
  echo "$DELETED_COUNT resource(s) removed for --name '$NAME_PREFIX'." >&2
fi
