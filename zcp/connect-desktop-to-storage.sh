#!/bin/bash
# ZCP Connect Desktop to Storage
# Mounts an existing NFS share (Deploy Private Shared Storage) onto an
# existing desktop VM (Deploy Ubuntu Employee Desktops), for one named
# employee login. Run by the operator over SSH, before handing RDP
# credentials to that employee. No destroy script - undo is 'sudo umount'.
#
# Usage:
#   ./connect-desktop-to-storage.sh --desktop-name my-desktop \
#     --storage-tier-ip 10.20.1.90 --username janedoe [options]
#
# Requires: zcp CLI (authenticated), jq, ssh
set -e
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
step() { echo "" >&2; echo -e "${CYAN}==>${NC} $1" >&2; }

usage() {
  cat <<EOF
ZCP Connect Desktop to Storage

Usage: $0 --desktop-name NAME --storage-tier-ip IP --username LOGIN [options]

Required:
  --desktop-name NAME    The desktop VM's name (same value passed to
                          deploy-employee-desktop.sh --name).
  --storage-tier-ip IP   The storage VM's tier IP, e.g. 10.20.1.90. This is
                          printed once by deploy-private-storage.sh's own
                          summary output - not auto-resolved here, there is
                          no reliable CLI-queryable field for an existing
                          VM's current tier NIC IP.
  --username LOGIN       The employee's Linux login on the desktop (same
                          value passed to deploy-employee-desktop.sh --username).
                          Used to confirm the account exists and to prove the
                          mounted share is actually writable by that account.

Options:
  --share-name NAME  NFS share directory name (default: company-share). Must
                      match the storage VM's own --share-name.
  --region REGION    zcp region slug (or \$ZCP_REGION)
  --project PROJECT  zcp project slug (or \$ZCP_PROJECT)
  -h, --help         Show this help

Example:
  ./connect-desktop-to-storage.sh --desktop-name my-desktop \\
    --storage-tier-ip 10.20.1.90 --username janedoe
EOF
}

require_value() {
  if [[ -z "${2:-}" || "$2" == -* ]]; then
    error "$1 requires a value."
  fi
}

DESKTOP_NAME=""
STORAGE_TIER_IP=""
SHARE_NAME="company-share"
DESKTOP_USERNAME=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --region) require_value "$1" "${2:-}"; ZCP_REGION="$2"; shift 2 ;;
    --project) require_value "$1" "${2:-}"; ZCP_PROJECT="$2"; shift 2 ;;
    --desktop-name) require_value "$1" "${2:-}"; DESKTOP_NAME="$2"; shift 2 ;;
    --storage-tier-ip) require_value "$1" "${2:-}"; STORAGE_TIER_IP="$2"; shift 2 ;;
    --share-name) require_value "$1" "${2:-}"; SHARE_NAME="$2"; shift 2 ;;
    --username) require_value "$1" "${2:-}"; DESKTOP_USERNAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1 (see --help)" ;;
  esac
done

step "Validating inputs"

[ -n "$DESKTOP_NAME" ] || error "--desktop-name is required."
[ -n "$STORAGE_TIER_IP" ] || error "--storage-tier-ip is required."
[ -n "$DESKTOP_USERNAME" ] || error "--username is required."

NAME_RE='^[a-zA-Z0-9-]+$'
[[ "$DESKTOP_NAME" =~ $NAME_RE ]] || error "--desktop-name '$DESKTOP_NAME' must contain only letters, numbers, and hyphens."
[[ "$SHARE_NAME" =~ $NAME_RE ]] || error "--share-name '$SHARE_NAME' must contain only letters, numbers, and hyphens (it's used as a directory name and an NFS export path)."

OCTET='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
[[ "$STORAGE_TIER_IP" =~ ^${OCTET}\.${OCTET}\.${OCTET}\.${OCTET}$ ]] || error "--storage-tier-ip '$STORAGE_TIER_IP' is not a valid IPv4 address."

[[ "$DESKTOP_USERNAME" =~ ^[a-z][a-z0-9_]*$ ]] \
  || error "--username '$DESKTOP_USERNAME' must match ^[a-z][a-z0-9_]*\$."
[ "${#DESKTOP_USERNAME}" -le 32 ] || error "--username too long (${#DESKTOP_USERNAME} chars; useradd's limit is 32)."

