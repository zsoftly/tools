#!/bin/bash
# ZCP Private Shared Storage Deployer
# Runs the ZCP Tutorial 2 workflow (Deploy Private Shared Storage) end to end.
# Deploys an NFS file share on a VM inside an EXISTING private tier (built by
# zcp/build-private-network.sh, Tutorial 1). A separate data volume, exported
# to both the tier CIDR and the Headscale mesh range, reachable only through
# the mesh. The VM gets a public IP for SSH admin access only; NFS is never
# exposed on it.
#
# Usage:
#   ./deploy-private-storage.sh --ssh-key my-key --tier-name my-workspace-tier [options]
#
# Requires: zcp CLI (authenticated), jq, ssh, curl
set -e
set -o pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAME_PREFIX="storage"
TIER_NAME=""
MESH_CIDR="100.64.0.0/10"
SHARE_NAME="company-share"
SSH_KEY=""
MY_IP=""
VM_TEMPLATE="ubuntu-2404-lts-1"
VM_PLAN=""
NETWORK_PLAN=""
VM_STORAGE_CATEGORY=""
VOLUME_STORAGE_CATEGORY=""
VOLUME_SIZE="20"
BILLING_CYCLE="hourly"
AUTO_YES="false"
SSH_WAIT_SECONDS=180

# ---------------------------------------------------------------------------
# Output helpers (matches build-private-network.sh conventions). All write to
# stderr so a message is never lost inside a $(...) command substitution.
# ---------------------------------------------------------------------------
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
ZCP Private Shared Storage Deployer

Usage: $0 --ssh-key <name> --tier-name <tier-name> [options]

Required:
  --ssh-key NAME    Name of an existing 'zcp ssh-key' entry.
  --tier-name NAME  The private tier to attach to, e.g. 'my-workspace-tier' from
                    build-private-network.sh. Not auto-discovered: an account can hold
                    more than one private tier, and guessing which one is unsafe.

Common overrides (auto-discovered or set to a default value if you leave them out):
  --region REGION                 zcp region slug (or \$ZCP_REGION)
  --project PROJECT               zcp project slug (or \$ZCP_PROJECT)
  --name PREFIX                   Base name for the VM and volume (default: storage)
                                  -> \${PREFIX}, \${PREFIX}-data
  --share-name NAME               NFS share directory name (default: company-share)
  --my-ip CIDR                    Your public IP in CIDR form, used to scope admin-port access
                                  (default: auto-detected via ifconfig.me, with /32 appended)
  --vm-template SLUG              OS template slug (default: ubuntu-2404-lts-1)
  --vm-plan SLUG                  Compute plan for the storage VM
  --network-plan SLUG             Network plan for the VM's public IP
  --vm-storage-category SLUG      Storage category for the VM's root disk
  --volume-storage-category SLUG  Storage category for the data volume
  --volume-size GB                Data volume size in GB (default: 20)
  --billing-cycle CYCLE           hourly or monthly (default: hourly)
  -y, --yes                       Skip the "resources about to be created" confirmation prompt
  -h, --help                      Show this help

If you omit a flag, the script looks up a default with 'zcp plan' or 'zcp storage-category' and
prints what it picked. Pass the flag explicitly to skip the lookup and pin your own value.

Example:
  ./deploy-private-storage.sh --ssh-key my-key --tier-name my-workspace-tier --name my-storage
EOF
}

require_value() {
  # $1 = flag name, $2 = the next positional value (or unset/missing)
  if [[ -z "${2:-}" || "$2" == -* ]]; then
    error "$1 requires a value."
  fi
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) require_value "$1" "${2:-}"; ZCP_REGION="$2"; shift 2 ;;
    --project) require_value "$1" "${2:-}"; ZCP_PROJECT="$2"; shift 2 ;;
    --name) require_value "$1" "${2:-}"; NAME_PREFIX="$2"; shift 2 ;;
    --tier-name) require_value "$1" "${2:-}"; TIER_NAME="$2"; shift 2 ;;
    --share-name) require_value "$1" "${2:-}"; SHARE_NAME="$2"; shift 2 ;;
    --ssh-key) require_value "$1" "${2:-}"; SSH_KEY="$2"; shift 2 ;;
    --my-ip) require_value "$1" "${2:-}"; MY_IP="$2"; shift 2 ;;
    --vm-template) require_value "$1" "${2:-}"; VM_TEMPLATE="$2"; shift 2 ;;
    --vm-plan) require_value "$1" "${2:-}"; VM_PLAN="$2"; shift 2 ;;
    --network-plan) require_value "$1" "${2:-}"; NETWORK_PLAN="$2"; shift 2 ;;
    --vm-storage-category) require_value "$1" "${2:-}"; VM_STORAGE_CATEGORY="$2"; shift 2 ;;
    --volume-storage-category) require_value "$1" "${2:-}"; VOLUME_STORAGE_CATEGORY="$2"; shift 2 ;;
    --volume-size) require_value "$1" "${2:-}"; VOLUME_SIZE="$2"; shift 2 ;;
    --billing-cycle) require_value "$1" "${2:-}"; BILLING_CYCLE="$2"; shift 2 ;;
    -y|--yes) AUTO_YES="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1 (see --help)" ;;
  esac
done

NAME_RE='^[a-zA-Z0-9-]+$'
if ! [[ "$NAME_PREFIX" =~ $NAME_RE ]]; then
  error "--name '$NAME_PREFIX' must contain only letters, numbers, and hyphens (it's used in resource names, jq filters, and remote commands)."
fi
if ! [[ "$SHARE_NAME" =~ $NAME_RE ]]; then
  error "--share-name '$SHARE_NAME' must contain only letters, numbers, and hyphens (it's used as a directory name and an NFS export path)."
