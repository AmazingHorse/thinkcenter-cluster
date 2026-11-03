# Project Profile — thinkcenter-cluster

3-node Proxmox VE 9.2 + Ceph Tentacle cluster on Lenovo ThinkCentre M910q mini PCs with Intel Xeon CPUs.

## File Ownership Map

| Path | Purpose |
|---|---|
| `cluster-manifest.yml` | **Canonical Single Source of Truth** (MACs, IPs, RAM, NIC rules, power profile) |
| `ansible/playbooks/00-generate-boot-config.yml` | Native Ansible playbook rendering boot configs and host_vars from manifest |
| `ansible/inventory/hosts.yml` | Canonical inventory node list and group associations |
| `ansible/inventory/group_vars/all.yml` | PVE version pin, subnet, and global defaults |
| `ansible/inventory/group_vars/proxmox_nodes.yml` | Low-power Xeon tuning, Ceph memory targets, and HA toggles |
| `ansible/inventory/host_vars/pve-0N.yml` | Generated per-node vars: RAM, NIC bus paths, disk IDs, storage profile |
| `boot/server/boot_http_server.py` | Python 3 HTTP answer & asset server dispatching TOML answers by client MAC |
| `boot/prepare-pxe/prepare-pxe-entrypoint.sh` | Extracts vmlinuz/initrd and packages proxmox.iso.cpio |
| `boot/scripts/fetch-assets.sh` | Downloads upstream PVE ISO and orchestrates asset preparation |
| `boot/docker-compose.yml` | Container definitions for boot HTTP server and dnsmasq DHCP/TFTP |
| `fnox.toml` | Secret references mapped to Bitwarden vault via fnox |

## Network Planes

| Stable Name | NIC Interface | Role | Connected To |
|---|---|---|---|
| `eth-mgmt` (enslaved to `vmbr0`) | Built-in Intel I219-LM 1G | Management + Corosync Ring 0 + VM Bridge | Physical LAN Switch |
| `eth-cluster-a` | USB 2.5G | Cluster Fabric (Ceph + Corosync Ring 1) | Direct cable to Node A |
| `eth-cluster-b` | M.2 PCIe 2.5G | Cluster Fabric (Ceph + Corosync Ring 1) | Direct cable to Node B |

Routing on cluster direct links is handled dynamically by FRRouting (OSPF) across `/30` subnets.

## Agent Execution Boundaries

- **Never run live cluster mutators:** Do not execute `just up`, `just standup`, `just bootstrap`, or `just site` directly.
- **Offline testing only:** All verification must run via `just check`, `just test`, or `tests/run-mock-suite.sh`.
- **Secrets:** Do not execute commands requiring interactive Bitwarden unlock; use mock environments for offline testing.
