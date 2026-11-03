# ADR 0005: Alpine Hyper-V Boot Stack and Dedicated Python HTTP Answer Server

## Status
Accepted

## Context
Docker Desktop on Windows cannot bridge raw L2 DHCP broadcasts to the physical LAN due to NAT virtualization limitations. Unattended Proxmox VE 9.2 automated installations send an HTTP POST request containing MAC addresses to the answer URL (`/assets/answers/`), which a standard static Nginx file server cannot route dynamically, resulting in an HTML directory listing instead of TOML configuration.

## Decision
Host the PXE bootstack inside an Alpine Linux Hyper-V VM bound to an External Virtual Switch with a static MAC address. Replace static Nginx answer serving with a lightweight Python 3 stdlib HTTP server (`boot/server/boot_http_server.py`) that parses client MAC addresses from POST JSON payloads and serves matching `<mac>.toml` files.

## Consequences
- Reliable L2 DHCP response to ThinkCentre bare-metal PXE requests.
- Deterministic answer dispatch for PVE 9.x installer requests without heavy dependencies.
- Retains static file streaming for large boot artifacts (`linux26`, `initrd.img`, `proxmox.iso.cpio`).
