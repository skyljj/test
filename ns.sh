#!/bin/bash

# 检查当前是否登录了 oc
if ! oc whoami &>/dev/null; then
    echo "错误: 请先使用 oc login 登录您的 OpenShift 集群！"
    exit 1
fi

# 检查文件是否存在
NS_FILE="ns.txt"
if [ ! -f "$NS_FILE" ]; then
    echo "错误: 未找到 $NS_FILE 文件，请确保该文件在当前目录下。"
    exit 1
fi

echo "开始读取 $NS_FILE 并执行批量删除..."
echo "------------------------------------------------"

# 计数器
count=0

# 循环读取文件，tr -d '\r' 用于移除可能存在的 Windows 换行符
while IFS= read -r project || [ -n "$project" ]; do
    # 过滤掉空行和以 # 开头的注释行
    [[ -z "$project" || "$project" =~ ^# ]] && continue
    
    # 去除两端可能存在的空格
    project=$(echo "$project" | xargs)
    
    echo "[Progress] 正在处理 Project: $project"
    
    # 删除 Project
    # 提示：添加 --wait=false 可以让删除操作在后台异步进行，不用死等集群完全释放资源，极大地加速脚本执行
    echo "  -> 正在删除 project..."
    oc delete project "$project" --wait=false
    
    # 删除对应的 ClusterRoleBinding
    echo "  -> 正在删除 clusterrolebinding..."
    oc delete clusterrolebinding "${project}-cluster-reader"
    
    echo "------------------------------------------------"
    ((count++))
done < <(tr -d '\r' < "$NS_FILE")

echo "完成！共处理了 $count 个项目。"
echo "提示：由于使用了 --wait=false，OpenShift 后台可能仍在回收资源，你可以通过 'oc get project' 观察终结状态 (Terminating)。"
