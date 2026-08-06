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
fetch: build-tools
    bash boot/scripts/fetch-assets.sh

# Build tool images (prepare-pxe) — runs fast if image is already up to date
build-tools:
    docker compose -f boot/docker-compose.yml build prepare-pxe


# Wipe extracted kernel assets & generated configs (keeps downloaded ISO intact)
clean:
    rm -f boot/assets/linux26 boot/assets/initrd.img boot/assets/autoexec.ipxe
    rm -f boot/assets/*.tmp boot/assets/auto-installer-mode.toml
    rm -rf boot/assets/answers/ boot/assets/pxe-prepared/

# Full wipe including downloaded ISO files
clean-all: clean
    rm -f boot/assets/*.iso

# Render boot server configs & host_vars from cluster-manifest.yml
render:
    ansible-playbook ansible/playbooks/00-generate-boot-config.yml

# Start/reload the containerized boot stack (forces config reload)
up:
    docker compose -f boot/docker-compose.yml up -d --force-recreate --remove-orphans

# Stop the boot stack containers
down:
    docker compose -f boot/docker-compose.yml down

# View live container logs (usage: just logs or just logs dnsmasq)
logs service="":
    -@docker compose -f boot/docker-compose.yml logs -f {{ service }}

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

# Verify boot server HTTP endpoints (usage: just test or just test 192.168.50.206)
test target="localhost":
    @echo "==> 1. Testing GET /autoexec.ipxe..."
    curl -sf http://{{ target }}:8080/autoexec.ipxe | head -n 4
    @echo ""
    @echo "==> 2. Testing POST /assets/answers/pve01.toml (Simulating proxmox-fetch-answer by hostname)..."
    curl -sf -X POST http://{{ target }}:8080/assets/answers/pve01.toml | head -n 4
    @echo ""
    @echo "==> 3. Testing POST /assets/answers/80-86-f2-18-55-b6.toml (Simulating proxmox-fetch-answer by MAC)..."
    curl -sf -X POST http://{{ target }}:8080/assets/answers/80-86-f2-18-55-b6.toml | head -n 4
    @echo ""
    @echo "==> 4. Testing HEAD /assets/linux26..."
    curl -sfI http://{{ target }}:8080/assets/linux26 | grep -i "HTTP\|Content-Length"
    @echo ""
    @echo "==> 5. Testing HEAD /assets/initrd.img..."
    curl -sfI http://{{ target }}:8080/assets/initrd.img | grep -i "HTTP\|Content-Length"
    @echo ""
    @echo "[OK] All boot server endpoints operational!"

