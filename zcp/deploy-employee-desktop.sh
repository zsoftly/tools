#!/bin/bash
# ZCP Employee Desktop Deployer
# Runs the ZCP Tutorial 3 workflow (Deploy Ubuntu Employee Desktops) end to end.
# Deploys a full Ubuntu KDE remote desktop for one employee inside an EXISTING
# private tier (built by zcp/build-private-network.sh, Tutorial 1), with a
# named non-default login provisioned via cloud-init. RDP is never exposed
# publicly, reached only over the tier. The VM gets a public IP for the
# one-time setup below only (no console/recovery access on this platform);
# SSH is locked down to your own IP and RDP is never opened on the public
# side at all.
#
# Usage:
#   ./deploy-employee-desktop.sh --name jane-doe-desktop --tier-name my-workspace-tier \
#     --username janedoe --ssh-key my-key [options]
#
# Requires: zcp CLI (authenticated), jq, ssh, curl
set -e
set -o pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
VM_NAME=""
TIER_NAME=""
DESKTOP_USERNAME=""
DESKTOP_PASSWORD=""
PASSWORD_PROVIDED="false"
VM_ALREADY_EXISTED="false"
SSH_KEY=""
MY_IP=""
VM_TEMPLATE=""
VM_PLAN=""
NETWORK_PLAN=""
STORAGE_CATEGORY=""
BILLING_CYCLE="hourly"
AUTO_YES="false"
SSH_WAIT_SECONDS=180
# The tutorial this script ports budgets "~30 minutes total, including first-boot KDE
# provisioning as its own distinct phase" - a 5-minute default hard-errored on healthy
# deploys that just took a little longer, leaving a created, billable VM with its
# already-baked-in password unrecoverable (see the password-printing note near VM
# creation below). Raised to match that budget; override with --cloud-init-wait.
CLOUD_INIT_WAIT_SECONDS=1800

# ---------------------------------------------------------------------------
# Output helpers (matches deploy-private-storage.sh conventions). All write to
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
ZCP Employee Desktop Deployer

Usage: $0 --name <vm-name> --tier-name <tier-name> --username <login> --ssh-key <name> [options]

Required:
  --name NAME       Exact name for the desktop VM, e.g. 'jane-doe-desktop'.
  --tier-name NAME  The private tier to attach to, e.g. 'my-workspace-tier' from
                    build-private-network.sh. Not auto-discovered: an account can hold
                    more than one private tier, and guessing which one is unsafe.
  --username NAME   The desktop login, provisioned via cloud-init (not the template's
                    generated default user). Must match ^[a-z][a-z0-9_]*\$: lowercase
                    letters, digits, and underscores only, starting with a letter. A
                    dotted or otherwise punctuated username is rejected by the
                    template's own first-boot script (confirmed live: fails first boot
                    with 'invalid desktop username' and never creates the user), so this
                    is checked here before anything is created.
  --ssh-key NAME    Name of an existing 'zcp ssh-key' entry.

Common overrides (auto-discovered or set to a default value if you leave them out):
  --region REGION           zcp region slug (or \$ZCP_REGION)
  --project PROJECT         zcp project slug (or \$ZCP_PROJECT)
  --password PASSWORD       The desktop login's password. If omitted, a strong random
                            password is generated locally and printed once in the final
                            summary. If passed explicitly, it may be visible in your
                            shell history or process list, and must be at least 8
                            characters using only letters, digits, and
                            !#%+,./:=?@^_- (it's written into a cloud-init env file
                            and YAML block scalar verbatim, so anything else risks
                            breaking or being executed by that file).
  --my-ip CIDR              Your public IP as a /32 (a single address), used to scope
                            admin-port access (default: auto-detected via ifconfig.me,
                            with /32 appended)
  --vm-template SLUG        ubuntukde marketplace template slug
                            (default: first match in 'zcp template list | grep ubuntukde')
  --ssh-wait SECONDS        How long to wait for SSH to come up (default: 180)
  --cloud-init-wait SECONDS How long to wait for cloud-init to finish provisioning the
                            desktop user - KDE first-boot can take several minutes
                            (default: 1800)
  --vm-plan SLUG            Compute plan for the desktop VM. 4 vCPU/16GB is a comfortable
                            baseline for a genuinely smooth desktop; 4 vCPU/8GB is usable
                            but noticeably less responsive. If omitted, the smallest plan
                            meeting the 4 vCPU/16GB baseline is selected automatically
                            (errors if none exists in this account/region).
  --network-plan SLUG       Network plan for the VM's public IP
  --storage-category SLUG   Storage category for the VM's root disk
  --billing-cycle CYCLE     hourly or monthly (default: hourly)
  -y, --yes                 Skip the "resources about to be created" confirmation prompt
  -h, --help                 Show this help

