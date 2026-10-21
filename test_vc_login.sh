#!/bin/bash
# 保存为 vc_login_test.sh 并执行：bash vc_login_test.sh

VC_IP="10.133.8.4"  # 你的 vCenter IP 或 FQDN
USER="virt_auto_prod@cod.ms.com.cn"
PASS="YOUR_PASSWORD"

echo "开始循环测试 vCenter API 登录..."
for i in {1..100}; do
    echo -n "第 $i 次尝试 - 耗时/状态码: "
    
    # 向 vCenter 发起 SSO 登录请求，提取 HTTP 状态码和总耗时
    curl -k -s -u "$USER:$PASS" -X POST "https://$VC_IP/api/session" \
         -o /dev/null -w "耗时: %{time_total}s | HTTP状态码: %{http_code}\n"
    
    sleep 1 # 每次间隔 1 秒
done


#!/bin/bash
# 保存为 ldap_login_test.sh 并执行：bash ldap_login_test.sh

LDAP_SERVER="10.18.41.100" # 指定特定域控 IP，可以换成 10.18.41.101 对比测试
USER="virt_auto_prod@cod.ms.com.cn"
PASS="YOUR_PASSWORD"

echo "开始循环测试 AD LDAP 认证..."
for i in {1..100}; do
    echo -n "第 $i 次尝试: "
    
    # 使用 ldapwhoami 验证凭据 (-x 简单认证, -w 密码)
    ldapwhoami -H ldaps://$LDAP_SERVER:636 -x -D "$USER" -w "$PASS" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "\033[32m成功 (Success)\033[0m"
    else
        echo -e "\033[31m失败 (Failed - 可能是密码错或网络超时)\033[0m"
    fi
    
    sleep 1
done
