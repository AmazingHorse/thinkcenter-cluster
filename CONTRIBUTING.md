# Contributing

Run `just setup` once to install pinned tools and Git hooks. After setup,
`just check` is the deterministic offline gate; it must not unlock a vault,
download dependencies, or contact a live target. CI runs the same gate.

Keep changes focused. Put project-specific recipes in `project.just`; the import
order is project > archetype > base. Update documentation when behavior changes
and record durable decisions in `docs/adr/`. Do not hand-edit Copier answer state.

Never commit secret values, `.env` files, local agent grants, or vault exports.
Store references in `fnox.toml`. Live recipes require explicit authorization and
must wrap commands with `fnox exec --`. Do not run `just smoke` from CI.

Use Conventional Commits (for example, `feat: document deployment workflow`).
Describe exercised validation and any blockers in the pull request.
