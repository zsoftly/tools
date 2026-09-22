#!/bin/bash
# ZCP Private Shared Storage: Teardown
# Removes the storage VM and its data volume for a given --name prefix.
# The volume is explicitly detached before the VM is deleted, then deleted as
# its own separate step - this does not rely on any assumption about what
# 'instance delete' does to a still-attached data volume, since that has not
# been independently confirmed on this platform. The VM's --network-plan
# deploy also creates its own standalone network that instance delete never
# touches, same as build-private-network.sh's VMs - this script detects one
# left behind but can't safely delete it automatically (the zcp CLI has no
# way to resolve that network by ID to a deletable slug), it reports what's
# left and where to find it instead.
#
# This does NOT touch the private tier or VPC. Those belong to
# build-private-network.sh / destroy-private-network.sh (Tutorial 1).
#
# Usage:
#   ./destroy-private-storage.sh --name my-storage [--region ...] [--project ...]
#
# Requires: zcp CLI (authenticated), jq
set -e
set -o pipefail

NAME_PREFIX=""
DELETE_WAIT_SECONDS=180
DELETED_COUNT=0
ISSUED_COUNT=0
ALLOW_UNVERIFIED_VOLUME_DELETE="false"

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
ZCP Private Shared Storage: Teardown

Usage: $0 --name PREFIX [options]

Required:
  --name PREFIX    Same prefix you passed to deploy-private-storage.sh.

Options:
  --region REGION   zcp region slug (or \$ZCP_REGION)
  --project PROJECT zcp project slug (or \$ZCP_PROJECT)
  --allow-unverified-volume-delete
                    Required to delete the data volume when deploy's own
                    recorded state isn't available (a different machine, a
                    different --region/--project, or state that was never
                    written or has been cleaned up). Without it, the volume
                    is left alone and reported rather than deleted on a bare
                    --name match. The VM itself is still deleted either way.
  -h, --help          Show this help

Example:
  ./destroy-private-storage.sh --name my-storage --region yul-1 --project default-9
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
    --allow-unverified-volume-delete) ALLOW_UNVERIFIED_VOLUME_DELETE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1 (see --help)" ;;
  esac
done

command -v zcp >/dev/null 2>&1 || error "zcp CLI not found."
command -v jq >/dev/null 2>&1 || error "jq not found."
zcp auth validate >/dev/null 2>&1 || error "zcp CLI is not authenticated."
[ -n "${ZCP_REGION:-}" ] || error "--region (or \$ZCP_REGION) is required."
[ -n "${ZCP_PROJECT:-}" ] || error "--project (or \$ZCP_PROJECT) is required."
[ -n "$NAME_PREFIX" ] || error "--name is required (same prefix used with deploy-private-storage.sh)."

NAME_RE='^[a-zA-Z0-9-]+$'
if ! [[ "$NAME_PREFIX" =~ $NAME_RE ]]; then
  error "--name '$NAME_PREFIX' must contain only letters, numbers, and hyphens."
fi

export ZCP_REGION ZCP_PROJECT
zcp() { command zcp --region "$ZCP_REGION" --project "$ZCP_PROJECT" "$@"; }

VM_NAME="$NAME_PREFIX"
VOLUME_NAME="${NAME_PREFIX}-data"

wait_for_gone() {
  # Same as destroy-private-network.sh's wait_for_gone: only an explicit
  # "not found" error counts as gone. Any other failure (API hiccup, auth
  # blip) is retried like the instance is still present.
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
  zcp ip list -o json | jq -r --arg vm "$vm_name" '.[] | select(.vm==$vm) | .network_id // empty' | head -1 || true
}

step "Checking the storage VM"

# Resolved and ambiguity-checked FIRST, before anything is deleted, same
# reasoning as destroy-private-network.sh's VPC check.
VM_PRESENT="false"
VM_SLUG=""
VM_LIST_JSON="$(zcp instance list -o json)" || error "Could not list instances to check whether '$VM_NAME' exists."
VM_MATCHES="$(echo "$VM_LIST_JSON" | jq --arg n "$VM_NAME" '[.[] | select(.name==$n)]')"
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

step "Checking the data volume"

