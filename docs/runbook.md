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

> [!WARNING]
> **M.2 WiFi 6-Inch Ribbon Cable Routing:**
> The M.2 A+E key 2.5G Ethernet adapters use a 6-inch flat flex ribbon cable to reach the rear breakout slot.
> - **Strain Relief:** Ensure the ribbon has a gentle S-bend; avoid sharp 90-degree creases.
> - **EMI Protection:** Keep the ribbon cable routed away from the CPU VRMs and power inductors to prevent packet drop / link flapping under heavy load.
> - **PCIe Link Speed:** If experiencing link renegotiation, force 2.5G speed via `ethtool -s eth-cluster-b speed 2500 duplex full autoneg off`.
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

## 4 — Start Boot Server (`just standup`)

In your boot server host / Hyper-V VM:

```bash
# Idempotently fetch assets, render boot configs from manifest, and start stack
just standup

# Check live logs
just logs
```

*(Alternatively, run manually: `bash boot/scripts/fetch-assets.sh` → `ansible-playbook ansible/playbooks/00-generate-boot-config.yml` → `docker compose -f boot/docker-compose.yml up -d`)*

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

## 8 — Discovering & Verifying udev Bus Paths (M910q Port Map)

Every physical USB port on the Lenovo ThinkCentre M910q corresponds to a fixed hardware bus path (`ID_PATH`).

### M910q Physical USB & NIC Port Map

```text
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ REAR PANEL                                                                  │
  │   [DP2]  [USB SS]  [DP1]  [USB SS]  [USB SS]  [USB SS (Top-Right)]          │
  │                                                      (usb-0:1.3)            │
  │                                                 [Built-in 1G RJ45 (Bot-Right)]│
  │                                                 (pci-0000:00:1f.6)          │
  └─────────────────────────────────────────────────────────────────────────────┘
```

### Standard M910q Bus Paths (Pre-configured in `cluster-manifest.yml`)

| Interface | Physical Port | Standard `ID_PATH` Match Value |
|---|---|---|
| `eth-mgmt` | Built-in 1G RJ45 | `pci-0000:00:1f.6` |
| `eth-cluster-a` | Rear Top-Left USB (Port 3) | `usb-0:1.3:1.0` (or `pci-0000:00:14.0-usb-0:3:1.0`) |
| `eth-cluster-b` | M.2 WiFi Slot 2.5G NIC | `pci-0000:01:00.0` |

> [!NOTE]
> **Why Rear Top-Left USB (Port 3) Specifically?**
> 1. **Direct xHCI Root Hub Channel:** Port 3 links directly to standard USB 3.0 Root Hub Port 3 on Intel's 200 Series chipset (`00:14.0-usb-0:3`), avoiding internal USB hub daisy-chaining or sharing bandwidth with front-panel headers.
> 2. **Physical Cable Management:** The rear top port sits directly above the video output ports, keeping heavy 2.5G Ethernet cables neatly bundled alongside video/power cables without blocking access to adjacent USB ports.
> 3. **Thermal Clearance:** Rear placement keeps 2.5G USB NIC heat sinks out of the front intake airflow path.

### Verifying Bus Paths on a Live Node

Boot any Linux live environment or Proxmox install shell, plug the USB NIC into **Rear Port 3**, and run:

```bash
# Print bus path for all network interfaces
for iface in $(ls /sys/class/net/ | grep -v lo); do
  echo "=== Interface: $iface ==="
  udevadm info /sys/class/net/$iface | grep -E "ID_PATH="
done
```

Update `cluster-manifest.yml` under `udev_rules` with the exact `ID_PATH` if your kernel formats the string slightly differently (e.g. `pci-0000:00:14.0-usb-0:3:1.0`).

---

## 9 — Monitoring & Stress Testing M.2 / USB Link Stability Under Load

Use these commands to detect EMI interference, CRC frame errors, or link flapping on `eth-cluster-b` (M.2 ribbon) or `eth-cluster-a` (USB):

### 1. Check for Hardware Packet Errors & CRC Drops
```bash
# Check interface counter errors (CRC errors indicate EMI / poor ribbon signal)
ethtool -S eth-cluster-b | grep -E "error|crc|drop|miss|reset"
ip -s link show eth-cluster-b
```
*If `rx_crc_errors` or `rx_frame_errors` rise during load tests, the ribbon cable needs EMI shielding or re-routing.*

### 2. Check for Link Flapping in Kernel Logs
```bash
dmesg -wT | grep -E "eth-cluster|Link is Down|Link is Up|carrier"
```

### 3. Check OSPF Neighbor & Routing Health (frr)
```bash
# Verify OSPF neighbors on cluster links are FULL
vtysh -c "show ip ospf neighbor"
vtysh -c "show ip route ospf"
```

### 4. Stress Test the Fabric Under Load
Run an `iperf3` bandwidth test across `eth-cluster-b` while stressing CPU/VRMs:
```bash
# On pve02 (Server):
iperf3 -s

# On pve01 (Client — push 2.5G traffic for 60 seconds):
iperf3 -c 10.10.12.2 -t 60 -i 5
```
Watch `dmesg` or `ethtool -S eth-cluster-b` in a separate terminal during the test.