fi
if ! [[ "$VOLUME_SIZE" =~ ^[0-9]+$ ]] || [ "$VOLUME_SIZE" -lt 1 ]; then
  error "--volume-size '$VOLUME_SIZE' must be a positive whole number of GB."
fi

VM_NAME="$NAME_PREFIX"
VOLUME_NAME="${NAME_PREFIX}-data"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
step "Preflight checks"

command -v zcp >/dev/null 2>&1 || error "zcp CLI not found. Install it first: https://docs.zcp.zsoftly.ca/public-cloud/cli/installation"
command -v jq >/dev/null 2>&1 || error "jq not found. Install it (apt install jq / brew install jq) and re-run."
command -v ssh >/dev/null 2>&1 || error "ssh client not found."

zcp auth validate >/dev/null 2>&1 || error "zcp CLI is not authenticated. Run 'zcp profile add default' first."

[ -n "${ZCP_REGION:-}" ] || error "--region (or \$ZCP_REGION) is required."
[ -n "${ZCP_PROJECT:-}" ] || error "--project (or \$ZCP_PROJECT) is required."
[ -n "$SSH_KEY" ] || error "--ssh-key is required. Import one first: zcp ssh-key import --name <name> --key-file ~/.ssh/id_ed25519.pub"
[ -n "$TIER_NAME" ] || error "--tier-name is required. Use the tier build-private-network.sh created, e.g. 'my-workspace-tier'."

export ZCP_REGION ZCP_PROJECT
zcp() { command zcp --region "$ZCP_REGION" --project "$ZCP_PROJECT" "$@"; }

zcp ssh-key list -o json | jq -e --arg n "$SSH_KEY" '.[] | select(.name==$n)' >/dev/null 2>&1 \
  || error "SSH key '$SSH_KEY' not found in this account (zcp ssh-key list)."

success "zcp CLI authenticated, region=$ZCP_REGION project=$ZCP_PROJECT"

# Resolved and ambiguity-checked up front, same reasoning as every
# *_slug_for_name helper in build-private-network.sh: a bare name can be
# ambiguous (slugs auto-suffix on collision), and this is the tier every NFS
# export/UFW rule below is scoped to, so guessing wrong is a real isolation
# risk, not just an inconvenience.
TIER_LIST_JSON="$(zcp network list -o json)" || error "Could not list networks to find '$TIER_NAME'."
TIER_MATCHES="$(echo "$TIER_LIST_JSON" | jq --arg n "$TIER_NAME" '[.[] | select(.name==$n)]')"
TIER_MATCH_COUNT="$(echo "$TIER_MATCHES" | jq 'length')"
case "$TIER_MATCH_COUNT" in
  0) error "Tier '$TIER_NAME' not found. Run build-private-network.sh first, or check the name with 'zcp network list'." ;;
  1)
    TIER_SLUG="$(echo "$TIER_MATCHES" | jq -r '.[0].slug')"
    [ -n "$TIER_SLUG" ] && [ "$TIER_SLUG" != "null" ] || error "Found tier '$TIER_NAME' but it has no slug in the API response. Check manually: zcp network list"
    ;;
  *) error "Ambiguous: $TIER_MATCH_COUNT networks are named '$TIER_NAME'. This script can't safely tell them apart, rename or remove the duplicate, then re-run. (zcp network list)" ;;
esac

TIER_DETAILS_JSON="$(zcp network get "$TIER_SLUG" -o json)" || error "Could not look up details for tier '$TIER_NAME'."
TIER_CIDR="$(echo "$TIER_DETAILS_JSON" | jq -r '.[] | select(.field=="CIDR") | .value' | head -1 || true)"
[ -n "$TIER_CIDR" ] && [ "$TIER_CIDR" != "null" ] || error "Could not determine the CIDR for tier '$TIER_NAME'. Check manually: zcp network get $TIER_SLUG"
# TIER_CIDR is interpolated into remote shell commands and an /etc/exports
# line later, so its shape is checked here rather than trusted blindly, the
# same reasoning --name/--share-name get a format check for. Bounded to real
# octets (0-255) and a real prefix (0-32), not just digit-shaped: a loose
# [0-9]{1,2} prefix would let /33+ through and silently defeat the tier-NIC
# membership check further down (a left-shift past 32 bits masks to zero).
OCTET_RE='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
PREFIX_RE='(3[0-2]|[1-2][0-9]|[0-9])'
if ! [[ "$TIER_CIDR" =~ ^${OCTET_RE}\.${OCTET_RE}\.${OCTET_RE}\.${OCTET_RE}/${PREFIX_RE}$ ]]; then
  error "Tier '$TIER_NAME' has an unexpected CIDR format: '$TIER_CIDR'. Check manually: zcp network get $TIER_SLUG"
fi
info "Tier '$TIER_NAME' found: $TIER_CIDR"

if [ -n "$MY_IP" ]; then
  # User-supplied, checked with the same OCTET_RE/PREFIX_RE pair as TIER_CIDR
  # above: MY_IP is interpolated straight into firewall rules below, so an
  # unvalidated value would reach the zcp/ufw calls unchecked.
  if ! [[ "$MY_IP" =~ ^${OCTET_RE}\.${OCTET_RE}\.${OCTET_RE}\.${OCTET_RE}/${PREFIX_RE}$ ]]; then
    error "--my-ip '$MY_IP' must be a valid IPv4 CIDR, including the prefix (e.g. 203.0.113.5/32)."
  fi
