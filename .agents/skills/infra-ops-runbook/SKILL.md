---
name: infra-ops-runbook
description: Plan, review and carry out explicitly approved infrastructure changes without exposing secrets or silently contacting live systems.
---

# Infrastructure change runbook

1. Read `AGENTS.md`, `.agents/archetype.md`, `.agents/project.md`, the source-of-truth manifest and the project's runbook/design documents. Identify selected tooling and target CIDRs. The base sandbox is deny-by-default: the project owner must map approved CIDRs and ports before live operations; an archetype answer does not grant network access.
2. Establish the intended change, rollback and explicit user approval boundary. Do not edit inventory or duplicate manifest facts as an incidental workaround. Preserve host-key checking and use numbered, idempotent playbooks.
3. Run `just check`. It is an offline gate: no vault access, collection/provider downloads, SSH, live probes or infrastructure changes. If dependencies were added, arrange a separate explicit setup operation and review their exact versions first.
4. Run `just plan` only with permission for any live reads and credentials it requires. Its commands run through `fnox exec --`; never echo secret environment variables. Ansible uses `--check --diff`; OpenTofu creates a plan without applying it. Inspect diffs locally because infrastructure output may contain sensitive data.
5. Review the complete change and explain affected targets, destructive actions, expected outage, state impact and rollback. Do not treat a successful plan as authorization to apply.
6. Apply only after the user explicitly approves the reviewed change and targets. Use a project-specific procedure and `fnox exec --` around the live command. Do not add a generic apply-all recipe, disable host-key checking or use `-auto-approve`. OpenTofu plans may hold secrets: save them only outside tracked files if the project procedure requires them, protect access, and remove them afterward.
7. Run only explicitly approved live smoke checks. Record non-secret results and any manifest/runbook changes; do not commit state, credential files, decrypted content, private keys or runtime artifacts.

Ansible Vault, if unavoidable, uses executable `.config/fnox/vault-password.sh` and an explicitly configured project fnox reference. A `.vault-pass` file or inline password is never an acceptable shortcut. A failure to retrieve a secret is an error to report, not permission to replace the secret provider or write plaintext.
