# ADR 0008: Secret Injection, Fail-Closed Rendering, and SSH Host Trust

Status: proposed

## Context

ADR 0006 moved secrets to fnox with Bitwarden (`rbw`) but kept a plaintext
default (`ProxmoxDefault123!`) as a fallback when the variable isn't set. Other
problems:

- Rendered answer TOMLs contain the plaintext root password, and the boot server
  hands them to any LAN client that POSTs a MAC address.
- `ansible/inventory/known_hosts` is rendered but nothing uses it.
  `ansible.cfg` only sets `host_key_checking = True`. Every PXE reinstall changes
  the host keys, which pushes operators toward disabling host-key checking.
- Leak scanning (`betterleaks`) only runs in pre-commit, which can be skipped.
- `rbw` has to be unlocked interactively, so it can't feed unattended consumers
  (the Tier 1 boot server, Flux, Talos).

## Decision

### Phase 1: Fail closed
No secret has a default value. Rendering aborts if `PROXMOX_ROOT_PASSWORD` is
unset and tells the operator to use `fnox exec --`. The offline mock suite
supplies a dummy value explicitly.

### Phase 2: No plaintext at rest
Answer files use `root-password-hashed` (SHA-512 crypt, computed at render time
with `no_log`). The boot bundle, k8s Secret, and HTTP responses only ever carry
the hash. Because the hash is still exposed to the LAN, the password must be
long and random.

### Phase 3: SSH host CA
- One ed25519 host CA. Its private key lives only in Bitwarden
  (`SSH_HOST_CA_KEY`) and is loaded into `ssh-agent` at signing time, never
  written to disk.
- The committed `ansible/ssh/known_hosts` holds a single `@cert-authority` line
  (public). `ansible.cfg` points `UserKnownHostsFile` at it.
- Enrollment:
  1. A PVE `[first-boot]` hook (fetched from the boot server) POSTs the host's
     ed25519 public key to `boot-http` (`/hostkeys/<mac>`).
  2. The operator runs `fnox exec -- just sign-hostkeys`. It lists fingerprints
     and asks for confirmation, signs each key with principals
     `<hostname>,<fqdn>,<mgmt-ip>` and a 52-week validity, then installs the
     certificate and `HostCertificate` config over SSH, pinned to the just-posted
     key for that single connection.
- Trust anchor for step 1 is "a host that just PXE-installed from our boot
  server on our LAN". That's accepted for a home lab and recorded here.
- The CA key never touches the boot server or the cluster.

### Phase 4: Leak scanning in CI
CI scans the full Git history for leaks on every push. A one-time history audit
is done. Any real credential found gets rotated. History rewrite is optional.

### Phase 5: Unattended secrets (deferred until Tier 1 exists)
Bitwarden Secrets Manager (`bws`) with a machine account, read in-cluster by
External Secrets Operator. Its single bootstrap token is injected with
`fnox exec -- kubectl create secret …`. Until then, Tier 1 gets its Secrets the
same way, by hand. The same pattern carries over to Talos/Flux.

## Bitwarden fields

On the existing `thinkcenter-cluster` item:

| Field | Phase |
|---|---|
| `PROXMOX_ROOT_PASSWORD` | exists; rotate to a long random value |
| `PROXMOX_SSH_PUBLIC_KEY` | 2 (add to `fnox.toml`) |
| `SSH_HOST_CA_KEY` | 3 |
| `BWS_ACCESS_TOKEN` | 5 |

## Consequences

- Forgetting `fnox exec` now fails loudly instead of installing nodes with a
  known password.
- Reinstalling a node needs only `just sign-hostkeys`, never editing
  `known_hosts`.
- Losing `SSH_HOST_CA_KEY` means re-enrolling every host. That's cheap, so no
  extra backup beyond Bitwarden.
