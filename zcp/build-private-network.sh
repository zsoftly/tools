#!/bin/bash
# ZCP Private Network + Headscale Mesh Builder
# Runs the ZCP Tutorial 1 workflow (Build a Private Network with Headscale) end to end.
# It creates the VPC, private tier, locked-down ACL, a self-hosted Headplane (Headscale)
# server, and a subnet router that advertises the tier into the mesh.
#
# Usage:
#   ./build-private-network.sh --ssh-key my-key [options]
#
# Requires: zcp CLI (authenticated), jq, ssh, curl
set -e
set -o pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAME_PREFIX="workspace"
NETWORK_ADDRESS="10.20.0.0"
NETWORK_SIZE="16"
MESH_CIDR="100.64.0.0/10"
SSH_KEY=""
MY_IP=""
HEADPLANE_TEMPLATE=""
HEADPLANE_PLAN=""
ROUTER_TEMPLATE="ubuntu-2404-lts-1"
ROUTER_PLAN=""
NETWORK_PLAN=""
ROUTER_VPC_PLAN=""
STORAGE_CATEGORY_VPC=""
STORAGE_CATEGORY_VM=""
BILLING_CYCLE="hourly"
AUTO_YES="false"
SSH_WAIT_SECONDS=180
FIRSTBOOT_WAIT_SECONDS=300

# ---------------------------------------------------------------------------
# Output helpers (matches tools/vpn/install.sh conventions). All write to
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
ZCP Private Network + Headscale Mesh Builder

Usage: $0 --ssh-key <name> [options]

Required:
  --ssh-key NAME             Name of an existing 'zcp ssh-key' entry, used to deploy both VMs.

Common overrides (auto-discovered or set to a default value if you leave them out):
  --region REGION             zcp region slug (or \$ZCP_REGION)
  --project PROJECT           zcp project slug (or \$ZCP_PROJECT)
  --name PREFIX                Base name for every resource (default: workspace)
                                -> \${PREFIX}, \${PREFIX}-tier, \${PREFIX}-acl,
                                   \${PREFIX}-headscale, \${PREFIX}-subnet-router
  --network-address CIDR-BASE  VPC network base, size fixed at /16 (default: 10.20.0.0).
                                The tier is derived as <first two octets>.1.0/24.
  --my-ip CIDR                 Your public IP in CIDR form, used to scope admin-port access
                                (default: auto-detected via ifconfig.me, with /32 appended)
  --headplane-template SLUG    Headplane marketplace template slug
                                (default: first match in 'zcp template list | grep headplane')
  --router-template SLUG       Subnet router OS template slug (default: ubuntu-2404-lts-1,
                                a fixed value, not looked up from your account)
  --headplane-plan SLUG        Compute plan for the Headplane VM
  --router-plan SLUG           Compute plan for the subnet router VM
  --network-plan SLUG          Network plan for both VMs' public network
  --router-vpc-plan SLUG       Compute plan for the VPC's built-in router (not the subnet
                                router VM, use --router-plan for that)
  --vpc-storage-category SLUG  Storage category for the VPC
  --vm-storage-category SLUG   Storage category for both VMs
  --billing-cycle CYCLE        hourly or monthly (default: hourly)
  -y, --yes                    Skip the "resources about to be created" confirmation prompt
  -h, --help                    Show this help

If you omit a flag, the script looks up a default with 'zcp plan' or 'zcp template' and
prints what it picked. Pass the flag explicitly to skip the lookup and pin your own value.