# Same reserved list as deploy-employee-desktop.sh's own validation: real
# accounts on the ubuntukde image, not a guess. Without this, --username
# ubuntu or --username root would pass getent passwd trivially (they're real
# accounts) and the script would run the verification write/read as them
# instead of an actual employee.
RESERVED=(ubuntu nobody root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats syslog messagebus landscape xrdp sddm sshd polkitd dhcpcd uuidd tss pollinate tcpdump usbmux rtkit avahi geoclue dnsmasq)
for r in "${RESERVED[@]}"; do
  [ "$DESKTOP_USERNAME" != "$r" ] \
    || error "--username '$DESKTOP_USERNAME' collides with an existing account on the image. Use the employee's actual login, not a system account."
done

command -v zcp >/dev/null 2>&1 || error "zcp CLI not found."
command -v jq >/dev/null 2>&1 || error "jq not found."
command -v ssh >/dev/null 2>&1 || error "ssh client not found."
zcp auth validate >/dev/null 2>&1 || error "zcp CLI is not authenticated."
[ -n "${ZCP_REGION:-}" ] || error "--region (or \$ZCP_REGION) is required."
[ -n "${ZCP_PROJECT:-}" ] || error "--project (or \$ZCP_PROJECT) is required."
export ZCP_REGION ZCP_PROJECT
zcp() { command zcp --region "$ZCP_REGION" --project "$ZCP_PROJECT" "$@"; }

# Retries on exit 255 (connection-level failure) only, never a real remote
# command failure. Everything runs as 'ubuntu' - passwordless root sudo.
remote() {
  local ip="$1" cmd="$2" user="${3:-ubuntu}" attempt status
  for attempt in 1 2 3; do
    set +e; ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${user}@${ip}" "$cmd"; status=$?; set -e
    [ "$status" -ne 255 ] && return "$status"
    [ "$attempt" -lt 3 ] && sleep 5
  done
  return "$status"
}

step "Resolving the desktop VM"

VM_LIST_JSON="$(zcp instance list -o json)" || error "Could not list instances to look up '$DESKTOP_NAME'."
VM_MATCHES="$(echo "$VM_LIST_JSON" | jq --arg n "$DESKTOP_NAME" '[.[] | select(.name==$n)]')"
VM_MATCH_COUNT="$(echo "$VM_MATCHES" | jq 'length')"
case "$VM_MATCH_COUNT" in
  0) error "No desktop VM named '$DESKTOP_NAME' found. Check: zcp instance list" ;;
  1) VM_SLUG="$(echo "$VM_MATCHES" | jq -r '.[0].slug')" ;;
  *) error "Ambiguous: $VM_MATCH_COUNT instances are named '$DESKTOP_NAME'. This script can't safely tell them apart. Rename or remove the duplicate, then re-run. (zcp instance list)" ;;
esac
[ -n "$VM_SLUG" ] && [ "$VM_SLUG" != "null" ] || error "Found instance '$DESKTOP_NAME' but it has no slug in the API response. Check manually: zcp instance list"

VM_INSTANCE_JSON="$(zcp instance get "$VM_SLUG" -o json)" || error "Could not look up '$DESKTOP_NAME'."
VM_IP="$(echo "$VM_INSTANCE_JSON" | jq -r '.[] | select(.field=="Public IP") | .value' | head -1)"
[ -n "$VM_IP" ] && [ "$VM_IP" != "null" ] || error "Could not determine '$DESKTOP_NAME' public IP. Check manually: zcp instance get $VM_SLUG"
success "Desktop VM '$DESKTOP_NAME' resolved, public IP: $VM_IP"

step "Checking the employee account"

remote "$VM_IP" "getent passwd '$DESKTOP_USERNAME' >/dev/null" "ubuntu" \
  || error "Employee account '$DESKTOP_USERNAME' not found on '$DESKTOP_NAME' (getent passwd). Deploy that account first with deploy-employee-desktop.sh --username $DESKTOP_USERNAME, then re-run this script."
success "Employee account '$DESKTOP_USERNAME' confirmed on '$DESKTOP_NAME'."

step "Checking whether the share is already mounted"