# The zcp CLI has no way to ask "is volume X attached to VM Y" - 'volume
# list' exposes no attachment field, and there's no 'volume get'. A bare
# name match is the best this script can do on its own, and it is not
# enough on its own: deploy-private-storage.sh explicitly tolerates finding
# an existing ${name}-data volume attached to something else entirely, which
# means the same name collision is just as possible here, and deleting the
# wrong volume is irreversible. So deploy records the slugs it resolved
# (only after its own disk-setup checks succeeded, not just after 'volume
# attach') to a small local state file, and this script prefers that over a
# name guess whenever it's present, current, and matches the VM this run
# actually resolved. Still a name-and-shape match under the hood, not a
# cryptographic one - see deploy-private-storage.sh's own comment on this -
# but a strictly stronger one than a bare name lookup with nothing else to
# go on.
VOLUME_PRESENT="false"
VOLUME_SLUG=""
VOLUME_OWNERSHIP_VERIFIED="false"
VOLUME_LEFT_UNVERIFIED="false"
# Namespaced by region+project, not just --name: two deployments that reuse
# the same --name in different regions/projects would otherwise share one
# state file, and whichever ran deploy most recently would silently clobber
# the other's record.
STATE_FILE="$HOME/.zcp-private-storage-state/${ZCP_REGION}-${ZCP_PROJECT}-${NAME_PREFIX}.json"
if [ -f "$STATE_FILE" ]; then
  STATE_VM_SLUG="$(jq -r '.vm_slug // empty' "$STATE_FILE" 2>/dev/null || true)"
  STATE_VOLUME_SLUG="$(jq -r '.volume_slug // empty' "$STATE_FILE" 2>/dev/null || true)"
  STATE_REGION="$(jq -r '.region // empty' "$STATE_FILE" 2>/dev/null || true)"
  STATE_PROJECT="$(jq -r '.project // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [ -n "$STATE_VOLUME_SLUG" ] && [ "$STATE_REGION" = "$ZCP_REGION" ] && [ "$STATE_PROJECT" = "$ZCP_PROJECT" ] \
     && { [ "$VM_PRESENT" != "true" ] || [ "$STATE_VM_SLUG" = "$VM_SLUG" ]; }; then
    # A failure of the list call itself must abort, not fall into the same
    # branch as a genuine zero-match: a transient API error is not proof the
    # volume is gone, and treating it as such would skip a real, still-
    # billable volume and then delete the local record that was the only way
    # to find it again.
    STATE_VOLUME_LIST_JSON="$(zcp volume list -o json)" || error "Could not list volumes to check whether the recorded volume '$STATE_VOLUME_SLUG' still exists. Check manually: zcp volume list"
    STATE_VOLUME_MATCH_COUNT="$(echo "$STATE_VOLUME_LIST_JSON" | jq --arg s "$STATE_VOLUME_SLUG" '[.[] | select(.slug==$s)] | length')"
    if [ "$STATE_VOLUME_MATCH_COUNT" -eq 1 ]; then
      VOLUME_PRESENT="true"
      VOLUME_SLUG="$STATE_VOLUME_SLUG"
      VOLUME_OWNERSHIP_VERIFIED="true"
      info "Volume for '$VOLUME_NAME' resolved from deploy's own recorded state, not a name match."
    elif [ "$STATE_VOLUME_MATCH_COUNT" -eq 0 ]; then
      # The volume this deploy run actually attached is gone - already
      # deleted (a prior teardown that got this far but not further, or a
      # manual delete). A genuine, successfully-checked absence, not an
      # unverifiable situation: falling through to a name match here would
      # mean deleting a DIFFERENT, merely-same-named volume on the strength
      # of a record that says this one specific volume no longer exists.
      VOLUME_OWNERSHIP_VERIFIED="true"
      info "Volume for '$VOLUME_NAME' (recorded slug '$STATE_VOLUME_SLUG') is already gone. Nothing to delete."
    else
      error "Found $STATE_VOLUME_MATCH_COUNT volumes matching the recorded slug '$STATE_VOLUME_SLUG'. This shouldn't happen. Check manually: zcp volume list"
    fi
  fi
