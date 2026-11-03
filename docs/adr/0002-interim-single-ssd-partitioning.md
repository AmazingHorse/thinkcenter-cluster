# ADR 0002: Interim Single-SSD Partitioning with OS HDSize Cap

## Status
Accepted

## Context
The cluster nodes currently have a single 1 TB SATA SSD installed. The target architecture is NVMe (OS) + dedicated SSD (Ceph OSD whole disk). During this interim phase, both Proxmox OS and Ceph OSD must coexist on the single drive. If the installer claims 100% of the disk, zero capacity remains for the OSD.

## Decision
Cap the Proxmox OS installation disk size to 64 GiB via `zfs.hdsize = 64` (or `lvm.hdsize = 64`) in the automated answer file. For ZFS installations, reserve partition 4 (`parted -- mkpart ceph-osd 64GiB 100%`) for Ceph OSD, leaving partitions 1–3 for BIOS boot, EFI ESP, and `rpool`.

## Consequences
- Preserves ~860 GiB unpartitioned disk space for Ceph OSD on each 1 TB SSD.
- Seamless migration path to NVMe + SSD target architecture via `storage_profile` variable toggle.
- Avoids installer disk collisions between ZFS pools and Ceph bluestore.
