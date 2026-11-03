# Project-specific recipes for thinkcenter-cluster.
# Standard verbs (setup, check, lint, fmt, doctor) live in .config/just/base.just and archetype.just.

export ANSIBLE_CONFIG := justfile_directory() / "ansible" / "ansible.cfg"

boot_dir := justfile_directory() / "boot"
ansible_dir := justfile_directory() / "ansible"

# Offline test gate: runs all modular offline test recipes
test: test-syntax test-render test-answers test-invariants test-server test-assets test-templates
    @echo ""
    @echo "==> All offline mock tests passed successfully!"

# Check Ansible playbook syntax
test-syntax:
    @echo "==> [test] Checking Ansible playbook syntax..."
    ansible-playbook --syntax-check -i {{ansible_dir}}/inventory/hosts.yml {{ansible_dir}}/playbooks/*.yml

# Render boot configs from manifest and assert output files exist
test-render: configure
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> [test] Verifying rendered boot and inventory files..."
    required=(
        "boot/dnsmasq/dnsmasq.conf"
        "boot/ipxe/autoexec.ipxe"
        "boot/assets/answers/pve01.toml"
        "boot/assets/answers/pve02.toml"
        "boot/assets/answers/pve03.toml"
        "boot/assets/answers/default.toml"
        "boot/assets/answers/80-86-f2-18-55-b6.toml"
        "ansible/inventory/host_vars/pve01.yml"
        "ansible/inventory/host_vars/pve02.yml"
        "ansible/inventory/host_vars/pve03.yml"
        "ansible/inventory/known_hosts"
    )
    for f in "${required[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "  [FAIL] Missing required rendered file: $f" >&2
            exit 1
        fi
        echo "  [ok] $f"
    done

# Validate rendered Proxmox answer TOML files against PVE 9.2 schema
test-answers:
    #!/usr/bin/env python3
    import sys, tomllib
    from pathlib import Path
    answers_dir = Path("boot/assets/answers")
    toml_files = list(answers_dir.glob("*.toml"))
    if not toml_files:
        sys.exit("No .toml answer files found in boot/assets/answers")
    print(f"==> [test] Validating {len(toml_files)} answer files against PVE 9.2 schema...")
    for p in toml_files:
        data = tomllib.loads(p.read_text(encoding="utf-8"))
        g = data.get("global", {})
        assert g.get("keyboard") and g.get("country") and "." in g.get("fqdn", "")
        assert "@" in g.get("mailto", "") and g.get("timezone") and g.get("root-password")
        assert data.get("network", {}).get("source") == "from-dhcp"
        disk = data.get("disk-setup", {})
        assert disk.get("filesystem") in ("zfs", "ext4", "xfs", "btrfs")
        assert disk.get("disk-list") and not any(d.startswith("/dev/") for d in disk["disk-list"])
        if disk["filesystem"] == "zfs":
            z = disk.get("zfs", {})
            assert z.get("raid") in ("raid0", "raid1", "raid10", "raidz-1", "raidz-2", "raidz-3")
            assert isinstance(z.get("hdsize"), int) and 16 <= z["hdsize"] <= 500
            assert isinstance(z.get("arc-max"), int) and z["arc-max"] > 0
        print(f"  [ok] {p.name}")

# Check iPXE magic headers, dual initrd, dnsmasq static mode, and Option 250
test-invariants:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> [test] Checking dnsmasq and iPXE invariants..."
    head -n1 boot/ipxe/autoexec.ipxe | grep -q "^#!ipxe$"
    grep -q "initrd=initrd.img initrd=proxmox.iso.cpio" boot/ipxe/autoexec.ipxe
    grep -q "initrd --name proxmox.iso.cpio" boot/ipxe/autoexec.ipxe
    echo "  [ok] autoexec.ipxe: #!ipxe magic header and dual EFI initrds verified"

    grep -q "dhcp-ignore=tag:\!known" boot/dnsmasq/dnsmasq.conf
    grep -q "dhcp-option=250," boot/dnsmasq/dnsmasq.conf
    ! grep -q 'dhcp-boot=tag:ipxe,"http' boot/dnsmasq/dnsmasq.conf
    for mac in $(yq -r '.nodes[].mac' cluster-manifest.yml); do
        grep -qi "$mac" boot/dnsmasq/dnsmasq.conf
    done
    echo "  [ok] dnsmasq.conf: static MAC isolation, Option 250, and unquoted URL verified"

# Ephemeral live test of boot_http_server.py with simulated PXE and POST clients
test-server:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> [test] Testing boot_http_server.py dispatch on ephemeral port..."
    TMP_ROOT=$(mktemp -d /tmp/boot-test.XXXXXX)
    PORT=$(python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()")
    mkdir -p "${TMP_ROOT}/assets/answers"
    echo "dummy-kernel" > "${TMP_ROOT}/assets/linux26"
    echo "dummy-initrd" > "${TMP_ROOT}/assets/initrd.img"
    echo "dummy-cpio" > "${TMP_ROOT}/assets/proxmox.iso.cpio"
    cp boot/assets/autoexec.ipxe "${TMP_ROOT}/assets/autoexec.ipxe"
    cp -r boot/assets/answers/* "${TMP_ROOT}/assets/answers/"

    python3 boot/server/boot_http_server.py --root "${TMP_ROOT}" --port "${PORT}" --bind 127.0.0.1 >/dev/null 2>&1 &
    PID=$!
    trap 'kill $PID 2>/dev/null || true; rm -rf "${TMP_ROOT}"' EXIT
    sleep 0.5

    curl -sf "http://127.0.0.1:${PORT}/autoexec.ipxe" | grep -q "#!ipxe"
    curl -sfI "http://127.0.0.1:${PORT}/assets/linux26" | grep -q "200 OK"
    curl -sfI "http://127.0.0.1:${PORT}/assets/proxmox.iso.cpio" | grep -q "200 OK"
    echo "  [ok] iPXE static GET requests succeeded"

    # POST dispatch by MAC
    resp1=$(curl -sf -X POST "http://127.0.0.1:${PORT}/assets/answers/" \
        -H "Content-Type: application/json" -d '{"mac_addresses":["80:86:f2:18:55:b6"]}')
    echo "$resp1" | grep -q 'fqdn = "pve01.cluster.local"'
    resp2=$(curl -sf -X POST "http://127.0.0.1:${PORT}/assets/answers" \
        -H "Content-Type: application/json" -d '{"mac_addresses":["aa:bb:cc:dd:ee:02"]}')
    echo "$resp2" | grep -q 'fqdn = "pve02.cluster.local"'
    resp_fallback=$(curl -sf -X POST "http://127.0.0.1:${PORT}/assets/answers/" \
        -H "Content-Type: application/json" -d '{"mac_addresses":["00:00:00:00:00:00"]}')
    echo "$resp_fallback" | grep -q 'keyboard = "en-us"'
    echo "  [ok] Proxmox POST fetch-answer MAC routing and default fallback verified"

# Test asset preparation pipeline with mocked binaries
test-assets:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> [test] Testing asset preparation pipeline with mocked binaries..."
    TMP_DIR=$(mktemp -d /tmp/mock-assets.XXXXXX)
    MOCK_BIN="${TMP_DIR}/bin"
    MOCK_ASSETS="${TMP_DIR}/assets"
    MOCK_PREP="${TMP_DIR}/prepared"
    mkdir -p "${MOCK_BIN}" "${MOCK_ASSETS}" "${MOCK_PREP}"

    # Mock curl
    cat << 'EOF' > "${MOCK_BIN}/curl"
    #!/usr/bin/env bash
    out=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
    done
    [[ -n "$out" ]] && { mkdir -p "$(dirname "$out")"; echo "mock-data" > "$out"; }
    exit 0
    EOF
    chmod +x "${MOCK_BIN}/curl"

    # Mock proxmox-auto-install-assistant
    cat << 'EOF' > "${MOCK_BIN}/proxmox-auto-install-assistant"
    #!/usr/bin/env bash
    [[ "$1" == "--version" ]] && { echo "proxmox-auto-install-assistant 9.2.8"; exit 0; }
    out=""
    while [[ $# -gt 0 ]]; do
      case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac
    done
    mkdir -p "$out"
    echo "mock-iso" > "${out}/proxmox-prepared.iso"
    echo "mock-kernel" > "${out}/linux26"
    echo "mock-initrd" | zstd > "${out}/initrd.img"
    exit 0
    EOF
    chmod +x "${MOCK_BIN}/proxmox-auto-install-assistant"

    # Run pipeline with mocks
    (
      export PATH="${MOCK_BIN}:${PATH}"
      proxmox-auto-install-assistant prepare-iso dummy.iso --fetch-from http --url http://dummy/ --tmp "${MOCK_PREP}" --output "${MOCK_PREP}"
      cp "${MOCK_PREP}/linux26" "${MOCK_ASSETS}/linux26"
      cp "${MOCK_PREP}/initrd.img" "${MOCK_ASSETS}/initrd.img"
      zstd -d -c "${MOCK_ASSETS}/initrd.img" | gzip -1 > "${MOCK_ASSETS}/initrd.img.gz"
      mv "${MOCK_ASSETS}/initrd.img.gz" "${MOCK_ASSETS}/initrd.img"
      cp "${MOCK_PREP}/proxmox-prepared.iso" "${MOCK_PREP}/proxmox.iso"
      (cd "${MOCK_PREP}" && echo "proxmox.iso" | cpio -H newc -o > "${MOCK_ASSETS}/proxmox.iso.cpio")
    ) 2>/dev/null

    gzip -t "${MOCK_ASSETS}/initrd.img"
    echo "  [ok] initrd.img recompressed to gzip"
    head -c 6 "${MOCK_ASSETS}/proxmox.iso.cpio" | grep -q "^070701"
    echo "  [ok] proxmox.iso.cpio has valid newc 070701 CPIO header"
    rm -rf "${TMP_DIR}"

# Render and assert post-install interfaces and corosync templates
test-templates:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> [test] Rendering post-install network and corosync templates..."
    TMP_PLAY=$(mktemp -d /tmp/ansible-tmpl.XXXXXX)
    ansible-playbook -i ansible/inventory/hosts.yml tests/test-render-playbook.yml --extra-vars "out_dir=${TMP_PLAY}" >/dev/null

    pve01_if="${TMP_PLAY}/interfaces-pve01"
    grep -q "iface eth-mgmt inet manual" "$pve01_if"
    grep -q "iface vmbr0 inet static" "$pve01_if"
    grep -q "address 192.168.50.10/24" "$pve01_if"
    grep -q "gateway 192.168.50.1" "$pve01_if"
    ! grep -q "ip route add 10.10.0.0/8" "$pve01_if"
    echo "  [ok] interfaces.j2: vmbr0 holds static IP/gw, no static 10.10.0.0/8 route"

    pve01_coro="${TMP_PLAY}/corosync-pve01"
    grep -q "ring0_addr: 192.168.50.10" "$pve01_coro"
    grep -q "ring1_addr: 10.10.12.1" "$pve01_coro"
    ! grep -q "ring1_addr: 192.168.50." "$pve01_coro"
    echo "  [ok] corosync.conf.j2: distinct ring0 and ring1 IPs verified"

    rm -rf "${TMP_PLAY}"

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