fi
if [ -z "$MY_IP" ]; then
  info "Detecting your public IP..."
  DETECTED_IP="$(curl -4 -fsSL https://ifconfig.me)" || error "Could not detect your public IP. Pass --my-ip explicitly."
  if ! [[ "$DETECTED_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error "Detected public IP '$DETECTED_IP' is not a valid IPv4 address. Pass --my-ip explicitly (e.g. --my-ip 203.0.113.5/32)."
  fi
  MY_IP="${DETECTED_IP}/32"
fi
info "Admin-port access scoped to: $MY_IP"

resolve() {
  local flag_val="$1" label="$2" lookup_cmd="$3" field="$4"
  if [ -n "$flag_val" ]; then
    echo "$flag_val"
    return
  fi
  local resolved
  resolved="$(eval "$lookup_cmd" | jq -r "$field" | head -1 || true)"
  [ -n "$resolved" ] && [ "$resolved" != "null" ] || error "Could not auto-discover $label. Pass it explicitly (see --help)."
  echo "$resolved"
}

VM_PLAN="$(resolve "$VM_PLAN" "storage VM compute plan" "zcp plan vm -o json" '.[0].slug')"
NETWORK_PLAN="$(resolve "$NETWORK_PLAN" "network plan" "zcp plan network -o json" '.[0].slug')"
VM_STORAGE_CATEGORY="$(resolve "$VM_STORAGE_CATEGORY" "VM storage category" "zcp storage-category list -o json" '.[0].slug')"
VOLUME_STORAGE_CATEGORY="$(resolve "$VOLUME_STORAGE_CATEGORY" "volume storage category" "zcp storage-category list -o json" '.[0].slug')"

info "Resolved resources:"
echo "    Tier                     : $TIER_NAME ($TIER_CIDR)" >&2
echo "    VM template              : $VM_TEMPLATE" >&2
echo "    VM plan                  : $VM_PLAN" >&2
echo "    Network plan             : $NETWORK_PLAN" >&2
echo "    VM storage category      : $VM_STORAGE_CATEGORY" >&2
echo "    Volume storage category  : $VOLUME_STORAGE_CATEGORY" >&2
echo "    Volume size              : ${VOLUME_SIZE}GB" >&2

if [ "$AUTO_YES" != "true" ]; then
  echo "" >&2
  echo "This creates a VM (plan above) and a ${VOLUME_SIZE}GB data volume on your account now." >&2
  echo "Billing starts as soon as each resource is created." >&2
  read -r -p "Type 'yes' to continue: " CONFIRM
  [ "$CONFIRM" = "yes" ] || error "Cancelled. Re-run with the flags above (or --yes to skip this prompt) when ready."
fi

# ---------------------------------------------------------------------------
# Existence + slug lookup helpers (same pattern as build-private-network.sh)
# ---------------------------------------------------------------------------
instance_exists() {
  local list_json
  list_json="$(zcp instance list -o json)" || error "Could not list instances to check whether '$1' already exists."
  echo "$list_json" | jq -e --arg n "$1" '.[] | select(.name==$n)' >/dev/null 2>&1
}
volume_exists() {
  local list_json
  list_json="$(zcp volume list -o json)" || error "Could not list volumes to check whether '$1' already exists."
  echo "$list_json" | jq -e --arg n "$1" '.[] | select(.name==$n)' >/dev/null 2>&1
}

slug_for_name() {
  local label="$1" list_cmd="$2" name="$3" list_json matches count
  list_json="$(eval "$list_cmd")" || error "Could not list ${label}s to resolve the slug for '$name'."
  matches="$(echo "$list_json" | jq --arg n "$name" '[.[] | select(.name==$n)]')"
  count="$(echo "$matches" | jq 'length')"
  case "$count" in
    0) error "No $label named '$name' found after creation. This shouldn't happen, check manually: $list_cmd" ;;
    1) echo "$matches" | jq -r '.[0].slug' ;;
    *) error "Ambiguous: $count ${label}s are named '$name'. This script can't safely tell them apart, rename or remove the duplicate, then re-run. ($list_cmd)" ;;
  esac
}

instance_slug_for_name() { slug_for_name "instance" "zcp instance list -o json" "$1"; }

wait_for_ssh() {
  local ip="$1" timeout="$2" user="${3:-ubuntu}" waited=0
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  info "Waiting for SSH on $ip..."
  while ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "${user}@${ip}" true 2>/dev/null; do
    waited=$((waited + 5))
    [ "$waited" -ge "$timeout" ] && error "SSH on $ip did not become ready within ${timeout}s. If this VM was already locked down to a previous --my-ip, and your real IP is different now, add a rule for it manually (zcp firewall create --ip <ip-slug> --protocol tcp --start-port 22 --end-port 22 --cidr <your-ip>/32) and re-run."
    sleep 5
  done
  success "SSH ready on $ip"
}

remote() {
  # Retries on ssh's own exit code 255 only, same reasoning as
  # build-private-network.sh's remote(): a connection can transiently time
  # out and recover seconds later with no underlying problem. The `set +e`
  # around the ssh call is not decorative: most call sites below invoke this
  # as a bare statement (netplan apply, apt-get install, the disk-setup/
  # exports/ufw heredocs), and under `set -e` a bare failing command in that
  # position aborts the whole script immediately, before `status=$?` on the
  # next line ever runs - the retry loop below never executed for those.
  # Verified directly against this file's real call-site patterns: bare
  # statements died on the first 255 with zero retries without this pair;
  # the two call sites already inside a `$(... || true)` substitution were
  # unaffected either way, since bash already suspends errexit there. With
  # the pair, all call sites get the retry uniformly.
  local ip="$1" cmd="$2" user="${3:-ubuntu}" attempt status
  for attempt in 1 2 3; do
    set +e
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${user}@${ip}" "$cmd"
    status=$?
    set -e
    [ "$status" -ne 255 ] && return "$status"
    [ "$attempt" -lt 3 ] && sleep 5
  done
  return "$status"
}

