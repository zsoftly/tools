JQ_PORT_MATCH='def port_has($target): (. // "" | tostring) as $p | ($p == ($target|tostring)) or (($p | test("^[0-9]+-[0-9]+$")) and (($p / "-") as $r | ($r[0]|tonumber) <= $target and $target <= ($r[1]|tonumber))); def proto_is($target): (. // "" | ascii_downcase) == $target;'
scoped_rule_exists() { zcp firewall list --ip "$1" -o json | jq -e --arg c "$MY_IP" "$JQ_PORT_MATCH"' .[] | select((.protocol|proto_is("tcp")) and (.ports|port_has(22)) and .cidr==$c)' >/dev/null 2>&1; }
open_rule_ids() {
  local j; j="$(zcp firewall list --ip "$1" -o json)" && require_list_json "$j" || return 1
  jq -r "$JQ_PORT_MATCH"' .[] | select(((.protocol|proto_is("tcp")) or (.protocol|proto_is("udp"))) and (.ports|port_has(22)) and .cidr=="0.0.0.0/0") | .id' <<< "$j"
}
delete_rule() { zcp firewall delete "$1" --ip "$2" --yes || error "Could not delete rule '$1'. VM is billable - clean up with: $CLEANUP_HINT"; }
lock_down_ssh() {
  local ip_slug="$1" label="$2" confirmed attempt id ids
  scoped_rule_exists "$ip_slug" \
    || zcp firewall create --ip "$ip_slug" --protocol tcp --start-port 22 --end-port 22 --cidr "$MY_IP" \
    || error "Could not create the scoped SSH rule for $MY_IP on '$label'. VM is billable - clean up with: $CLEANUP_HINT"
  for attempt in 1 2 3; do scoped_rule_exists "$ip_slug" && { confirmed="true"; break; }; sleep 3; done
  [ "$confirmed" = "true" ] || error "Could not confirm the scoped SSH rule on '$label'. VM is billable - clean up with: $CLEANUP_HINT"
  ids="$(zcp firewall list --ip "$ip_slug" -o json | jq -r --arg c "$MY_IP" \
    "$JQ_PORT_MATCH"' .[] | select((.protocol|proto_is("tcp")) and (.ports|port_has(22)) and .cidr!="0.0.0.0/0" and .cidr!=$c) | .id')"
  if [ -n "$ids" ]; then
    warn "Removing SSH rule(s) on '$label' scoped to a different IP than today's."
    while read -r id; do [ -n "$id" ] && delete_rule "$id" "$ip_slug"; done <<< "$ids"
  fi
  confirmed="false"
  for attempt in 1 2 3; do
    if ids="$(open_rule_ids "$ip_slug")"; then
      [ -n "$ids" ] && while read -r id; do [ -n "$id" ] && delete_rule "$id" "$ip_slug"; done <<< "$ids"
      [ -z "$ids" ] && { confirmed="true"; break; }
    fi
    sleep 3
  done
  [ "$confirmed" = "true" ] || error "Lockdown failed: 0.0.0.0/0 still exposes port 22 for '$label' (or the query to check kept failing). VM is billable - clean up with: $CLEANUP_HINT"
  confirmed="false"
  for attempt in 1 2 3; do scoped_rule_exists "$ip_slug" && { confirmed="true"; break; }; sleep 3; done
  [ "$confirmed" = "true" ] || error "Lockdown failed: scoped rule for '$label' gone after cleanup. VM is billable - clean up with: $CLEANUP_HINT"
}
ip_to_int() { local IFS=. o1 o2 o3 o4; read -r o1 o2 o3 o4 <<< "$1"; echo $(( (o1<<24)+(o2<<16)+(o3<<8)+o4 )); }
setup_tier_nic() {
  step "Step 2/3: Bring up the tier network interface"
  local mask net_int ip_int start=$SECONDS
  TIER_NIC="$(remote "$VM_IP" "ip -br link show | awk '{print \$1}' | grep -v '^lo\$' | grep -v '^enp' | grep -v '^tailscale' | tail -1" "$VM_USER" || true)"
  [ -n "$TIER_NIC" ] || error "Could not identify the tier NIC on '$VM_NAME'. VM is billable - clean up with: $CLEANUP_HINT"
  remote "$VM_IP" "sudo tee /etc/netplan/60-tier-nic.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${TIER_NIC}:
      dhcp4: true
EOF" "$VM_USER" || error "Could not write netplan on '$VM_NAME'. VM is billable - clean up with: $CLEANUP_HINT"
  remote "$VM_IP" "sudo netplan apply" "$VM_USER" || error "Could not apply netplan on '$VM_NAME'. VM is billable - clean up with: $CLEANUP_HINT"
  info "Waiting for '$TIER_NIC' to get its tier address..."
  VM_TIER_IP=""
  while true; do
    VM_TIER_IP="$(remote "$VM_IP" "ip -4 -br addr show ${TIER_NIC} | awk '{print \$3}' | cut -d/ -f1" "$VM_USER" || true)"
    [ -n "$VM_TIER_IP" ] && break
    [ $((SECONDS - start)) -ge "$TIER_NIC_WAIT_SECONDS" ] \
      && error "Tier NIC '$TIER_NIC' did not get an address within ${TIER_NIC_WAIT_SECONDS}s. VM is billable - clean up with: $CLEANUP_HINT"
    sleep 5
  done
  mask=$(( "${TIER_CIDR##*/}" == 0 ? 0 : (0xFFFFFFFF << (32 - "${TIER_CIDR##*/}")) & 0xFFFFFFFF ))
  net_int="$(ip_to_int "${TIER_CIDR%%/*}")"; ip_int="$(ip_to_int "$VM_TIER_IP")"
  [ $(( ip_int & mask )) -eq $(( net_int & mask )) ] \
    || error "Interface '$TIER_NIC' came up with $VM_TIER_IP, not on the tier ($TIER_CIDR). VM is billable - clean up with: $CLEANUP_HINT"
  success "Tier NIC ($TIER_NIC) up at $VM_TIER_IP"
}
wait_for_cloud_init_user() {
  step "Step 3/3: Confirm the cloud-init user exists"
  local start=$SECONDS uid
  info "Waiting for cloud-init to finish provisioning '$DESKTOP_USERNAME'..."
  while true; do
    uid="$(remote "$VM_IP" "if [ -f /var/lib/zmi/ubuntukde-first-boot.done ] && systemctl is-active --quiet xrdp; then id -u $DESKTOP_USERNAME 2>/dev/null; fi" "$VM_USER" || true)"
    [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] \
      && { success "Cloud-init user '$DESKTOP_USERNAME' confirmed (uid $uid), first-boot complete, xrdp active"; return 0; }
    [ $((SECONDS - start)) -ge "$CLOUD_INIT_WAIT_SECONDS" ] \
      && error "Cloud-init user '$DESKTOP_USERNAME' not ready after ${CLOUD_INIT_WAIT_SECONDS}s. Check: ssh ${VM_USER}@$VM_IP 'sudo journalctl -u ubuntukde-first-boot'. If the account exists and just needs a password reset: ssh ${VM_USER}@$VM_IP 'sudo passwd $DESKTOP_USERNAME'. To start over: $CLEANUP_HINT"
    sleep 10
  done
}
print_summary() {
  step "Done"
  local pw_summary
  if [ "$VM_ALREADY_EXISTED" = "true" ]; then
    [ "$PASSWORD_PROVIDED" = "true" ] \
      && pw_summary="  RDP password : (NOT the value you just passed -- cloud-init never re-ran on this existing VM)" \
      || pw_summary="  RDP password : (unchanged -- set at first boot, not recoverable here)"
  else
    pw_summary="  RDP password : $DESKTOP_PASSWORD"
  fi
  cat <<EOF

Employee desktop deployed:

  Desktop VM   : $VM_NAME -> tier IP ${VM_TIER_IP}
                  SSH: ssh ${VM_USER}@${VM_IP} (admin access only, scoped to $MY_IP)
  RDP login    : $DESKTOP_USERNAME
$pw_summary

  RDP address  : ${VM_TIER_IP}   <-- connect here, NEVER the public IP ($VM_IP) above.

Notes:
  - First RDP login may show a PolicyKit prompt; enter $DESKTOP_USERNAME's own password.
  - This template's xrdp has no H.264 support; run video calls locally and screen-share.
  - If mounting shared storage on this desktop, see the tutorial's identity/UID section
    before the employee's first login.

Inspect: zcp instance list / zcp ip list

Clean up (billing runs hourly while this exists):
  bash <(curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/zcp/destroy-employee-desktop.sh) \\
    --name $VM_NAME --region $ZCP_REGION --project $ZCP_PROJECT
EOF
}
