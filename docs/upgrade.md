# Upgrade Guide

How to bump the Proxmox VE version pin and perform a safe rolling upgrade.

---

## 1 — Update Version Pin

Edit `ansible/inventory/group_vars/all.yml`:

```yaml
pve_version: "X.Y"
pve_iso_filename: "proxmox-ve_X.Y-1.iso"
pve_iso_sha256: "<sha256 from https://www.proxmox.com/en/downloads>"
ceph_version: "<ceph-codename>"   # check Proxmox release notes for bundled Ceph version
```

---

## 2 — Fetch New ISO

```bash
bash boot/scripts/fetch-assets.sh
# Script verifies sha256 and skips download if already present
```

---

## 3 — Rolling Node Upgrade (one node at a time)

For each node, in order (workers first, primary last):

```bash
# 1. Drain HA workloads
ansible <node> -m command -a "ha-manager disarm-ha"

# 2. Upgrade packages on the node
ansible <node> -m apt -a "upgrade=dist update_cache=yes"

# 3. Reboot
ansible <node> -m reboot -a "reboot_timeout=300"

# 4. Re-arm HA
ansible <node> -m command -a "ha-manager arm-ha"

# 5. Verify cluster health before proceeding to next node
pvecm status
ceph -s
```

> **Never upgrade two nodes simultaneously.** Corosync quorum and Ceph require at least
> 2 of 3 nodes to be healthy at all times.

---

## Ceph Version Upgrades

If the PVE upgrade also bumps the Ceph major version:

```bash
# On all nodes (rolling)
pveceph install --version <new-version>
# Restart OSDs and monitors after each node
```

Consult the [Proxmox Ceph upgrade documentation](https://pve.proxmox.com/wiki/Ceph_Server)
for the specific migration path (e.g., Tentacle → next release).