If you omit a flag, the script looks up a default with 'zcp plan', 'zcp template', or
'zcp storage-category' and prints what it picked. Pass the flag explicitly to skip the
lookup and pin your own value.

Example:
  ./deploy-employee-desktop.sh --name jane-doe-desktop --tier-name my-workspace-tier \\
    --username janedoe --ssh-key my-key
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
    -y|--yes) AUTO_YES="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1 (see --help)" ;;
  esac
done

# Emptiness checked before format, not after: an omitted --name/--username should read as
# "required" (below), not as a confusing regex-format complaint. Matches
# destroy-employee-desktop.sh's own ordering.
[ -n "$VM_NAME" ] || error "--name is required."
NAME_RE='^[a-zA-Z0-9-]+$'
if ! [[ "$VM_NAME" =~ $NAME_RE ]]; then
  error "--name '$VM_NAME' must contain only letters, numbers, and hyphens (it's used in resource names, jq filters, and remote commands)."
fi

# Checked before any zcp command is ever invoked, not just before instance
# create: the template's own first-boot script rejects some usernames
# outright (confirmed live with a dotted username, 'invalid desktop
# username', the user never gets created), and discovering that only after
# --wait returns wastes a full VM deploy. Lowercase letters, digits, and
# underscores only, starting with a letter - the same constraint useradd/most
# Linux login-name validators apply, and strictly narrower than what the
# template has been confirmed to reject.
[ -n "$DESKTOP_USERNAME" ] || error "--username is required."
USERNAME_RE='^[a-z][a-z0-9_]*$'
if ! [[ "$DESKTOP_USERNAME" =~ $USERNAME_RE ]]; then
  error "--username '$DESKTOP_USERNAME' must match ^[a-z][a-z0-9_]*\$ (lowercase letters, digits, and underscores only, starting with a letter). Dotted or otherwise punctuated usernames are rejected by the template's own first-boot script (confirmed live: fails with 'invalid desktop username' and never creates the user)."
fi
# useradd's real limit; the regex above has no length bound of its own.
if [ "${#DESKTOP_USERNAME}" -gt 32 ]; then
  error "--username '$DESKTOP_USERNAME' is too long (${#DESKTOP_USERNAME} chars; useradd's limit is 32)."
fi

# Rejects usernames that are guaranteed (or near-guaranteed) to collide with a
# pre-existing system/default account rather than land on a genuinely
# cloud-init-created desktop user. Checked here, at parse time, before any zcp
# call, for the same reason as USERNAME_RE above: discovering the collision
# only after a full VM deploy wastes it. Confirmed live: 'ubuntu' is this
# script's own SSH user AND the cloud image's own pre-existing default user
# (UID 1000, same as this platform's UID_MIN in /etc/login.defs) - it passes
# USERNAME_RE and would otherwise produce a false "Cloud-init user confirmed"
# with a password that was never actually set on that account, on every
# single run, since 'ubuntu' is guaranteed to exist on every VM this script
# creates. The rest of this list is the standard Debian/Ubuntu base-system
# account names (what 'getent passwd' shows on a stock image), including
# 'nobody' (UID 65534), which would otherwise also slip past the runtime
# UID>=1000 poll in wait_for_cloud_init_user below - that check is a
# secondary layer only, not sufficient alone (see its own comment).
RESERVED_USERNAMES=(ubuntu nobody root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats syslog messagebus landscape)
for reserved_username in "${RESERVED_USERNAMES[@]}"; do
  if [ "$DESKTOP_USERNAME" = "$reserved_username" ]; then
    error "--username '$DESKTOP_USERNAME' collides with a pre-existing system/default account on this platform's Ubuntu image (confirmed: it would never get a genuinely cloud-init-created login, and would falsely report success). Choose a different username."
  fi
done

