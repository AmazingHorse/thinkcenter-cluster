# Infrastructure operations

Selected toolchain: ansible.

## Operating contract

- Treat the repository's manifest (for example `cluster-manifest.yml`) as the source of truth. Do not duplicate inventory, addresses, versions or topology across playbooks and prose; keep `docs/runbook.md` and `docs/design.md` aligned with it when those files exist.
- Work in the sequence **check → plan → review → apply**. `just check` is offline and must not unlock a vault, install collections/providers or contact hosts. `just plan` may contact live systems and uses `fnox exec --`; review its complete diff before any approved apply.
- Live target CIDR(s): **192.168.50.0/24**. Obtain explicit user approval before apply or smoke checks against these targets. Do not scan, SSH to or change them merely because a plan is requested. The base `.agents/sandbox.toml` denies network by default: its project owner must explicitly map approved CIDRs into `allow_private` and select the appropriate `network` policy before live work. This file records intent until a sandbox launcher enforces it; the overlay never rewrites it.
- There is deliberately no generic `apply` or live `smoke` recipe. Write a project-specific, reviewed procedure; preserve Ansible SSH host-key checking and never add auto-approve flags. Number playbooks and make changes idempotent.
- Read `.agents/skills/infra-ops-runbook/SKILL.md` for execution and review details; read `.agents/skills/infra-ops-add-secret/SKILL.md` before adding credentials.

## Secrets and local state

- Project secret references belong only in the project-owned `fnox.toml`; provider configuration stays in base-owned `.config/fnox/provider.toml`. Do not put credentials, encrypted secret blobs, vault passwords, decrypted files or real secret values in Git.
- Store one Bitwarden item named after the project slug in the base-configured folder (default `proj`), with one custom field per environment variable. Reference it as `project-slug/FIELD_NAME`; never copy a field into Ansible vars, inventory, OpenTofu inputs or a dotenv file.
- Recipes that use credentials wrap the live command in `fnox exec --`; `check`, lint and syntax validation never do. The Bitwarden session is inherited from the calling shell, not stored in project files.
- If Ansible Vault is unavoidable in a project, never configure `vault_password_file = .vault-pass`; use the executable `.config/fnox/vault-password.sh` only with an explicitly configured project secret reference. No runtime files or temporary credentials belong in the repository.


## Ansible

Run from `ansible/` so `ansible.cfg` is used. Collections are local to `ansible/.ansible/collections`; review and exactly pin `requirements.yml` before an explicit setup install. The seeded localhost playbook has no remote effects. The empty inventory is intentional; add approved hosts only after documenting the manifest and access policy.
