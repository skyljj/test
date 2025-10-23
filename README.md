# test

#!/bin/bash
# PowerFlex 4.6+ API login + fetch non-compliant resources
# Requires: curl, jq

MGMT="https://<MGMT>"      # 🔧 Replace with PowerFlex Manager address
USER="<USER>"              # 🔧 Replace with your username
PASS="<PASS>"              # 🔧 Replace with your password

# --- Step 1: Login and get token ---
echo "[INFO] Logging in to PowerFlex..."
LOGIN_RESP=$(curl -k -s -X POST "${MGMT}/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${USER}\",\"password\":\"${PASS}\"}")

# Extract token (supports .access_token or .token)
TOKEN=$(echo "$LOGIN_RESP" | jq -r '.access_token // .token')

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
  echo "[ERROR] Failed to get token. Response:"
  echo "$LOGIN_RESP"
  exit 1
fi
echo "[INFO] Got token: ${TOKEN:0:20}..."

# --- Step 2: Query compliance report ---
echo "[INFO] Fetching compliance report..."
COMP_RESP=$(curl -k -s -X GET "${MGMT}/api/complianceReport" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json")

# Save full JSON (optional)
echo "$COMP_RESP" > compliance_full.json

# --- Step 3: Filter non-compliant resources ---
echo "[INFO] Non-compliant resources:"
echo "$COMP_RESP" | jq -r '
  (["compliance","displayname","servicetag"]),
  (.[] | [.compliance, .displayname, .servicetag])
  | @csv
' > "$OUTPUT"
