---
name: infra-ops-add-secret
description: Add project-owned fnox references to Bitwarden without putting secret values or provider definitions into the infrastructure repository.
---

# Add an infrastructure secret reference

1. Read the base provider include, project `fnox.toml`, `.agents/archetype.md` and the current `fnox` help/provider schema. Reuse the configured Bitwarden provider name. Never redefine it in the project file or edit `.config/fnox/provider.toml` as part of adding a reference.
2. Confirm the desired environment-variable name and the exact Bitwarden folder, item and field. Prefer `<company>/<project>` folders and explicit fields such as `token`, `password` or `private_key`. Ask the user to create or select the item through their normal Bitwarden workflow; never request that they paste the secret into chat or a tracked file.
3. Add only the named reference under project-owned `fnox.toml`, using the installed fnox provider's documented item/field reference syntax. Preserve the existing base include and all unrelated project references. Do not store values, encrypted blobs, `.env` files or vault-password files in Git.
4. Wire the consuming live command through `fnox exec --` and an environment-variable interface. Do not use shell tracing, print the retrieved value or write a temporary copy into the repository. Do not inject credentials into `just check`, lint, syntax checks or CI's offline validation.
5. Review the diff as text to ensure it contains identifiers only and no real values. Any retrieval test requires the user's approved Bitwarden session and live-access authorization; test command success without echoing the credential. Record the variable name and intended consumer, not its value.

For an unavoidable Ansible Vault password, use the base executable `.config/fnox/vault-password.sh` and explicitly configure its expected project reference. Never set `vault_password_file = .vault-pass` and never run `ansible-vault decrypt` into the working tree.
