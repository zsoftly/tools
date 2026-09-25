#!/bin/bash
# ZCP Employee Desktop: Teardown
# Removes the desktop VM for a given --name. Unlike deploy-private-storage.sh's
# VM+volume pair, this VM has no companion volume - confirmed live (QA on
# zsoftly/zmi#551): 'zcp volume list' shows nothing left behind after deleting
# the desktop instance. So this is just an instance delete, plus the same
# leftover-standalone-network detection every other zcp/*.sh teardown in this
# series does: 'zcp instance create --network-plan' gives the VM its own
# isolated network, separate from the tier, and 'instance delete' never
# touches it.
#
# This does NOT touch the private tier or VPC. Those belong to
# build-private-network.sh / destroy-private-network.sh (Tutorial 1).
#
# Usage:
#   ./destroy-employee-desktop.sh --name jane-doe-desktop [--region ...] [--project ...]
#
# Requires: zcp CLI (authenticated), jq
set -e
set -o pipefail

VM_NAME=""
DELETE_WAIT_SECONDS=180
DELETED_COUNT=0
ISSUED_COUNT=0

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
ZCP Employee Desktop: Teardown

Usage: $0 --name NAME [options]

Required:
  --name NAME      Same VM name you passed to deploy-employee-desktop.sh.

Options:
  --region REGION   zcp region slug (or \$ZCP_REGION)
  --project PROJECT zcp project slug (or \$ZCP_PROJECT)
  -h, --help          Show this help

Example:
  ./destroy-employee-desktop.sh --name jane-doe-desktop --region yul-1 --project default-9
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
    --name) require_value "$1" "${2:-}"; VM_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1 (see --help)" ;;
  esac
done

command -v zcp >/dev/null 2>&1 || error "zcp CLI not found."
command -v jq >/dev/null 2>&1 || error "jq not found."
zcp auth validate >/dev/null 2>&1 || error "zcp CLI is not authenticated."
[ -n "${ZCP_REGION:-}" ] || error "--region (or \$ZCP_REGION) is required."
[ -n "${ZCP_PROJECT:-}" ] || error "--project (or \$ZCP_PROJECT) is required."
[ -n "$VM_NAME" ] || error "--name is required (same VM name used with deploy-employee-desktop.sh)."

NAME_RE='^[a-zA-Z0-9-]+$'
if ! [[ "$VM_NAME" =~ $NAME_RE ]]; then
  error "--name '$VM_NAME' must contain only letters, numbers, and hyphens."
fi

export ZCP_REGION ZCP_PROJECT
zcp() { command zcp --region "$ZCP_REGION" --project "$ZCP_PROJECT" "$@"; }

wait_for_gone() {
  # Same as the other zcp/*.sh teardown scripts' wait_for_gone: only an
  # explicit "not found" error counts as gone. Any other failure (API
  # hiccup, auth blip) is retried like the instance is still present.
  local name="$1" waited=0 output
  while true; do
    if output="$(zcp instance get "$name" 2>&1)"; then
      :
    elif echo "$output" | grep -qi "not found"; then
      return 0
    fi
    waited=$((waited + 5))
    if [ "$waited" -ge "$DELETE_WAIT_SECONDS" ]; then
      warn "'$name' did not confirm as deleted within ${DELETE_WAIT_SECONDS}s. Continuing with the rest of the teardown. Check manually: zcp instance get $name"
      return 1
    fi
    sleep 5
  done
}

capture_vm_network_id() {
  local vm_name="$1"
  # '(. // [])[]' guard: same reasoning as the VM_MATCHES fix below for 'zcp instance list'
  # returning literal 'null' on an empty account - 'zcp ip list -o json' does the same thing.
  # The trailing '|| true' alone was only accidentally safe against that (it masks ANY
  # pipeline failure, not just a null-shaped one), so this is made explicit for consistency.
  zcp ip list -o json | jq -r --arg vm "$vm_name" '(. // [])[] | select(.vm==$vm) | .network_id // empty' | head -1 || true
}

step "Checking the desktop VM"

# Resolved and ambiguity-checked FIRST, before anything is deleted, same
# reasoning as destroy-private-storage.sh's VM check.
VM_PRESENT="false"
VM_SLUG=""
VM_LIST_JSON="$(zcp instance list -o json)" || error "Could not list instances to check whether '$VM_NAME' exists."
# Confirmed live: 'zcp instance list -o json' returns the literal 'null', not '[]', on a
# fully clean account. '.[] // []' tolerates that instead of crashing under set -e/pipefail
# before ever reaching the friendly "Nothing matched --name" path at the bottom.
VM_MATCHES="$(echo "$VM_LIST_JSON" | jq --arg n "$VM_NAME" '[(. // [])[] | select(.name==$n)]')"
VM_MATCH_COUNT="$(echo "$VM_MATCHES" | jq 'length')"
case "$VM_MATCH_COUNT" in
  0) ;;
  1)
    VM_PRESENT="true"
    VM_SLUG="$(echo "$VM_MATCHES" | jq -r '.[0].slug')"
    [ -n "$VM_SLUG" ] && [ "$VM_SLUG" != "null" ] || error "Found instance '$VM_NAME' but it has no slug in the API response. Check manually: zcp instance list"
    ;;
  *)
    error "Ambiguous: $VM_MATCH_COUNT instances are named '$VM_NAME'. This script can't safely tell them apart, and deleting the wrong one is irreversible. Rename or remove the duplicate, then re-run. (zcp instance list)"
    ;;