# jq helpers, ported verbatim from build-private-network.sh. Same
# range-aware port matching and case-insensitive protocol matching, both
# confirmed necessary live there.
JQ_PORT_MATCH='def port_has($target): (. // "" | tostring) as $p | ($p == ($target|tostring)) or (($p | test("^[0-9]+-[0-9]+$")) and (($p / "-") as $r | ($r[0]|tonumber) <= $target and $target <= ($r[1]|tonumber))); def proto_is($target): (. // "" | ascii_downcase) == $target;'

# Locks SSH down to $MY_IP on the given IP slug. Ported verbatim from
# build-private-network.sh's lock_down_ssh: same create-verify-before-delete
# ordering, same delete-and-verify-in-one-retry-loop for both the scoped-rule
# confirmation and the open-rule cleanup (both confirmed live to need retries
# against real API/platform propagation delays), same reason for being called
# before wait_for_ssh (only talks to the zcp API, so a rerun from a new IP can
# reconcile before anything tries to connect).
lock_down_ssh() {
  local ip_slug="$1" vm_label="$2"

  if ! zcp firewall list --ip "$ip_slug" -o json | jq -e --arg c "$MY_IP" \
      "$JQ_PORT_MATCH"' .[] | select((.protocol | proto_is("tcp")) and (.ports | port_has(22)) and .cidr==$c)' >/dev/null 2>&1; then
    zcp firewall create --ip "$ip_slug" --protocol tcp --start-port 22 --end-port 22 --cidr "$MY_IP"
  fi
  local confirmed="false" attempt
  for attempt in 1 2 3 4 5; do
    if zcp firewall list --ip "$ip_slug" -o json | jq -e --arg c "$MY_IP" \
        "$JQ_PORT_MATCH"' .[] | select((.protocol | proto_is("tcp")) and (.ports | port_has(22)) and .cidr==$c)' >/dev/null 2>&1; then
      confirmed="true"
      break
    fi
    sleep 3
  done
  [ "$confirmed" = "true" ] \
    || error "Could not confirm the scoped SSH rule for $MY_IP exists on '$vm_label' after ${attempt} attempts. Not removing anything until this is fixed. Check manually: zcp firewall list --ip $ip_slug"

  local stale_ids
  stale_ids="$(zcp firewall list --ip "$ip_slug" -o json | jq -r --arg c "$MY_IP" \
    "$JQ_PORT_MATCH"' .[] | select((.protocol | proto_is("tcp")) and (.ports | port_has(22)) and .cidr!="0.0.0.0/0" and .cidr!=$c) | .id')"
  if [ -n "$stale_ids" ]; then
    warn "Found SSH rule(s) on '$vm_label' scoped to a different IP than today's ($MY_IP), removing them. Your IP may have changed since the last run."
    while read -r rule_id; do
      [ -n "$rule_id" ] && zcp firewall delete "$rule_id" --ip "$ip_slug" --yes
    done <<< "$stale_ids"
  fi

  local still_open open_ids
  for attempt in 1 2 3 4 5; do
    open_ids="$(zcp firewall list --ip "$ip_slug" -o json | jq -r "$JQ_PORT_MATCH"' .[] | select(((.protocol | proto_is("tcp")) or (.protocol | proto_is("udp"))) and (.ports | port_has(22)) and .cidr=="0.0.0.0/0") | .id' || true)"
    if [ -n "$open_ids" ]; then
      while read -r rule_id; do
        [ -n "$rule_id" ] && zcp firewall delete "$rule_id" --ip "$ip_slug" --yes
      done <<< "$open_ids"
    fi
    still_open="$(zcp firewall list --ip "$ip_slug" -o json | jq "$JQ_PORT_MATCH"' [.[] | select(((.protocol | proto_is("tcp")) or (.protocol | proto_is("udp"))) and (.ports | port_has(22)) and .cidr=="0.0.0.0/0")] | length' || true)"
    [ "$still_open" = "0" ] && break
    sleep 3
  done
  [ "$still_open" = "0" ] || error "Lockdown failed: $still_open rule(s) still expose 0.0.0.0/0 on port 22 for '$vm_label' after ${attempt} attempts. Check manually: zcp firewall list --ip $ip_slug"

  confirmed="false"
  for attempt in 1 2 3 4 5; do
    if zcp firewall list --ip "$ip_slug" -o json | jq -e --arg c "$MY_IP" \
        "$JQ_PORT_MATCH"' .[] | select((.protocol | proto_is("tcp")) and (.ports | port_has(22)) and .cidr==$c)' >/dev/null 2>&1; then
      confirmed="true"
      break
    fi
    sleep 3
  done
  [ "$confirmed" = "true" ] \
    || error "Lockdown failed: the scoped rule for $MY_IP on '$vm_label' is gone after cleanup (checked ${attempt} times). Check manually: zcp firewall list --ip $ip_slug"
}

# ---------------------------------------------------------------------------
# Step 1: Storage VM
# ---------------------------------------------------------------------------
step "Step 1/4: Deploy the storage VM"

# A public IP is allocated deliberately, same reasoning as the router in
# build-private-network.sh: a VM with no public footprint at all can't be
# reached even for the one-time tier-NIC setup. SSH is then locked to your
# own IP, and NFS is never opened on the public side at all, so the VM ends
# up just as unreachable for NFS as a no-public-IP VM would be.
if ! instance_exists "$VM_NAME"; then
  zcp instance create --name "$VM_NAME" \
    --template "$VM_TEMPLATE" --plan "$VM_PLAN" --billing-cycle "$BILLING_CYCLE" \
    --network-plan "$NETWORK_PLAN" --storage-category "$VM_STORAGE_CATEGORY" \
    --ssh-key "$SSH_KEY" --wait
  success "'$VM_NAME' created"
