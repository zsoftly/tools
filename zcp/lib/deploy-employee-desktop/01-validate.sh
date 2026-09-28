# Sourced by deploy-employee-desktop.sh. Validates all inputs before any zcp call.
validate_inputs() {
  [[ "$SSH_WAIT_SECONDS" =~ ^[1-9][0-9]{0,6}$ ]] || error "--ssh-wait must be 1-9999999 seconds."
  [[ "$CLOUD_INIT_WAIT_SECONDS" =~ ^[1-9][0-9]{0,6}$ ]] || error "--cloud-init-wait must be 1-9999999 seconds."
  [[ "$BILLING_CYCLE" == "hourly" || "$BILLING_CYCLE" == "monthly" ]] || error "--billing-cycle must be hourly or monthly."

  [ -n "$VM_NAME" ] || error "--name is required."
  [[ "$VM_NAME" =~ ^[a-zA-Z0-9-]+$ ]] || error "--name must be letters, numbers, and hyphens only."

  [ -n "$DESKTOP_USERNAME" ] || error "--username is required."
  [[ "$DESKTOP_USERNAME" =~ ^[a-z][a-z0-9_]*$ ]] \
    || error "--username must match ^[a-z][a-z0-9_]*\$ (the template rejects anything else at first boot)."
  [ "${#DESKTOP_USERNAME}" -le 32 ] || error "--username too long (${#DESKTOP_USERNAME} chars; useradd's limit is 32)."

  # Every name here is a real account confirmed present on the ubuntukde image (getent
  # passwd, UID<1000), not a guess. 'ubuntu' is also this script's own SSH admin user.
  local reserved=(ubuntu nobody root daemon bin sys sync games man lp mail news uucp proxy \
    www-data backup list irc gnats syslog messagebus landscape xrdp sddm sshd polkitd \
    dhcpcd uuidd tss pollinate tcpdump usbmux rtkit avahi geoclue dnsmasq) r
  for r in "${reserved[@]}"; do
    [ "$DESKTOP_USERNAME" != "$r" ] \
      || error "--username '$DESKTOP_USERNAME' collides with an existing account on the image, rejected here before anything is created. Choose a different username."
  done

  if [ "$PASSWORD_PROVIDED" = "true" ] \
      && ! [[ "$DESKTOP_PASSWORD" =~ ^[A-Za-z0-9\!#%+,./:=?@^_-]{8,}$ ]]; then
    error "--password must be 8+ chars using only letters, digits, and !#%+,./:=?@^_- (sourced as a shell env file on the VM)."
  fi
}