fi
if [ "$VOLUME_OWNERSHIP_VERIFIED" != "true" ]; then
  VOLUME_LIST_JSON="$(zcp volume list -o json)" || error "Could not list volumes to check whether '$VOLUME_NAME' exists."
  VOLUME_MATCHES="$(echo "$VOLUME_LIST_JSON" | jq --arg n "$VOLUME_NAME" '[.[] | select(.name==$n)]')"
  VOLUME_MATCH_COUNT="$(echo "$VOLUME_MATCHES" | jq 'length')"
  case "$VOLUME_MATCH_COUNT" in
    0) ;;
    1)
      VOLUME_SLUG="$(echo "$VOLUME_MATCHES" | jq -r '.[0].slug')"
      [ -n "$VOLUME_SLUG" ] && [ "$VOLUME_SLUG" != "null" ] || error "Found volume '$VOLUME_NAME' but it has no slug in the API response. Check manually: zcp volume list"
      # Deploy's own recorded state is unavailable or doesn't apply (a
      # different machine, a different --region/--project, or state that
      # was never written or has since been cleaned up), so this is a bare
      # name match with nothing to verify it against - not proof this
      # volume belongs to this deployment. Refused by default: deleting on
      # a name guess alone, with no confirmation prompt in this script, is
      # exactly the risk deploy's own state file exists to avoid.
      if [ "$ALLOW_UNVERIFIED_VOLUME_DELETE" = "true" ]; then
        VOLUME_PRESENT="true"
        warn "Could not confirm '$VOLUME_NAME' ($VOLUME_SLUG) actually belongs to '$VM_NAME' - proceeding anyway because --allow-unverified-volume-delete was passed."
      else
        VOLUME_LEFT_UNVERIFIED="true"
        warn "Could not confirm '$VOLUME_NAME' ($VOLUME_SLUG) actually belongs to '$VM_NAME' - no recorded state from deploy was found (or usable) for this --name. Leaving it alone. Pass --allow-unverified-volume-delete to delete it anyway on this name match, or verify and delete it yourself: zcp volume detach $VOLUME_SLUG && zcp volume delete $VOLUME_SLUG --yes"
      fi
      ;;
    *)
      error "Ambiguous: $VOLUME_MATCH_COUNT volumes are named '$VOLUME_NAME'. This script can't safely tell them apart, and deleting the wrong one is irreversible. Rename or remove the duplicate, then re-run. (zcp volume list)"
      ;;
  esac
fi

step "Capturing the VM's network reference before deletion"
# This only works while the VM still exists. On a rerun after a previous
# invocation already deleted it, there's no '.vm' association left to find.
VM_NETWORK_ID=""
if [ "$VM_PRESENT" = "true" ]; then
  VM_NETWORK_ID="$(capture_vm_network_id "$VM_NAME")"
fi

step "Detaching the data volume"

# Explicit step, not relying on an unverified assumption about what
# 'instance delete' does to an attached volume. If both exist, detach first
# so the volume delete below never depends on how (or whether) instance
# delete handles an attached disk.
if [ "$VM_PRESENT" = "true" ] && [ "$VOLUME_PRESENT" = "true" ]; then
  if zcp volume detach "$VOLUME_SLUG"; then
    success "'$VOLUME_NAME' detached from '$VM_NAME'"
    sleep 5
  else
    warn "Could not detach '$VOLUME_NAME' from '$VM_NAME' (it may already be detached, or wasn't actually attached). Continuing."
  fi
fi

step "Deleting the storage VM"

if [ "$VM_PRESENT" = "true" ]; then
  ISSUED_COUNT=$((ISSUED_COUNT + 1))
  # A few retries, not just one attempt: the detach above is asynchronous on
  # the platform side, and an instance delete issued before it has actually
  # settled can be rejected.
  VM_DELETE_OK="false"
  for vm_delete_attempt in 1 2 3; do
    if zcp instance delete "$VM_SLUG" --yes; then
      VM_DELETE_OK="true"
      break
    fi
    if [ "$vm_delete_attempt" -lt 3 ]; then
      warn "Instance delete failed (attempt $vm_delete_attempt/3), the volume detach above may not have settled yet. Retrying in 10s..."
      sleep 10
    fi
  done
  if [ "$VM_DELETE_OK" = "true" ]; then
    info "Waiting for '$VM_NAME' to finish deleting..."
    if wait_for_gone "$VM_SLUG"; then
      success "'$VM_NAME' deleted"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
  else
    warn "Could not delete instance '$VM_NAME' ($VM_SLUG) after 3 attempts. Check manually: zcp instance list"
  fi
