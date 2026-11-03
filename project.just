# Project-specific recipes for thinkcenter-cluster.
# Standard verbs (setup, check, lint, fmt, doctor) live in .config/just/base.just and archetype.just.
export ANSIBLE_CONFIG := justfile_directory() / "ansible" / "ansible.cfg"

boot_dir := justfile_directory() / "boot"
ansible_dir := justfile_directory() / "ansible"

# Offline test gate: syntax-check playbooks + run mocked boot/render test suite
test:
    ansible-playbook --syntax-check {{ansible_dir}}/playbooks/*.yml
    bash {{justfile_directory()}}/tests/run-mock-suite.sh

# Render boot configs (dnsmasq, iPXE, answers, host_vars, known_hosts) from cluster-manifest.yml
configure:
    @echo "==> Rendering configurations from cluster-manifest.yml..."
    ansible-playbook {{ansible_dir}}/playbooks/00-generate-boot-config.yml

# Download Proxmox ISO + iPXE binaries and build PXE/USB assets (run on boot host)
fetch: configure
    @echo "==> Fetching and preparing PXE assets..."
    bash {{boot_dir}}/scripts/fetch-assets.sh

# Start the PXE boot server containers (nginx/answer-server + dnsmasq) on the Alpine Hyper-V VM
up: configure
    @echo "==> Starting boot server containers..."
    docker compose -f {{boot_dir}}/docker-compose.yml up -d nginx dnsmasq
    @echo "==> Boot stack is UP."

# Full idempotent PXE boot server standup: configure -> fetch -> up
standup: fetch up

# Stop the boot server containers
down:
    docker compose -f {{boot_dir}}/docker-compose.yml down

# Restart the boot server containers
restart:
    docker compose -f {{boot_dir}}/docker-compose.yml restart nginx dnsmasq

# Tail container logs (pass service name, e.g., `just logs dnsmasq`)
logs *service:
    docker compose -f {{boot_dir}}/docker-compose.yml logs -f {{service}}

# Show container status and prepared asset files
status:
    @echo "=== Containers ==="
    docker compose -f {{boot_dir}}/docker-compose.yml ps
    @echo ""
    @echo "=== Prepared Assets ==="
    ls -lh {{boot_dir}}/assets/ 2>/dev/null || echo "  (not yet created)"
    @echo ""
    @echo "=== Rendered Answer Files ==="
    ls -lh {{boot_dir}}/assets/answers/ 2>/dev/null || echo "  (not yet rendered)"

# Live smoke check against running boot stack (never run in CI)
smoke-boot:
    #!/usr/bin/env bash
    set -euo pipefail
    BOOT_IP=$(yq -r '.cluster.boot_server_ip' cluster-manifest.yml)
    echo "=== Testing Boot Stack on ${BOOT_IP}:8080 ==="
    curl -sfI "http://${BOOT_IP}:8080/autoexec.ipxe" >/dev/null && echo "  [ok] GET /autoexec.ipxe"
    curl -sfI "http://${BOOT_IP}:8080/assets/linux26" >/dev/null && echo "  [ok] GET /assets/linux26"
    curl -sfI "http://${BOOT_IP}:8080/assets/initrd.img" >/dev/null && echo "  [ok] GET /assets/initrd.img"
    curl -sfI "http://${BOOT_IP}:8080/assets/proxmox.iso.cpio" >/dev/null && echo "  [ok] GET /assets/proxmox.iso.cpio"
    curl -sf -X POST "http://${BOOT_IP}:8080/assets/answers/" \
      -H "Content-Type: application/json" \
      -d '{"mac_addresses":["80:86:f2:18:55:b6"]}' | grep -q 'fqdn = "pve01' && echo "  [ok] POST /assets/answers/ (MAC lookup)"

# Dry-run Ansible site.yml against live nodes (requires unlocked rbw vault)
plan *args: configure
    fnox exec -- ansible-playbook {{ansible_dir}}/playbooks/site.yml --check --diff {{args}}

# Run Ansible site.yml against a specific node (e.g. `just bootstrap pve01`)
bootstrap node: configure
    fnox exec -- ansible-playbook {{ansible_dir}}/playbooks/site.yml --limit {{node}}

# Run full Ansible site.yml across all nodes
site *args: configure
    fnox exec -- ansible-playbook {{ansible_dir}}/playbooks/site.yml {{args}}