# Written into a cloud-init env file (UBUNTUKDE_PASSWORD=...) that the template's first-boot
# script sources with shell semantics, and interpolated into a YAML literal block scalar, so
# it gets the same validation rigor as --username, checked here at parse time rather than
# left to fail silently later. Confirmed live: a space silently truncates/corrupts the
# env-file line, and a newline breaks out of the YAML block scalar entirely, letting
# following lines become real top-level cloud-config keys executed as root at first boot -
# both "silent lockout, undetectable by later checks". Also confirmed live, since the file is
# genuinely shell-sourced: '( ) & ; < >' are shell control operators, not just risky-looking
# punctuation - '(' aborts the whole source with a syntax error (username never gets set
# either), '&'/';' silently drop or execute the remainder of the value as a command, and '<'/
# '>' silently truncate it. '~' is excluded too, since it tilde-expands after '='. None of
# these are needed for a strong password. The generated-password path is unaffected
# (alphanumeric only by construction) and isn't run through this check.
PASSWORD_RE='^[A-Za-z0-9!#%+,./:=?@^_-]{8,}$'
if [ "$PASSWORD_PROVIDED" = "true" ] && ! [[ "$DESKTOP_PASSWORD" =~ $PASSWORD_RE ]]; then
  error "--password must be at least 8 characters using only letters, digits, and !#%+,./:=?@^_- (it's sourced as a shell env file and interpolated into a YAML block scalar verbatim; anything else risks breaking or being executed by that file)."
fi

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
# ambiguous (slugs auto-suffix on collision), and this is the tier the
# desktop is attached to, so guessing wrong is a real isolation risk, not
# just an inconvenience.
TIER_LIST_JSON="$(zcp network list -o json)" || error "Could not list networks to find '$TIER_NAME'."
# Confirmed live (same as destroy-employee-desktop.sh's instance-list check): 'zcp network
# list -o json' returns the literal 'null', not '[]', on an account with zero networks -
# exactly the first-time-user scenario this error path exists to handle nicely. '(. // [])[]'
# tolerates that instead of crashing with a raw jq error before ever reaching the friendly
# "Tier not found, run build-private-network.sh first" message below.
TIER_MATCHES="$(echo "$TIER_LIST_JSON" | jq --arg n "$TIER_NAME" '[(. // [])[] | select(.name==$n)]')"
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
# TIER_CIDR is interpolated into a subnet-membership check later, so its
# shape is checked here rather than trusted blindly. Bounded to real octets
# (0-255) and a real prefix (0-32), not just digit-shaped: a loose [0-9]{1,2}
# prefix would let /33+ through and silently defeat that check further down
# (a left-shift past 32 bits masks to zero).
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
  # Anything broader than /32 defeats the whole point of "your own IP" (it's meant to
  # scope admin access to exactly one machine), and lock_down_ssh's own open-rule
  # cleanup below would delete a broad rule like this right after creating it,
  # locking the VM out of SSH entirely after it's already billable. Confirmed live.
  if [ "${MY_IP##*/}" != "32" ]; then
    error "--my-ip '$MY_IP' must be a /32 (a single address). Anything broader gets removed by this script's own SSH lockdown, after the VM already exists."
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

# Password handling: a passed-in --password is used as-is (with a caution
# about shell history / process visibility). Without one, a strong random
# password is generated locally - alphanumeric only, so it needs no
# shell-escaping anywhere it's used (the cloud-init file, the final summary).
if [ "$PASSWORD_PROVIDED" = "true" ]; then
  warn "--password was passed explicitly. It may be visible in your shell history or process list (e.g. 'ps'). Prefer omitting --password and letting this script generate one."
else
  # `head -c N` closes its read end as soon as it has N bytes, and under `set -o pipefail`
  # (set near the top of this file) an upstream writer that's still writing when that
  # happens dies of SIGPIPE (exit 141) and, under `set -e`, aborts the whole script with no
  # output - confirmed live, 5/5 runs, on both branches below (the openssl branch was only
  # ever "safe" by luck: its output is short enough to usually fit the pipe buffer before
  # `head` reads and closes). Fixed by bounding the input instead: `head -c N /dev/urandom`
  # reads a fixed N bytes from the device file directly (not through a pipe it can close
  # early) and exits normally at EOF, so nothing downstream of it can ever SIGPIPE it. `cut`,
  # unlike `head`, reads its input to EOF rather than closing early, so it's safe on both
  # sides of the pipeline it's used in here.
  if command -v openssl >/dev/null 2>&1; then
    DESKTOP_PASSWORD="$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  else
    DESKTOP_PASSWORD="$(head -c 200 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  fi
  [ -n "$DESKTOP_PASSWORD" ] || error "Could not generate a random password locally. Pass --password explicitly."
fi

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

# $1 >= $2, dotted-numeric version comparison (e.g. "1.0.3" >= "1.0.2").
version_ge() {
  [ "$1" = "$2" ] && return 0
  local highest
  highest="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)"
  [ "$highest" = "$1" ]
}

