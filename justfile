# justfile — thinkcenter-cluster command runner
#
# Usage:
#   just standup          # Idempotently fetch assets, render configs from manifest, and bring up stack
#   just logs [service]   # View boot server container logs (e.g. just logs nginx)
#   just down             # Stop the boot stack
#   just bootstrap pve01  # Run Ansible site playbook against pve01

# Default target: list recipes
default:
    @just --list

# Fetch Proxmox ISO & iPXE assets if missing or outdated
fetch:
    bash boot/scripts/fetch-assets.sh

# Render boot server configs & host_vars from cluster-manifest.yml
render:
    ansible-playbook ansible/playbooks/00-generate-boot-config.yml

# Start the containerized boot stack (nginx + dnsmasq)
up:
    docker compose -f boot/docker-compose.yml up -d --remove-orphans

# Stop the boot stack containers
down:
    docker compose -f boot/docker-compose.yml down

# View live container logs from the boot stack
logs service="":
    docker compose -f boot/docker-compose.yml logs -f {{ service }}

# Idempotent full boot stack bring-up: fetch assets, render configs, start stack
standup: fetch render up

# Provision/bootstrap a specific node (usage: just bootstrap pve01)
bootstrap node="pve01":
    ansible-playbook ansible/playbooks/site.yml --limit {{ node }}

# Run full site deployment across all installed cluster nodes
site:
    ansible-playbook ansible/playbooks/site.yml

# Check boot stack container status & node inventory
status:
    docker compose -f boot/docker-compose.yml ps
    ansible-inventory -i ansible/inventory/hosts.yml --list
