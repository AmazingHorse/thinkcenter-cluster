# Day-0 Runbook — thinkcenter-cluster

Complete bring-up procedure from zero to a working 3-node Proxmox + Ceph cluster.

**Windows users**: complete [`docs/windows-setup.md`](windows-setup.md) before starting here.

---

## Prerequisites

| Tool | Where |
|---|---|
| `age` + `age-keygen` | https://github.com/FiloSottile/age/releases |
| `sops` | https://github.com/getsops/sops/releases |
| `ansible` ≥ 2.17 | `pip install ansible` |
| `docker` + `docker compose` | In boot server VM (Linux) |
| `git` | On your workstation |

---

## 1 — Physical Cabling & Setup

1. **Direct Cluster Cables (Full Mesh)**:
   - `pve01` [USB / eth-cluster-a] ─── direct cable ─── `pve02` [USB / eth-cluster-a]
   - `pve01` [WiFi / eth-cluster-b] ── direct cable ─── `pve03` [USB / eth-cluster-a]
   - `pve02` [WiFi / eth-cluster-b] ── direct cable ─── `pve03` [WiFi / eth-cluster-b]
2. **Management LAN**: Plug each node's built-in 1G port (`eth-mgmt`) into your LAN switch.
3. **Power off** all ThinkCentre nodes.

---

## 2 — Secrets Setup (SOPS + age)

```bash
# Generate age key (once on your workstation)
age-keygen -o ~/.config/sops/age/keys.txt

# Add public key to .sops.yaml
nano .sops.yaml

# Create secrets file from template and set your root password
cp ansible/secrets/vault.sops.yaml.example ansible/secrets/vault.sops.yaml
nano ansible/secrets/vault.sops.yaml

# Encrypt the secrets file
sops --encrypt --in-place ansible/secrets/vault.sops.yaml
```

---

## 3 — Single Source of Truth Configuration

Edit **`cluster-manifest.yml`** in the root of the repository:
- `mac`: Set MAC addresses of built-in 1G NICs for each node.
- `pve_iso_sha256`: Set official ISO SHA256 checksum from Proxmox download portal.
- `udev_rules`: Set USB bus paths if using custom physical ports (see Section 8).

---

## 4 — Start Boot Server

In your boot server host / Hyper-V VM:

```bash
# Download PVE ISO and iPXE binaries (verifies sha256 from cluster-manifest.yml)
bash boot/scripts/fetch-assets.sh

# Start matchbox + dnsmasq
docker compose -f boot/docker-compose.yml up -d
docker compose -f boot/docker-compose.yml logs -f
```

---

## 5 — Bring Up Single Node (`pve01`)

1. Power on `pve01`, enter BIOS (F1), set **Network (PXE)** first in boot order.
2. Save & reboot — `pve01` PXE boots, receives HTTP answer file, installs Proxmox VE 9.2 unattended, and reboots.
3. Once `pve01` boots into Proxmox, bootstrap `pve01` with Ansible:
   ```bash
   cd ansible
   ansible-playbook playbooks/site.yml --limit pve01
   ```
   *(Note: Step 0 natively renders all boot server configs and `host_vars` directly from `cluster-manifest.yml`)*

---

## 6 — Add Additional Nodes (`pve02` & `pve03`)

1. Power on `pve02` and `pve03` to PXE boot and auto-install Proxmox.
2. Once booted into Proxmox, run Ansible to join the nodes to the cluster and initialize Ceph storage:
   ```bash
   ansible-playbook playbooks/site.yml
   ```

---

## 7 — Verify Cluster Health

```bash
# SSH into any node
pvecm status                # Should show 3 nodes, quorate
ceph -s                     # Should show HEALTH_OK, 3 OSDs
```

Proxmox Web UI: `https://192.168.50.10:8006`

---

## 8 — Discovering udev Bus Paths

Boot a live Linux environment on a node to verify USB/PCI bus paths if needed:

```bash
for iface in $(ls /sys/class/net/ | grep -v lo); do
  echo "=== $iface ==="
  udevadm info /sys/class/net/$iface | grep -E "ID_PATH|ID_BUS|SUBSYSTEM"
done
```
Enter these `ID_PATH` strings into `cluster-manifest.yml` under `udev_rules`.
