# ADR 0007: Portable Boot Stack, proxyDHCP, and Two-Tier Hosting

Status: proposed (proxyDHCP pending node testing)

## Context

The boot stack (ADR 0005) runs a bind-mounted `boot_http_server.py` and an
unpinned `strm/dnsmasq:latest` in a manually built Hyper-V Alpine VM. dnsmasq
acts as an authoritative DHCP server with static leases. The stack can't be
rebuilt from the repo, can't move to another host, and would conflict with the
LAN router if more than one copy ran at a time.

The goal is to host the boot server on the Proxmox-hosted Kubernetes cluster
without losing the ability to bootstrap that cluster from nothing. Talos on bare
metal is a likely future target.

## Decision

1. **One artifact, many runtimes.** CI builds two pinned OCI images and pushes
   them to GHCR: `boot-http` (with the server code baked in) and `boot-dnsmasq`
   (Alpine plus dnsmasq). Images contain no cluster-specific or secret data.
2. **Config as a separate bundle.** Ansible renders `cluster-manifest.yml` into
   a local bundle (dnsmasq conf plus answer TOMLs). Compose mounts it. Kubernetes
   gets it as a Secret, because the answer files contain credentials. The bundle
   is never put in an image or pushed to a registry.
3. **proxyDHCP.** dnsmasq runs with `dhcp-range=<subnet>,proxy` and only answers
   PXE clients. The LAN router keeps handing out leases. Consequences:
   - Option 250 (answer URL) is no longer delivered. The URL is already baked in
     by `prepare-iso --fetch-from http --url`, so nothing breaks.
   - Static `dhcp-host` leases go away. Node addressing moves into the answer
     TOML (`[network] source = "from-answer"`) using values from the manifest.
   - **Revert path:** keep the authoritative-mode template behind a manifest flag
     (`boot.dhcp_mode: proxy|authoritative`) until a ThinkCentre M910q has
     completed UEFI PXE end to end in proxy mode.
4. **Two-tier hosting.**
   - **Tier 0 (seed, outside the cluster):** Hyper-V Alpine VM built by Packer
     (`hyperv-iso`, External switch, static MAC). Plain Linux hosts run the same
     compose file. Tier 0 keeps no state that the repo and `fetch-assets.sh`
     can't regenerate.
   - **Tier 1 (in-cluster):** single-replica Deployment with `hostNetwork`,
     `NET_ADMIN`, a nodeSelector for nodes attached to the mgmt network, and an
     anti-affinity rule against the node being reinstalled. Assets go in
     node-local storage, not Ceph.
   - Rule: the cluster may rebuild part of itself, never all of itself. Full
     rebuilds always use Tier 0.
5. **One entry point:** `just boot-up target=hyperv|linux|k8s`.

## Talos migration seams

- **Boot profiles:** each manifest node gets `boot.profile: pve|talos`. Today
  only `pve` is implemented. `talos` will serve a kernel and initramfs with
  `talos.config=<url>` instead of the PVE ISO, and `boot-http` will serve
  machine configs by MAC instead of answer TOMLs. Keep the HTTP route handler
  keyed by profile so Talos support is a new handler, not a rewrite.
- **Static addressing from the manifest** (decision 3) matches Talos machine
  config networking, so no DHCP-reservation dependency carries over.
- **Tier 1 manifests** stay plain Kubernetes (no Proxmox APIs, no PVE-specific
  host mounts), so they can run unchanged on Talos. Talos forbids arbitrary
  hostPath writes outside `/var`, so asset storage must sit under `/var`.
- **Tier 0** is unaffected by the OS choice.

## Consequences

- Moving off the Hyper-V VM means building the Packer image and running
  `just boot-up target=linux` elsewhere. No code changes.
- If proxyDHCP fails on UEFI, set `dhcp_mode: authoritative`. Only then are the
  rogue-DHCP and duplicate-instance risks back, so Tier 0 and Tier 1 must never
  run at the same time in that mode.
- Packer and Hyper-V builds only run on a Windows host. CI runs
  `packer fmt -check` and an offline-safe syntax check only.
