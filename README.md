# test

#!/bin/bash
# PowerFlex 多 MGMT 合规报告导出 CSV（列表内置）

OUTPUT="compliance_report.csv"

# --- CSV 表头 ---
echo '"mgmt_displayname","mgmt_url","compliance","displayname","servicetag"' > "$OUTPUT"

# --- 定义 MGMT 列表 ---
MGMT_LIST='[
  {"displayname":"MGMT-A","url":"https://a.com","username":"userA","password":"passA"},
  {"displayname":"MGMT-B","url":"https://b.com","username":"userB","password":"passB"}
]'

# --- 遍历每个 MGMT ---
echo "$MGMT_LIST" | jq -c '.[]' | while read -r mgmt; do
  NAME=$(echo "$mgmt" | jq -r '.displayname')
  URL=$(echo "$mgmt" | jq -r '.url')
  USER=$(echo "$mgmt" | jq -r '.username')
  PASS=$(echo "$mgmt" | jq -r '.password')

  echo "[INFO] Processing $NAME ($URL)"

  # --- 登录 ---
  LOGIN_RESP=$(curl -k -s -X POST "${URL}/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${USER}\",\"password\":\"${PASS}\"}")

  TOKEN=$(echo "$LOGIN_RESP" | jq -r '.access_token // .token')

  if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo "[WARN] Failed to get token for $NAME, skipping..."
    continue
  fi

  # --- 获取合规报告 ---
  COMP_RESP=$(curl -k -s -X GET "${URL}/api/complianceReport" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

  # --- 写入 CSV ---
  echo "$COMP_RESP" | jq -r --arg name "$NAME" --arg url "$URL" '
    .[] | [$name, $url, .compliance, .displayname, .servicetag] | @csv
  ' >> "$OUTPUT"

done

echo "[INFO] Done! CSV saved to $OUTPUT"