esac

step "Capturing the VM's network reference before deletion"
# This only works while the VM still exists. On a rerun after a previous
# invocation already deleted it, there's no '.vm' association left to find.
VM_NETWORK_ID=""
if [ "$VM_PRESENT" = "true" ]; then
  VM_NETWORK_ID="$(capture_vm_network_id "$VM_NAME")"
fi

step "Deleting the desktop VM"

if [ "$VM_PRESENT" = "true" ]; then
  ISSUED_COUNT=$((ISSUED_COUNT + 1))
  # Unguarded under `set -e`, this would kill the script on any rejection (confirmed live:
  # 'zcp instance delete --help' documents rejection of a VM that's mid-transition, e.g.
  # Starting/Stopping, until it settles), skipping the leftover-network check, the Done
  # summary, and this script's own exit-2 "still billing" contract below. ISSUED_COUNT is
  # already incremented above regardless of outcome, so that contract still fires correctly
  # on a failed delete (DELETED_COUNT stays behind it).
  if zcp instance delete "$VM_SLUG" --yes; then
    info "Waiting for '$VM_NAME' to finish deleting..."
    if wait_for_gone "$VM_SLUG"; then
      success "'$VM_NAME' deleted"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
  else
    warn "Could not delete instance '$VM_NAME' ($VM_SLUG). Check manually: zcp instance list"
  fi
else
  warn "'$VM_NAME' not found, skipping."
fi

step "Checking for a leftover standalone network"

# Same reasoning and same retry-before-reporting fix as
# destroy-private-storage.sh / destroy-private-network.sh: the platform
# releases a VM's standalone network asynchronously, a few seconds after the
# instance delete is confirmed gone.
LEFTOVER=""
UNVERIFIED=""
if [ "$VM_PRESENT" = "false" ]; then
  UNVERIFIED="${UNVERIFIED}${VM_NAME} (already gone before this run)"$'\n'
elif [ -z "$VM_NETWORK_ID" ]; then
  UNVERIFIED="${UNVERIFIED}${VM_NAME} (no network reference captured)"$'\n'
else
  found=""
  for lo_attempt in 1 2 3 4 5; do
    # '(. // [])[]' guard: confirmed live, 'zcp ip list -o json' returns the literal 'null'
    # (not '[]') once the last IP-holding resource in the project is gone - exactly the
    # normal, successful teardown path this loop runs on. The unguarded '.[]' here crashed
    # with 'jq: error: Cannot iterate over null (null)' (exit 5) and, under set -e/pipefail,
    # killed the script before it ever reached the Done summary or the exit-2 contract below.
    found="$(zcp ip list -o json | jq -r --arg id "$VM_NETWORK_ID" '(. // [])[] | select(.network_id==$id) | .slug' | head -1)"
    [ -z "$found" ] && break
    sleep 4
  done
  [ -n "$found" ] && LEFTOVER="${LEFTOVER}${found} (network id: ${VM_NETWORK_ID})"$'\n'
fi

if [ -n "$LEFTOVER" ]; then
  warn "Left behind: a standalone network 'instance delete' doesn't clean up, and its pinned IP(s):"
  echo "$LEFTOVER" >&2
  warn "Find and remove these from the CMP web portal (search by the network ID above), or ask platform"
  warn "support. The zcp CLI can't resolve or delete a network by ID today."
fi
if [ -n "$UNVERIFIED" ]; then
  warn "Cannot verify network cleanup for:"
  echo "$UNVERIFIED" >&2
  warn "If this is the first time you're tearing this deployment down, that's unexpected. Check the CMP"
  warn "portal manually."
fi
if [ -z "$LEFTOVER" ] && [ -z "$UNVERIFIED" ]; then
  success "No leftover network tied to what this run created"
fi

step "Done"
if [ "$ISSUED_COUNT" -eq 0 ]; then
  warn "Nothing matched --name '$VM_NAME'. No resources were found or deleted. If you expected something here, check the actual name with: zcp instance list"
elif [ "$DELETED_COUNT" -eq "$ISSUED_COUNT" ]; then
  echo "$DELETED_COUNT resource(s) removed for --name '$VM_NAME'." >&2
else
  warn "$ISSUED_COUNT delete(s) issued, only $DELETED_COUNT confirmed. Check the [WARN] lines above for what didn't confirm in time."
fi

# Non-zero exit whenever cleanup is provably incomplete, so CI/automation
# driving this script can detect it instead of seeing exit 0 and moving on.
# Same LEFTOVER/UNVERIFIED exit logic as the other zcp/*.sh teardown scripts:
# LEFTOVER is unconditional, UNVERIFIED only counts when the VM delete was
# actually issued this run (gated on VM_PRESENT, captured before deletion
# above) - a confirmatory rerun on an already-clean account should exit 0,
# not report a false-dirty result forever.
if [ -n "$LEFTOVER" ] \
   || { [ -n "$UNVERIFIED" ] && [ "$VM_PRESENT" = "true" ]; } \
   || [ "$DELETED_COUNT" -ne "$ISSUED_COUNT" ]; then
  exit 2
fi
