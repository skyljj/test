#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import argparse
import ssl
import sys
import atexit
import urllib.request
import base64

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

# ================= REST API 客户端 (用于读取 Tags) =================
def vapi_request(host, path, method="GET", data=None, headers=None, validate_certs=False):
    url = f"https://{host}{path}"
    ctx = ssl.create_default_context()
    if not validate_certs:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    req_headers = headers or {}
    req_data = json.dumps(data).encode('utf-8') if data else None

    req = urllib.request.Request(url, data=req_data, headers=req_headers, method=method)
    if data:
        req.add_header('Content-Type', 'application/json')

    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            res_body = resp.read().decode('utf-8')
            return json.loads(res_body) if res_body else {}
    except Exception:
        # 如果 REST API 失败，静默返回以保证主清单正常输出
        return None

def fetch_all_tags(host, user, password, validate_certs_bool, vm_moids):
    """通过 REST API 批量获取虚拟机标签"""
    if not vm_moids:
        return {}

    auth_str = f"{user}:{password}"
    b64_auth = base64.b64encode(auth_str.encode('utf-8')).decode('utf-8')
    auth_headers = {"Authorization": f"Basic {b64_auth}"}

    # 1. 登录 REST API 获取 Session
    session_resp = vapi_request(host, "/rest/com/vmware/cis/session", "POST", headers=auth_headers, validate_certs=validate_certs_bool)
    if not session_resp or 'value' not in session_resp:
        return {}
    api_headers = {"vmware-api-session-id": session_resp['value']}

    try:
        # 2. 获取所有 Categories
        cat_map = {}
        cats_resp = vapi_request(host, "/rest/com/vmware/cis/tagging/category", "GET", headers=api_headers, validate_certs=validate_certs_bool)
        if cats_resp and 'value' in cats_resp:
            for cid in cats_resp['value']:
                c_resp = vapi_request(host, f"/rest/com/vmware/cis/tagging/category/id:{cid}", "GET", headers=api_headers, validate_certs=validate_certs_bool)
                if c_resp and 'value' in c_resp:
                    cat_map[cid] = c_resp['value'].get('name')

        # 3. 获取所有 Tags 详情
        tag_map = {}
        tags_resp = vapi_request(host, "/rest/com/vmware/cis/tagging/tag", "GET", headers=api_headers, validate_certs=validate_certs_bool)
        if tags_resp and 'value' in tags_resp:
            for tid in tags_resp['value']:
                t_resp = vapi_request(host, f"/rest/com/vmware/cis/tagging/tag/id:{tid}", "GET", headers=api_headers, validate_certs=validate_certs_bool)
                if t_resp and 'value' in t_resp:
                    t_val = t_resp['value']
                    tag_map[tid] = {
                        "name": t_val.get('name'),
                        "category_name": cat_map.get(t_val.get('category_id'), "Unknown")
                    }

        # 4. 批量查询虚拟机关联的 Tags
        vm_tag_results = {moid: {"tags": [], "categories": [], "tag_category": {}} for moid in vm_moids}
        chunk_size = 1000
        for i in range(0, len(vm_moids), chunk_size):
            chunk = vm_moids[i:i+chunk_size]
            obj_ids = [{"id": m, "type": "VirtualMachine"} for m in chunk]
            assoc_resp = vapi_request(host, "/rest/com/vmware/cis/tagging/tag-association?~action=list-attached-tags-on-objects", "POST", data={"object_ids": obj_ids}, headers=api_headers, validate_certs=validate_certs_bool)
            
            if assoc_resp and 'value' in assoc_resp:
                for item in assoc_resp['value']:
                    m_id = item.get('object_id', {}).get('id')
                    attached_tids = item.get('tag_ids', [])
                    
                    tags = []
                    categories = set()
                    tag_category = {}

                    for tid in attached_tids:
                        if tid in tag_map:
                            t_name = tag_map[tid]["name"]
                            c_name = tag_map[tid]["category_name"]
                            tags.append(t_name)
                            categories.add(c_name)
                            if c_name not in tag_category:
                                tag_category[c_name] = []
                            tag_category[c_name].append(t_name)

                    if m_id in vm_tag_results:
                        vm_tag_results[m_id]["tags"] = tags
                        vm_tag_results[m_id]["categories"] = list(categories)
                        vm_tag_results[m_id]["tag_category"] = tag_category
        return vm_tag_results
    finally:
        # 注销 Session
        vapi_request(host, "/rest/com/vmware/cis/session", "DELETE", headers=api_headers, validate_certs=validate_certs_bool)

