# Keep the local just-lint pre-commit hook from recursively entering this recipe.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    SKIP=project-lint pre-commit run --all-files
    yamllint -d '{extends: default, rules: {document-start: disable, line-length: disable, truthy: disable, comments: {min-spaces-from-content: 1}, indentation: {spaces: 2, indent-sequences: consistent}}}' .

    playbooks=(ansible/playbooks/*.yml)
    if [[ -n "${playbooks[*]}" ]]; then
        cd ansible
        ANSIBLE_CONFIG=ansible.cfg ansible-lint --offline playbooks/*.yml
    fi


# Offline only: never use fnox or contact a live inventory from this gate.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob

    playbooks=(ansible/playbooks/*.yml)
    for playbook in "${playbooks[@]}"; do
        (cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook --syntax-check "${playbook#ansible/}")
    done



# Live-system dry run: obtain approval for the documented target CIDRs first.
plan:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob

    playbooks=(ansible/playbooks/*.yml)
    for playbook in "${playbooks[@]}"; do
        (cd ansible && ANSIBLE_CONFIG=ansible.cfg fnox exec -- ansible-playbook --check --diff "${playbook#ansible/}")
    done
