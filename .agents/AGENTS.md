# Agent Notes — thinkcenter-cluster

Read this before touching the repo. Avoids drift, saves tokens.

## Project Summary

3-node Proxmox VE 9.2 cluster on Lenovo ThinkCentre M910q mini PCs.
Automated PXE boot → unattended install → Ansible cluster formation.
Ceph Tentacle for shared storage. Corosync 3-node quorum.

## Key Design Decisions (do not re-debate without user confirmation)

| Decision | Choice | Rationale |
|---|---|---|
| PVE version | **9.2** (pinned) | Stable May 2026; `arm-ha`/`disarm-ha` maintenance mode |
| Ceph version | **Tentacle 20.2.x** | Ships with PVE 9.2, managed via `pveceph` |
| OS filesystem | ZFS single-disk | Snapshot support; ARC capped by `zfs_arc_max` |
| Storage interim | SSD partition 1 = ZFS, partition 2 = Ceph OSD | Single disk per node today |
| Storage target | NVMe (OS) + SSD (Ceph OSD whole disk) | `storage_profile` var flip to migrate |
| Network | Flat L2 on eth-mgmt (POC); VLAN-ready (Mikrotik Phase 2); SDN-ready (EVPN Phase 3) | Incremental complexity |
| Cluster fabric | Full mesh direct cables, no switch | 2 NICs × 3 nodes = 3 cables exactly |
| Cluster routing | OSPF via frr on cluster links | Self-healing; frr already installed |
| NIC naming | udev bus-path rules → `eth-mgmt`, `eth-cluster-a`, `eth-cluster-b` | Role-neutral; peer in host_vars |
| Node identity | MAC → matchbox group → Ansible host_vars | Single source of truth in inventory |
| Secrets | SOPS + age | Private key never in repo |
| Boot stack host | Hyper-V External Switch VM (Windows) / native Linux | Docker Desktop breaks L2 DHCP on Windows |
| SDN | `pve_sdn_enabled: false` flag; `frr` installed but dormant for SDN | Learning goal, Phase 3 |
| Automation split | Ansible through cluster formation; Terraform stub for VM workloads later | No Terraform until cluster is stable |

## File Ownership Map

| Path | Purpose |
|---|---|
| `cluster-manifest.yml` | **Canonical Single Source of Truth** (MAC, IPs, RAM, NIC rules) |
| `ansible/playbooks/00-generate-boot-config.yml` | Native Ansible playbook rendering boot configs from manifest |
| `ansible/inventory/hosts.yml` | Canonical inventory node list |
| `ansible/inventory/group_vars/all.yml` | PVE version pin, subnet, global defaults |
| `ansible/inventory/host_vars/pve-0N.yml` | Per-node: RAM, NIC bus paths, disk IDs, storage_profile |
| `boot/matchbox/answers/pve-0N.toml` | Per-node Proxmox answer file (hostname, disk, network) |
| `boot/matchbox/groups/pve-0N.json` | matchbox MAC → profile + answer URL mapping |
| `.sops.yaml` | SOPS age public key (operator replaces placeholder) |

## Upgrade Path Notes

- Bump `pve_version`, `pve_iso_filename`, `pve_iso_sha256`, `ceph_version` in `group_vars/all.yml`
- Re-run `boot/scripts/fetch-assets.sh` to fetch and verify new ISO
- Rolling upgrade: use `ha-manager disarm-ha` before each node, `arm-ha` after
- Storage migration (SSD → NVMe+SSD): see `docs/storage-migration.md`

## Network Planes

| Stable name | NIC | Use | Connected to |
|---|---|---|---|
| `eth-mgmt` | Built-in I219-LM 1G | Management + Corosync ring 0 + VMs (shared) | LAN switch |
| `eth-cluster-a` | USB 2.5G | Cluster fabric (Ceph + Corosync ring 1) | Direct cable to one peer node |
| `eth-cluster-b` | WiFi-slot 2.5G | Cluster fabric (Ceph + Corosync ring 1) | Direct cable to other peer node |

Full mesh: pve01↔pve02 (one cable), pve01↔pve03 (one cable), pve02↔pve03 (one cable).
IP subnets: 10.10.12.0/30, 10.10.13.0/30, 10.10.23.0/30. OSPF via frr routes between them.

USB NIC **must** be in the same physical USB port on every node (runbook enforces this).

## Known Constraints

- 8 GB RAM nodes: ZFS ARC capped at ~15% (~1.2 GB), Ceph OSD target 1 GB, Mon 512 MB
- `network_mode: host` required for dnsmasq container (DHCP broadcast needs L2 access)
- Windows boot stack: needs Hyper-V External Switch VM — Docker Desktop cannot serve DHCP to physical LAN
- PVE SDN EVPN requires `frr` in BGP/EVPN mode (frr is installed; OSPF for cluster routing is separate config)
- Ceph cluster_network is `10.10.0.0/8` — covers all three /30 subnets; OSPF makes them mutually routable
- VM bridge (`vmbr0`) shares eth-mgmt 1G with management and Corosync ring 0 during POC
- M.2 WiFi 2.5G NIC (eth-cluster-b) uses 6-inch ribbon cable: route away from CPU VRMs; use `ethtool` if link renegotiation occurs

## Scratchpad

<!-- Agents: use this section for temporary working notes during tasks -->
