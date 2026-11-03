# ADR 0004: Stable NIC Naming via udev PCI Bus-Path Rules

## Status
Accepted

## Context
Kernel network interface enumeration (`eth0`, `enp1s0`, `enx...`) fluctuates based on probe timing and USB device attachment order. If interface names change between reboots or kernel upgrades, cluster storage links and management connectivity drop.

## Decision
Generate declarative systemd/udev link rules based on physical PCI bus paths and USB topology to bind interfaces to fixed role names:
- `eth-mgmt`: Built-in Intel I219-LM 1G NIC (LAN switch connection)
- `eth-cluster-a`: USB 2.5G NIC (direct link to first cluster peer)
- `eth-cluster-b`: M.2 PCIe 2.5G NIC (direct link to second cluster peer)

## Consequences
- USB NIC must remain plugged into the identical physical USB port across all nodes.
- Interface names are role-neutral and deterministic across installer boots and post-install operation.
- Network configurations (`/etc/network/interfaces`) reference predictable interface aliases.
