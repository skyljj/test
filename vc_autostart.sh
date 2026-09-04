#!/bin/sh

# ==============================================================================
# Custom startup script: auto-detect and power on vCenter VM after cold reboot
# ==============================================================================

(
  # vCenter VM display name keyword (case-insensitive search)
  VC_NAME="vCenter"
  
  # Maximum polling attempts: 40 times; 15s interval (~10 minutes total buffer)
  MAX_RETRIES=40
  INTERVAL=15

  # Initial sleep to ensure hostd, base network drivers, and storage stack are up
  sleep 90

  # 1. Check if the current ESXi host inventory holds the vCenter VM
  VMID=$(vim-cmd vmsvc/getallvms 2>/dev/null | grep -i "$VC_NAME" | awk '{print $1}')

  # If vCenter is not registered on this host, exit immediately
  if [ -z "$VMID" ]; then
    exit 0
  fi

  # 2. vCenter is registered on this host; poll until vSAN is ready and power on
  COUNT=0
  while [ $COUNT -lt $MAX_RETRIES ]; do
    STATE=$(vim-cmd vmsvc/getvmstate $VMID 2>/dev/null)

    if echo "$STATE" | grep -qi "Powered on"; then
      # Already running, exit cleanly
      exit 0
    elif echo "$STATE" | grep -qi "Powered off"; then
      # Currently powered off; attempt power on.
      # If vSAN datastore is not yet accessible, this command fails silently and retries.
      if vim-cmd vmsvc/power.on $VMID >/dev/null 2>&1; then
        exit 0
      fi
    fi

    sleep $INTERVAL
    COUNT=$((COUNT + 1))
  done
) &

exit 0
