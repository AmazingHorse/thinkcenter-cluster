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

## Step 4 — Install Docker, Git, Bash & Ansible in the Boot Server VM

SSH into the VM, then install required prerequisites:

**Alpine Linux:**
```bash
# Enable community repository
echo "http://dl-cdn.alpinelinux.org/alpine/v3.24/community" >> /etc/apk/repositories

# Update package index and install packages
apk update
apk add git bash curl docker docker-cli-compose python3 py3-pip py3-yaml py3-netaddr ansible

# Start and enable Docker service
rc-update add docker boot
service docker start
```

**Debian / Ubuntu:**
```bash
sudo apt update
sudo apt install -y git bash curl docker.io docker-compose-v2 ansible
sudo usermod -aG docker $USER
```

---

## Step 5 — Mount or Clone the Repo in the VM

**Option A — Direct Clone in VM (recommended)**

```bash
git clone https://github.com/AmazingHorse/thinkcenter-cluster.git
cd thinkcenter-cluster
```

**Option B — VS Code Remote-SSH**

Install the **Remote - SSH** extension in VS Code on Windows. Connect to the VM's IP and open the folder.

---

## Step 6 — Configure Manifest, Fetch Assets & Render Boot Configs

In the boot server VM:

```bash
cd thinkcenter-cluster

# 1. Edit node MACs, IPs, & ISO SHA256 in the single source of truth
nano cluster-manifest.yml

# 2. Fetch PVE ISO and iPXE binaries (reads pve_version & sha256 from manifest)
bash boot/scripts/fetch-assets.sh

# 3. Render boot configs & matchbox groups
ansible-playbook ansible/playbooks/00-generate-boot-config.yml
```

> **Why `00-generate-boot-config.yml` instead of `site.yml` here?**
> `site.yml` includes all playbooks (00 through 07). If run before `pve01` is PXE-booted, step 00 renders the boot configs successfully, but step 01 (`01-bootstrap.yml`) will fail trying to SSH into `pve01` before it exists. Running `00-generate-boot-config.yml` directly renders the boot files cleanly. Once `pve01` is installed and online, you can run `ansible-playbook ansible/playbooks/site.yml` to execute the full site deployment.

---

## Step 7 — Start the Boot Stack

```bash
cd thinkcenter-cluster
docker compose -f boot/docker-compose.yml up -d
docker compose -f boot/docker-compose.yml logs -f dnsmasq   # watch for DHCP/boot requests
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

## Troubleshooting Hyper-V Network & "Bad Address" Issues

### 1. "ping: bad address 'google.com'" (Alpine DNS Fix)
By default, Alpine's `/etc/resolv.conf` may not receive DNS servers from Hyper-V DHCP.
```bash
# Add public / local DNS servers manually
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf
```
To make DNS persistent across Alpine reboots, configure `/etc/network/interfaces`:
```ini
auto eth0
iface eth0 inet dhcp
    dns-nameservers 1.1.1.1 8.8.8.8
```

### 2. VM Stuck on "Broadcasting Discover" (DHCP Blocked)
If Alpine is stuck on `udhcpc: broadcasting discover` during setup:

#### A. Wi-Fi Adapter Issue (Critical)
**Hyper-V External Switches do NOT work with Wi-Fi cards out-of-the-box** because IEEE 802.11 Wi-Fi frames reject multiple MAC addresses on a single wireless association.
- **If connected over Wi-Fi:** You must use **Hyper-V Internal Switch + Internet Connection Sharing (ICS)** or an Ethernet cable.

#### B. Allow Hyper-V Traffic in Windows Firewall
Run in **PowerShell as Administrator**:
```powershell
# Allow DHCP & Hyper-V switch traffic through Windows Firewall
New-NetFirewallRule -DisplayName "Hyper-V DHCP Allow" -Direction Inbound -Protocol UDP -LocalPort 67,68 -Action Allow
New-NetFirewallRule -DisplayName "Hyper-V Outbound Allow" -Direction Outbound -Action Allow
```

#### C. Enable Promiscuous Mode / MAC Spoofing
1. **Hyper-V Manager** → Right-click VM → **Settings**.
2. **Network Adapter** → **Advanced Features**.
3. Check ✅ **Enable MAC address spoofing**.
4. Click **Apply**.

### 3. Verify Switch Binding in PowerShell (Windows)
Make sure your Hyper-V switch is bound to the active physical Ethernet adapter:
```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status
Get-VMSwitch | Select-Object Name, SwitchType, NetAdapterInterfaceDescription
```

### 4. "Bindings will be disabled" Warning / Cannot Check Extensible Switch Manually
- **Do NOT manually check `Hyper-V Extensible Virtual Switch` or `Microsoft Network Adapter Multiplexor Protocol` in `ncpa.cpl` (Network Connections GUI).** Windows manages `vms_pp` dynamically. Manually checking them causes Windows to show a prompt saying they will be disabled upon clicking OK.
- **Create the Virtual Switch via Hyper-V Manager or Elevated PowerShell:**
  ```powershell
  # Run PowerShell as Administrator
  New-VMSwitch -Name "ClusterBridge" -NetAdapterName "Ethernet 2" -AllowManagementOS $true
  ```
- **Error `0x80071A90` (Transactional Conflict / Hanging at 80%):**
  If `New-VMSwitch` hangs around 80% with error `0x80071A90` (*“The function attempted to use a name that is reserved for use by another transaction”*):
  1. Disable conflicting NDIS filter drivers in Elevated PowerShell:
     ```powershell
     Disable-NetAdapterBinding -Name "Ethernet 2" -ComponentID "ms_l2bridge"
     Disable-NetAdapterBinding -Name "Ethernet 2" -ComponentID "oracle_VBoxNetLwf"
     ```
  2. **Reboot Windows:** Once an NDIS transaction conflict (`0x80071A90`) occurs, Windows Kernel Transaction Manager (KTM) locks the adapter port in kernel memory. A system reboot is **required** to purge the locked transaction.
  3. After reboot, run `New-VMSwitch` again:
     ```powershell
     New-VMSwitch -Name "ClusterBridge" -NetAdapterName "Ethernet 2" -AllowManagementOS $true
     ```

- **Alternative Workaround (Internal Switch + Windows Network Bridge):**
  If External Switch creation continues to fail on your physical NIC, use an Internal Switch bridged via Windows:
  1. Create an Internal Switch: `New-VMSwitch -Name "ClusterBridge" -SwitchType Internal`
  2. Open `ncpa.cpl`
  3. Select both `Ethernet 2` and `vEthernet (ClusterBridge)` -> Right-click -> **Bridge Connections**