Example:
  ./build-private-network.sh --ssh-key my-key --name acme-workspace
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
    --network-address) require_value "$1" "${2:-}"; NETWORK_ADDRESS="$2"; shift 2 ;;
    --ssh-key) require_value "$1" "${2:-}"; SSH_KEY="$2"; shift 2 ;;
    --my-ip) require_value "$1" "${2:-}"; MY_IP="$2"; shift 2 ;;
    --headplane-template) require_value "$1" "${2:-}"; HEADPLANE_TEMPLATE="$2"; shift 2 ;;
    --router-template) require_value "$1" "${2:-}"; ROUTER_TEMPLATE="$2"; shift 2 ;;
    --headplane-plan) require_value "$1" "${2:-}"; HEADPLANE_PLAN="$2"; shift 2 ;;
    --router-plan) require_value "$1" "${2:-}"; ROUTER_PLAN="$2"; shift 2 ;;
    --network-plan) require_value "$1" "${2:-}"; NETWORK_PLAN="$2"; shift 2 ;;
    --router-vpc-plan) require_value "$1" "${2:-}"; ROUTER_VPC_PLAN="$2"; shift 2 ;;
    --vpc-storage-category) require_value "$1" "${2:-}"; STORAGE_CATEGORY_VPC="$2"; shift 2 ;;
    --vm-storage-category) require_value "$1" "${2:-}"; STORAGE_CATEGORY_VM="$2"; shift 2 ;;
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

VPC_NAME="$NAME_PREFIX"
TIER_NAME="${NAME_PREFIX}-tier"
ACL_NAME="${NAME_PREFIX}-acl"
HEADSCALE_NAME="${NAME_PREFIX}-headscale"
ROUTER_NAME="${NAME_PREFIX}-subnet-router"

# --network-address drives the tier's addressing too, instead of a hardcoded 10.20.x
# constant, so the flag actually does something.
IFS='.' read -r NET_OCTET1 NET_OCTET2 _ _ <<< "$NETWORK_ADDRESS"
if [ -z "$NET_OCTET1" ] || [ -z "$NET_OCTET2" ]; then
  error "--network-address '$NETWORK_ADDRESS' is not a valid IPv4 base (expected form like 10.20.0.0)."
fi
TIER_GATEWAY="${NET_OCTET1}.${NET_OCTET2}.1.1"
TIER_NETMASK="255.255.255.0"
TIER_CIDR="${NET_OCTET1}.${NET_OCTET2}.1.0/24"

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

export ZCP_REGION ZCP_PROJECT
zcp() { command zcp --region "$ZCP_REGION" --project "$ZCP_PROJECT" "$@"; }

zcp ssh-key list -o json | jq -e --arg n "$SSH_KEY" '.[] | select(.name==$n)' >/dev/null 2>&1 \
  || error "SSH key '$SSH_KEY' not found in this account (zcp ssh-key list)."

success "zcp CLI authenticated, region=$ZCP_REGION project=$ZCP_PROJECT"

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
  resolved="$(eval "$lookup_cmd" | jq -r "$field" | head -1)"
  [ -n "$resolved" ] && [ "$resolved" != "null" ] || error "Could not auto-discover $label. Pass it explicitly (see --help)."
  echo "$resolved"
}

HEADPLANE_TEMPLATE="$(resolve "$HEADPLANE_TEMPLATE" "Headplane template" \
  "zcp template list -o json" '.[] | select(.name | test("headplane";"i")) | .slug')"
HEADPLANE_PLAN="$(resolve "$HEADPLANE_PLAN" "Headplane compute plan" "zcp plan vm -o json" '.[0].slug')"
ROUTER_PLAN="$(resolve "$ROUTER_PLAN" "subnet router compute plan" "zcp plan vm -o json" '.[0].slug')"
NETWORK_PLAN="$(resolve "$NETWORK_PLAN" "network plan" "zcp plan network -o json" '.[0].slug')"
ROUTER_VPC_PLAN="$(resolve "$ROUTER_VPC_PLAN" "VPC router plan" "zcp plan router -o json" '.[0].slug')"
STORAGE_CATEGORY_VPC="$(resolve "$STORAGE_CATEGORY_VPC" "VPC storage category" "zcp storage-category list -o json" '.[0].slug')"
STORAGE_CATEGORY_VM="$(resolve "$STORAGE_CATEGORY_VM" "VM storage category" "zcp storage-category list -o json" '.[0].slug')"

