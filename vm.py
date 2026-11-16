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
    container = content.viewManager.CreateContainerView(
        content.rootFolder, [vim.VirtualMachine], True
    )
    
    for vm in container.view:
        if vm.config and vm.config.template:
            continue

        try:
            host_name = vm.config.name
        except AttributeError:
            host_name = vm.name
            
        if not host_name:
            continue

        vm_path = get_obj_path(vm)
        moid = vm._moId

        path_parts = vm_path.split('/')
        datacenter = path_parts[1] if len(path_parts) > 1 else ""
        
        # 获取 connection state
        try:
            conn_state = str(vm.runtime.connectionState)
        except AttributeError:
            conn_state = "unknown"
            
        # 格式化 summary.vm 字符串
        summary_vm = f"'vim.VirtualMachine:{moid}'"

        # 完全匹配截图中的变量结构
        inventory["_meta"]["hostvars"][host_name] = {
            "categories": [],
            "config": {
                "name": host_name
            },
            "config.name": host_name,
            "datacenter": datacenter,
            "moid": moid,
            "name": vm.name,
            "path": vm_path,
            "runtime": {
                "connectionState": conn_state
            },
            "runtime.connectionState": conn_state,
            "summary": {
                "vm": summary_vm
            },
            "summary.vm": summary_vm,
            "tag_category": {},
            "tags": []
        }

        # 分组逻辑
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
