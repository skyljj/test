#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import argparse
import ssl
import sys
import atexit

try:
    from pyVim.connect import SmartConnect, Disconnect
    from pyVmomi import vim
except ImportError:
    print(json.dumps({
        "_meta": {"hostvars": {}},
        "all": {"children": []},
        "error": "Missing required Python library: pyvmomi"
    }))
    sys.exit(1)

def get_env_var(var_name, default=None):
    return os.environ.get(var_name, default)

def connect_vcenter():
    host = get_env_var('VMWARE_HOST')
    user = get_env_var('VMWARE_USER')
    password = get_env_var('VMWARE_PASSWORD')
    validate_certs = get_env_var('VMWARE_VALIDATE_CERTS', 'no').lower()

    if not host or not user or not password:
        return None

    context = None
    if validate_certs in ['no', 'false', '0']:
        context = ssl._create_unverified_context()

    try:
        si = SmartConnect(host=host, user=user, pwd=password, sslContext=context)
        atexit.register(Disconnect, si)
        return si
    except Exception as e:
        return None

def build_inventory(si):
    # 基础的 Ansible 动态清单结构
    inventory = {
        "_meta": {
            "hostvars": {}
        },
        "all": {
            "children": []
        }
    }

    if not si:
        return inventory

    content = si.RetrieveContent()
    container = content.viewManager.CreateContainerView(
        content.rootFolder, [vim.HostSystem], True
    )
    
    # 遍历所有 ESXi 主机
    for host in container.view:
        host_name = host.name
        
        # 获取 yaml 中的 properties
        try:
            # 相当于 yaml 中的 config.product.fullName
            product_full_name = host.config.product.fullName
        except AttributeError:
            product_full_name = "Unknown"
            
        try:
            # 相当于 yaml 中的 config.vsanHostConfig.enabled
            vsan_enabled = host.config.vsanHostConfig.enabled
        except AttributeError:
            vsan_enabled = False

        # --- 实现 compose 逻辑 ---
        # storage_type: config.vsanHostConfig.enabled | ternary('vsan', 'hci')
        storage_type = 'vsan' if vsan_enabled else 'hci'
        current_version = product_full_name
        
        # 填充主机的 hostvars
        inventory["_meta"]["hostvars"][host_name] = {
            "current_version": current_version,
            "storage_type": storage_type,
            "ansible_user": "root",
            "ansible_connection": "ssh",
            "ansible_python_interpreter": "/bin/python",
            # 如果需要，可以将原始获取的属性也放进去备用
            "name": host_name,
            "config": {
                "product": {"fullName": product_full_name},
                "vsanHostConfig": {"enabled": vsan_enabled}
            }
        }

        # --- 实现 keyed_groups 逻辑 ---
        # prefix: ESXi, key: storage_type (即产生 ESXi_vsan 或 ESXi_hci 组)
        group_name = f"ESXi_{storage_type}"
        
        if group_name not in inventory:
            inventory[group_name] = {"hosts": []}
            inventory["all"]["children"].append(group_name)
            
        inventory[group_name]["hosts"].append(host_name)

    return inventory

def main():
    parser = argparse.ArgumentParser(description="VMware Host Dynamic Inventory")
    parser.add_argument('--list', action='store_true', help='List all inventory')
    parser.add_argument('--host', help='List specific host variables')
    args = parser.parse_args()

    # 读取环境变量或执行
    if args.host:
        # 如果提供了 _meta/hostvars，--host 可以直接返回空字典，Ansible 会自动从 meta 中读取
        print(json.dumps({}))
    else:
        si = connect_vcenter()
        inventory = build_inventory(si)
        print(json.dumps(inventory, indent=2))

if __name__ == '__main__':
    main()
