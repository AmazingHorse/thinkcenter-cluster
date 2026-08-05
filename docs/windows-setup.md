# Windows Setup Guide

Prerequisites for running the thinkcenter-cluster boot stack from a Windows workstation.

> **Why not Docker Desktop?** Docker Desktop on Windows runs containers inside a VM (Hyper-V
> or WSL2). DHCP broadcasts from that VM do not reach your physical LAN, so dnsmasq cannot
> assign IPs to PXE-booting ThinkCentres. The solution is a thin Linux VM with a bridged
> (External) virtual switch that gives containers direct L2 access.

---

## Step 1 — Enable Hyper-V

Open **PowerShell as Administrator**:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
# Reboot when prompted
```

Or via **Settings → Apps → Optional Features → More Windows features → Hyper-V**.

---

## Step 2 — Create a Hyper-V External Virtual Switch

1. Open **Hyper-V Manager** (search Start menu)
2. In the right panel click **Virtual Switch Manager**
3. Select **External** → **Create Virtual Switch**
4. **Name**: `ClusterBridge`
5. **Connection type**: External network → select your physical NIC connected to the cluster LAN
6. ✅ Check **Allow management operating system to share this network adapter**
7. Click **OK** → accept the warning about temporary network disruption

> The `Allow management OS to share` option lets your workstation keep network access through
> the same physical NIC. Without it your workstation loses connectivity.

---

## Step 3 — Create the Boot Server VM

Download a minimal Debian or Alpine Linux ISO, then:

1. **Hyper-V Manager → New → Virtual Machine**
2. **Name**: `boot-server`
3. **Generation**: 2 (UEFI)
4. **Memory**: 1024 MB (static, no dynamic memory)
5. **Network**: select `ClusterBridge`
6. **Virtual Hard Disk**: 20 GB
7. **Install from ISO**: select your Debian/Alpine ISO
8. Finish wizard → **Start** the VM → install the OS (minimal, SSH only)

After install, note the VM's IP address — it will be on the same subnet as your ThinkCentres.

---

## Step 4 — Install Docker in the Boot Server VM

SSH into the VM, then:

```bash
# Debian
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# log out and back in
```

---

## Step 5 — Mount the Repo into the VM

**Option A — VS Code Remote-SSH (recommended)**

Install the **Remote - SSH** extension in VS Code on Windows. Connect to the VM's IP.
Open the folder where you cloned `thinkcenter-cluster`. Edit files normally in VS Code on
Windows; they are saved directly on the VM's filesystem.

**Option B — Hyper-V File Share (SMB)**

In the VM:
```bash
sudo apt install samba -y
# Configure a share pointing at your repo clone directory
```

Then on Windows: `\\<vm-ip>\share` in File Explorer.

---

## Step 6 — Clone the Repo and Configure

In the boot server VM:

```bash
git clone https://github.com/YOUR_ORG/thinkcenter-cluster.git
cd thinkcenter-cluster

# Configure your node MACs and IPs
nano boot/dnsmasq/dnsmasq.conf     # set interface=, MAC leases, boot_server_ip
nano boot/matchbox/groups/pve01.json  # set real MAC
# repeat for pve02, pve03

# Fetch PVE ISO and iPXE binaries
bash boot/scripts/fetch-assets.sh
```

---

## Step 7 — Start the Boot Stack

```bash
cd thinkcenter-cluster
docker compose -f boot/docker-compose.yml up -d
docker compose -f boot/docker-compose.yml logs -f   # watch for DHCP/boot requests
```

---

## Step 8 — Run Ansible from Windows (or the VM)

Ansible requires a Linux/macOS control node. Options:

- **From the boot server VM**: install Ansible there and run playbooks via SSH
- **From WSL2** (Windows): WSL2 networking can reach the VM and cluster nodes over the physical
  NIC. Use WSL2 only for Ansible control (not for running the boot stack containers).

```bash
# In WSL2 or the VM
cd thinkcenter-cluster/ansible
pip install ansible ansible-lint
ansible-playbook playbooks/site.yml
```

---

## Moving the Boot Stack to a Linux Server

When you're ready to retire the Hyper-V VM:

1. Copy `boot/` directory to the target Linux server
2. Run `bash boot/scripts/fetch-assets.sh` on the server
3. `docker compose -f boot/docker-compose.yml up -d`

No changes to `docker-compose.yml` are needed — it uses `network_mode: host` throughout,
which works natively on Linux without any VM or bridge setup.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| ThinkCentre gets no DHCP offer | dnsmasq container not on L2 segment | Verify VM is using `ClusterBridge` switch, not `Default Switch` |
| dnsmasq won't start | Port 67 (DHCP) already in use | Disable Windows DHCP client on the shared NIC: `netsh int ip set address "ClusterBridge" static ...` |
| matchbox returns 404 | ISO not in `assets/` | Re-run `fetch-assets.sh` |
| SSH to nodes fails after install | Proxmox installed on wrong NIC | Verify `eth-mgmt` is the NIC on the cluster subnet |