# ================= SOAP API (基础清单信息) =================
def connect_vcenter(host, user, password, validate_certs_bool):
    context = ssl._create_unverified_context() if not validate_certs_bool else None
    try:
        si = SmartConnect(host=host, user=user, pwd=password, sslContext=context)
        atexit.register(Disconnect, si)
        return si
    except Exception:
        return None

def get_obj_path(obj):
    path_elements = []
    current = obj
    while current.parent is not None:
        if current.name not in ['Datacenters'] and current.parent.name != '':
            path_elements.insert(0, current.name)
        current = current.parent
    return '/' + '/'.join(path_elements)

def build_inventory(si, host, user, password, validate_certs_bool):
    inventory = {
        "_meta": {"hostvars": {}},
        "all": {"children": ["COD_Linux", "COD_Windows", "COD_OVA"]},
        "COD_Linux": {"hosts": []},
        "COD_Windows": {"hosts": []},
        "COD_OVA": {"hosts": []}
    }
    if not si:
        return inventory

    content = si.RetrieveContent()
    container = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)
    
    valid_vms = []
    vm_moids = []
    for vm in container.view:
        if vm.config and vm.config.template:
            continue
        try:
            host_name = vm.config.name
        except AttributeError:
            host_name = vm.name
        if not host_name:
            continue
        valid_vms.append((vm, host_name))
        vm_moids.append(vm._moId)

    # 批量拉取所有虚拟机的 Tags 数据
    tags_data = fetch_all_tags(host, user, password, validate_certs_bool, vm_moids)

    for vm, host_name in valid_vms:
        vm_path = get_obj_path(vm)
        moid = vm._moId
        path_parts = vm_path.split('/')
        datacenter = path_parts[1] if len(path_parts) > 1 else ""
        
        try:
            conn_state = str(vm.runtime.connectionState)
        except AttributeError:
            conn_state = "unknown"
            
        summary_vm = f"'vim.VirtualMachine:{moid}'"

        # 获取该虚拟机的标签数据，如果没有则为空
        vm_tags = tags_data.get(moid, {"tags": [], "categories": [], "tag_category": {}})

        # 组合基础变量 (复刻截图结构)
        hostvars = {
            "categories": vm_tags["categories"],
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
            "tag_category": vm_tags["tag_category"],
            "tags": vm_tags["tags"]
        }

        # 展平 tag_category.xxx，如截图中的 "tag_category.EONID": ["320897"]
        for cat_name, tag_list in vm_tags["tag_category"].items():
            hostvars[f"tag_category.{cat_name}"] = tag_list

        inventory["_meta"]["hostvars"][host_name] = hostvars

        # 动态分组
        if 'Linux' in vm_path:
            inventory["COD_Linux"]["hosts"].append(host_name)
        if 'Windows' in vm_path:
            inventory["COD_Windows"]["hosts"].append(host_name)
        if 'OVA' in vm_path:
            inventory["COD_OVA"]["hosts"].append(host_name)

    return inventory

def main():
    parser = argparse.ArgumentParser(description="VMware VM Dynamic Inventory with Tags")
    parser.add_argument('--list', action='store_true', help='List all inventory')
    parser.add_argument('--host', help='List specific host variables')
    args = parser.parse_args()

    if args.host:
        print(json.dumps({}))
    else:
        host = get_env_var('VMWARE_HOST')
        user = get_env_var('VMWARE_USER')
        password = get_env_var('VMWARE_PASSWORD')
        validate_certs_bool = get_env_var('VMWARE_VALIDATE_CERTS', 'no').lower() not in ['no', 'false', '0']

        si = connect_vcenter(host, user, password, validate_certs_bool)
        inventory = build_inventory(si, host, user, password, validate_certs_bool)
        print(json.dumps(inventory, indent=2))

if __name__ == '__main__':
    main()