info "Resolved resources:"
echo "    Headplane template   : $HEADPLANE_TEMPLATE" >&2
echo "    Headplane plan       : $HEADPLANE_PLAN" >&2
echo "    Router template      : $ROUTER_TEMPLATE" >&2
echo "    Router plan          : $ROUTER_PLAN" >&2
echo "    Network plan         : $NETWORK_PLAN" >&2
echo "    VPC router plan      : $ROUTER_VPC_PLAN" >&2
echo "    VPC storage category : $STORAGE_CATEGORY_VPC" >&2
echo "    VM storage category  : $STORAGE_CATEGORY_VM" >&2

if [ "$AUTO_YES" != "true" ]; then
  echo "" >&2
  echo "This creates a VPC, two VMs (plans above), and networking on your account now." >&2
  echo "Billing starts as soon as each resource is created." >&2
  read -r -p "Type 'yes' to continue: " CONFIRM
  [ "$CONFIRM" = "yes" ] || error "Cancelled. Re-run with the flags above (or --yes to skip this prompt) when ready."
fi

# ---------------------------------------------------------------------------
# Slug lookup helpers
#
# The human-readable --name you pass is not always the slug the API expects:
# slugs auto-suffix on collision (an existing resource named "test-vpc" can
# have slug "test-vpc-1"). Always resolve the real slug right after a create
# (or right after finding an existing resource) and use that slug for every
# later reference, never the name string itself.
# ---------------------------------------------------------------------------
vpc_slug_for_name() { zcp vpc list -o json | jq -r --arg n "$1" '.[] | select(.name==$n) | .slug' | head -1; }
network_slug_for_name() { zcp network list -o json | jq -r --arg n "$1" '.[] | select(.name==$n) | .slug' | head -1; }
instance_slug_for_name() { zcp instance list -o json | jq -r --arg n "$1" '.[] | select(.name==$n) | .slug' | head -1; }

wait_for_ssh() {
  local ip="$1" timeout="$2" user="${3:-ubuntu}" waited=0
  # ZCP recycles public IPs across deploys. A prior VM's host key might still be
  # cached for this exact IP. Purge it before pinning the new one.
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  info "Waiting for SSH on $ip..."
  while ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "${user}@${ip}" true 2>/dev/null; do
    waited=$((waited + 5))
    [ "$waited" -ge "$timeout" ] && error "SSH on $ip did not become ready within ${timeout}s."
    sleep 5
  done
  success "SSH ready on $ip"
}

remote() {
  local ip="$1" cmd="$2" user="${3:-ubuntu}"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${user}@${ip}" "$cmd"
}

# ---------------------------------------------------------------------------
# Step 5: VPC + private tier
# ---------------------------------------------------------------------------
step "Step 5/8: VPC and private tier"

if zcp vpc list -o json | jq -e --arg n "$VPC_NAME" '.[] | select(.name==$n)' >/dev/null 2>&1; then
  warn "VPC '$VPC_NAME' already exists, skipping creation."
else
  zcp vpc create --name "$VPC_NAME" --plan "$ROUTER_VPC_PLAN" \
    --network-address "$NETWORK_ADDRESS" --size "$NETWORK_SIZE" \
    --billing-cycle "$BILLING_CYCLE" --storage-category "$STORAGE_CATEGORY_VPC"
  success "VPC '$VPC_NAME' created"
fi
VPC_SLUG="$(vpc_slug_for_name "$VPC_NAME")"
[ -n "$VPC_SLUG" ] || error "Could not resolve the real slug for VPC '$VPC_NAME' after creation."

if zcp network list -o json | jq -e --arg n "$TIER_NAME" '.[] | select(.name==$n)' >/dev/null 2>&1; then
  warn "Tier '$TIER_NAME' already exists, skipping creation."
else
  zcp network create --name "$TIER_NAME" --vpc "$VPC_SLUG" \
    --gateway "$TIER_GATEWAY" --netmask "$TIER_NETMASK" --billing-cycle "$BILLING_CYCLE"
  success "Private tier '$TIER_NAME' created (no public IP by default)"
fi
TIER_SLUG="$(network_slug_for_name "$TIER_NAME")"
[ -n "$TIER_SLUG" ] || error "Could not resolve the real slug for tier '$TIER_NAME' after creation."

