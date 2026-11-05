# Agent Spec (queued): SSH host CA + CI leak scan (ADR 0008 phases 3–4)

Run this after the ADR 0007 spec has merged. To start it, copy this file over
`.agent-spec.md`. Read `docs/adr/0008-secret-injection-and-host-trust.md`
first.

## Allowed files

Modify:
- `fnox.toml`: add `PROXMOX_SSH_PUBLIC_KEY` and `SSH_HOST_CA_KEY` references (`thinkcenter-cluster/<FIELD>`, provider `vault`)
- `ansible/ansible.cfg`: `[ssh_connection] ssh_args` adds `-o UserKnownHostsFile=<repo-relative path to ansible/ssh/known_hosts>`; keep `host_key_checking = True`
- `ansible/playbooks/00-generate-boot-config.yml`: stop rendering `ansible/inventory/known_hosts`
- `ansible/roles/pve-base/templates/proxmox-answer.toml.j2`: add `[first-boot]` (`source = "from-url"`, URL on the boot server, `ordering = "fully-up"`)
- `boot/server/boot_http_server.py`: serve the first-boot script; `POST /hostkeys/<mac>` accepts one OpenSSH ed25519 public key (validate format, reject >1 KiB, MAC must exist in the manifest) and stores it under a writable data dir; `GET /hostkeys/` lists them
- `boot/docker-compose.yml`, `boot/k8s/deployment.yaml`: writable `hostkeys` volume
- `project.just`: `ssh-ca-init` (generates the CA in a tmpfs dir and prints the public line plus instructions for storing the private key with `rbw`; never echoes the private key), `sign-hostkeys`
- `.github/workflows/ci.yml`: full-history leak scan job (`fetch-depth: 0`), pinned action version
- `.gitignore`: remove the `ansible/inventory/known_hosts` entry
- `docs/runbook.md`, `README.md`: enrollment flow

Create:
- `boot/server/first-boot.sh`: POSIX sh; POSTs `/etc/ssh/ssh_host_ed25519_key.pub` along with the primary MAC; retries with backoff
- `ansible/ssh/known_hosts`: placeholder `@cert-authority` line, marked for the operator to replace after `ssh-ca-init`
- `scripts/sign-hostkeys.sh`: loads `SSH_HOST_CA_KEY` into a short-lived `ssh-agent` (`ssh-add -` from stdin), signs with `ssh-keygen -s <ca.pub> -U -h -I <hostname> -n <hostname>,<fqdn>,<ip> -V +52w`, installs the cert at `/etc/ssh/ssh_host_ed25519_key-cert.pub` plus `/etc/ssh/sshd_config.d/10-hostcert.conf`, reloads sshd; connects with a temporary known_hosts holding only the posted key; asks for interactive confirmation of each fingerprint; kills the agent on exit (trap)
- `tests/test-hostkeys.sh`: offline; drives the boot server's hostkey endpoint (valid key accepted; bad format, oversize, and unknown MAC rejected) and runs a local sign/verify round trip with a throwaway CA; wire it into `tests/run-mock-suite.sh`

## Hard constraints

- The CA private key never touches disk, Git, logs, the boot server, or images. It lives only in agent memory.
- `just check` stays offline. Tests use throwaway keys generated in `mktemp -d` and cleaned up by a trap.
- No `StrictHostKeyChecking=no` and no `UserKnownHostsFile=/dev/null` anywhere.

## Acceptance

- `just check` passes, including `tests/test-hostkeys.sh`.
- `rg -n 'StrictHostKeyChecking=no|/dev/null' ansible scripts boot` finds nothing SSH-related.
- The CI leak-scan job passes on full history. If it flags something, report it. Don't suppress findings without operator approval.
- Manual (operator): after a node reinstall, `fnox exec -- just sign-hostkeys` followed by `ansible all -m ping` succeeds with no known_hosts edits.

## Out of scope

Phase 5 (`bws` plus External Secrets Operator) waits until a Tier 1 cluster exists.
