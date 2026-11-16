#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import argparse
import ssl
import sys
import atexit
import requests
import urllib3

try:
    # 引入你截图中的包
    from pyVmomi import vim
    from pyVim.connect import SmartConnect, Disconnect
    from vmware.vapi.vsphere.client import create_vsphere_client
except ImportError:
    print(json.dumps({
        "_meta": {"hostvars": {}},
        "all": {"children": []},
        "error": "Missing required Python libraries: pyvmomi or vSphere Automation SDK"
    }))
    sys.exit(1)

def get_env_var(var_name, default=None):
    return os.environ.get(var_name, default)

def get_tags_data(host, user, password, validate_certs_bool):
    """
    使用官方 vSphere Automation SDK (vAPI) 获取所有虚拟机的 Tags
    """
    session = requests.Session()
    session.verify = validate_certs_bool
    if not validate_certs_bool:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    try:
        # 使用 SDK 创建客户端，自动处理 Token 认证
        client = create_vsphere_client(
            server=host, 
            username=user, 
            password=password, 
            session=session
        )
        
        # 1. 获取所有的 Categories
        cat_map = {}
        for cat_id in client.cis.tagging.Category.list():
            cat_obj = client.cis.tagging.Category.get(cat_id)
            cat_map[cat_id] = cat_obj.name

        # 2. 获取所有的 Tags，并映射到其所属的 Category Name
        tag_map = {}
        for tag_id in client.cis.tagging.Tag.list():
            tag_obj = client.cis.tagging.Tag.get(tag_id)
            tag_map[tag_id] = {
                "name": tag_obj.name,
                "category": cat_map.get(tag_obj.category_id, "Unknown")
            }

        # 3. 反向查询：遍历 Tag 找到所有关联的 VirtualMachine，合并生成字典
        vm_tag_map = {}
        for tag_id, tag_info in tag_map.items():
            # 获取打上了这个标签的所有对象
            attached_objs = client.cis.tagging.TagAssociation.list_attached_objects(tag_id)
            for obj in attached_objs:
                if obj.type == 'VirtualMachine':
                    moid = obj.id
                    if moid not in vm_tag_map:
                        vm_tag_map[moid] = {"tags": [], "categories": set(), "tag_category": {}}
                    
                    t_name = tag_info["name"]
                    c_name = tag_info["category"]
                    
                    vm_tag_map[moid]["tags"].append(t_name)
                    vm_tag_map[moid]["categories"].add(c_name)
                    
                    if c_name not in vm_tag_map[moid]["tag_category"]:
                        vm_tag_map[moid]["tag_category"][c_name] = []
                    vm_tag_map[moid]["tag_category"][c_name].append(t_name)
                    
        return vm_tag_map
    except Exception as e:
        # 如果获取 Tags 失败，静默返回空字典以保证主清单运行
        return {}

def get_obj_path(obj):
    path_elements = []
    current = obj
    while current.parent is not None:
        if current.name not in ['Datacenters'] and current.parent.name != '':
            path_elements.insert(0, current.name)
        current = current.parent
    return '/' + '/'.join(path_elements)

def build_inventory():
    host = get_env_var('VMWARE_HOST')
    user = get_env_var('VMWARE_USER')
    password = get_env_var('VMWARE_PASSWORD')
    validate_certs_str = get_env_var('VMWARE_VALIDATE_CERTS', 'no').lower()
    validate_certs_bool = validate_certs_str not in ['no', 'false', '0']

    inventory = {
        "_meta": {"hostvars": {}},
        "all": {"children": ["COD_Linux", "COD_Windows", "COD_OVA"]},
        "COD_Linux": {"hosts": []},
        "COD_Windows": {"hosts": []},
        "COD_OVA": {"hosts": []}
    }

    if not host or not user or not password:
        return inventory

    # --- 1. 通过 vAPI SDK 批量拉取所有 Tags 数据 (存入缓存字典) ---
    vm_tags_data = get_tags_data(host, user, password, validate_certs_bool)

    # --- 2. 通过 pyVmomi 建立 SOAP 连接拉取基础清单 ---
    context = None
    if not validate_certs_bool:
        context = ssl._create_unverified_context()

    try:
        si = SmartConnect(host=host, user=user, pwd=password, sslContext=context)
        atexit.register(Disconnect, si)
    except Exception:
        return inventory

    content = si.RetrieveContent()
    container = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)

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
        
        try:
            conn_state = str(vm.runtime.connectionState)
        except AttributeError:
            conn_state = "unknown"
            
        summary_vm = f"'vim.VirtualMachine:{moid}'"

        # 从第 1 步生成的字典中获取该虚拟机的标签，无则返回空结构
        vm_tags = vm_tags_data.get(moid, {"tags": [], "categories": set(), "tag_category": {}})

        hostvars = {
            "categories": list(vm_tags.get("categories", [])),
            "config": {"name": host_name},
            "config.name": host_name,
            "datacenter": datacenter,
            "moid": moid,
            "name": vm.name,
            "path": vm_path,
            "runtime": {"connectionState": conn_state},
            "runtime.connectionState": conn_state,
            "summary": {"vm": summary_vm},
            "summary.vm": summary_vm,
            "tag_category": vm_tags.get("tag_category", {}),
            "tags": vm_tags.get("tags", [])
        }

        # 展平 tag_category 下的所有键值，符合截图中的结构
        for cat_name, tag_list in hostvars["tag_category"].items():
            hostvars[f"tag_category.{cat_name}"] = tag_list

        inventory["_meta"]["hostvars"][host_name] = hostvars

        # 动态组划分
        if 'Linux' in vm_path:
            inventory["COD_Linux"]["hosts"].append(host_name)
        if 'Windows' in vm_path:
            inventory["COD_Windows"]["hosts"].append(host_name)
        if 'OVA' in vm_path:
            inventory["COD_OVA"]["hosts"].append(host_name)

    return inventory

def main():
    parser = argparse.ArgumentParser(description="VMware VM Dynamic Inventory with SDK Tags")
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--host')
    args = parser.parse_args()

    if args.host:
        print(json.dumps({}))
    else:
        inventory = build_inventory()
        print(json.dumps(inventory, indent=2))

if __name__ == '__main__':
    main()
