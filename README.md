# thinkcenter-cluster

Automated bring-up for a 3-node Lenovo ThinkCentre M910q Proxmox VE cluster.

PXE-boot a blank node → unattended Proxmox 9.2 install → Ansible cluster formation (Corosync + Ceph Tentacle). Fully declarative, monorepo-managed via a single root manifest (`cluster-manifest.yml`).

## Hardware

| Component | Spec |
|---|---|
| Nodes | 3× Lenovo ThinkCentre M910q (modified BIOS, Xeon CPU, power-limited) |
| NIC 1 | Built-in Intel I219-LM 1G → management + Corosync ring 0 + VMs (shared, POC) |
| NIC 2 | 2.5G USB3 adapter (`eth-cluster-a`) → direct point-to-point cluster interconnect |
| NIC 3 | 2.5G WiFi-slot NIC (`eth-cluster-b`) → direct point-to-point cluster interconnect |
| RAM | 1× 16 GB node (`pve01`), 2× 8 GB nodes (`pve02`, `pve03`) |
| Storage (interim) | Single SSD: partition 1 = ZFS (Proxmox OS), partition 2 = Ceph OSD |
| Storage (target) | NVMe (Proxmox OS) + SSD (Ceph OSD whole disk) |

## Stack

| Layer | Technology |
|---|---|
| Single Source of Truth | `cluster-manifest.yml` at repo root |
| Network boot | nginx + dnsmasq (Docker, `network_mode: host`) |
| OS install | Proxmox VE 9.2 unattended ISO + HTTP answer file |
| Configuration | Ansible (agentless, SSH) |
| Cluster fabric | Full-mesh switchless direct cables + OSPF routing via `frr` |
| Cluster | Corosync (3-node quorum) + Ceph Tentacle via `pveceph` |
| Secrets | SOPS + age keys (`ansible/secrets/vault.sops.yaml`) |
| CI | GitHub Actions + self-hosted runner |

---

## Quick Start (Step-by-Step Bring-Up)

See **[`docs/runbook.md`](docs/runbook.md)** for detailed commands and **[`docs/windows-setup.md`](docs/windows-setup.md)** for the Windows Hyper-V boot host setup.

### Step 1 — Edit Single Manifest & Secrets (Workstation)
1. **Secrets:** Generate age key (`age-keygen -o ~/.config/sops/age/keys.txt`), put public key in `.sops.yaml`.
   Create `ansible/secrets/vault.sops.yaml` (copy from `.example`) and set your root password.
2. **Manifest:** Edit **`cluster-manifest.yml`** at repo root:
   - Fill in node built-in 1G **MAC addresses** and official Proxmox ISO **SHA256 hash**.

### Step 2 — Start Boot Stack (Boot Server)
Run assets fetcher and start containerized boot server (dnsmasq + nginx):
```bash
bash boot/scripts/fetch-assets.sh
docker compose -f boot/docker-compose.yml up -d
```

### Step 3 — Bring Up Single Node (`pve01`)
1. Plug in `pve01`, enter BIOS (F1), set **Network (PXE)** as 1st boot device.
2. Power on `pve01` — it PXE boots, receives HTTP answer file, and installs Proxmox VE 9.2 unattended.
3. Once `pve01` reboots into Proxmox, run Ansible to bootstrap `pve01`:
   ```bash
   ansible-playbook ansible/playbooks/site.yml --limit pve01
   ```
   *(Note: Step 0 automatically renders all derived boot & host_vars configs natively from `cluster-manifest.yml`)*

### Step 4 — Add Nodes `pve02` & `pve03` to Cluster
1. Power on `pve02` and `pve03` to PXE boot and install unattended.
2. Once booted, run Ansible for the remaining nodes to join the cluster and initialize Ceph:
   ```bash
   ansible-playbook ansible/playbooks/site.yml
   ```

---

## Repository Layout

```
thinkcenter-cluster/
├── cluster-manifest.yml        # 🌟 SINGLE SOURCE OF TRUTH (edit MACs, IPs, hardware specs here)
├── .agents/                    # Agent design notes & scratchpad (AGENTS.md)
├── .github/workflows/          # CI workflows (lint.yml, sops-check.yml)
├── boot/                       # Boot server stack
│   ├── docker-compose.yml      # matchbox + dnsmasq containers
│   ├── dnsmasq/                # Generated dnsmasq configuration
│   ├── matchbox/               # Generated Matchbox groups & answer files
│   └── scripts/                # fetch-assets.sh (PVE ISO & iPXE downloader)
├── ansible/                    # Cluster automation
│   ├── ansible.cfg             # Ansible defaults & SSH pipelining settings
│   ├── inventory/              # Generated hosts.yml & host_vars/
│   ├── playbooks/              # 00-generate-boot-config.yml through 07-ceph.yml & site.yml
│   ├── roles/                  # pve-base, pve-network, pve-storage, pve-cluster, pve-ceph
│   └── secrets/                # vault.sops.yaml (SOPS-encrypted root password & keys)
├── terraform/                  # Workload provisioning stub (activate post-cluster)
│   ├── README.md
│   └── providers.tf.example
└── docs/                       # Detailed guides & architecture
    ├── design.md               # Network, storage, and cluster design
    ├── runbook.md              # Day-0 step-by-step operator guide
    ├── windows-setup.md        # Hyper-V External Switch boot host setup
    ├── storage-migration.md    # Single SSD → NVMe+SSD rolling migration
    ├── upgrade.md              # Rolling PVE & Ceph version upgrades
    └── sdn-learning-path.md    # Phase 3 Proxmox SDN & EVPN roadmap
```

## Network Planes (Full Mesh Switchless Cluster Fabric)

| Stable name | NIC | Use | Connected to |
|---|---|---|---|
| `eth-mgmt` | Built-in I219-LM 1G | Management + Corosync ring 0 + VMs (shared) | LAN switch |
| `eth-cluster-a` | USB 2.5G | Cluster fabric (Ceph + Corosync ring 1) | Direct cable to Peer A |
| `eth-cluster-b` | WiFi-slot 2.5G | Cluster fabric (Ceph + Corosync ring 1) | Direct cable to Peer B |

3 cables total, 0 cluster switches. OSPF via `frr` provides self-healing routing between direct `/30` subnets.

## License

MIT
