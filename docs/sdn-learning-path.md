# SDN Learning Path

A staged guide to understanding and enabling Proxmox SDN on this cluster.

Current state: `pve_sdn_enabled: false` — `frr` is installed but unconfigured.
This document is your roadmap to Phase 3.

---

## What is Proxmox SDN?

Proxmox VE 9.x has a built-in Software Defined Networking subsystem that manages
virtual networks (VNets) and their underlying transport (zones) through the PVE API,
web UI, or Terraform. It replaces manually configured Linux bridges with a declarative
network model.

---

## Zone Types (pick one to start)

| Zone type | Transport | Best for | Complexity |
|---|---|---|---|
| `simple` | VLAN-tagged bridge | Single-site, managed switch | Low |
| `vxlan` | VXLAN overlay (UDP) | No managed switch required | Medium |
| `evpn` | BGP EVPN + VXLAN | Full L3 routing, Mikrotik BGP peer | High |

**Recommendation for this cluster**: start with `simple` (VLAN + Mikrotik), then
graduate to `evpn` when you're comfortable with BGP concepts.

---

## Phase 3A — Simple Zone (VLAN-backed)

### Prerequisites
- Mikrotik VLAN tagging configured (Phase 2 complete)
- All nodes have `vlan_id_vm` set in group_vars

### Steps
1. In Proxmox web UI: **Datacenter → SDN → Zones → Add → Simple**
2. Create a VNet in that zone
3. Assign VMs to the VNet instead of `vmbr1`
4. Set `vm_bridge` in `group_vars/all.yml` to the new VNet name

---

## Phase 3B — EVPN Zone (BGP + VXLAN)

### Background Reading
- [RFC 7432 — BGP EVPN](https://datatracker.ietf.org/doc/html/rfc7432) (skim the concepts)
- [FRRouting EVPN docs](https://docs.frrouting.org/en/latest/evpn.html)
- [Proxmox SDN EVPN docs](https://pve.proxmox.com/wiki/Setup_Simple_Zone_With_SNAT_and_DHCP)
- [Mikrotik BGP guide](https://help.mikrotik.com/docs/display/ROS/BGP)

### Key Concepts
- **ASN**: Autonomous System Number — your cluster uses a private ASN (e.g., `65000`)
- **VTEP**: VXLAN Tunnel Endpoint — each Proxmox node acts as a VTEP
- **Route Reflector**: The Mikrotik acts as BGP route reflector, distributing MAC/IP bindings
- **VNI**: VXLAN Network Identifier — maps to a VNet

### Architecture

```
  Mikrotik (ASN 65000, Route Reflector)
       |
  eBGP/iBGP peering
       |
  ┌────┴────┐
  │         │
pve-01   pve-02   pve-03
(VTEP)   (VTEP)   (VTEP)
  │         │         │
  └─── VXLAN overlay ─┘
       (eth-vm NICs)
```

### Enabling on this cluster

1. Set `pve_sdn_enabled: true` in `group_vars/all.yml`
2. Run `ansible-playbook playbooks/02-proxmox-base.yml` — enables and configures `frr`
3. Configure BGP peering in Proxmox web UI: **Datacenter → SDN → Controllers → Add → EVPN**
4. Configure matching BGP peering on the Mikrotik

---

## Useful Commands

```bash
# Check FRR status (once enabled)
systemctl status frr
vtysh -c "show bgp summary"
vtysh -c "show evpn vni"

# Check Proxmox SDN status
pvesh get /cluster/sdn
pvesh get /nodes/<node>/network
```

---

## Terraform SDN Resources

Once Terraform is activated, VNets can be managed as code:

```hcl
resource "proxmox_virtual_environment_network_linux_vlan" "vnet_prod" {
  # See bpg/proxmox provider docs for SDN VNet resources
}
```