else
  warn "'$VM_NAME' already exists, skipping creation."
fi
VM_SLUG="$(instance_slug_for_name "$VM_NAME")"

if ! ADDNET_OUTPUT="$(zcp instance add-network "$VM_SLUG" --network "$TIER_SLUG" 2>&1)"; then
  if echo "$ADDNET_OUTPUT" | grep -qi "already"; then
    warn "Tier network already attached to '$VM_NAME'."
  else
    error "Failed to attach tier network to '$VM_NAME': $ADDNET_OUTPUT"
  fi
else
  success "'$VM_NAME' attached to '$TIER_NAME'"
fi

# --plan fails here with an API 500 (Undefined property: stdClass::$storage) -
# confirmed on this platform. --size is the only working option.
if ! volume_exists "$VOLUME_NAME"; then
  zcp volume create --name "$VOLUME_NAME" --billing-cycle "$BILLING_CYCLE" \
    --storage-category "$VOLUME_STORAGE_CATEGORY" --size "$VOLUME_SIZE" --vm "$VM_SLUG"
  success "Data volume '$VOLUME_NAME' created and attached (${VOLUME_SIZE}GB)"
  VOLUME_SLUG="$(slug_for_name "volume" "zcp volume list -o json" "$VOLUME_NAME")"
else
  # A rerun where a previous attempt created the volume but failed before (or
  # without) attaching it - e.g. the VM had to be recreated after the volume
  # already existed - must not silently leave it unattached. --vm at create
  # time only covers the fresh-create path above.
  VOLUME_SLUG="$(slug_for_name "volume" "zcp volume list -o json" "$VOLUME_NAME")"
  if ! ATTACH_OUTPUT="$(zcp volume attach "$VOLUME_SLUG" --vm "$VM_SLUG" 2>&1)"; then
    if echo "$ATTACH_OUTPUT" | grep -qi "already"; then
      # "already" here could mean already attached to THIS VM, or to some
      # other VM from an earlier run - 'zcp volume list' doesn't expose
      # attachment state to tell the two apart ahead of time. Not trusted
      # blindly: if this volume isn't actually on this VM, Step 2 below fails
      # loudly (no second disk found) rather than silently mounting the root
      # disk's own filesystem.
      warn "Volume '$VOLUME_NAME' reported as already attached somewhere ($ATTACH_OUTPUT). If Step 2 can't find a second disk, it's attached to a different VM - detach it manually: zcp volume detach $VOLUME_SLUG"
    else
      error "Volume '$VOLUME_NAME' exists but could not be attached to '$VM_NAME': $ATTACH_OUTPUT"
    fi
  else
    success "Existing volume '$VOLUME_NAME' attached to '$VM_NAME'"
  fi
fi

VM_INSTANCE_JSON="$(zcp instance get "$VM_SLUG" -o json)" || error "Could not look up instance details for '$VM_NAME'."
VM_IP="$(echo "$VM_INSTANCE_JSON" | jq -r '.[] | select(.field=="Public IP") | .value' | head -1 || true)"
[ -n "$VM_IP" ] && [ "$VM_IP" != "null" ] || error "Could not determine '$VM_NAME' public IP."
VM_USER="$(echo "$VM_INSTANCE_JSON" | jq -r '.[] | select(.field=="Username") | .value' | head -1 || true)"
[ -n "$VM_USER" ] && [ "$VM_USER" != "null" ] || VM_USER="ubuntu"
info "Storage VM public IP: $VM_IP"

# Runs BEFORE wait_for_ssh, same reasoning as build-private-network.sh: only
# talks to the zcp API, so a rerun from a new $MY_IP reconciles before
# anything tries to connect, instead of deadlocking against the old rule.
IP_SLUG="$(zcp ip list -o json | jq -r --arg vm "$VM_NAME" '.[] | select(.vm==$vm) | .slug' | head -1 || true)"
[ -n "$IP_SLUG" ] || error "Could not find the public IP slug for '$VM_NAME'."

info "Locking down SSH to your own IP (nothing else is ever opened on the public side)..."
lock_down_ssh "$IP_SLUG" "$VM_NAME"

wait_for_ssh "$VM_IP" "$SSH_WAIT_SECONDS" "$VM_USER"

# ---------------------------------------------------------------------------
# Step 2: Tier NIC + data disk
# ---------------------------------------------------------------------------
step "Step 2/4: Bring up the tier NIC and prepare the data disk"

info "Bringing up the tier NIC (hot-added, not auto-configured by the OS)..."
# Same exclusions as build-private-network.sh's router: lo, enp* (the VM's
# own public NIC), tailscale* (not applicable here, but kept for consistency
# and in case this VM is ever joined to the mesh for troubleshooting).
TIER_NIC="$(remote "$VM_IP" "ip -br link show | awk '{print \$1}' | grep -v '^lo\$' | grep -v '^enp' | grep -v '^tailscale' | tail -1" "$VM_USER" || true)"
[ -n "$TIER_NIC" ] || error "Could not identify the tier NIC on '$VM_NAME'. Check manually: ssh ${VM_USER}@$VM_IP 'ip -br link show'"
remote "$VM_IP" "sudo tee /etc/netplan/60-tier-nic.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${TIER_NIC}:
      dhcp4: true
