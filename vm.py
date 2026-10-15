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

def get_obj_path(obj):
    """
    向上遍历对象获取完整的 inventory 路径。
    模拟 yaml 插件中的 with_path 功能。
    """
    path_elements = []
    current = obj
    while current.parent is not None:
        # 跳过隐藏的根节点和基础文件夹（如 datacenters）以匹配标准路径格式
        if current.name not in ['Datacenters'] and current.parent.name != '':
            path_elements.insert(0, current.name)
        current = current.parent
    return '/' + '/'.join(path_elements)

def build_inventory(si):
    inventory = {
        "_meta": {
            "hostvars": {}
        },
        "all": {
            "children": ["COD_Linux", "COD_Windows", "COD_OVA"]
        },
        "COD_Linux": {"hosts": []},
        "COD_Windows": {"hosts": []},
        "COD_OVA": {"hosts": []}
    }

    if not si:
        return inventory

    content = si.RetrieveContent()
    # 查找所有的虚拟机
    container = content.viewManager.CreateContainerView(
        content.rootFolder, [vim.VirtualMachine], True
    )
    
    for vm in container.view:
        # 忽略模板，如果你想包含模板可以去掉这个判断
        if vm.config and vm.config.template:
            continue

        # hostnames: config.name (截图第17行)
        try:
            host_name = vm.config.name
        except AttributeError:
            host_name = vm.name
            
        if not host_name:
            continue

        # 获取路径 (模拟 with_path: yes)
        vm_path = get_obj_path(vm)

        # 提取 moid (模拟 moid: summary.vm | trim | split | last)
        # 在 pyvmomi 中，vm 的 moid 直接就是 vm._moId
        moid = vm._moId

        # 提取 datacenter (模拟 datacenter: path.split('/')[1])
        path_parts = vm_path.split('/')
        datacenter = path_parts[1] if len(path_parts) > 1 else ""

        # 填充主机的 hostvars
        inventory["_meta"]["hostvars"][host_name] = {
            "name": vm.name,
            "config": {"name": host_name},
            "path": vm_path,
            "moid": moid,
            "datacenter": datacenter
        }

        # --- 实现 groups 逻辑 (截图 21-24 行) ---
        if 'Linux' in vm_path:
            inventory["COD_Linux"]["hosts"].append(host_name)
        if 'Windows' in vm_path:
            inventory["COD_Windows"]["hosts"].append(host_name)
        if 'OVA' in vm_path:
            inventory["COD_OVA"]["hosts"].append(host_name)

    return inventory

def main():
    parser = argparse.ArgumentParser(description="VMware VM Dynamic Inventory")
    parser.add_argument('--list', action='store_true', help='List all inventory')
    parser.add_argument('--host', help='List specific host variables')
    args = parser.parse_args()

    if args.host:
        print(json.dumps({}))
    else:
        si = connect_vcenter()
        inventory = build_inventory(si)
        print(json.dumps(inventory, indent=2))

if __name__ == '__main__':
    main()
