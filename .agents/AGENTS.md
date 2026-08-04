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
| Network | Flat L2 POC; VLAN-ready (Mikrotik Phase 2); SDN-ready (EVPN Phase 3) | Incremental complexity |
| NIC naming | udev bus-path rules → `eth-mgmt`, `eth-ceph`, `eth-vm` | No MAC lookup, stable across reboots |
| Node identity | MAC → matchbox group → Ansible host_vars | Single source of truth in inventory |
| Secrets | SOPS + age | Private key never in repo |
| Boot stack host | Hyper-V External Switch VM (Windows) / native Linux | Docker Desktop breaks L2 DHCP on Windows |
| SDN | `pve_sdn_enabled: false` flag; `frr` installed but dormant | Learning goal, Phase 3 |
| Automation split | Ansible through cluster formation; Terraform stub for VM workloads later | No Terraform until cluster is stable |

## File Ownership Map

| Path | Purpose |
|---|---|
| `ansible/inventory/hosts.yml` | Canonical node list (MAC → hostname → group) |
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

| Stable name | NIC | Use | Bridge |
|---|---|---|---|
| `eth-mgmt` | Built-in I219-LM 1G | Management + Corosync ring 0 | `vmbr0` |
| `eth-ceph` | USB3 2.5G | Ceph OSD + monitor | (no bridge, raw) |
| `eth-vm` | WiFi-slot 2.5G | VM traffic | `vmbr1` |

USB NIC **must** be in the same physical USB port on every node (runbook enforces this).

## Known Constraints

- 8 GB RAM nodes: ZFS ARC capped at ~15% (~1.2 GB), Ceph OSD target 1 GB, Mon 512 MB
- `network_mode: host` required for dnsmasq container (DHCP broadcast needs L2 access)
- Windows boot stack: needs Hyper-V External Switch VM — Docker Desktop cannot serve DHCP to physical LAN
- PVE SDN EVPN requires `frr` package (installed, unconfigured until `pve_sdn_enabled: true`)

## Scratchpad

<!-- Agents: use this section for temporary working notes during tasks -->