# ---------------------------------------------------------------------------
# Step 6: Lock the tier down with a custom ACL
# ---------------------------------------------------------------------------
step "Step 6/8: Custom network ACL"

if zcp acl rules "$VPC_SLUG" "$ACL_NAME" >/dev/null 2>&1; then
  ACL_RULE_COUNT="$(zcp acl rules "$VPC_SLUG" "$ACL_NAME" -o json | jq 'length')"
else
  zcp vpc acl-create "$VPC_SLUG" --name "$ACL_NAME" --description "Workspace tier lockdown"
  ACL_RULE_COUNT=0
fi

if [ "$ACL_RULE_COUNT" -eq 0 ]; then
  zcp acl create-rule "$VPC_SLUG" "$ACL_NAME" --number 1 --protocol all --cidr "$TIER_CIDR" --action allow --traffic-type ingress
  zcp acl create-rule "$VPC_SLUG" "$ACL_NAME" --number 2 --protocol all --cidr "$MESH_CIDR" --action allow --traffic-type ingress
  zcp acl create-rule "$VPC_SLUG" "$ACL_NAME" --number 3 --protocol all --cidr "$TIER_CIDR" --action allow --traffic-type egress
  zcp acl create-rule "$VPC_SLUG" "$ACL_NAME" --number 4 --protocol all --cidr "$MESH_CIDR" --action allow --traffic-type egress
  success "ACL '$ACL_NAME' created: tier CIDR + mesh CIDR, ingress and egress"
elif [ "$ACL_RULE_COUNT" -lt 4 ]; then
  error "ACL '$ACL_NAME' exists but only has $ACL_RULE_COUNT of the expected 4 rules (a prior run may have failed partway through). Inspect it with 'zcp acl rules $VPC_SLUG $ACL_NAME', fix or delete it, then re-run."
else
  warn "ACL '$ACL_NAME' already has $ACL_RULE_COUNT rule(s), skipping rule creation."
fi

zcp vpc acl-replace --network "$TIER_SLUG" --acl "$ACL_NAME" --vpc "$VPC_SLUG"
success "ACL applied to '$TIER_NAME'. This is what makes the tier private, not the VPC by itself."

# ---------------------------------------------------------------------------
# Step 7: Deploy Headplane (Headscale + admin UI)
# ---------------------------------------------------------------------------
step "Step 7/8: Deploy Headplane"

if ! zcp instance list -o json | jq -e --arg n "$HEADSCALE_NAME" '.[] | select(.name==$n)' >/dev/null 2>&1; then
  zcp instance create --name "$HEADSCALE_NAME" \
    --template "$HEADPLANE_TEMPLATE" --plan "$HEADPLANE_PLAN" \
    --billing-cycle "$BILLING_CYCLE" --network-plan "$NETWORK_PLAN" \
    --storage-category "$STORAGE_CATEGORY_VM" --ssh-key "$SSH_KEY" --wait
  success "'$HEADSCALE_NAME' created"
else
  warn "'$HEADSCALE_NAME' already exists, skipping creation."
fi
HEADSCALE_SLUG="$(instance_slug_for_name "$HEADSCALE_NAME")"
[ -n "$HEADSCALE_SLUG" ] || error "Could not resolve the real slug for '$HEADSCALE_NAME' after creation."

HEADSCALE_INSTANCE_JSON="$(zcp instance get "$HEADSCALE_SLUG" -o json)"
HEADSCALE_IP="$(echo "$HEADSCALE_INSTANCE_JSON" | jq -r '.[] | select(.field=="Public IP") | .value' | head -1)"
[ -n "$HEADSCALE_IP" ] && [ "$HEADSCALE_IP" != "null" ] || error "Could not determine '$HEADSCALE_NAME' public IP."
HEADSCALE_USER="$(echo "$HEADSCALE_INSTANCE_JSON" | jq -r '.[] | select(.field=="Username") | .value' | head -1)"
[ -n "$HEADSCALE_USER" ] && [ "$HEADSCALE_USER" != "null" ] || HEADSCALE_USER="ubuntu"
info "Headplane public IP: $HEADSCALE_IP"