VM_TEMPLATE="$(resolve "$VM_TEMPLATE" "ubuntukde template" "zcp template list -o json" '.[] | select(.name | test("ubuntukde";"i")) | .slug')"

# The tutorial this script ports was validated against ubuntukde 1.0.2, which fixes a real
# bug: snap-confined apps such as Firefox and Chromium silently failing to launch over RDP.
# Confirmed live: the app version isn't in the template's `.version` field (that's the OS
# version, e.g. "24.04 LTS"), it's embedded in `.name`/`.slug` only, e.g.
# "zmi-ubuntukde--ubuntu2404-1.0.2". Refused below rather than silently deployed if older.
UBUNTUKDE_MIN_VERSION="1.0.2"
VM_TEMPLATE_NAME="$(zcp template list -o json | jq -r --arg s "$VM_TEMPLATE" '.[] | select(.slug==$s) | .name' | head -1)"
VM_TEMPLATE_VERSION="$(echo "$VM_TEMPLATE_NAME" | jq -Rr 'capture("(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)$").v // empty')"
[ -n "$VM_TEMPLATE_VERSION" ] || error "Could not determine the ubuntukde template's app version from its name ('$VM_TEMPLATE_NAME'). Check manually: zcp template list"
# This check runs on an explicitly-passed --vm-template too (VM_TEMPLATE is only
# resolved from the flag or discovery above, never bypassed) - --vm-template lets you pin
# a *specific* 1.0.2-or-later template if more than one qualifies, it is not a way around
# this floor.
version_ge "$VM_TEMPLATE_VERSION" "$UBUNTUKDE_MIN_VERSION" \
  || error "ubuntukde template '$VM_TEMPLATE' is version $VM_TEMPLATE_VERSION, older than the validated minimum ($UBUNTUKDE_MIN_VERSION). That version fixes a real bug where snap-confined apps like Firefox/Chromium silently fail to launch over RDP. Check 'zcp template list' for a 1.0.2-or-later template and pass it with --vm-template - there is no way to deploy an older one with this script."

# --vm-plan default: resolve() alone can't express "smallest plan meeting the documented
# baseline", so this is a dedicated resolution rather than a generic resolve() call. Fields
# confirmed live via 'zcp plan vm -o json': cpu is a numeric string (e.g. "4"), memory is a
# string like "16.0 (GB)". 4 vCPU/16GB is the baseline this script's own --help already
# recommends for "a genuinely smooth desktop experience" (1 vCPU/2GB is what plan[0] happens
# to be today, unusable for a desktop) - matched here, not silently under-provisioned, and
# sorted ascending so the smallest plan meeting the baseline wins, not an arbitrarily bigger
# one. Confirmed live via 'zcp plan vm -o json': 5 real plans tie exactly at 4 vCPU/16GB with
# different prices, so cpu/memory alone leaves the pick dependent on API list ordering rather
# than pinned to a defensible choice. 'monthly' is a plain numeric string (no unit suffix,
# unlike memory) and is added as a tiebreaker so the cheapest qualifying plan is always
# picked, and 'slug' as a final tiebreaker so the result is fully deterministic even between
# plans that also tie on price. Errors clearly if nothing in this account/region qualifies.
if [ -z "$VM_PLAN" ]; then
  VM_PLAN_MATCH="$(zcp plan vm -o json | jq -r '
    [.[] | select((.cpu|tonumber) >= 4 and ((.memory | sub(" *\\(GB\\)";"") | tonumber) >= 16))]
    | sort_by((.cpu|tonumber), (.memory | sub(" *\\(GB\\)";"") | tonumber), (.monthly|tonumber), .slug)
    | .[0]')"
  [ -n "$VM_PLAN_MATCH" ] && [ "$VM_PLAN_MATCH" != "null" ] \
    || error "No VM compute plan with at least 4 vCPU / 16GB memory is available in this region/project. Pass --vm-plan explicitly (see 'zcp plan vm -o json' for what's available)."
  VM_PLAN="$(echo "$VM_PLAN_MATCH" | jq -r '.slug')"
