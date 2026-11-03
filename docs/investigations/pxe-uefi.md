# Investigation: PXE Netboot, UEFI Quirks, and Automated Installer Failures

## Overview
This document consolidates the debugging findings, firmware quirks, and installer mechanics discovered during bring-up of the automated PXE boot stack for the 3× Lenovo ThinkCentre M910q cluster.

---

## Historical Timeline and Resolved Issues

### 1. iPXE Magic Header Rejection
- **Symptom:** Netboot clients received TFTP `ipxe.efi` but aborted with syntax errors when executing `autoexec.ipxe`.
- **Root Cause:** Script began with `#!/ipxe`. The iPXE parser mandates exactly `#!ipxe` (no leading slash).
- **Resolution:** Updated `autoexec.ipxe.j2` to start with `#!ipxe`.

### 2. Hyper-V DHCP IP Drift
- **Symptom:** Boot server IP address changed across VM reboots, breaking dnsmasq and TFTP next-server targets.
- **Root Cause:** Dynamic MAC address assignment on the Hyper-V virtual network adapter.
- **Resolution:** Configured a Static MAC address in Hyper-V Advanced Features for the boot VM adapter.

### 3. dnsmasq Quoting Bug
- **Symptom:** iPXE HTTP boot chains failed; dnsmasq tried to serve HTTP URLs over TFTP.
- **Root Cause:** Quoting the URL in `dhcp-boot=tag:ipxe,"http://..."` caused dnsmasq to treat the string as a TFTP filename.
- **Resolution:** Unquoted URL in dnsmasq configuration: `dhcp-boot=tag:ipxe,http://...`.

### 4. DHCP Race Condition on Flat Home LAN
- **Symptom:** dnsmasq answered DHCP requests from non-cluster devices (smartphones, IoT devices) on the home 192.168.50.0/24 LAN.
- **Root Cause:** `dhcp-range` specified a dynamic pool (`192.168.50.100,192.168.50.199,12h`), racing against the primary router (`192.168.50.1`).
- **Resolution:** Configured `dhcp-range=192.168.50.0,static,255.255.255.0,12h` with `dhcp-ignore=tag:!known`. Dnsmasq answers only explicitly mapped MAC addresses from `cluster-manifest.yml`.

### 5. Nginx Directory Index vs. TOML Answer Dispatch
- **Symptom:** Proxmox auto-installer failed during fetch-answer phase with parse errors.
- **Root Cause:** `prepare-pxe` sets answer URL to `http://<ip>:8080/assets/answers/`. When `proxmox-fetch-answer` runs, it sends an `HTTP POST` with JSON (`{"mac_addresses": [...]}`). Nginx rewrote POST to GET on `/assets/answers/`, returning an HTML directory listing (`autoindex on`) rather than the target TOML answer.
- **Resolution:** Replaced static Nginx with `boot/server/boot_http_server.py`, which parses JSON POST bodies to identify client MAC addresses and serves the corresponding `<mac>.toml` file.

### 6. TOML Answer Syntax and Schema Violations
- **Symptom:** Installer crashed parsing answer file even when retrieved.
- **Root Cause:** `proxmox-answer.toml.j2` output unquoted strings (`keyboard = en-us`, `disk_list = /dev/sda`, `source = from-dhcp`), used invalid enum `zfs.raid = single` instead of `"raid0"`, omitted `zfs.hdsize` (consuming full 1 TB disk and leaving zero room for Ceph OSD), and used camelCase `rootPassword` instead of kebab-case `root-password`.
- **Resolution:** Rebuilt template conforming strictly to Proxmox VE 9.2 schema with quoted string literals, device list array `["sda"]`, and `zfs.hdsize = 64`.

### 7. UEFI PXE Kernel Panic and CPIO Alignment
- **Symptom:** Kernel panic during boot: `unable to mount root on unknown block(0,0)`.
- **Root Cause:**
  1. Concatenating a 1.6 GB uncompressed ISO onto a zstd-compressed `initrd.img` required UEFI firmware to allocate an enormous single contiguous memory buffer that exceeded firmware limits.
  2. Passing raw ISOs via multiple `initrd` statements fails under UEFI: iPXE synthesizes CPIO headers only in BIOS mode; the Linux EFI stub silently drops non-CPIO initrds lacking the `070701` magic bytes.
- **Resolution:**
  - Recompress `initrd.img` to gzip format.
  - Strip `/boot` from the installer ISO to save memory.
  - Wrap `proxmox.iso` in a standalone `newc` CPIO archive (`proxmox.iso.cpio`).
  - Instruct iPXE to load both initrds with explicit EFI virtual filenames: `kernel ... initrd=initrd.img initrd=proxmox.iso.cpio` with `initrd --name initrd.img ...` and `initrd --name proxmox.iso.cpio ...`.
