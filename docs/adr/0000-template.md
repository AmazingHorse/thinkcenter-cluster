# ADR 0000: Layered Copier templates

Status: accepted

## Context

Projects need consistent, updateable tooling without coupling their secrets,
project recipes, or operational instructions to a shared template.

## Decision

The base owns shared tooling and its `.copier-answers.base.yml` state. Each
archetype keeps a separate answers file. Recipe precedence is project > archetype
> base. Project secret references in `fnox.toml` import the separately managed
provider configuration from `.config/fnox/provider.toml`.

`just check` is offline and secret-free. Live commands require explicit
permission and scoped `fnox exec --` invocation. Sandbox files document intent;
actual enforcement belongs to a launcher, not this template.

## Consequences

Commit local changes before template updates and review the diff afterward.
Project-owned starter files are preserved. Never combine layer answer files or
store credential values in template answers.