fi
# Looked up regardless of whether --vm-plan was passed explicitly or resolved above, so the
# "Resolved resources" summary always shows real cpu/memory, not just an opaque slug - and so
# an explicitly-passed --vm-plan that doesn't exist is caught here, with a clear error,
# instead of surfacing only as a bare 'zcp instance create' failure later. jq on no match
# emits nothing at all (not null), so '// "?"' would never even fire - checked directly
# instead.
VM_PLAN_DETAILS="$(zcp plan vm -o json | jq -r --arg s "$VM_PLAN" '.[] | select(.slug==$s)')"
[ -n "$VM_PLAN_DETAILS" ] || error "VM plan '$VM_PLAN' not found. Check available plans: zcp plan vm"
VM_PLAN_CPU="$(echo "$VM_PLAN_DETAILS" | jq -r '.cpu')"
VM_PLAN_MEMORY="$(echo "$VM_PLAN_DETAILS" | jq -r '.memory')"

NETWORK_PLAN="$(resolve "$NETWORK_PLAN" "network plan" "zcp plan network -o json" '.[0].slug')"
STORAGE_CATEGORY="$(resolve "$STORAGE_CATEGORY" "VM storage category" "zcp storage-category list -o json" '.[0].slug')"

info "Resolved resources:"
echo "    Tier                : $TIER_NAME ($TIER_CIDR)" >&2
echo "    VM template (ubuntukde) : $VM_TEMPLATE (version $VM_TEMPLATE_VERSION)" >&2
echo "    VM plan             : $VM_PLAN ($VM_PLAN_CPU vCPU / $VM_PLAN_MEMORY)" >&2
echo "    Network plan        : $NETWORK_PLAN" >&2
echo "    Storage category    : $STORAGE_CATEGORY" >&2
echo "    Username            : $DESKTOP_USERNAME" >&2

if [ "$AUTO_YES" != "true" ]; then
  echo "" >&2
  echo "This creates a VM (plan above) on your account now." >&2
  echo "Billing starts as soon as the resource is created." >&2
  read -r -p "Type 'yes' to continue: " CONFIRM
  [ "$CONFIRM" = "yes" ] || error "Cancelled. Re-run with the flags above (or --yes to skip this prompt) when ready."
fi

# ---------------------------------------------------------------------------
# Existence + slug lookup helpers (same pattern as the other zcp/*.sh scripts)
# ---------------------------------------------------------------------------
instance_exists() {
  local list_json
  list_json="$(zcp instance list -o json)" || error "Could not list instances to check whether '$1' already exists."
  echo "$list_json" | jq -e --arg n "$1" '(. // [])[] | select(.name==$n)' >/dev/null 2>&1
}

slug_for_name() {
  local label="$1" list_cmd="$2" name="$3" list_json matches count
  list_json="$(eval "$list_cmd")" || error "Could not list ${label}s to resolve the slug for '$name'."
  matches="$(echo "$list_json" | jq --arg n "$name" '[(. // [])[] | select(.name==$n)]')"
  count="$(echo "$matches" | jq 'length')"
  case "$count" in
    0) error "No $label named '$name' found after creation. This shouldn't happen, check manually: $list_cmd" ;;
    1) echo "$matches" | jq -r '.[0].slug' ;;
    *) error "Ambiguous: $count ${label}s are named '$name'. This script can't safely tell them apart, rename or remove the duplicate, then re-run. ($list_cmd)" ;;
  esac
}

instance_slug_for_name() { slug_for_name "instance" "zcp instance list -o json" "$1"; }

wait_for_ssh() {
  # Deadline based on the bash SECONDS builtin, not a fixed-per-iteration counter: the ssh
  # probe itself can take up to its own ConnectTimeout, so a counter that just adds a fixed
  # increment per loop understates real elapsed time and the actual wall-clock wait can run
  # well past the number printed in the timeout message. Confirmed live.
  local ip="$1" timeout="$2" user="${3:-ubuntu}" start=$SECONDS
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  info "Waiting for SSH on $ip..."
  while ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "${user}@${ip}" true 2>/dev/null; do
    [ $((SECONDS - start)) -ge "$timeout" ] && error "SSH on $ip did not become ready within ${timeout}s. If this VM was already locked down to a previous --my-ip, and your real IP is different now, add a rule for it manually (zcp firewall create --ip <ip-slug> --protocol tcp --start-port 22 --end-port 22 --cidr <your-ip>/32) and re-run. Raise the timeout with --ssh-wait."
    sleep 5
  done
  success "SSH ready on $ip"
}

