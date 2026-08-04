# thinkcenter-cluster

Automated bring-up for a 3-node Lenovo ThinkCentre M910q Proxmox VE cluster.

PXE-boot a blank node → unattended Proxmox 9.2 install → Ansible cluster formation (Corosync + Ceph Tentacle). Fully declarative, monorepo-managed.

## Hardware

| Component | Spec |
|---|---|
| Nodes | 3× Lenovo ThinkCentre M910q (modified BIOS, Xeon CPU, power-limited) |
| NIC 1 | Built-in Intel I219-LM 1G → management + Corosync |
| NIC 2 | 2.5G USB3 adapter → Ceph storage traffic |
| NIC 3 | 2.5G WiFi-slot NIC → VM bridge |
| RAM | 1× 16 GB node, 2× 8 GB nodes |
| Storage (interim) | Single SSD: partition 1 = ZFS (Proxmox OS), partition 2 = Ceph OSD |
| Storage (target) | NVMe (Proxmox OS) + SSD (Ceph OSD whole disk) |

## Stack

| Layer | Technology |
|---|---|
| Network boot | matchbox + dnsmasq (Docker, `network_mode: host`) |
| OS install | Proxmox VE 9.2 unattended ISO + HTTP answer file |
| Configuration | Ansible (agentless, SSH) |
| Cluster | Corosync (3-node quorum) + Ceph Tentacle via `pveceph` |
| Secrets | SOPS + age keys |
| CI | GitHub Actions + self-hosted runner |
| Future workloads | Terraform (stub, activate post-cluster) |
| Future networking | Proxmox SDN (VNets, EVPN) — see `docs/sdn-learning-path.md` |

## Quick Start

See **[`docs/runbook.md`](docs/runbook.md)** for the full day-0 bring-up procedure.

**Windows users**: read **[`docs/windows-setup.md`](docs/windows-setup.md)** first to configure Hyper-V for the boot stack.

```
# 1. Generate age key and configure SOPS
age-keygen -o ~/.config/sops/age/keys.txt
# Add public key to .sops.yaml

# 2. Edit inventory — add your node MACs
$EDITOR ansible/inventory/hosts.yml
$EDITOR ansible/inventory/host_vars/pve-01.yml   # repeat for pve-02, pve-03

# 3. Fetch PVE ISO (verified by sha256)
bash boot/scripts/fetch-assets.sh

# 4. Start boot server (Linux host or Hyper-V VM — see docs/windows-setup.md)
docker compose -f boot/docker-compose.yml up -d

# 5. Boot each ThinkCentre from network (PXE) — Proxmox installs unattended

# 6. Run Ansible to form cluster
ansible-playbook ansible/playbooks/site.yml
```

## Repository Layout

```
thinkcenter-cluster/
├── .agents/          # Agent design notes and scratchpad (AGENTS.md)
├── .github/          # CI workflows (lint, SOPS check)
├── boot/             # Boot server: matchbox profiles, dnsmasq, docker-compose
├── ansible/          # Playbooks, roles, inventory (host_vars per node)
├── terraform/        # Stub — activate for VM workload provisioning
└── docs/             # Runbook, Windows setup, storage migration, SDN learning path
```

## Network Planes (POC — flat L2)

| Plane | NIC | Stable name | Use |
|---|---|---|---|
| Management + Corosync | Built-in 1G | `eth-mgmt` | SSH, Proxmox API, Corosync ring 0 |
| Ceph | USB 2.5G | `eth-ceph` | Ceph OSD + monitor traffic |
| VM | WiFi-slot 2.5G | `eth-vm` | `vmbr1` VM bridge |

VLAN-ready (Mikrotik, Phase 2) → SDN-ready (EVPN, Phase 3). See `docs/design.md`.

## License

MIT
