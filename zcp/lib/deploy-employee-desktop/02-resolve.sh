resolve() {
  local val="$1" label="$2" cmd="$3" field="$4" out
  [ -n "$val" ] && { echo "$val"; return; }
  out="$(eval "$cmd" | jq -r "$field" | head -1 || true)"
  [ -n "$out" ] && [ "$out" != "null" ] || error "Could not auto-discover $label. Pass it explicitly."
  echo "$out"
}
version_ge() { [ "$1" = "$2" ] && return 0; [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
resolve_resources() {
  step "Preflight checks"
  command -v zcp >/dev/null 2>&1 || error "zcp CLI not found."
  command -v jq >/dev/null 2>&1 || error "jq not found."
  command -v ssh >/dev/null 2>&1 || error "ssh client not found."
  zcp auth validate >/dev/null 2>&1 || error "zcp CLI not authenticated. Run 'zcp profile add default'."
  [ -n "${ZCP_REGION:-}" ] || error "--region (or \$ZCP_REGION) is required."
  [ -n "${ZCP_PROJECT:-}" ] || error "--project (or \$ZCP_PROJECT) is required."
  [ -n "$SSH_KEY" ] || error "--ssh-key is required."
  [ -n "$TIER_NAME" ] || error "--tier-name is required."
  export ZCP_REGION ZCP_PROJECT
  CLEANUP_HINT="bash <(curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/zcp/destroy-employee-desktop.sh) --name $VM_NAME --region $ZCP_REGION --project $ZCP_PROJECT"
  zcp ssh-key list -o json | jq -e --arg n "$SSH_KEY" '.[] | select(.name==$n)' >/dev/null 2>&1 || error "SSH key '$SSH_KEY' not found (zcp ssh-key list)."
  success "zcp CLI authenticated, region=$ZCP_REGION project=$ZCP_PROJECT"
  local tj tm tc octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])' prefix='(3[0-2]|[1-2][0-9]|[0-9])'
  tj="$(zcp network list -o json)" || error "Could not list networks."
  tm="$(echo "$tj" | jq --arg n "$TIER_NAME" '[(. // [])[] | select(.name==$n)]')"; tc="$(echo "$tm" | jq 'length')"
  case "$tc" in
    0) error "Tier '$TIER_NAME' not found. Run build-private-network.sh first." ;;
    1) TIER_SLUG="$(echo "$tm" | jq -r '.[0].slug')" ;;
    *) error "Ambiguous: $tc networks named '$TIER_NAME'." ;;
  esac
  TIER_DETAILS_JSON="$(zcp network get "$TIER_SLUG" -o json)" || error "Could not look up tier '$TIER_NAME'."
  TIER_CIDR="$(echo "$TIER_DETAILS_JSON" | jq -r '.[] | select(.field=="CIDR") | .value' | head -1)"
  [[ "$TIER_CIDR" =~ ^${octet}\.${octet}\.${octet}\.${octet}/${prefix}$ ]] || error "Tier '$TIER_NAME' has an unexpected CIDR: '$TIER_CIDR'."
  info "Tier '$TIER_NAME' found: $TIER_CIDR"
  if [ -n "$MY_IP" ]; then
    [[ "$MY_IP" =~ ^${octet}\.${octet}\.${octet}\.${octet}/${prefix}$ ]] || error "--my-ip must be a valid IPv4 CIDR."
    [ "${MY_IP##*/}" != "0" ] || error "--my-ip can't use a /0 prefix (covers the whole internet regardless of address)."
  else
    info "Detecting your public IP..."
    local ip; ip="$(curl -4 -fsSL https://ifconfig.me)" || error "Could not detect your public IP."
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || error "Detected IP '$ip' is invalid."
    MY_IP="${ip}/32"
  fi
  info "Admin-port access scoped to: $MY_IP"
  if [ "$PASSWORD_PROVIDED" = "true" ]; then
    warn "--password passed explicitly; may be visible in shell history."
  elif command -v openssl >/dev/null 2>&1; then
    DESKTOP_PASSWORD="$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  else
    DESKTOP_PASSWORD="$(head -c 200 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  fi
  [ "$PASSWORD_PROVIDED" = "true" ] || [ -n "$DESKTOP_PASSWORD" ] || error "Could not generate a random password."
  VM_TEMPLATE="$(resolve "$VM_TEMPLATE" "ubuntukde template" "zcp template list -o json" '.[] | select(.name | test("ubuntukde";"i")) | .slug')"
  local tname; tname="$(zcp template list -o json | jq -r --arg s "$VM_TEMPLATE" '.[] | select(.slug==$s) | .name' | head -1)"
  [ -n "$tname" ] || error "Template '$VM_TEMPLATE' not found."
  echo "$tname" | grep -qi ubuntukde || error "Template '$VM_TEMPLATE' is not an ubuntukde template."
  VM_TEMPLATE_VERSION="$(echo "$tname" | jq -Rr 'capture("(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)$").v // empty')"
  [ -n "$VM_TEMPLATE_VERSION" ] || error "Could not determine template version from '$tname'."
  version_ge "$VM_TEMPLATE_VERSION" "1.0.2" || error "ubuntukde template is version $VM_TEMPLATE_VERSION, older than the required 1.0.2 (fixes a Firefox/Chromium RDP launch bug)."
  if [ -z "$VM_PLAN" ]; then
    local match
    match="$(zcp plan vm -o json | jq -r '[.[] | select((.cpu|tonumber)>=4 and ((.memory|sub(" *\\(GB\\)";"")|tonumber)>=16))] | sort_by((.cpu|tonumber),(.memory|sub(" *\\(GB\\)";"")|tonumber),(.monthly|tonumber),.slug) | .[0]')"
    [ -n "$match" ] && [ "$match" != "null" ] || error "No plan with at least 4 vCPU/16GB is available. Pass --vm-plan explicitly."
    VM_PLAN="$(echo "$match" | jq -r '.slug')"
  fi
  local pd; pd="$(zcp plan vm -o json | jq -r --arg s "$VM_PLAN" '.[] | select(.slug==$s)')"
  [ -n "$pd" ] || error "VM plan '$VM_PLAN' not found."
  VM_PLAN_CPU="$(echo "$pd" | jq -r '.cpu')"; VM_PLAN_MEMORY="$(echo "$pd" | jq -r '.memory')"
  NETWORK_PLAN="$(resolve "$NETWORK_PLAN" "network plan" "zcp plan network -o json" '.[0].slug')"
  STORAGE_CATEGORY="$(resolve "$STORAGE_CATEGORY" "storage category" "zcp storage-category list -o json" '.[0].slug')"
  info "Resolved: tier=$TIER_NAME($TIER_CIDR) template=$VM_TEMPLATE($VM_TEMPLATE_VERSION) plan=$VM_PLAN($VM_PLAN_CPU vCPU/$VM_PLAN_MEMORY) network=$NETWORK_PLAN storage=$STORAGE_CATEGORY user=$DESKTOP_USERNAME"
  if [ "$AUTO_YES" != "true" ]; then
    if instance_exists "$VM_NAME"; then echo "'$VM_NAME' already exists; this attaches/reconfigures it, no new VM." >&2
    else echo "This creates a VM now; billing starts immediately." >&2; fi
    read -r -p "Type 'yes' to continue: " CONFIRM
    [ "$CONFIRM" = "yes" ] || error "Cancelled."
  fi
}
