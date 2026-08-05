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

## 1 — Physical Setup

1. **USB NICs**: plug each node's 2.5G USB NIC into the **same USB port on every node**
   (e.g., the rear-top USB port). This keeps the udev bus path consistent.
2. **Connect all nodes** to the same switch/LAN as your boot server.
3. **Power off** all ThinkCentre nodes.

---

## 2 — SOPS / age Key Setup

```bash
# Generate your age key (once, on your workstation)
age-keygen -o ~/.config/sops/age/keys.txt
# Output: Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Add the public key to .sops.yaml
sed -i 's/age1REPLACE_WITH_YOUR_PUBLIC_KEY/age1<YOUR_PUBLIC_KEY>/' .sops.yaml

# Generate all dependent boot and Ansible configuration files natively:

ansible-playbook ansible/playbooks/00-generate-boot-config.yml --connection=local

# Create and encrypt your secrets file
cp ansible/secrets/vault.sops.yaml.example ansible/secrets/vault.sops.yaml
# Edit the file with real values
nano ansible/secrets/vault.sops.yaml
# Encrypt it
sops --encrypt --in-place ansible/secrets/vault.sops.yaml
```

---

## 3 — Configure Inventory

Edit `ansible/inventory/hosts.yml` — the IPs should already match `dnsmasq.conf`.

For each node, edit `ansible/inventory/host_vars/pve-0N.yml`:
- `node_mac`: the MAC of the **built-in 1G NIC** (used for PXE identity)
- `os_disk`: verify the disk device (usually `/dev/sda`)
- `udev_rules[*].match_value`: see [Discovering udev Bus Paths](#discovering-udev-bus-paths) below

---

## 4 — Configure Boot Server

Edit `boot/dnsmasq/dnsmasq.conf`:
- `interface=`: set to the VM/host NIC on the cluster network
- `dhcp-host=` lines: replace `AA:BB:CC:DD:EE:0N` with real node MACs

Edit `boot/matchbox/groups/pve-0N.json`: replace `AA:BB:CC:DD:EE:0N` with real node MACs.

Edit `boot/matchbox/answers/pve-0N.toml`:
- `fqdn`: correct hostname
- `root_password`: this will be replaced by SOPS value at Ansible time, but set a temp one for install

---

## 5 — Fetch Assets

In the boot server VM:

```bash
# Update the sha256 first (from https://www.proxmox.com/en/downloads)
nano boot/scripts/fetch-assets.sh   # update PVE_SHA256

bash boot/scripts/fetch-assets.sh
```

---

## 6 — Start Boot Stack

```bash
docker compose -f boot/docker-compose.yml up -d
docker compose -f boot/docker-compose.yml logs -f
```

You should see dnsmasq start and matchbox listening on :8080.

---

## 7 — Boot Each ThinkCentre (PXE)

1. Power on node, enter BIOS/UEFI (F1 on M910q)
2. Set boot order: **Network (PXE)** first
3. Save and reboot — the node should PXE boot, receive a DHCP lease, and start the Proxmox installer
4. Installation is fully unattended — watch `docker compose logs -f` for the request
5. Node reboots into Proxmox when done (~10 minutes)

Repeat for all three nodes.

---

## 8 — Run Ansible

```bash
cd ansible

# Test connectivity
ansible proxmox_nodes -m ping

# Full cluster bring-up
ansible-playbook playbooks/site.yml
```

Or run individual phases:

```bash
ansible-playbook playbooks/01-bootstrap.yml
ansible-playbook playbooks/02-proxmox-base.yml
ansible-playbook playbooks/03-network.yml
ansible-playbook playbooks/04-storage.yml
ansible-playbook playbooks/05-cluster-init.yml
ansible-playbook playbooks/06-corosync.yml
ansible-playbook playbooks/07-ceph.yml
```

---

## 9 — Verify

```bash
# On any node
pvecm status                # should show 3 nodes, quorate
ceph -s                     # should show HEALTH_OK, 3 OSDs
```

Open Proxmox web UI: `https://192.168.50.10:8006`

---

## Discovering udev Bus Paths

Boot a Proxmox live environment or any Linux live USB on a node, then:

```bash
# For each NIC, find its ID_PATH
for iface in $(ls /sys/class/net/ | grep -v lo); do
  echo "=== $iface ==="
  udevadm info /sys/class/net/$iface | grep -E "ID_PATH|ID_BUS|SUBSYSTEM"
done
```

Record the `ID_PATH` values for:
- The USB NIC (look for `usb-0:...` in the path)
- The WiFi-slot NIC (look for `pci-0000:01:...`)
- The built-in NIC (look for `pci-0000:00:1f.6` — fixed on M910q)

Enter these into `host_vars/pve-0N.yml` under `udev_rules[*].match_value`.

---

## HA-Safe Node Maintenance

To safely reboot a node without disrupting HA VMs:

```bash
# Before rebooting pve-02
ansible pve-02 -m command -a "ha-manager disarm-ha"
# Migrate VMs manually or wait for HA to migrate them
reboot pve-02

# After pve-02 comes back up
ansible pve-02 -m command -a "ha-manager arm-ha"
```

Or use the playbook:

```bash
ansible-playbook playbooks/05-cluster-init.yml \
  -e cluster_action=disarm_ha --limit pve-02
```
