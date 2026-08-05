# Architecture & Design

Reference for the cluster's architecture, decisions, and network design.
For agent context, see [`.agents/AGENTS.md`](../.agents/AGENTS.md).

---

## Network Design

### Phase 1 — Full Mesh Cluster Fabric (current)

```
Physical cabling (3 cables, no cluster switch):

  pve01 [eth-cluster-a / USB]       ─────── [eth-cluster-a / USB]       pve02
  pve01 [eth-cluster-b / WiFi-slot] ─────── [eth-cluster-a / USB]       pve03
                          pve02 [eth-cluster-b / WiFi-slot] ─────── [eth-cluster-b / WiFi-slot] pve03

  All nodes → LAN switch via eth-mgmt (1G built-in, management + Corosync ring 0 + VMs shared)
```

#### IP Addressing

| Link | Subnet | pve01 | pve02 | pve03 |
|---|---|---|---|---|
| pve01 ↔ pve02 | 10.10.12.0/30 | .1 (eth-cluster-a) | .2 (eth-cluster-a) | — |
| pve01 ↔ pve03 | 10.10.13.0/30 | .1 (eth-cluster-b) | — | .2 (eth-cluster-a) |
| pve02 ↔ pve03 | 10.10.23.0/30 | — | .1 (eth-cluster-b) | .2 (eth-cluster-b) |

#### Routing

OSPF via frr runs on `eth-cluster-a` and `eth-cluster-b` only. Redistributes all
connected /30 routes so every node can reach every other node's cluster-fabric IPs.
`eth-mgmt` is excluded from OSPF — cluster routing stays off the management plane.

#### NIC Planes

| Stable name | Interface | Use | Connected to |
|---|---|---|---|
| `eth-mgmt` | Built-in I219-LM 1G | Management + Corosync ring 0 + VMs (POC) | LAN switch |
| `eth-cluster-a` | USB 2.5G | Cluster fabric: Ceph + Corosync ring 1 | Direct cable to peer A |
| `eth-cluster-b` | WiFi-slot 2.5G | Cluster fabric: Ceph + Corosync ring 1 | Direct cable to peer B |

Which peer each NIC connects to is recorded in `host_vars/<node>.yml → cluster_links`.

### Phase 2 — Mikrotik VLANs

Applies to `eth-mgmt` plane only (management + VM traffic separation).
Cluster interconnect links are direct cables — unaffected by switch VLAN changes.

### Phase 3 — Proxmox SDN (EVPN)

Set `pve_sdn_enabled: true`. frr switches from OSPF-only to BGP/EVPN mode.
Mikrotik acts as BGP route reflector. See [`docs/sdn-learning-path.md`](sdn-learning-path.md).

---

## Storage Design

### Interim (single SSD, `storage_profile: interim_single_ssd`)

```
/dev/sda
  partition 1  → ZFS rpool   (Proxmox OS, ~50%)
  partition 2  → Ceph OSD    (bluestore, raw, ~50%)
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
| Clustering | Corosync 3-node quorum | Ring 0 on eth-mgmt; ring 1 on cluster fabric |
| Cluster routing | OSPF (frr) | Runs on eth-cluster-a/b; self-healing |
| Shared storage | Ceph Tentacle 20.2.x | via `pveceph`; 3-replica pool |
| VM networking | vmbr0 → SDN (Phase 3) | `vm_bridge` var abstracts the name |
| Secrets | SOPS + age | `.sops.yaml` has public key; private key local-only |

---

## Key Design Principles

1. **Single source of truth**: `group_vars/all.yml` owns version pins and cluster-wide
   defaults; `host_vars/` owns per-node hardware including peer link assignments;
   `boot/matchbox/` references these through the inventory.
2. **Variable-gated phases**: VLAN, SDN, and Corosync ring features are vars, not code
   branches. Activating them doesn't require role rewrites.
3. **Storage profile abstraction**: `storage_profile` var drives all disk layout decisions in
   `pve-storage` and `pve-ceph` roles. Migration is a var change + playbook re-run.
4. **HA-safe operations**: `ha-manager arm-ha`/`disarm-ha` for all maintenance requiring
   node reboots, preventing VM downtime.
5. **Switchless cluster fabric**: 2 NICs × 3 nodes = 3 direct cables, no cluster switch
   needed. OSPF via frr provides self-healing routing between the /30 subnets.
