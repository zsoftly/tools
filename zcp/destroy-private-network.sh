#!/bin/bash
# ZCP Private Network + Headscale Mesh: Teardown
# Removes the subnet router, the Headplane VM, the private tier, and the VPC
# for a given --name prefix. Confirmed live: 'zcp vpc delete' does NOT cascade
# -delete the tier network on this platform, despite that being the natural
# assumption. It just hangs and fails with "not confirmed within 30s" while
# the tier silently blocks it. The tier is deleted explicitly, before the VPC.
# Each VM's --network-plan deploy also creates its own standalone network that
# instance delete never touches.
# This script detects one left behind but can't safely delete it automatically
# (the zcp CLI has no way to resolve that network by ID to a deletable slug) -
# it reports what's left and where to find it instead. On a rerun where a VM
# was already gone before this run started, that detection can't happen at
# all (the network reference is only capturable while the VM still exists),
# so those are reported as unverified rather than silently assumed clean.
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

# Same validation build-private-network.sh applies to --name: it gets used in
# a colon-delimited pair below (name:network_id:present), so a name containing
# ':' would corrupt that parsing.
NAME_RE='^[a-zA-Z0-9-]+$'
if ! [[ "$NAME_PREFIX" =~ $NAME_RE ]]; then
  error "--name '$NAME_PREFIX' must contain only letters, numbers, and hyphens."
fi

export ZCP_REGION ZCP_PROJECT
zcp() { command zcp --region "$ZCP_REGION" --project "$ZCP_PROJECT" "$@"; }

VPC_NAME="$NAME_PREFIX"
TIER_NAME="${NAME_PREFIX}-tier"
HEADSCALE_NAME="${NAME_PREFIX}-headscale"
ROUTER_NAME="${NAME_PREFIX}-subnet-router"

wait_for_gone() {
  # Returns non-zero on timeout instead of hard-exiting, so a single slow or
  # stuck deletion doesn't abort the rest of the teardown.
  #
  # 'instance get' failing does not by itself mean the instance is gone: an API
  # hiccup, an auth blip, or a transient network error all fail the same way.
  # Only a "not found" style error means the instance is actually deleted -
  # every other failure is retried like a still-present instance, so a flaky
  # API can't make this report a deletion that hasn't happened yet.
  local name="$1" waited=0 output
  while true; do
    if output="$(zcp instance get "$name" 2>&1)"; then
      : # still present, fall through to the wait/retry below
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

# Captures the standalone network each VM's own --network-plan deploy created,
# before the instance is deleted (the association may not be queryable after).
capture_vm_network_id() {
  local vm_name="$1"
  zcp ip list -o json | jq -r --arg vm "$vm_name" '.[] | select(.vm==$vm) | .network_id // empty' | head -1 || true
}

# Resolves a name to a slug before deleting, same reasoning as the VPC check
# above: build-private-network.sh's slug_for_name comment documents that
# slugs auto-suffix on collision, so a bare name can be ambiguous. Sets
# INSTANCE_PRESENT and, when present, INSTANCE_SLUG_RESOLVED.
resolve_instance_for_delete() {
  local name="$1" list_json matches count
  INSTANCE_PRESENT="false"
  INSTANCE_SLUG_RESOLVED=""
  list_json="$(zcp instance list -o json)" || error "Could not list instances to check whether '$name' exists."
  matches="$(echo "$list_json" | jq --arg n "$name" '[.[] | select(.name==$n)]')"
  count="$(echo "$matches" | jq 'length')"
  case "$count" in
    0) return 0 ;;
    1)
      INSTANCE_PRESENT="true"
      INSTANCE_SLUG_RESOLVED="$(echo "$matches" | jq -r '.[0].slug')"
      ;;
    *)
      error "Ambiguous: $count instances are named '$name'. This script can't safely tell them apart, and deleting the wrong one is irreversible. Rename or remove the duplicate, then re-run. (zcp instance list)"
      ;;
  esac
}

step "Checking the VPC"

