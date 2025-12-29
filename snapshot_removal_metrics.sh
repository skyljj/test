#!/usr/bin/env bash
set -euo pipefail

#####################################
# CONFIG
#####################################
VC="vc01"
LOG_FILE="/var/log/ansible/snapshot-removal-vc01.log"
OUT_DIR="/var/lib/node_exporter/textfile_collector"
OUT_FILE="${OUT_DIR}/snapshot_removal_${VC}.prom"

TMP_FILE="$(mktemp)"
UTC_NOW=$(date -u +%s)

#####################################
# INIT
#####################################
> "$TMP_FILE"

#####################################
# 1. no host matches
#####################################
if grep -qiE "no hosts matched|No hosts matched" "$LOG_FILE"; then
  echo "snapshot_removal{vc=\"$VC\"} 0" >> "$TMP_FILE"
else
  echo "snapshot_removal{vc=\"$VC\"} 1" >> "$TMP_FILE"
fi

#####################################
# 2. Parse PLAY RECAP for failed VMs
#####################################
grep -E '^[^[:space:]]+ *:.*failed=[1-9]' "$LOG_FILE" | while read -r line; do
  # 提取 VM 名称（冒号前）
  VM=$(echo "$line" | awk -F':' '{print $1}' | xargs)

  # 提取 failed 数
  FAILED=$(echo "$line" | sed -n 's/.*failed=\([0-9]\+\).*/\1/p')

  if [[ "$FAILED" -ge 1 ]]; then
    echo "snapshot_removal_vm{vc=\"$VC\",vm=\"$VM\"} 0" >> "$TMP_FILE"
  fi
done

#####################################
# 3. Execution time
#####################################
echo "snapshot_removal_collection_time{vc=\"$VC\"} $UTC_NOW" >> "$TMP_FILE"

#####################################
# Atomic replace
#####################################
mv "$TMP_FILE" "$OUT_FILE"