wait_for_ssh "$HEADSCALE_IP" "$SSH_WAIT_SECONDS" "$HEADSCALE_USER"

info "Waiting for first-boot to finish provisioning Headscale/Headplane..."
waited=0
until remote "$HEADSCALE_IP" "test -f /etc/headplane/credentials.txt" "$HEADSCALE_USER" 2>/dev/null; do
  waited=$((waited + 10))
  [ "$waited" -ge "$FIRSTBOOT_WAIT_SECONDS" ] && error "First boot did not finish within ${FIRSTBOOT_WAIT_SECONDS}s. Check manually: ssh ${HEADSCALE_USER}@$HEADSCALE_IP"
  sleep 10
done
success "First boot complete"

info "Repointing server_url at the public IP and restarting the stack..."
# server_url (Headscale's mesh control endpoint, port 8080) needs the public IP -
# real remote devices connect to it directly. base_url (the admin UI, port 3000)
# stays on localhost: the admin UI is never opened to the internet, only reached
# through an SSH tunnel, so it must match how the browser actually sees it.
remote "$HEADSCALE_IP" "sudo sed -i 's|^server_url:.*|server_url: http://${HEADSCALE_IP}:8080|' /opt/headplane/headscale/config/config.yaml" "$HEADSCALE_USER"
remote "$HEADSCALE_IP" "sudo sed -i 's|^  base_url:.*|  base_url: \"http://localhost:3000\"|' /opt/headplane/headplane/config.yaml" "$HEADSCALE_USER"
remote "$HEADSCALE_IP" "cd /opt/headplane && sudo docker compose restart" "$HEADSCALE_USER"
success "Headplane repointed at $HEADSCALE_IP and restarted"

IP_SLUG="$(zcp ip list -o json | jq -r --arg vm "$HEADSCALE_NAME" '.[] | select(.vm==$vm) | .slug' | head -1)"
[ -n "$IP_SLUG" ] || error "Could not find the public IP slug for '$HEADSCALE_NAME'."

# Every rule below is reconciled independently: checked, then created only if
# missing. That's instead of gating the whole block on one proxy marker. A single
# marker (e.g. "does the scoped SSH rule exist") can be true even when a prior
# run failed partway through, leaving port 8080 never opened while the script
# still reports success on a rerun.

info "Locking down the template's default open SSH rule..."
OPEN_SSH_RULES_JSON="$(zcp firewall list --ip "$IP_SLUG" -o json)" || error "Could not list firewall rules for '$HEADSCALE_NAME' (IP slug $IP_SLUG)."
OPEN_SSH_RULE_IDS="$(echo "$OPEN_SSH_RULES_JSON" | jq -r '.[] | select((.protocol=="tcp" or .protocol=="udp") and .ports=="22" and .cidr=="0.0.0.0/0") | .id')"
if [ -n "$OPEN_SSH_RULE_IDS" ]; then
  while read -r rule_id; do
    [ -n "$rule_id" ] && zcp firewall delete "$rule_id" --ip "$IP_SLUG" --yes
  done <<< "$OPEN_SSH_RULE_IDS"
fi

# Defense in depth: a VM built with an older version of this script may still
# have port 3000 open from before the admin UI moved to SSH-tunnel-only. Close
# it if found, regardless of how this VM was originally built.
OPEN_3000_RULE_IDS="$(zcp firewall list --ip "$IP_SLUG" -o json | jq -r '.[] | select(.protocol=="tcp" and .ports=="3000") | .id')"
if [ -n "$OPEN_3000_RULE_IDS" ]; then
  warn "Found an existing port 3000 rule (from an older run or manual change). Removing it. The admin UI is SSH-tunnel-only."
  while read -r rule_id; do
    [ -n "$rule_id" ] && zcp firewall delete "$rule_id" --ip "$IP_SLUG" --yes
  done <<< "$OPEN_3000_RULE_IDS"
fi

if ! zcp firewall list --ip "$IP_SLUG" -o json | jq -e --arg c "$MY_IP" \
    '.[] | select(.protocol=="tcp" and .ports=="22" and .cidr==$c)' >/dev/null 2>&1; then
  zcp firewall create --ip "$IP_SLUG" --protocol tcp --start-port 22 --end-port 22 --cidr "$MY_IP"