EOF" "$VM_USER"
remote "$VM_IP" "sudo netplan apply" "$VM_USER"
sleep 5
VM_TIER_IP="$(remote "$VM_IP" "ip -4 -br addr show ${TIER_NIC} | awk '{print \$3}' | cut -d/ -f1" "$VM_USER" || true)"
[ -n "$VM_TIER_IP" ] || error "Tier NIC did not come up with an address. Check manually: ssh ${VM_USER}@$VM_IP"
# Belt and suspenders, same reasoning as build-private-network.sh's router NIC
# check: even with the interface-name exclusions above, confirm the address
# that actually came up is really on the tier, not some other interface that
# slipped through the selection. A real prefix-aware check, not a first-three-
# octets guess - --tier-name accepts any existing tier, and a /16 or other
# non-/24 CIDR would false-positive-error a correctly configured NIC.
ip_to_int() {
  local IFS=. o1 o2 o3 o4
  read -r o1 o2 o3 o4 <<< "$1"
  echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}
TIER_NET="${TIER_CIDR%%/*}"
TIER_PREFIX="${TIER_CIDR##*/}"
TIER_MASK=$(( TIER_PREFIX == 0 ? 0 : (0xFFFFFFFF << (32 - TIER_PREFIX)) & 0xFFFFFFFF ))
VM_TIER_IP_INT="$(ip_to_int "$VM_TIER_IP")"
TIER_NET_INT="$(ip_to_int "$TIER_NET")"
if [ $(( VM_TIER_IP_INT & TIER_MASK )) -ne $(( TIER_NET_INT & TIER_MASK )) ]; then
  error "Interface '$TIER_NIC' came up with $VM_TIER_IP, which is not on the tier ($TIER_CIDR). Wrong interface selected. Check manually: ssh ${VM_USER}@$VM_IP 'ip -br addr show'"
fi
success "Tier NIC ($TIER_NIC) up at $VM_TIER_IP"

