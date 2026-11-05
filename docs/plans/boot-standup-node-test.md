# Boot Server Standup and First Node Test

Use this after both specs (ADR 0007 and ADR 0008 phases 1–4) have merged. Live
steps need explicit authorization and run through `fnox exec --`.

## Before you start
- [ ] `just check` is green on main, and the GHCR images exist for the tag in `boot.image_tag`.
- [ ] Bitwarden: `PROXMOX_ROOT_PASSWORD` rotated to a long random value; `PROXMOX_SSH_PUBLIC_KEY` set; `SSH_HOST_CA_KEY` stored after `just ssh-ca-init`, with its public line committed to `ansible/ssh/known_hosts`.
- [ ] Router: no DHCP reservations required (addresses are static via the answer files). Confirm the manifest node IPs are outside the router's DHCP pool.
- [ ] Node firmware: UEFI network boot enabled, Secure Boot state matches `docs/investigations/pxe-uefi.md`.

## Standup (Tier 0, Hyper-V)
1. On Windows: `packer init` / `packer validate` / `packer build boot/packer`, then `New-BootVM.ps1` on the External switch bound to the wired NIC.
2. In the VM: clone the repo, `fnox exec -- just boot-up target=hyperv`.
3. Check: `boot-http` and `boot-dnsmasq` healthchecks are healthy; `curl http://<boot-ip>:8080/assets/` lists the ISO/cpio; dnsmasq log shows `proxy` mode.
4. Check from another LAN client that normal router DHCP still works (no rogue leases).

## Node test (one M910q)
1. PXE-boot the node. Watch the dnsmasq log for a PXE proxy offer, and the TFTP/iPXE chain.
2. The installer POSTs to `/assets/answers/` and the boot-http log shows the MAC matched to its node.
3. The install completes and the node comes up on its manifest IP.
4. The first-boot hook POSTs the host key, and `GET /hostkeys/` shows it.
5. `fnox exec -- just sign-hostkeys`, then `ansible <node> -m ping` succeeds with host-key checking on.

## If proxy mode fails
- Symptom: no PXE offer, or firmware ignores the proxy reply. Set `boot.dhcp_mode: authoritative`, re-render, `just boot-down`/`boot-up`, retest.
- Record the firmware behaviour and the result in ADR 0007. Change its status to accepted or amended.