fi

# Post-condition: confirm the default-open SSH rule and port 3000 are both
# actually gone, rather than trusting the delete loops ran (a failed
# 'zcp firewall list' above would otherwise leave either exposed while this
# script reports success).
STILL_OPEN="$(zcp firewall list --ip "$IP_SLUG" -o json | jq '[.[] | select((.protocol=="tcp" or .protocol=="udp") and (.ports=="22" and .cidr=="0.0.0.0/0" or .ports=="3000"))] | length')"
[ "$STILL_OPEN" = "0" ] || error "Lockdown failed: $STILL_OPEN rule(s) still expose 0.0.0.0/0 on port 22 or any rule on port 3000 for '$HEADSCALE_NAME'. Check manually: zcp firewall list --ip $IP_SLUG"

info "Opening port 8080 (mesh control, open to every device that will ever connect)..."
if ! zcp firewall list --ip "$IP_SLUG" -o json | jq -e \
    '.[] | select(.protocol=="tcp" and .ports=="8080" and .cidr=="0.0.0.0/0")' >/dev/null 2>&1; then
  zcp firewall create --ip "$IP_SLUG" --protocol tcp --start-port 8080 --end-port 8080 --cidr 0.0.0.0/0
fi
# Port-forward creation doesn't have a verified JSON shape to check against, so
# this attempts the create and tolerates an "already exists" style failure,
# the same pattern used for add-network above, rather than risk a wrong field
# name silently skipping the check.
if ! PORTFORWARD_OUTPUT="$(zcp portforward create --ip "$IP_SLUG" --protocol tcp --public-port 8080 --public-end-port 8080 \
    --private-port 8080 --private-end-port 8080 --instance "$HEADSCALE_SLUG" 2>&1)"; then
  echo "$PORTFORWARD_OUTPUT" | grep -qi "already" || error "Failed to create the port 8080 port-forward rule: $PORTFORWARD_OUTPUT"
fi
success "Firewall + port-forward rule in place"

HEADPLANE_API_KEY="$(remote "$HEADSCALE_IP" "sudo cat /etc/headplane/credentials.txt" "$HEADSCALE_USER" | grep -oE 'hskey-[A-Za-z0-9_-]+' | head -1)"
[ -n "$HEADPLANE_API_KEY" ] || warn "Could not parse the Headplane API key automatically. Read it manually: ssh ${HEADSCALE_USER}@$HEADSCALE_IP sudo cat /etc/headplane/credentials.txt"
success "Headplane ready (admin UI reachable only via SSH tunnel, see the summary at the end)"
info "API key (also saved on the VM at /etc/headplane/credentials.txt): $HEADPLANE_API_KEY"

# ---------------------------------------------------------------------------
# Step 8: Subnet router
# ---------------------------------------------------------------------------
step "Step 8/8: Deploy the subnet router and enroll it in the mesh"

if ! zcp instance list -o json | jq -e --arg n "$ROUTER_NAME" '.[] | select(.name==$n)' >/dev/null 2>&1; then
  zcp instance create --name "$ROUTER_NAME" \
    --template "$ROUTER_TEMPLATE" --plan "$ROUTER_PLAN" --billing-cycle "$BILLING_CYCLE" \
    --network-plan "$NETWORK_PLAN" --storage-category "$STORAGE_CATEGORY_VM" \
    --ssh-key "$SSH_KEY" --wait
  success "'$ROUTER_NAME' created"
else
  warn "'$ROUTER_NAME' already exists, skipping creation."
fi
ROUTER_SLUG="$(instance_slug_for_name "$ROUTER_NAME")"
[ -n "$ROUTER_SLUG" ] || error "Could not resolve the real slug for '$ROUTER_NAME' after creation."

