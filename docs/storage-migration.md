# Storage Migration: Single SSD → NVMe + SSD

Procedure to migrate each node from `interim_single_ssd` to `target_nvme_ssd` profile.
Do one node at a time. Never migrate two nodes simultaneously (Ceph needs quorum).

---

## Prerequisites

- NVMe drive physically installed in the M910q NVMe slot
- Cluster `HEALTH_OK` before starting
- HA enabled and functional

---

## Per-Node Migration Procedure

### 1 — Drain the node

```bash
# Disable HA on this node (safe migration of HA VMs)
ansible <node> -m command -a "ha-manager disarm-ha"

# Optionally: manually migrate non-HA VMs
# qm migrate <vmid> <target-node> --online
```

Wait for all VMs to leave the node.

### 2 — Remove the Ceph OSD on this node

```bash
# On the node being migrated
ceph osd out osd.<ID>               # mark OSD out
pveceph osd destroy osd.<ID> --cleanup
```

Wait for Ceph rebalance (`ceph -s` shows HEALTH_OK or HEALTH_WARN with recovery).

### 3 — Install Proxmox OS on NVMe

Boot the node from USB/PXE with the PVE installer.
Choose the **NVMe drive** as the installation target.
Hostname and network config same as before.

### 4 — Rejoin the cluster

After install boots, run Ansible:

```bash
ansible-playbook playbooks/01-bootstrap.yml --limit <node>
ansible-playbook playbooks/02-proxmox-base.yml --limit <node>
ansible-playbook playbooks/03-network.yml --limit <node>
ansible-playbook playbooks/05-cluster-init.yml --limit <node> \
  -e cluster_action=join
```

### 5 — Update the storage profile

Edit `ansible/inventory/host_vars/<node>.yml`:

```yaml
storage_profile: "target_nvme_ssd"
os_disk: "/dev/nvme0n1"
ceph_osd_disk: "/dev/sda"      # whole SSD, no partition needed
ceph_osd_partition: "/dev/sda" # same as disk for whole-disk OSD
```

Run storage and Ceph roles:

```bash
ansible-playbook playbooks/04-storage.yml --limit <node>
ansible-playbook playbooks/07-ceph.yml --limit <node> -e ceph_action=add_osd
```

### 6 — Re-arm HA

```bash
ansible <node> -m command -a "ha-manager arm-ha"
```

### 7 — Verify

```bash
ceph -s       # HEALTH_OK, OSD count restored
pvecm status  # all nodes present
```

Repeat for next node.
