# VM HA Groups

## User Guide

This guide is for application owners. It explains why VM HA Groups exist and what you need to do. You do not log in to vSphere, tag ESXi hosts, or start a migration yourself.

## 1. Purpose

VM HA Groups keeps the virtual machines of one application on different ESXi hosts. When rack information is available, it also keeps them on ESXi hosts in different racks.

If one ESXi host fails, or an entire rack is lost, the other virtual machines in the same group keep running. The application stays available at the ESXi layer.

You do not place or move the virtual machines. You submit one ITSM form. The form data is stored in the CMDB, and a scheduled automation job reads it and places the virtual machines.

## 2. What you need to do

Fill in one ITSM form for each application that needs this protection. After you submit the ticket, ITSM writes the data into the CMDB.

On the form, provide:

| Field | What to enter |
| --- | --- |
| Application | The application name, for example `App1`. |
| Virtual machines | Every virtual machine that belongs to this application and must stay apart from the others. |

Example of the records stored in the CMDB:

| Application | Virtual machines in the HA group |
| --- | --- |
| App1 | VM11, VM12 |
| App2 | VM21, VM22 |
| AppN | VMN1, VMN2 |

A group is the set of virtual machines for one application. Those virtual machines are the ones you want to survive the loss of a single ESXi host or a single rack.

Use the virtual machine names as they appear in vSphere. A virtual machine that is left off the form is not part of the group, and the automation will not place it for this application.

A group needs at least two virtual machines. One virtual machine cannot be spread across hosts.

When you add or remove a virtual machine, submit an updated ITSM form. The next scheduled run uses the updated CMDB record.

You do not:

- Update the CMDB directly
- Tag ESXi hosts with rack information
- Choose the destination ESXi host
- Start vMotion

## 3. What happens after you submit

Placement is not immediate. A scheduled job picks up the CMDB data and corrects placement on its regular run. If a virtual machine is later moved back onto the same host or the same rack as another member of its group, a later run separates them again.

### 3.1 The form is stored in the CMDB

ITSM inserts the application and its virtual machine list into the CMDB. That record is the HA group the automation reads.

### 3.2 ESXi hosts are tagged with rack information

A separate Ansible job, run by EDC, reads rack information and tags each ESXi host with the rack it belongs to. For example:

| ESXi host | Rack |
| --- | --- |
| ESXi11 | Rack1 |
| ESXi12 | Rack1 |
| ESXi21 | Rack2 |

This step is not part of your ticket. You do not maintain these tags.

### 3.3 The placement job runs on a schedule

An Ansible playbook runs regularly and does the following:

1. **Fetch.** Read the VM HA groups from the CMDB.
2. **Filter.** Select the groups that need a placement check.
3. **Scan.** Find where each virtual machine is running, and which rack that ESXi host is in.
4. **vMotion.** If virtual machines in the same group share an ESXi host, or share a rack when another rack is available, send a vMotion request to vSphere.
5. **Confirm.** Read the virtual machine location again so the next run sees the updated placement.

vSphere completes the move. vMotion migrates a running virtual machine, so the guest stays powered on during the move, subject to the normal vMotion requirements.

## 4. Example

App1 has two virtual machines, VM11 and VM12. Before the job runs, both are on ESXi11 in Rack1.

| Virtual machine | ESXi host | Rack |
| --- | --- | --- |
| VM11 | ESXi11 | Rack1 |
| VM12 | ESXi11 | Rack1 |

The playbook sees that both members of the group are on the same host. It sends a vMotion request, and vSphere moves VM12 to an ESXi host in another rack.

| Virtual machine | ESXi host | Rack |
| --- | --- | --- |
| VM11 | R1-ESXi 11 | Rack1 |
| VM12 | R2-ESXi 21 | Rack2 |

If ESXi11 or Rack1 fails, VM12 is still running in Rack2.

## 5. What you should expect

- Virtual machines in one group are spread across ESXi hosts.
- When more than one rack is available, the job prefers hosts in different racks.
- You do not receive a task to migrate the virtual machines. vMotion does that.
- A change to the ITSM form takes effect on a later scheduled run, not at the moment you submit the ticket.
- This feature separates virtual machines across hosts and racks. It does not replace application failover, guest clustering, or backups. The application still needs to keep serving when one of its virtual machines is down.