info "Formatting and mounting the data disk (idempotent: skips an already-formatted disk)..."
# Detects the data disk as "the whole disk that isn't the root disk", rather
# than assuming a fixed device name like vdb, since the underlying device naming
# can vary by platform/driver. Written to a file and executed rather than
# passed inline: this script has its own internal $-variables that must NOT
# be expanded by the local shell building the remote() command string, only
# by the remote one, and a quoted heredoc terminator ('DISKSETUP') is the
# simplest way to guarantee that, matching the netplan heredoc's approach
# just above.
#
# Selection is NOT trusted on the ROOT_DISK name alone: a wrong guess here
# means running mkfs on the root disk. If PKNAME can't resolve the root
# disk's parent (e.g. an unpartitioned whole-disk root), this fails loudly
# instead of guessing one from the device name. The selected DATA_DEV is then
# independently confirmed to have nothing mounted anywhere on it or its
# partitions, and to be within an order of magnitude of the requested
# --volume-size, before mkfs ever runs.
remote "$VM_IP" "cat > \$HOME/storage-disk-setup.sh <<'DISKSETUP'
#!/bin/bash
set -e
SHARE_NAME=\"\$1\"
EXPECT_SIZE_GB=\"\$2\"
ROOT_SRC=\"\$(findmnt -no SOURCE /)\"
ROOT_DISK=\"\$(lsblk -no PKNAME \"\$ROOT_SRC\" 2>/dev/null || true)\"
if [ -z \"\$ROOT_DISK\" ]; then
  echo \"ERROR: could not resolve the parent disk of the root filesystem (\$ROOT_SRC). Refusing to guess which disk is safe to format.\" >&2
  exit 1
fi
NON_ROOT_DISKS=\"\$(lsblk -dno NAME,TYPE | awk -v root=\"\$ROOT_DISK\" '\$2==\"disk\" && \$1!=root {print \$1}')\"
if [ -z \"\$NON_ROOT_DISKS\" ]; then
  echo 'ERROR: could not identify the data disk (found only the root disk)' >&2
  exit 1
fi
NON_ROOT_COUNT=\$(printf '%s\n' \"\$NON_ROOT_DISKS\" | wc -l)
if [ \"\$NON_ROOT_COUNT\" -gt 1 ]; then
  echo \"ERROR: found \$NON_ROOT_COUNT non-root disks, expected exactly one. Refusing to guess which one is this script's data volume (a non-default --vm-template, or a leftover disk from outside this script, can cause this). Check manually: lsblk\" >&2
  exit 1
fi
DATA_DEV=\"/dev/\$NON_ROOT_DISKS\"
CURRENT_MOUNTS=\"\$(lsblk -no MOUNTPOINTS \"\$DATA_DEV\" | tr -d '[:space:]')\"
if [ -n \"\$CURRENT_MOUNTS\" ] && [ \"\$CURRENT_MOUNTS\" != \"/srv/nfs\" ]; then
  echo \"ERROR: \$DATA_DEV (or a partition on it) is already mounted at '\$CURRENT_MOUNTS', not /srv/nfs. Refusing to touch it.\" >&2
  exit 1
fi
if [ -z \"\$CURRENT_MOUNTS\" ]; then
  # Only sanity-checked before this disk has ever been touched. A disk already
  # mounted at /srv/nfs is this script's own prior run (or a post-reboot
  # fstab automount) - skip the recheck so a rerun with a different
  # --volume-size than originally used doesn't false-positive on an existing,
  # already-correct disk.
  DEV_SIZE_GB=\$(( \$(lsblk -dnbo SIZE \"\$DATA_DEV\") / 1073741824 ))
  if [ \"\$DEV_SIZE_GB\" -lt \$(( EXPECT_SIZE_GB / 2 )) ] || [ \"\$DEV_SIZE_GB\" -gt \$(( EXPECT_SIZE_GB * 2 )) ]; then
    echo \"ERROR: \$DATA_DEV is \${DEV_SIZE_GB}GB, expected roughly \${EXPECT_SIZE_GB}GB. Refusing to format a disk that doesn't match the requested volume size.\" >&2
    exit 1
  fi
  echo \"Data disk: \$DATA_DEV (\${DEV_SIZE_GB}GB)\"
else
  echo \"Data disk: \$DATA_DEV (already mounted at /srv/nfs, this is a rerun)\"
fi
# wipefs, not blkid -s TYPE: blkid -s TYPE only reports a filesystem sitting
# directly on the whole disk, and returns empty for a disk that instead has a
# partition table (GPT/MBR) with no top-level filesystem - even though that
# disk is very much not blank. wipefs -n reports every signature it finds
# (filesystem, partition table, RAID superblock, ...) in one pass, so a
# non-empty result here means \"don't touch it\", not specifically \"has ext4\".
if [ -n \"\$(sudo wipefs -n \"\$DATA_DEV\" 2>/dev/null)\" ]; then
  echo 'Already formatted or partitioned, skipping mkfs.'
else
  sudo mkfs.ext4 -F \"\$DATA_DEV\"
fi
# Re-checked after the above rather than assumed: a disk wipefs found a
# signature on (so mkfs was skipped) is not guaranteed to have a directly
# mountable filesystem - a partition table alone has no TYPE. Failing loudly
# here is far better than mounting/fstab-ing a device that isn't actually
# usable as one.
DATA_TYPE=\"\$(sudo blkid -s TYPE -o value \"\$DATA_DEV\" 2>/dev/null)\"
if [ -z \"\$DATA_TYPE\" ]; then
  echo \"ERROR: \$DATA_DEV has no directly-mountable filesystem (only a partition table or other signature was found, not a TYPE). Refusing to guess how to mount or fstab-configure it. Check manually: sudo wipefs \$DATA_DEV; sudo blkid \$DATA_DEV\" >&2
  exit 1
fi
sudo mkdir -p /srv/nfs
if ! mountpoint -q /srv/nfs; then
  sudo mount \"\$DATA_DEV\" /srv/nfs
fi
sudo mkdir -p \"/srv/nfs/\$SHARE_NAME\"
# fstab is keyed by filesystem UUID, not the raw device path: the device name
# can enumerate differently after a reboot, and nofail keeps a missing/changed
# device from dropping the VM to emergency mode with no SSH. The filesystem
# type is DATA_TYPE, whatever was actually detected above - not hardcoded to
# ext4, since a recycled volume formatted with something else would otherwise
# get an fstab entry that silently fails to mount on every future boot.
DATA_UUID=\"\$(sudo blkid -s UUID -o value \"\$DATA_DEV\")\"
if [ -z \"\$DATA_UUID\" ]; then
  echo \"ERROR: \$DATA_DEV has no filesystem UUID (blkid returned empty). Refusing to add a blank UUID= line to /etc/fstab.\" >&2
  exit 1
fi
grep -qF \"UUID=\$DATA_UUID \" /etc/fstab || echo \"UUID=\$DATA_UUID /srv/nfs \$DATA_TYPE defaults,noatime,nofail 0 2\" | sudo tee -a /etc/fstab >/dev/null
DISKSETUP
chmod +x \$HOME/storage-disk-setup.sh
sudo \$HOME/storage-disk-setup.sh '$SHARE_NAME' '$VOLUME_SIZE'
ds_status=\$?
rm -f \$HOME/storage-disk-setup.sh
exit \$ds_status" "$VM_USER"
success "Data disk formatted and mounted at /srv/nfs, share directory /srv/nfs/$SHARE_NAME ready"

# Recorded locally only now that the disk-setup checks above have positively
# confirmed this exact volume is genuinely attached to and mounted on this
# exact VM - not right after 'volume attach' succeeds, since attach alone
# doesn't prove that. destroy-private-storage.sh reads this, when present, to
# resolve the volume by its actual recorded slug instead of by name alone:
# the zcp CLI has no way to ask "is volume X attached to VM Y", so a bare
# name match is the only fallback destroy has when this file is missing (a
# different machine than the one deploy ran on, or state cleaned up).
STATE_DIR="$HOME/.zcp-private-storage-state"
mkdir -p "$STATE_DIR" 2>/dev/null && cat > "$STATE_DIR/${NAME_PREFIX}.json" <<EOF 2>/dev/null
{"vm_slug": "$VM_SLUG", "volume_slug": "$VOLUME_SLUG", "region": "$ZCP_REGION", "project": "$ZCP_PROJECT"}
EOF

# ---------------------------------------------------------------------------
# Step 3: NFS
# ---------------------------------------------------------------------------
step "Step 3/4: Install and export NFS"

remote "$VM_IP" "for i in \$(seq 1 30); do sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; sleep 5; done" "$VM_USER"
remote "$VM_IP" "sudo apt-get update && sudo apt-get install -y nfs-kernel-server" "$VM_USER"
remote "$VM_IP" "sudo chown nobody:nogroup /srv/nfs/$SHARE_NAME && sudo chmod 1777 /srv/nfs/$SHARE_NAME" "$VM_USER"

# Exported to BOTH the tier CIDR and the mesh CIDR, not just one. A VM
# physically on the tier connects with a tier-address source. A device
# connecting over Tailscale from anywhere else (the scenario this whole
# series is built for) is forwarded by the subnet router - by default,
# Tailscale SNATs subnet-route traffic there, so it actually arrives with a
# tier-address source too, unless build-private-network.sh's 'tailscale up'
# call is ever changed to pass --snat-subnet-routes=false, in which case it
# arrives with its real mesh-range (100.64.0.0/10) source instead. The mesh
# CIDR export exists for that case, but is NOT a complete fix for it on its
# own: an NFS export ACL only controls who the server answers, it doesn't
# give this VM a route back to 100.64.0.0/10 - without SNAT, replies would
# still go out this VM's default route, not back through the subnet router,
# and the connection would hang rather than work. Exporting to only the tier
# CIDR would still be strictly worse (it wouldn't even get this far), so this
# export stays as-is either way, but --snat-subnet-routes=false on the
# subnet router needs its own routing fix on this VM to actually work, not
# just this export. root_squash (not no_root_squash) is the safer default.
# Root on a client does not get root-equivalent access to the share.
#
# Replaces only this share's own line in /etc/exports rather than truncating
# the whole file: a rerun with a different --share-name than a previous run
# on the same VM must not silently drop that earlier export.
EXPORT_LINE="/srv/nfs/$SHARE_NAME $TIER_CIDR(rw,sync,no_subtree_check,root_squash) $MESH_CIDR(rw,sync,no_subtree_check,root_squash)"
# set -e so a real failure in this multi-command block (unlike a plain
# newline-separated sequence, whose exit status is only that of its last
# line) aborts loudly instead of silently continuing. The grep step writes
# to a plain user-owned file (no sudo, no pipe into tee) specifically so its
# own '|| true' - needed because grep -v exits 1 on a file with nothing left
# after filtering, e.g. a fresh, empty /etc/exports on the first run - can't
# also swallow a real tee/sudo failure the way a `grep | sudo tee || true`
# pipeline would (this block has no pipefail, so only the pipeline's last
# command's exit status would count anyway).
remote "$VM_IP" "set -e
sudo touch /etc/exports
grep -vF '/srv/nfs/$SHARE_NAME ' /etc/exports > \$HOME/exports.new 2>/dev/null || true
echo '$EXPORT_LINE' >> \$HOME/exports.new
sudo cp \"\$HOME/exports.new\" /etc/exports
rm -f \"\$HOME/exports.new\"
sudo exportfs -ra" "$VM_USER"
success "NFS installed, exporting /srv/nfs/$SHARE_NAME to $TIER_CIDR and $MESH_CIDR"

# ---------------------------------------------------------------------------
# Step 4: OS firewall
# ---------------------------------------------------------------------------
step "Step 4/4: Open the OS firewall, scoped the same way"

# This is the VM's own OS firewall, separate from (and in addition to) the
# fact that no zcp firewall/port-forward rule for these ports exists on the
# public IP at all. Both layers matter. ufw's own rule-add is idempotent
# (re-adding an identical rule is a no-op, not a duplicate), so no extra
# existence check is needed here the way the zcp-level rules above need one.
#
# set -e so a failure partway through (e.g. a malformed CIDR) aborts the
# whole block instead of silently falling through to '--force enable' with
# incomplete rules - a newline-separated remote() command has no implicit
# error propagation between lines, only the last line's exit status counts
# otherwise. Port 22 is allowed first, before anything else, so SSH is
# guaranteed permitted before ufw is ever enabled.
#
# Stale rules from a previous run against a different --tier-name are removed
# first, same reasoning as lock_down_ssh's stale-CIDR cleanup above: rerunning
# against a different tier must not leave the old tier's allow rules in
# place forever. 'ufw status numbered' is parsed for allow-tcp rules on the
# three NFS ports whose source CIDR is neither today's tier nor the mesh
# range, then deleted highest rule number first, since ufw renumbers
# remaining rules downward after each delete and the numbers were all
# gathered from a single snapshot up front.
remote "$VM_IP" "set -e
STALE_UFW_IDS=\$(sudo ufw status numbered | sed -En 's/^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+)\/tcp[[:space:]]+ALLOW IN[[:space:]]+([0-9.]+\/[0-9]+)[[:space:]]*\$/\1 \2 \3/p' | awk -v t=\"$TIER_CIDR\" -v m=\"$MESH_CIDR\" '(\$2==2049 || \$2==111 || \$2==20048) && \$3!=t && \$3!=m {print \$1}' | sort -rn)
for id in \$STALE_UFW_IDS; do sudo ufw --force delete \"\$id\"; done
sudo ufw allow 22/tcp
sudo ufw allow from $TIER_CIDR to any port 2049 proto tcp
sudo ufw allow from $TIER_CIDR to any port 111 proto tcp
sudo ufw allow from $TIER_CIDR to any port 20048 proto tcp
sudo ufw allow from $MESH_CIDR to any port 2049 proto tcp
sudo ufw allow from $MESH_CIDR to any port 111 proto tcp
sudo ufw allow from $MESH_CIDR to any port 20048 proto tcp
sudo ufw --force enable" "$VM_USER"
success "OS firewall scoped to the tier and mesh CIDRs for NFS, SSH open"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Done"
cat <<EOF

Private shared storage deployed:

  Storage VM   : $VM_NAME -> tier IP ${VM_TIER_IP}
                  SSH: ssh ${VM_USER}@${VM_IP} (admin access only, scoped to $MY_IP)
  Data volume  : $VOLUME_NAME (--volume-size requested ${VOLUME_SIZE}GB, at /srv/nfs; on a rerun
                  against an already-existing volume, its actual size may differ - check: zcp volume list)
  NFS share    : /srv/nfs/$SHARE_NAME
                  Exported to: $TIER_CIDR and $MESH_CIDR (mesh range)

Inspect what was created:

  zcp instance list
  zcp volume list
  zcp ip list

Mount from a device already connected to the mesh (not something physically on the tier -
that's a different verification, see the tutorial's "Verify isolation" section):

  sudo apt-get install -y nfs-common
  sudo mkdir -p /mnt/$SHARE_NAME
  sudo mount -t nfs ${VM_TIER_IP}:/srv/nfs/$SHARE_NAME /mnt/$SHARE_NAME

Clean up when done (billing runs hourly while these exist):

  bash <(curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/zcp/destroy-private-storage.sh) \\
    --name $NAME_PREFIX --region $ZCP_REGION --project $ZCP_PROJECT

EOF
