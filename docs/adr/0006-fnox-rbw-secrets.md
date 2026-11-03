# ADR 0006: Secret Management Migration from SOPS to fnox with Bitwarden Provider

## Status
Accepted

## Context
Initial prototypes used SOPS with `age` encryption keys stored locally or requiring manual operator exchange. This introduced encrypted binary blobs in git, created CI lint failures due to sample secrets, and complicated operator workflows across workstations.

## Decision
Migrate cluster secret resolution to `fnox` backed by Bitwarden (`rbw`) vault integration. Declarative secrets are configured in `fnox.toml` and resolved into environment variables at execution time via `fnox exec -- ...`. Plaintext default fallbacks are provided for local offline test generation.

## Consequences
- No encrypted keyfiles or ciphertext payloads committed to git.
- Secrets are scoped to explicit runbook workflows and protected by operator Bitwarden authentication.
- Ansible templates and playbooks pull credentials from environment variables (`lookup('env', ...)`).