# Polls for the cloud-init-provisioned desktop user rather than checking once: a KDE
# desktop image's first-boot provisioning (installing/configuring the desktop, xrdp,
# creating the user) can legitimately still be running for minutes after SSH becomes
# reachable - the tutorial this script ports budgets ~30 minutes total including
# "first-boot KDE provisioning" as its own distinct phase. A single-shot check here would
# hard-error on a deploy that's simply still finishing, leaving a created, billable VM
# with no summary ever printed. Checks more than mere presence: the real protection against
# --username colliding with a pre-existing system account (e.g. 'ubuntu', UID 1000 on this
# platform's images and this script's own SSH user - a 100% collision; 'nobody', UID 65534;
# and the rest of the standard Debian/Ubuntu base accounts) is the RESERVED_USERNAMES
# denylist checked at parse time, before any zcp call, above. Requiring a human UID (>=1000)
# here is only a second, belt-and-suspenders layer on top of that - it does NOT by itself
# catch every possible collision (it would not, for example, catch a colliding account an
# operator manually created locally with a UID >= 1000), so it must not be relied on alone.
wait_for_cloud_init_user() {
  # Deadline based on SECONDS, same reasoning as wait_for_ssh above: each remote() probe
  # here can itself take up to 3 retries x ~15s, so a fixed per-iteration counter can badly
  # understate real elapsed time against the printed timeout.
  local ip="$1" username="$2" timeout="$3" user="${4:-ubuntu}" start=$SECONDS uid
  info "Waiting for cloud-init to finish provisioning '$username' (first-boot KDE provisioning can take several minutes)..."
  while true; do
    uid="$(remote "$ip" "id -u $username 2>/dev/null" "$user" || true)"
    if [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ]; then
      success "Cloud-init user '$username' confirmed on '$VM_NAME' (uid $uid)"
      return 0
    fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      error "Cloud-init user '$username' does not exist (or has no human uid >= 1000) on '$VM_NAME' after ${timeout}s. The template's first-boot provisioning may still be running (raise the timeout with --cloud-init-wait and re-run), may have failed, or '$username' may have collided with a pre-existing system account. Check manually: ssh ${user}@$ip 'sudo journalctl -u cloud-final' (or check for an 'invalid desktop username' style error, or 'id $username'). If the account exists and just needs a password reset: ssh ${user}@$ip 'sudo passwd $username'."
    fi
    sleep 10
  done
}