else
  warn "'$VM_NAME' not found, skipping."
fi

step "Deleting the data volume"

# Explicit, separate step. Deleting the VM above does not delete this.
if [ "$VOLUME_PRESENT" = "true" ]; then
  ISSUED_COUNT=$((ISSUED_COUNT + 1))
  if zcp volume delete "$VOLUME_SLUG" --yes; then
    success "'$VOLUME_NAME' deleted"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  else
    warn "Could not delete volume '$VOLUME_NAME' ($VOLUME_SLUG). It may still be attached. Check manually: zcp volume list"
  fi
elif [ "$VOLUME_LEFT_UNVERIFIED" = "true" ]; then
  warn "'$VOLUME_NAME' left alone (see the [WARN] above) - not deleted, still billable."
else
  warn "'$VOLUME_NAME' not found, skipping."
fi

step "Checking for a leftover standalone network"

# Same reasoning and same retry-before-reporting fix as
# destroy-private-network.sh: the platform releases a VM's standalone network
# asynchronously, a few seconds after the instance delete is confirmed gone.
LEFTOVER=""
UNVERIFIED=""
if [ "$VM_PRESENT" = "false" ]; then
  UNVERIFIED="${UNVERIFIED}${VM_NAME} (already gone before this run)"$'\n'
elif [ -z "$VM_NETWORK_ID" ]; then
  UNVERIFIED="${UNVERIFIED}${VM_NAME} (no network reference captured)"$'\n'
else
  found=""
  for lo_attempt in 1 2 3 4 5; do
    found="$(zcp ip list -o json | jq -r --arg id "$VM_NETWORK_ID" '.[] | select(.network_id==$id) | .slug' | head -1)"
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
if [ "$ISSUED_COUNT" -eq 0 ] && [ "$VOLUME_LEFT_UNVERIFIED" != "true" ]; then
  warn "Nothing matched --name '$NAME_PREFIX'. No resources were found or deleted. If you expected something here, check the actual prefix with: zcp instance list"
elif [ "$DELETED_COUNT" -eq "$ISSUED_COUNT" ] && [ "$VOLUME_LEFT_UNVERIFIED" != "true" ]; then
  echo "$DELETED_COUNT resource(s) removed for --name '$NAME_PREFIX'." >&2
  # The recorded state's only purpose was resolving this exact teardown by
  # confirmed slug rather than a name guess - stale once everything it
  # points at is gone.
  rm -f "$STATE_FILE"
elif [ "$VOLUME_LEFT_UNVERIFIED" = "true" ]; then
  echo "$DELETED_COUNT resource(s) removed for --name '$NAME_PREFIX'. The data volume was left alone - see the [WARN] lines above." >&2
else
  warn "$ISSUED_COUNT delete(s) issued, only $DELETED_COUNT confirmed. Check the [WARN] lines above for what didn't confirm in time."
fi

# Same LEFTOVER/UNVERIFIED exit logic as destroy-private-network.sh: LEFTOVER
# always signals incomplete cleanup, UNVERIFIED only does when the VM delete
# was actually issued THIS run (gated on VM_PRESENT, captured before deletion
# above - not on ISSUED_COUNT, which also counts the unrelated volume delete
# and would otherwise force a false exit 2 on the documented recovery path:
# run 1 deletes the VM but the volume delete fails while still detaching,
# run 2 finds the VM already gone and cleanly deletes the volume, and that
# second run must be able to report a real success). Also: a delete that was
# issued but not confirmed (e.g. the volume delete failing because the VM
# hadn't finished detaching from it) must make this exit non-zero too - the
# whole point of this script, per its own header comment, is making sure the
# volume doesn't silently stay billable, and a plain [WARN] with exit 0
# defeats that for anything scripted against it (CI, automation).
if [ -n "$LEFTOVER" ] \
   || { [ -n "$UNVERIFIED" ] && [ "$VM_PRESENT" = "true" ]; } \
   || [ "$DELETED_COUNT" -ne "$ISSUED_COUNT" ] \
   || [ "$VOLUME_LEFT_UNVERIFIED" = "true" ]; then
  exit 2
fi
