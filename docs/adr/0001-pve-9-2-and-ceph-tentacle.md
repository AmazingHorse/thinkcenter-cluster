# ADR 0001: PVE 9.2 and Ceph Tentacle Pinned Versions

## Status
Accepted

## Context
The cluster is built on 3× Lenovo ThinkCentre M910q mini PCs with power-limited 6-core Intel Xeon CPUs (16 GB, 8 GB, 8 GB RAM). We require a stable, enterprise-grade hypervisor and hyperconverged storage engine with predictable operational tooling and long-term support.

## Decision
Pin Proxmox Virtual Environment (PVE) to version **9.2** and Ceph to **Tentacle 20.2.x**, managed natively via `pveceph`. Maintenance operations use `ha-manager disarm-ha` and `arm-ha`.

## Consequences
- Upstream stability through May 2026.
- Upgrades follow pinned `group_vars/all.yml` version bumps and rolling node maintenance.
- Repositories target Debian Trixie rather than Bookworm.
