# Architecture & Design

Reference for the cluster's architecture, decisions, and network design.
For agent context, see [`.agents/AGENTS.md`](../.agents/AGENTS.md).

---

## Network Design

### Phase 1 — Flat L2 POC (current)

```
192.168.50.0/24 — single flat subnet

Workstation / Boot Server VM (192.168.50.1)
  ├── matchbox :8080  — PXE profiles + answer files
  └── dnsmasq  :67    — DHCP static leases + TFTP

pve-01 (192.168.50.10)
pve-02 (192.168.50.11)
pve-03 (192.168.50.12)

Per node:
  eth-mgmt  (1G built-in)     → management + Corosync ring 0  → vmbr0
  eth-ceph  (2.5G USB)        → Ceph storage traffic           → (no bridge, raw)
  eth-vm    (2.5G WiFi-slot)  → VM bridge                      → vmbr1
```

### Phase 2 — Mikrotik VLANs

Set `vlan_id_*` vars in `group_vars/all.yml`. No role rewrites needed.

### Phase 3 — Proxmox SDN (EVPN)

Set `pve_sdn_enabled: true`. See [`docs/sdn-learning-path.md`](sdn-learning-path.md).

---

## Storage Design

### Interim (single SSD, `storage_profile: interim_single_ssd`)

```
/dev/sda
  partition 1  → ZFS rpool   (Proxmox OS)
  partition 2  → Ceph OSD    (bluestore, raw)
```

### Target (NVMe + SSD, `storage_profile: target_nvme_ssd`)

```
/dev/nvme0n1  → ZFS rpool   (Proxmox OS)
/dev/sda      → Ceph OSD    (bluestore, whole disk)
```

Migration: see [`docs/storage-migration.md`](storage-migration.md).

---

## Cluster Stack

| Layer | Technology | Notes |
|---|---|---|
| Hypervisor | Proxmox VE 9.2 | Pinned; upgrade path in `docs/upgrade.md` |
| Clustering | Corosync 3-node quorum | Ring 0 on eth-mgmt; ring 1 var ready |
| Shared storage | Ceph Tentacle 20.2.x | via `pveceph`; 3-replica pool |
| VM networking | Linux bridge → SDN (Phase 3) | `vm_bridge` var abstracts the name |
| Secrets | SOPS + age | `.sops.yaml` has public key; private key local-only |

---

## Key Design Principles

1. **Single source of truth**: `group_vars/all.yml` owns version pins; `host_vars/` owns
   per-node hardware config; `boot/matchbox/` references these through the inventory.
2. **Variable-gated phases**: VLAN and SDN features are vars (`vlan_id_*`, `pve_sdn_enabled`),
   not code branches. Activating them doesn't require role rewrites.
3. **Storage profile abstraction**: `storage_profile` var drives all disk layout decisions in
   `pve-storage` and `pve-ceph` roles. Migration is a var change + playbook re-run.
4. **HA-safe operations**: `ha-manager arm-ha`/`disarm-ha` is used for all maintenance that
   requires node reboots, preventing VM downtime.
