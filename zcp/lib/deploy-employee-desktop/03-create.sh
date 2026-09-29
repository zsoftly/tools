# A valid-JSON-but-wrong-shape response (e.g. {}) must not silently read as "empty list": .[]
# on an object yields no output too, same as a genuinely empty array - shared by every site
# below that trusts a zcp *list -o json response.
require_list_json() { jq -e '(type=="array") or (type=="null")' <<< "$1" >/dev/null 2>&1; }
instance_exists() {
  local j; j="$(zcp instance list -o json)" || error "Could not list instances."
  require_list_json "$j" || error "zcp instance list returned an unexpected response, can't tell if '$1' exists. Check manually: zcp instance list."
  jq -e --arg n "$1" '(. // [])[] | select(.name==$n)' <<< "$j" >/dev/null 2>&1
}
slug_for_name() {
  local label="$1" cmd="$2" name="$3" j m c
  j="$(eval "$cmd")" || error "Could not list ${label}s. VM is billable - clean up with: $CLEANUP_HINT"
  m="$(echo "$j" | jq --arg n "$name" '[(. // [])[] | select(.name==$n)]')"; c="$(echo "$m" | jq 'length')"
  case "$c" in
    0) error "No $label named '$name' found. VM is billable - clean up with: $CLEANUP_HINT" ;;
    1) echo "$m" | jq -r '.[0].slug' ;;
    *) error "Ambiguous: $c ${label}s named '$name'. VM is billable - clean up with: $CLEANUP_HINT" ;;
  esac
}
instance_slug_for_name() { slug_for_name "instance" "zcp instance list -o json" "$1"; }
remote() {
  local ip="$1" cmd="$2" user="${3:-ubuntu}" attempt status
  for attempt in 1 2 3; do
    set +e; ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${user}@${ip}" "$cmd"; status=$?; set -e
    [ "$status" -ne 255 ] && return "$status"
    [ "$attempt" -lt 3 ] && sleep 5
  done
  return "$status"
}
wait_for_ssh() {
  local ip="$1" timeout="$2" user="${3:-ubuntu}" start=$SECONDS
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  info "Waiting for SSH on $ip..."
  while ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${user}@${ip}" true 2>/dev/null; do
    [ $((SECONDS - start)) -ge "$timeout" ] && error "SSH on $ip not ready after ${timeout}s. VM is billable - clean up with: $CLEANUP_HINT"
    sleep 5
  done
  success "SSH ready on $ip"
}
create_or_adopt_vm() {
  step "Step 1/3: Deploy the desktop VM"
  USERDATA_FILE="$(mktemp)"; chmod 600 "$USERDATA_FILE"
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
  if ! instance_exists "$VM_NAME"; then
    if [ "$PASSWORD_PROVIDED" = "true" ]; then
      info "Creating '$VM_NAME' with the password you passed."
    else
      warn "Creating '$VM_NAME' with a generated password. SAVE THIS NOW: $DESKTOP_PASSWORD"
    fi
    zcp instance create --name "$VM_NAME" --template "$VM_TEMPLATE" --plan "$VM_PLAN" \
        --billing-cycle "$BILLING_CYCLE" --network-plan "$NETWORK_PLAN" \
        --storage-category "$STORAGE_CATEGORY" --ssh-key "$SSH_KEY" \
        --user-data-file "$USERDATA_FILE" --wait \
      || error "Could not create '$VM_NAME'. If created anyway, its password is printed above. Clean up with: $CLEANUP_HINT"
    success "'$VM_NAME' created"
  else
    VM_ALREADY_EXISTED="true"
    VM_SLUG="$(instance_slug_for_name "$VM_NAME")"
    [ "$ADOPT_EXISTING" = "true" ] \
      || error "A VM named '$VM_NAME' already exists (slug: $VM_SLUG). Not modifying it without confirmation. Check 'zcp instance get $VM_SLUG'; re-run with --adopt-existing if it's the right one."
    warn "'$VM_NAME' already exists (slug: $VM_SLUG), adopting it per --adopt-existing."
  fi
  VM_SLUG="${VM_SLUG:-$(instance_slug_for_name "$VM_NAME")}"
  local addnet_out
  if addnet_out="$(zcp instance add-network "$VM_SLUG" --network "$TIER_SLUG" 2>&1)"; then
    success "'$VM_NAME' attached to '$TIER_NAME'"
  elif echo "$addnet_out" | grep -qi already; then
    warn "Tier network already attached to '$VM_NAME'."
  else
    error "Failed to attach tier network: $addnet_out. VM is billable - clean up with: $CLEANUP_HINT"
  fi
  VM_INSTANCE_JSON="$(zcp instance get "$VM_SLUG" -o json)" || error "Could not look up '$VM_NAME'. VM is billable - clean up with: $CLEANUP_HINT"
  VM_IP="$(echo "$VM_INSTANCE_JSON" | jq -r '.[] | select(.field=="Public IP") | .value' | head -1)"
  [ -n "$VM_IP" ] && [ "$VM_IP" != "null" ] || error "Could not determine '$VM_NAME' public IP. VM is billable - clean up with: $CLEANUP_HINT"
  VM_USER="$(echo "$VM_INSTANCE_JSON" | jq -r '.[] | select(.field=="Username") | .value' | head -1)"
  [ -n "$VM_USER" ] && [ "$VM_USER" != "null" ] || VM_USER="ubuntu"
  info "Desktop VM public IP: $VM_IP"
  IP_SLUG="$(zcp ip list -o json | jq -r --arg vm "$VM_NAME" '(. // [])[] | select(.vm==$vm) | .slug' | head -1)"
  [ -n "$IP_SLUG" ] || error "Could not find the public IP slug for '$VM_NAME'. VM is billable - clean up with: $CLEANUP_HINT"
}