# Always attempted, not just on fresh create. A prior run could have created
# the instance and then failed before attaching the tier, and re-running must
# still attach it rather than silently skipping.
if ! ADDNET_OUTPUT="$(zcp instance add-network "$ROUTER_SLUG" --network "$TIER_SLUG" 2>&1)"; then
  if echo "$ADDNET_OUTPUT" | grep -qi "already"; then
    warn "Tier network already attached to '$ROUTER_NAME'."
  else
    error "Failed to attach tier network to '$ROUTER_NAME': $ADDNET_OUTPUT"
  fi
else
  success "'$ROUTER_NAME' attached to '$TIER_NAME'"
fi

ROUTER_INSTANCE_JSON="$(zcp instance get "$ROUTER_SLUG" -o json)"
ROUTER_IP="$(echo "$ROUTER_INSTANCE_JSON" | jq -r '.[] | select(.field=="Public IP") | .value' | head -1)"
[ -n "$ROUTER_IP" ] && [ "$ROUTER_IP" != "null" ] || error "Could not determine '$ROUTER_NAME' public IP."
ROUTER_USER="$(echo "$ROUTER_INSTANCE_JSON" | jq -r '.[] | select(.field=="Username") | .value' | head -1)"
[ -n "$ROUTER_USER" ] && [ "$ROUTER_USER" != "null" ] || ROUTER_USER="ubuntu"
wait_for_ssh "$ROUTER_IP" "$SSH_WAIT_SECONDS" "$ROUTER_USER"

info "Bringing up the tier NIC (hot-added, not auto-configured by the OS)..."
# Excludes lo (loopback), enp* (the router's own public NIC), and tailscale*
# (Tailscale's own virtual interface, which does not exist on a fresh VM but
# does on any rerun against an already-configured router. Without this
# exclusion, 'tail -1' would pick tailscale0 instead of the real tier NIC and
# overwrite its netplan config).
TIER_NIC="$(remote "$ROUTER_IP" "ip -br link show | awk '{print \$1}' | grep -v '^lo\$' | grep -v '^enp' | grep -v '^tailscale' | tail -1" "$ROUTER_USER")"
[ -n "$TIER_NIC" ] || error "Could not identify the tier NIC on '$ROUTER_NAME'. Check manually: ssh ${ROUTER_USER}@$ROUTER_IP 'ip -br link show'"
remote "$ROUTER_IP" "sudo tee /etc/netplan/60-tier-nic.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${TIER_NIC}:
      dhcp4: true
EOF" "$ROUTER_USER"
remote "$ROUTER_IP" "sudo netplan apply" "$ROUTER_USER"
sleep 5
ROUTER_TIER_IP="$(remote "$ROUTER_IP" "ip -4 -br addr show ${TIER_NIC} | awk '{print \$3}' | cut -d/ -f1" "$ROUTER_USER")"
[ -n "$ROUTER_TIER_IP" ] || error "Tier NIC did not come up with an address. Check manually: ssh ${ROUTER_USER}@$ROUTER_IP"
# Belt and suspenders: even with the exclusions above, confirm the address
# that actually came up is really on the tier, not some other interface that
# slipped through.
case "$ROUTER_TIER_IP" in
  "${NET_OCTET1}.${NET_OCTET2}.1."*) ;;
  *) error "Interface '$TIER_NIC' came up with $ROUTER_TIER_IP, which is not on the tier ($TIER_CIDR). Wrong interface selected. Check manually: ssh ${ROUTER_USER}@$ROUTER_IP 'ip -br addr show'" ;;
esac
success "Tier NIC ($TIER_NIC) up at $ROUTER_TIER_IP"

info "Installing Tailscale and enabling IP forwarding..."
remote "$ROUTER_IP" "curl -fsSL https://tailscale.com/install.sh | sudo sh" "$ROUTER_USER"
remote "$ROUTER_IP" "grep -qxF 'net.ipv4.ip_forward = 1' /etc/sysctl.d/99-tailscale.conf 2>/dev/null || echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null && \
  grep -qxF 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.d/99-tailscale.conf 2>/dev/null || echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null && \
  sudo sysctl -p /etc/sysctl.d/99-tailscale.conf" "$ROUTER_USER"