remote() {
  # Retries on ssh's own exit code 255 only, same reasoning as
  # build-private-network.sh's remote(): a connection can transiently time
  # out and recover seconds later with no underlying problem. The `set +e`
  # around the ssh call is not decorative: most call sites below invoke this
  # as a bare statement, and under `set -e` a bare failing command in that
  # position aborts the whole script immediately, before `status=$?` on the
  # next line ever runs - the retry loop below never executed for those.
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
# against real API/platform propagation delays). Also covers this template's
# own default-open 0.0.0.0/0 TCP+UDP port-22 rule (confirmed live on the
# ubuntukde marketplace template, same as every other marketplace template in
# this series) as part of its existing generic logic - no separate cleanup
# needed for it. Called before wait_for_ssh (only talks to the zcp API, so a
# rerun from a new IP can reconcile before anything tries to connect).
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
# Step 1: Cloud-init userdata
# ---------------------------------------------------------------------------
step "Step 1/3: Deploy the desktop VM"

# Written to a local temp file, not passed inline: --user-data-file expects a
# path, and this keeps the password out of the process argv for the zcp
# instance create call below. Restricted to owner-only before anything is
# written to it, and removed on exit regardless of how the script terminates.
USERDATA_FILE="$(mktemp)"
trap 'rm -f "$USERDATA_FILE"' EXIT
chmod 600 "$USERDATA_FILE"
cat > "$USERDATA_FILE" <<EOF
#cloud-config
write_files:
  - path: /etc/zmi/deploy.env
    permissions: '0600'
    owner: root:root
    content: |
      UBUNTUKDE_USERNAME=$DESKTOP_USERNAME
      UBUNTUKDE_PASSWORD=$DESKTOP_PASSWORD
EOF

# A public IP is allocated deliberately, same reasoning as the storage VM in
# deploy-private-storage.sh: a VM with no public footprint at all can't be
# reached even for the one-time tier-NIC setup below, and there's no
# console/recovery access on this platform. SSH is then locked to your own
# IP, and RDP is never opened on the public side at all, so the desktop ends
# up just as unreachable over RDP publicly as a no-public-IP VM would be.
if ! instance_exists "$VM_NAME"; then
  if ! zcp instance create --name "$VM_NAME" \
    --template "$VM_TEMPLATE" --plan "$VM_PLAN" --billing-cycle "$BILLING_CYCLE" \
    --network-plan "$NETWORK_PLAN" --storage-category "$STORAGE_CATEGORY" \
    --ssh-key "$SSH_KEY" --user-data-file "$USERDATA_FILE" --wait; then
    error "Could not create '$VM_NAME' (or it didn't reach Running in time). If it was actually created despite that, check 'zcp instance list' and clean up with: destroy-employee-desktop.sh --name $VM_NAME"
  fi
  success "'$VM_NAME' created"
  # From this point on the VM exists and is billing, with its cloud-init password already
  # baked in - if anything below fails, the local copy of that password (the temp file
  # above) is gone by the time this script exits. Surfaced now, not only in the final
  # summary, so a later failure never makes it unrecoverable. Confirmed live: this is a
  # real, reachable outcome, not a hypothetical - several remote()/API calls below can fail
  # on a deploy that was otherwise healthy (a slow tier NIC, a transient API error).
  if [ "$PASSWORD_PROVIDED" = "true" ]; then
    info "'$VM_NAME' now exists and is billing. Its RDP password is the one you passed with --password - nothing below this point can lose it."
  else
    warn "'$VM_NAME' now exists and is billing, with its RDP password already baked in by cloud-init. SAVE THIS NOW - if anything below fails, this is the only place it's shown: $DESKTOP_PASSWORD"
  fi
else
  VM_ALREADY_EXISTED="true"
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

VM_INSTANCE_JSON="$(zcp instance get "$VM_SLUG" -o json)" || error "Could not look up instance details for '$VM_NAME'."
VM_IP="$(echo "$VM_INSTANCE_JSON" | jq -r '.[] | select(.field=="Public IP") | .value' | head -1 || true)"
[ -n "$VM_IP" ] && [ "$VM_IP" != "null" ] || error "Could not determine '$VM_NAME' public IP."
VM_USER="$(echo "$VM_INSTANCE_JSON" | jq -r '.[] | select(.field=="Username") | .value' | head -1 || true)"
[ -n "$VM_USER" ] && [ "$VM_USER" != "null" ] || VM_USER="ubuntu"
info "Desktop VM public IP: $VM_IP"

# Runs BEFORE wait_for_ssh, same reasoning as build-private-network.sh: only
# talks to the zcp API, so a rerun from a new $MY_IP reconciles before
# anything tries to connect, instead of deadlocking against the old rule.
IP_SLUG="$(zcp ip list -o json | jq -r --arg vm "$VM_NAME" '.[] | select(.vm==$vm) | .slug' | head -1 || true)"
[ -n "$IP_SLUG" ] || error "Could not find the public IP slug for '$VM_NAME'."

info "Locking down SSH to your own IP (nothing else is ever opened on the public side; RDP stays tier-only)..."
lock_down_ssh "$IP_SLUG" "$VM_NAME"

wait_for_ssh "$VM_IP" "$SSH_WAIT_SECONDS" "$VM_USER"

# ---------------------------------------------------------------------------
# Step 2: Tier NIC
# ---------------------------------------------------------------------------
step "Step 2/3: Bring up the tier network interface"

info "Bringing up the tier NIC (hot-added, not auto-configured by the OS)..."
# Same exclusions as deploy-private-storage.sh's tier NIC detection: lo, enp*, and
# tailscale* (not applicable here, but kept for consistency). Note this doesn't actually
# exclude the VM's own public NIC by name - this platform's public NICs are named ens*, not
# enp* - correct interface selection instead comes from the `tail -1` ordering here plus
# the prefix-aware subnet sanity check further down.
TIER_NIC="$(remote "$VM_IP" "ip -br link show | awk '{print \$1}' | grep -v '^lo\$' | grep -v '^enp' | grep -v '^tailscale' | tail -1" "$VM_USER" || true)"
[ -n "$TIER_NIC" ] || error "Could not identify the tier NIC on '$VM_NAME'. VM is billable - check manually: ssh ${VM_USER}@$VM_IP 'ip -br link show', or tear down with: destroy-employee-desktop.sh --name $VM_NAME"
if ! remote "$VM_IP" "sudo tee /etc/netplan/60-tier-nic.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${TIER_NIC}:
      dhcp4: true
EOF" "$VM_USER"; then
  error "Could not write the netplan config on '$VM_NAME'. VM is billable - check manually: ssh ${VM_USER}@$VM_IP, or tear down with: destroy-employee-desktop.sh --name $VM_NAME"
fi
if ! remote "$VM_IP" "sudo netplan apply" "$VM_USER"; then
  error "Could not apply the netplan config on '$VM_NAME'. VM is billable - check manually: ssh ${VM_USER}@$VM_IP, or tear down with: destroy-employee-desktop.sh --name $VM_NAME"
fi
info "If netplan printed a 'permissions too open' warning above, that's expected and harmless here, not a real problem with the file or the NIC coming up."
sleep 5
VM_TIER_IP="$(remote "$VM_IP" "ip -4 -br addr show ${TIER_NIC} | awk '{print \$3}' | cut -d/ -f1" "$VM_USER" || true)"
[ -n "$VM_TIER_IP" ] || error "Tier NIC did not come up with an address. VM is billable - check manually: ssh ${VM_USER}@$VM_IP, or tear down with: destroy-employee-desktop.sh --name $VM_NAME"
# Belt and suspenders, same reasoning as deploy-private-storage.sh's tier NIC
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
  error "Interface '$TIER_NIC' came up with $VM_TIER_IP, which is not on the tier ($TIER_CIDR). Wrong interface selected. VM is billable - check manually: ssh ${VM_USER}@$VM_IP 'ip -br addr show', or tear down with: destroy-employee-desktop.sh --name $VM_NAME"
fi
success "Tier NIC ($TIER_NIC) up at $VM_TIER_IP"

# ---------------------------------------------------------------------------
# Step 3: Confirm the cloud-init user
# ---------------------------------------------------------------------------
step "Step 3/3: Confirm the cloud-init user exists"

# Polls rather than checking once: see wait_for_cloud_init_user's own comment for why.
# $DESKTOP_USERNAME was already validated against ^[a-z][a-z0-9_]*\$ above, so it's safe to
# interpolate here without quoting concerns.
wait_for_cloud_init_user "$VM_IP" "$DESKTOP_USERNAME" "$CLOUD_INIT_WAIT_SECONDS" "$VM_USER"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Done"

# On a rerun against a VM that already existed, cloud-init never re-applied - the password
# generated/printed this run is NOT the VM's real password (that was set at the VM's
# original first boot, and the temp file holding it was already deleted by the EXIT trap
# from that first run). Only ever presented as real when this run actually created the VM.
if [ "$VM_ALREADY_EXISTED" = "true" ]; then
  RDP_PASSWORD_SUMMARY="  RDP password : (unchanged -- set at first boot by the original deploy, not recoverable here)"
else
  RDP_PASSWORD_SUMMARY="  RDP password : $DESKTOP_PASSWORD
                  $([ "$PASSWORD_PROVIDED" = "true" ] && echo "(the password you passed with --password)" || echo "(generated by this script - also printed right after creation above, in case a later step had failed)")"
fi

cat <<EOF

Employee desktop deployed:

  Desktop VM   : $VM_NAME -> tier IP ${VM_TIER_IP}
                  SSH: ssh ${VM_USER}@${VM_IP} (admin access only, scoped to $MY_IP)
  RDP login    : $DESKTOP_USERNAME
$RDP_PASSWORD_SUMMARY

  RDP address  : ${VM_TIER_IP}   <-- connect here, NEVER the public IP ($VM_IP) above.

Connect over RDP to the desktop's TIER IP above, never the public IP. RDP was never opened
on the public side at all, only SSH, and that's locked to $MY_IP alone.

Notes:

  - On first login, KDE may show a PolicyKit prompt: "System policy prevents control of
    network connections." Entering the employee's own password ($DESKTOP_USERNAME's) lets
    the session continue normally.
  - If the RDP window looks tiny despite filling the screen, set an explicit resolution in
    your RDP client rather than relying on auto-negotiation.
  - This template's xrdp has no H.264/AVC444 support, so video calls perform poorly inside
    the RDP session. Run the call app locally on the employee's own machine and screen-share
    the RDP window instead, rather than joining the call from inside the desktop.
  - If this desktop will also mount Tutorial 2's shared storage, there's an optional
    identity/UID decision to make before the employee's first login (NFS does raw UID
    mapping, not username mapping, so every desktop's first custom user tends to land on
    the same UID by default). This is a manual step, not something this script automates -
    see the "Deploy Ubuntu Employee Desktops" tutorial's identity section before the
    employee logs in for the first time.

Inspect what was created:

  zcp instance list
  zcp ip list

Clean up when done (billing runs hourly while this exists):

  bash <(curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/zcp/destroy-employee-desktop.sh) \\
    --name $VM_NAME --region $ZCP_REGION --project $ZCP_PROJECT

EOF
