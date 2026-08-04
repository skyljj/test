#!/bin/bash

# ==================== 配置项 ====================
ARTIFACTORY_URL="https://your-artifactory-domain.com/artifactory"
REPOSITORY="your-repo-name"
TARGET_DIR="path/to/directory"          # 要遍历的目录
USER="your_username"                   # 用户名 / API Token
PASS="your_password_or_token"

# 日志输出文件
BLOCKED_LOG="xray_blocked_rpms.txt"
> "$BLOCKED_LOG"

FOLDER_API_URL="${ARTIFACTORY_URL}/api/storage/${REPOSITORY}/${TARGET_DIR}"
BASE_FILE_URL="${ARTIFACTORY_URL}/${REPOSITORY}/${TARGET_DIR}"

echo "=== 1. 获取目录下的 RPM 文件列表 ==="

# 递归获取所有文件路径，并过滤出 .rpm 文件
FILES=$(curl -s -u "${USER}:${PASS}" "${FOLDER_API_URL}?list&deep=1" | \
        jq -r '.files[] | select(.folder == false and (.uri | endswith(".rpm"))) | .uri')

if [ -z "$FILES" ]; then
    echo "未找到任何 RPM 文件或 API 请求失败，请检查配置。"
    exit 1
fi

TOTAL_FILES=$(echo "$FILES" | wc -l | tr -d ' ')
echo "共找到 $TOTAL_FILES 个 RPM 包，开始进行真实下载测试（数据将直接丢弃，不占磁盘）..."
echo "----------------------------------------------------"

SUCCESS_COUNT=0
BLOCKED_COUNT=0
CURRENT=0

for FILE_PATH in $FILES; do
    ((CURRENT++))
    FULL_URL="${BASE_FILE_URL}${FILE_PATH}"
    FILE_NAME=$(basename "$FILE_PATH")

    # 尝试真实下载，将内容定向到 /dev/null（不占用磁盘）
    # -w 获取 HTTP 状态码，-L 允许跟随重定向（Xray 阻断有时会重定向到 403 页面）
    HTTP_CODE=$(curl -s -L -u "${USER}:${PASS}" -o /dev/null -w "%{http_code}" "$FULL_URL")

    # 判断是否被 Xray 挡住：
    # 1. 状态码不是 200（如 403 Forbidden、500/502 等 Xray 拦截码）
    if [ "$HTTP_CODE" -eq 200 ]; then
        echo "[$CURRENT/$TOTAL_FILES] [OK 200] $FILE_NAME"
        ((SUCCESS_COUNT++))
    else
        echo "[$CURRENT/$TOTAL_FILES] [BLOCKED $HTTP_CODE] ❌ $FILE_NAME"
        echo "[$HTTP_CODE] $FULL_URL" >> "$BLOCKED_LOG"
        ((BLOCKED_COUNT++))
    fi
done

echo "----------------------------------------------------"
echo "测试完成！"
echo "- 正常可下载: ${SUCCESS_COUNT} 个"
echo "- 被 Xray/权限拦截: ${BLOCKED_COUNT} 个"

if [ "$BLOCKED_COUNT" -gt 0 ]; then
    echo "被拦截的文件明细已保存至: ${BLOCKED_LOG}"
fi