EXPECTED_SOURCE="${STORAGE_TIER_IP}:/srv/nfs/${SHARE_NAME}"
# --mountpoint, not --target: --target walks up to the nearest ancestor
# mountpoint, so a plain unmounted directory would misreport the root disk
# as "already mounted" and wrongly refuse to proceed.
MOUNT_CHECK_CMD="findmnt -n -o SOURCE --mountpoint=/mnt/${SHARE_NAME} 2>/dev/null || true"
CURRENT_SOURCE="$(remote "$VM_IP" "$MOUNT_CHECK_CMD" "ubuntu")" || true

ALREADY_MOUNTED="false"
if [ -n "$CURRENT_SOURCE" ]; then
  if [ "$CURRENT_SOURCE" = "$EXPECTED_SOURCE" ]; then
    ALREADY_MOUNTED="true"
    warn "/mnt/${SHARE_NAME} on '$DESKTOP_NAME' is already mounted from $EXPECTED_SOURCE. Skipping install/mount, but still re-verifying it's actually usable before touching /etc/fstab."
  else
    error "/mnt/${SHARE_NAME} on '$DESKTOP_NAME' is already mounted from '$CURRENT_SOURCE', not the expected '$EXPECTED_SOURCE'. Refusing to mount over it - something may still be using it. If this tier IP is genuinely correct (e.g. the storage VM was redeployed), unmount it yourself first: ssh ubuntu@$VM_IP 'sudo umount /mnt/${SHARE_NAME}', then re-run this script."
  fi
fi

if [ "$ALREADY_MOUNTED" != "true" ]; then
  step "Installing nfs-common and mounting the share"

  # Required: the ubuntukde template's build strips /var/lib/apt/lists/*.
  remote "$VM_IP" "sudo apt-get update && sudo apt-get install -y nfs-common" "ubuntu" \
    || error "Could not install nfs-common on '$DESKTOP_NAME' (apt-get update/install failed). Check manually: ssh ubuntu@$VM_IP"

  remote "$VM_IP" "sudo mkdir -p /mnt/${SHARE_NAME}" "ubuntu" \
    || error "Could not create /mnt/${SHARE_NAME} on '$DESKTOP_NAME' (mkdir failed). Check manually: ssh ubuntu@$VM_IP"

  remote "$VM_IP" "sudo mount -t nfs ${STORAGE_TIER_IP}:/srv/nfs/${SHARE_NAME} /mnt/${SHARE_NAME}" "ubuntu" \
    || error "Could not mount ${STORAGE_TIER_IP}:/srv/nfs/${SHARE_NAME} at /mnt/${SHARE_NAME} on '$DESKTOP_NAME' (mount failed - check the storage VM is reachable on the tier and is actually exporting this share). Check manually: ssh ubuntu@$VM_IP"

  success "Mounted ${STORAGE_TIER_IP}:/srv/nfs/${SHARE_NAME} at /mnt/${SHARE_NAME} on '$DESKTOP_NAME'."
fi

# Always re-verified, even when already mounted: a mount that mounted fine
# but failed its write/read check on a prior run must not get silently
# persisted to fstab and reported as success just because it's still mounted.
step "Verifying the mount"

DF_SOURCE="$(remote "$VM_IP" "df --output=source /mnt/${SHARE_NAME} 2>/dev/null | tail -n1" "ubuntu")" \
  || error "Could not read df output for /mnt/${SHARE_NAME} on '$DESKTOP_NAME' (df failed)."
DF_SOURCE="$(echo "$DF_SOURCE" | xargs)"
[ "$DF_SOURCE" = "$EXPECTED_SOURCE" ] \
  || error "Mount 'succeeded' but /mnt/${SHARE_NAME} on '$DESKTOP_NAME' is not backed by $EXPECTED_SOURCE (df shows '$DF_SOURCE' - likely still the local root disk from a merged-argument mount failure). Check manually: ssh ubuntu@$VM_IP"

# Written/read as the employee via ubuntu's own sudo -u, to prove the file
# lands under their UID. Filename scoped to desktop+employee to avoid
# collisions.
TEST_FILE="/mnt/${SHARE_NAME}/.zcp-connect-test-${DESKTOP_NAME}-${DESKTOP_USERNAME}"
remote "$VM_IP" "sudo -u '$DESKTOP_USERNAME' -i bash -c 'echo zcp-connect-test-ok > ${TEST_FILE}'" "ubuntu" \
  || error "Could not write a test file to /mnt/${SHARE_NAME} on '$DESKTOP_NAME' as '$DESKTOP_USERNAME' (write failed). Check share permissions."