# Resolved and ambiguity-checked FIRST, before anything is deleted, same as
# build-private-network.sh's slug_for_name helper does before every create.
# This is the one irreversible, destructive call in either script, and it
# must never silently pick the first of several same-named VPCs (the old
# 'head -1' behavior). Doing this before the instances are touched also means
# an ambiguity abort here leaves the account completely untouched, rather
# than deleting both VMs and then aborting before the leftover-network report
# ever runs.
VPC_LIST_JSON="$(zcp vpc list -o json)" || error "Could not list VPCs to check whether '$VPC_NAME' exists."
VPC_MATCHES="$(echo "$VPC_LIST_JSON" | jq --arg n "$VPC_NAME" '[.[] | select(.name==$n)]')"
VPC_MATCH_COUNT="$(echo "$VPC_MATCHES" | jq 'length')"
VPC_SLUG=""
case "$VPC_MATCH_COUNT" in
  0) ;;
  1)
    VPC_SLUG="$(echo "$VPC_MATCHES" | jq -r '.[0].slug')"
    [ -n "$VPC_SLUG" ] && [ "$VPC_SLUG" != "null" ] || error "Found VPC '$VPC_NAME' but it has no slug in the API response. Check manually: zcp vpc list"
    ;;
  *)
    error "Ambiguous: $VPC_MATCH_COUNT VPCs are named '$VPC_NAME'. This script can't safely tell them apart, and deleting the wrong one is irreversible. Rename or remove the duplicate, then re-run. (zcp vpc list)"
    ;;
esac

step "Capturing per-VM network references before deletion"
# This only works while the VM still exists. On a rerun after a previous
# invocation already deleted it, there's no '.vm' association left to find,
# so these come back empty. ROUTER_PRESENT/HEADSCALE_PRESENT track that
# distinction below, so a rerun reports "unverified" instead of a false
# "no leftover" for anything it can no longer check.
ROUTER_NETWORK_ID="$(capture_vm_network_id "$ROUTER_NAME")"
HEADSCALE_NETWORK_ID="$(capture_vm_network_id "$HEADSCALE_NAME")"

step "Deleting instances"

ROUTER_PRESENT="false"
resolve_instance_for_delete "$ROUTER_NAME"
if [ "$INSTANCE_PRESENT" = "true" ]; then
  ROUTER_PRESENT="true"
  ISSUED_COUNT=$((ISSUED_COUNT + 1))
  zcp instance delete "$INSTANCE_SLUG_RESOLVED" --yes
  info "Waiting for '$ROUTER_NAME' to finish deleting..."
  if wait_for_gone "$INSTANCE_SLUG_RESOLVED"; then
    success "'$ROUTER_NAME' deleted"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  fi
else
  warn "'$ROUTER_NAME' not found, skipping."
fi

HEADSCALE_PRESENT="false"
resolve_instance_for_delete "$HEADSCALE_NAME"
if [ "$INSTANCE_PRESENT" = "true" ]; then
  HEADSCALE_PRESENT="true"
  ISSUED_COUNT=$((ISSUED_COUNT + 1))
  zcp instance delete "$INSTANCE_SLUG_RESOLVED" --yes
  info "Waiting for '$HEADSCALE_NAME' to finish deleting..."
  if wait_for_gone "$INSTANCE_SLUG_RESOLVED"; then
    success "'$HEADSCALE_NAME' deleted"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  fi
else
  warn "'$HEADSCALE_NAME' not found, skipping."
fi

step "Deleting the private tier"

# Must happen before the VPC delete below. 'zcp vpc delete' does not cascade
# -delete the tier network. Confirmed live: it fails with "not confirmed
# within 30s" while the tier silently keeps the VPC in use.
TIER_LIST_JSON="$(zcp network list -o json)" || error "Could not list networks to check whether '$TIER_NAME' exists."
TIER_MATCHES="$(echo "$TIER_LIST_JSON" | jq --arg n "$TIER_NAME" '[.[] | select(.name==$n)]')"
TIER_MATCH_COUNT="$(echo "$TIER_MATCHES" | jq 'length')"
case "$TIER_MATCH_COUNT" in
  0)
    warn "'$TIER_NAME' not found, skipping."
    ;;
  1)
    TIER_SLUG="$(echo "$TIER_MATCHES" | jq -r '.[0].slug')"
    ISSUED_COUNT=$((ISSUED_COUNT + 1))
    if zcp network delete "$TIER_SLUG" --yes; then
      success "'$TIER_NAME' deleted"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    else
      warn "Could not delete '$TIER_NAME' ($TIER_SLUG). The VPC delete below will likely fail too until this is resolved. Check manually: zcp network get $TIER_SLUG"
    fi
    ;;
  *)
    error "Ambiguous: $TIER_MATCH_COUNT networks are named '$TIER_NAME'. This script can't safely tell them apart, and deleting the wrong one is irreversible. Rename or remove the duplicate, then re-run. (zcp network list)"
    ;;