info "Minting a preauth key on Headscale..."
HEADSCALE_USER_ID="$(remote "$HEADSCALE_IP" "sudo docker exec headscale headscale users list -o json" "$HEADSCALE_USER" | jq -r '.[0].id')"
[ -n "$HEADSCALE_USER_ID" ] && [ "$HEADSCALE_USER_ID" != "null" ] || error "Could not find a Headscale user. Check manually on $HEADSCALE_IP."
PREAUTH_KEY="$(remote "$HEADSCALE_IP" "sudo docker exec headscale headscale preauthkeys create --user ${HEADSCALE_USER_ID} --expiration 1h" "$HEADSCALE_USER")"
[ -n "$PREAUTH_KEY" ] || error "Could not mint a preauth key for '$ROUTER_NAME' on Headscale."

info "Registering the subnet router and advertising ${TIER_CIDR}..."
remote "$ROUTER_IP" "sudo tailscale up --login-server http://${HEADSCALE_IP}:8080 --authkey ${PREAUTH_KEY} --advertise-routes=${TIER_CIDR} --accept-routes" "$ROUTER_USER"

info "Approving the advertised route on Headscale..."
NODE_ID="$(remote "$HEADSCALE_IP" "sudo docker exec headscale headscale nodes list -o json" "$HEADSCALE_USER" | jq -r --arg n "$ROUTER_NAME" '.[] | select(.given_name==$n or .name==$n) | .id' | head -1)"
[ -n "$NODE_ID" ] || error "Could not find the router's node ID in Headscale. Approve manually: docker exec headscale headscale nodes approve-routes --identifier <id> --routes ${TIER_CIDR}"
remote "$HEADSCALE_IP" "sudo docker exec headscale headscale nodes approve-routes --identifier ${NODE_ID} --routes ${TIER_CIDR}" "$HEADSCALE_USER"
success "Route approved. '$ROUTER_NAME' is now the door into '$TIER_NAME'."

info "Minting a preauth key for your own device..."
OWN_DEVICE_KEY="$(remote "$HEADSCALE_IP" "sudo docker exec headscale headscale preauthkeys create --user ${HEADSCALE_USER_ID} --expiration 24h" "$HEADSCALE_USER")"
[ -n "$OWN_DEVICE_KEY" ] || warn "Could not mint a preauth key for your own device. Mint one from the Headplane UI instead."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Done"
cat <<EOF

Private network built:

  VPC                 : $VPC_NAME
  Private tier         : $TIER_NAME ($TIER_CIDR, no public IP)
  ACL                    : $ACL_NAME (tier CIDR + mesh CIDR only)
  Headplane / Headscale   : $HEADSCALE_NAME (admin UI on port 3000, SSH tunnel only, not public)
                              Tunnel: ssh -L 3000:localhost:3000 ${HEADSCALE_USER}@${HEADSCALE_IP}
                              Then open: http://localhost:3000/admin/login
                              API key: ${HEADPLANE_API_KEY:-<see /etc/headplane/credentials.txt>}
  Subnet router             : $ROUTER_NAME -> tier IP ${ROUTER_TIER_IP}
                              SSH: ssh ${ROUTER_USER}@${ROUTER_IP} (for troubleshooting)

Inspect what was created:

  zcp vpc list
  zcp network list
  zcp instance list
  zcp acl rules $VPC_SLUG $ACL_NAME

Next: connect your own device to the mesh (this runs on YOUR machine, not ZCP infrastructure):

  HEADSCALE_URL="http://${HEADSCALE_IP}:8080" \\
    bash <(curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/vpn/install.sh) "your-name" --key "${OWN_DEVICE_KEY:-<mint one at the Headplane UI above, expired after 24h>}"

Then verify:

  tailscale status
  ping ${ROUTER_TIER_IP}

If your device shows offline in 'tailscale status' with a coordination-server health
warning, restart tailscaled: sudo systemctl restart tailscaled (same fix applies on
the subnet router over SSH above, if it ever shows offline).

Clean up when done (billing runs hourly while these exist):

  bash <(curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/zcp/destroy-private-network.sh) \\
    --name $NAME_PREFIX --region $ZCP_REGION --project $ZCP_PROJECT

EOF
