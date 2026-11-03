# Project agent guidance

- Read README.md, `.agents/project.md` and any `.agents/archetype.md` before changes.
- Keep edits and command effects inside this repository; ask before crossing it.
- Run `just check` before completion. It is deterministic, offline, and secret-free.
- Use `project.just` for project overrides; import order is project > archetype > base.
- Never put secrets in Git, command output, logs, answers, or documentation.
- Store references in `fnox.toml`; provider wiring lives in `.config/fnox/provider.toml`.
- Live operations require explicit authorization and `fnox exec -- COMMAND`.
- CI never runs `just smoke`; `just doctor` is offline and never resolves secrets.
- Do not edit Copier answer metadata or base-owned files to customize the project.
- Prefer small readable changes and update the relevant documentation.
- `.agents/sandbox.toml` is intent until enforced by a launcher; it grants no access.
