# Install pinned tools and git hooks.
setup:
    mise install
    pre-commit install

# Offline gate: never resolve secrets or contact live systems.
check: lint test

# The local project-lint hook invokes just lint; skip only that hook here.
lint:
    SKIP=project-lint pre-commit run --all-files

test:
    @echo "test: n/a"

fmt:
    @echo "fmt: n/a"

# Live operations must opt into fnox exec; CI never runs smoke.
smoke:
    @echo "smoke: n/a"

# Offline tool/config diagnostics. Secret resolution is a separate live gate.
doctor:
    mise --version
    just --version
    fnox --version
    test -f fnox.toml && test -f .config/fnox/provider.toml
    fnox list
    @echo "To resolve secret references, run fnox check interactively with explicit live authorization."