READBACK="$(remote "$VM_IP" "sudo -u '$DESKTOP_USERNAME' -i bash -c 'cat ${TEST_FILE} 2>/dev/null'" "ubuntu")" \
  || error "Could not read back the test file from /mnt/${SHARE_NAME} on '$DESKTOP_NAME' (read failed)."
[ "$(echo "$READBACK" | xargs)" = "zcp-connect-test-ok" ] \
  || error "Write+read verification failed on /mnt/${SHARE_NAME} on '$DESKTOP_NAME' (expected 'zcp-connect-test-ok', got '$READBACK')."
remote "$VM_IP" "sudo -u '$DESKTOP_USERNAME' -i bash -c 'rm -f ${TEST_FILE}'" "ubuntu" \
  || warn "Could not remove the verification test file ${TEST_FILE} on '$DESKTOP_NAME' (cleanup failed). Harmless, but you may want to remove it manually."
success "Mount verified: NFS-backed, writable and readable by '$DESKTOP_USERNAME'."

step "Updating /etc/fstab"

FSTAB_MOUNTPOINT="/mnt/${SHARE_NAME}"
FSTAB_LINE="${STORAGE_TIER_IP}:/srv/nfs/${SHARE_NAME} ${FSTAB_MOUNTPOINT} nfs defaults,noatime,nofail,_netdev 0 0"
# Replaces any existing line for this mountpoint (matched by field 2, not a
# whole-line/substring match), so a stale line from a different tier IP gets
# swapped, not duplicated.
FSTAB_CMD="set -e
existing=\$(awk -v mp='${FSTAB_MOUNTPOINT}' '\$2==mp' /etc/fstab)
if [ \"\$existing\" = '${FSTAB_LINE}' ]; then
  echo ALREADY_PRESENT
else
  awk -v mp='${FSTAB_MOUNTPOINT}' '\$2 != mp' /etc/fstab > \$HOME/fstab.new
  echo '${FSTAB_LINE}' >> \$HOME/fstab.new
  sudo cp \$HOME/fstab.new /etc/fstab
  rm -f \$HOME/fstab.new
  if [ -n \"\$existing\" ]; then echo REPLACED; else echo APPENDED; fi
fi"
FSTAB_OUTPUT="$(remote "$VM_IP" "$FSTAB_CMD" "ubuntu")" \
  || error "Could not update /etc/fstab on '$DESKTOP_NAME' (awk/cp of the fstab entry failed). Check manually: ssh ubuntu@$VM_IP"
case "$FSTAB_OUTPUT" in
  *ALREADY_PRESENT*) warn "/etc/fstab on '$DESKTOP_NAME' already has this exact entry, skipping (no duplicate added)." ;;
  *REPLACED*) success "Replaced a stale /etc/fstab entry for /mnt/${SHARE_NAME} on '$DESKTOP_NAME' with the current one." ;;
  *APPENDED*) success "Added /mnt/${SHARE_NAME} to /etc/fstab on '$DESKTOP_NAME'; it remounts automatically on reboot." ;;
  *) error "Unexpected output while updating /etc/fstab on '$DESKTOP_NAME': $FSTAB_OUTPUT" ;;
esac

step "Done"
cat <<EOF

Shared storage connected:

  Desktop VM   : $DESKTOP_NAME (ssh ubuntu@$VM_IP, admin access only)
  Employee     : $DESKTOP_USERNAME
  NFS share    : ${STORAGE_TIER_IP}:/srv/nfs/${SHARE_NAME} -> /mnt/${SHARE_NAME}
  fstab        : entry present, remounts automatically on reboot

Notes:
  - NFS here enforces permissions by raw UID number, not by username. If your
    organization needs per-employee isolation, that's a separate identity/UID
    decision to make before this employee's first login - see the identity/UID
    section of the "Deploy Ubuntu Employee Desktops" tutorial.
  - Before handing RDP credentials to $DESKTOP_USERNAME, log in once yourself
    with those credentials and confirm the share is visible in Dolphin (KDE's
    file manager) under Places -> Remote. That check can't be done over SSH -
    it's the one thing this script can't verify for you.

EOF