esac

step "Deleting VPC"

if [ -n "$VPC_SLUG" ]; then
  ISSUED_COUNT=$((ISSUED_COUNT + 1))
  if zcp vpc delete "$VPC_SLUG" --yes; then
    success "'$VPC_NAME' deleted"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  else
    warn "Could not delete VPC '$VPC_NAME'. If the tier delete above also failed or was skipped, that's almost certainly why. Check manually: zcp vpc get $VPC_SLUG"
  fi
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
UNVERIFIED=""
for pair in "$ROUTER_NAME:$ROUTER_NETWORK_ID:$ROUTER_PRESENT" "$HEADSCALE_NAME:$HEADSCALE_NETWORK_ID:$HEADSCALE_PRESENT"; do
  name="${pair%%:*}"
  rest="${pair#*:}"
  net_id="${rest%%:*}"
  present="${rest#*:}"
  if [ "$present" = "false" ]; then
    # This VM was already gone before this run started, so its network_id was
    # never captured. Report this as unverified rather than silently treating
    # it the same as "checked and clean". A genuine leftover could still be
    # sitting there from whatever deleted the VM originally.
    UNVERIFIED="${UNVERIFIED}${name} (already gone before this run)"$'\n'
    continue
  fi
  if [ -z "$net_id" ]; then
    # The VM WAS present, but no network_id was captured for it (e.g. the
    # capture itself failed, or the IP has no network_id in this account).
    # Can't rule out a leftover without one, so this can't be reported as
    # clean either. Same "don't claim clean when we couldn't check" rule.
    UNVERIFIED="${UNVERIFIED}${name} (no network reference captured)"$'\n'
    continue
  fi
  # Confirmed live: the platform releases a VM's standalone network
  # asynchronously, a few seconds after the instance/VPC deletes it was
  # attached to are already confirmed gone. A single immediate check reports
  # a false leftover for a network that's already in the process of going
  # away on its own. Retry before concluding it's genuinely left behind.
  found=""
  for lo_attempt in 1 2 3 4 5; do
    found="$(zcp ip list -o json | jq -r --arg id "$net_id" '.[] | select(.network_id==$id) | .slug' | head -1)"
    [ -z "$found" ] && break
    sleep 4
  done
  [ -n "$found" ] && LEFTOVER="${LEFTOVER}${found} (network id: ${net_id})"$'\n'
done

# Reported independently, not if/elif: a rerun can easily have one VM that was
# already gone (UNVERIFIED) and one that was just deleted with a confirmed
# leftover (LEFTOVER) in the same pass. Chaining them with elif would let a
# real LEFTOVER hide an UNVERIFIED, or vice versa.
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
  warn "Nothing matched --name '$NAME_PREFIX'. No resources were found or deleted. If you expected something here, check the actual prefix with: zcp vpc list"
elif [ "$DELETED_COUNT" -eq "$ISSUED_COUNT" ]; then
  echo "$DELETED_COUNT resource(s) removed for --name '$NAME_PREFIX'." >&2
else
  warn "$ISSUED_COUNT delete(s) issued, only $DELETED_COUNT confirmed. Check the [WARN] lines above for what didn't confirm in time."
fi

# Non-zero exit whenever cleanup is provably incomplete, so CI/automation
# driving this script can detect it instead of seeing exit 0 and moving on.
# LEFTOVER is unconditional: it's a directly confirmed leftover network, never
# a false positive, regardless of whether this run deleted anything. UNVERIFIED
# is gated on ISSUED_COUNT > 0: if this run didn't attempt any delete (everything
# was already gone before it started), UNVERIFIED just means "nothing here to
# check", not "we left something behind". A confirmatory rerun on an
# already-clean account should exit 0, not report a false-dirty result forever.
if [ -n "$LEFTOVER" ] || { [ -n "$UNVERIFIED" ] && [ "$ISSUED_COUNT" -gt 0 ]; }; then
  exit 2
fi
