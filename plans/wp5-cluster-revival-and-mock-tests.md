# WP5 & Cluster Revival Plan: Template Adoption, Mocked Test Suite, PXE/UEFI Fix & Xeon Resource Economization

> **Target Executor:** SWE-2 / implementing agent running inside `/home/bheughan/projects/thinkcenter-cluster`.
> **Hardware / Environment Context:**
> - **Nodes:** 3× Lenovo ThinkCentre M910q/M910x mini PCs with power-limited 6-core Intel Xeon CPUs (`pve01` = 16 GB RAM, `pve02` = 8 GB RAM, `pve03` = 8 GB RAM; single 1 TB SSD per node today).
> - **Boot Server:** Runs later inside an Alpine Linux Hyper-V VM (with External vSwitch for L2 DHCP/PXE broadcast). **Do not run live Docker/DHCP/Ansible against real hosts during implementation.** Instead, build and run the offline mocked test suite (`tests/run-mock-suite.sh` via `just test`) so every template, script, answer file, and playbook is deterministically verified offline.
> - **End Goal:** Hyperconverged 3-node Proxmox VE 9.2 + Ceph Tentacle cluster hosting a lightweight 3-node Kubernetes (k3s / Talos) cluster for Home Assistant and self-hosted services.

---

## Executive Summary: Why the Cluster Stalled & What This Plan Fixes

Auditing the current repository against upstream Proxmox VE 9.2 (`pve-installer`) and iPXE revealed **5 concrete bugs** that caused the PXE/auto-install stall and would have broken post-install Ansible runs:

1. **Bug 1 — `nginx.conf` + `prepare-pxe` HTTP Answer Endpoint Returns HTML Instead of TOML:**
   - `prepare-pxe-entrypoint.sh` bakes `--url "http://192.168.50.206:8080/assets/answers/"` into the ISO.
   - When `proxmox-fetch-answer` runs during installation, it sends an `HTTP POST` with a JSON body (`{"mac_addresses": [...], "network_interfaces": [...]}`) to that exact URL (`/assets/answers/`), **not** `/assets/answers/<mac>.toml`.
   - `boot/nginx/nginx.conf` rewrites `POST /assets/answers/` → `GET /assets/answers/`, which serves an **HTML directory listing (`autoindex on`)** instead of a TOML answer file!
   - **Fix (Phase 3):** Replace the static `nginx` container with a tiny, zero-dependency Python 3 stdlib HTTP server (`boot/server/boot_http_server.py` running in `python:3.12-alpine`) that serves static `/assets/*` and `/autoexec.ipxe` on `GET` **and** inspects `POST` JSON `mac_addresses` / `network_interfaces` (or peer IP / URL path) to return the matching `boot/assets/answers/<mac>.toml` (with `pve01.toml` / `default.toml` fallback). Also configure per-MAC DHCP Option `250` in `dnsmasq.conf.j2`.
2. **Bug 2 — `proxmox-answer.toml.j2` Has 10 TOML Syntax & Schema Errors:**
   - Unquoted strings (`keyboard = en-us`, `country = us`, `fqdn = ...`, `timezone = America/New_York`, `source = from-dhcp`, `filesystem = zfs`, `zfs.raid = single`, `disk_list = /dev/sda`) fail TOML parsing immediately.
   - Invalid Proxmox schema: `zfs.raid` must be `"raid0"` (not `single`), `disk-list` must be a TOML array of device names (`["sda"]`, not `/dev/sda`), `root-password` must be kebab-case, `mailto` must be a non-empty email (`"root@cluster.local"`), and `zfs.hdsize` **must** be set (e.g., `64` GiB) so Proxmox doesn't consume 100% of `/dev/sda` and leave 0 bytes for the Ceph OSD partition.
   - **Fix (Phase 3):** Rewrite `proxmox-answer.toml.j2` to valid PVE 9.2 TOML and validate every rendered `.toml` file with Python `tomllib` + schema assertions in `just test`.
3. **Bug 3 — UEFI PXE Kernel Panic (`fetch-assets.sh` + `autoexec.ipxe.j2`):**
   - `fetch-assets.sh` appended an uncompressed 1.6 GB CPIO archive (`proxmox.iso`) directly onto a **zstd-compressed** `initrd.img`, forcing UEFI firmware to allocate a single contiguous 1.75 GB buffer and panicking `init/initramfs.c` (`Unable to mount root fs on unknown-block(0,0)`).
   - Meanwhile, passing a raw `.iso` as a second `initrd` in UEFI mode fails because iPXE in UEFI mode does not synthesize a CPIO header around raw files—the Linux EFI stub silently drops any `initrd=` buffer lacking `070701` CPIO magic.
   - **Fix (Phase 3):**
     1. In `prepare-pxe-entrypoint.sh` / `fetch-assets.sh`, recompress `initrd.img` from `zstd` to `gzip` (matching `proxmox-auto-install-assistant 9.2`) and wrap `proxmox.iso` (with `/boot` stripped to save ~100 MiB) into a standalone CPIO archive `proxmox.iso.cpio`.
     2. In `autoexec.ipxe.j2`, pass `initrd=initrd.img initrd=proxmox.iso.cpio` on the `kernel` cmdline with matching `initrd --name initrd.img ...` and `initrd --name proxmox.iso.cpio ...` lines.
     3. Also retain `/var/lib/boot/assets/proxmox-prepared.iso` so a **single USB flash drive** can boot all 3 nodes unattended via the same HTTP answer server if UEFI PXE ever hits firmware quirks.
4. **Bug 4 — `dnsmasq.conf.j2` LAN DHCP Race Condition & Option Quoting:**
   - `dhcp-range=192.168.50.100,192.168.50.199,12h` races against the home LAN router (`192.168.50.1`) and hands out rogue leases to non-cluster devices on the LAN.
   - **Fix (Phase 3):** Use `dhcp-range=192.168.50.0,static,255.255.255.0,12h` + `dhcp-ignore=tag:!known` so `dnsmasq` answers **only** the 3 MACs in `cluster-manifest.yml`. Remove the broken quoted `dhcp-option=tag:ipxe,67,"..."`, add `{{ cluster.boot_server_ip }}` (`siaddr`) to `dhcp-boot=`, and change DHCP Option `224` → `250`.
5. **Bug 5 — Post-Install Ansible Bugs (`interfaces.j2`, `corosync.conf.j2`, `pve-base`, `pve-storage`):**
   - `interfaces.j2`: puts the static IP/gateway on `eth-mgmt` while enslaving `eth-mgmt` to `vmbr0` (which drops the node off the LAN as soon as `vmbr0` starts—IP/gateway must live on `vmbr0`), and adds `post-up ip route add 10.10.0.0/8 dev {{ link.iface }}` on both cluster links (blackholing the second link and breaking OSPF).
   - `corosync.conf.j2`: sets `ring1_addr` to `ansible_host` (`192.168.50.x`) instead of `corosync_ring1_addr` (`10.10.x.x`).
   - `pve-base/tasks/main.yml`: uses `bookworm` instead of `trixie` for PVE 9.2 apt repo, and stops `frr` when `not pve_sdn_enabled` even though `ospf_enabled: true` requires `frr`.
   - `pve-storage/tasks/main.yml`: tries to create partition 2 on `/dev/sda` (`50% 100%`), colliding with Proxmox ZFS partitions 1–3. Fix to create partition 4 (`{{ os_hdsize_gb | default(64) }}GiB 100%`) when `os_filesystem == 'zfs'` (or partition 4 on LVM).

---

## Execution Rules for SWE-2

1. **Stay strictly inside `/home/bheughan/projects/thinkcenter-cluster`.** Never write outside the repo root.
2. **Work on a dedicated branch:** `git checkout -b feat/wp5-cluster-revival` (if not already on a feature branch).
3. **Never run live commands** (`docker compose up`, `ansible-playbook` without `--syntax-check` or `00-generate-boot-config.yml` local render). All verification runs offline through `just check` and `just test`.
4. **Execute Phases 1 → 5 in order**, committing after each phase with a Conventional Commit message.

---

## Phase 1: WP5 Template Adoption & Repo Restructure (`chore(template): adopt copier-base and copier-infra-ops`)

### Step 1.1: Pre-adoption file moves
1. Create `plans/` and move `fetch_assets_justfile_plan.md` into it:
   ```bash
   mkdir -p plans
   git mv fetch_assets_justfile_plan.md plans/fetch_assets_justfile_plan.md
   ```
2. Rename the `terraform/` stub directory to `opentofu/`:
   ```bash
   git mv terraform opentofu
   ```
3. Move the existing `justfile` to `project.just`, stripping `default` (owned by `justfile`) and renaming `test` to `smoke-boot` (since `test` in `archetype.just` / `project.just` is the offline test gate). Write `project.just` with this exact content:
   ```just
   # Project-specific recipes for thinkcenter-cluster.
   # Standard verbs (setup, check, lint, fmt, doctor) live in .config/just/base.just and archetype.just.

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
   ```
4. Remove the old `justfile`, `.gitignore`, `.editorconfig`, and `ansible/ansible.cfg` before running Copier so Copier writes the canonical versions without interactive conflict prompts:
   ```bash
   git rm -f justfile .gitignore .editorconfig ansible/ansible.cfg
   ```

### Step 1.2: Apply `copier-base` and `copier-infra-ops`
Run `just -g adopt . --archetype infra-ops` (or if running `copier` directly, use the exact command below):
```bash
just -g adopt . --archetype infra-ops
```
Then append project-specific ignores to `.gitignore`:
```gitignore

# thinkcenter-cluster generated boot & ansible artifacts
boot/assets/
boot/dnsmasq/dnsmasq.conf
boot/ipxe/autoexec.ipxe
ansible/inventory/host_vars/*.yml
ansible/inventory/known_hosts
*.iso
*.cpio
*.img
*.kpxe
*.efi
```

### Step 1.3: Split `.agents/AGENTS.md` into ADRs, Investigation Doc, and `.agents/project.md`
1. Create `docs/adr/0001-pve-9-2-and-ceph-tentacle.md` through `docs/adr/0006-fnox-rbw-secrets.md` (concise ADRs covering the key rows from the old `.agents/AGENTS.md` table: PVE 9.2 + Ceph Tentacle, single-SSD ZFS/LVM + Ceph OSD interim storage with `hdsize` cap, 3-node full-mesh FRR OSPF cluster fabric, udev bus-path NIC naming, Hyper-V Alpine boot VM + HTTP answer server, and `fnox` + `rbw` secrets replacing SOPS).
2. Create `docs/investigations/pxe-uefi.md` preserving the historical PXE/UEFI debugging timeline from `.agents/AGENTS.md` and documenting the root causes found in this plan (`nginx` POST directory index, unquoted TOML in `proxmox-answer.toml.j2`, UEFI iPXE CPIO header requirement for `proxmox.iso.cpio`, and `dnsmasq` static MAC-only mode).
3. Write `.agents/project.md` with the updated File Ownership Map (referencing `boot/server/boot_http_server.py`, `cluster-manifest.yml`, `00-generate-boot-config.yml`, `fnox.toml`), the network planes table (`eth-mgmt` on `vmbr0`, `eth-cluster-a`, `eth-cluster-b`), and the rule that agents must never run `just up`, `just standup`, `just bootstrap`, or `just site` directly.
4. Delete `.agents/AGENTS.md` (`git rm -f .agents/AGENTS.md`). Confirm `wc -l < AGENTS.md` is `<= 40`.

### Step 1.4: Configure `.omp/permissions.json` and `.agents/sandbox.toml`
Write `.omp/permissions.json`:
```json
{
  "allow": [
    "just check",
    "just lint",
    "just test",
    "just fmt",
    "just configure",
    "just --list",
    "just status",
    "bash tests/*"
  ],
  "ask": [
    "just setup",
    "just doctor",
    "just plan*",
    "just smoke*"
  ],
  "deny": [
    "just up*",
    "just standup*",
    "just bootstrap*",
    "just site*",
    "docker compose*"
  ]
}
```
Update `.agents/sandbox.toml` so `allow_private = ["192.168.50.0/24"]`.

---

## Phase 2: Migrate Secrets from SOPS to `fnox` (`feat(secrets): replace sops with fnox and env lookups`)

1. Delete SOPS files and the broken self-hosted workflows:
   ```bash
   git rm -rf .sops.yaml ansible/secrets .github/workflows/lint.yml .github/workflows/sops-check.yml
   ```
2. Update `fnox.toml` to declare the cluster secrets (with `provider = "vault"`):
   ```toml
   #:schema https://fnox.jdx.dev/schema.json
   root = true
   import = [".config/fnox/provider.toml"]
   default_provider = "vault"
   env = "exec"
   if_missing = "error"

   [secrets]
   # Bitwarden: folder "proj", item "thinkcenter-cluster", custom fields below.
   PROXMOX_ROOT_PASSWORD = { provider = "vault", value = "thinkcenter-cluster/PROXMOX_ROOT_PASSWORD" }
   PROXMOX_API_TOKEN_ID = { provider = "vault", value = "thinkcenter-cluster/PROXMOX_API_TOKEN_ID" }
   PROXMOX_API_TOKEN_SECRET = { provider = "vault", value = "thinkcenter-cluster/PROXMOX_API_TOKEN_SECRET" }
   ```
3. In `ansible/playbooks/00-generate-boot-config.yml`:
   - Remove the `Check if secrets file exists` and `Load decrypted SOPS secrets if present` tasks.
   - Pass `proxmox_root_password: "{{ lookup('env', 'PROXMOX_ROOT_PASSWORD') | default('ProxmoxDefault123!', true) }}"` and `proxmox_ssh_public_key: "{{ lookup('env', 'PROXMOX_SSH_PUBLIC_KEY') | default('', true) }}"`.
4. Verify with `rg -i 'sops' ansible/ boot/ .github/ project.just` that zero SOPS references remain in code/configs.

---

## Phase 3: Fix PXE / UEFI Boot, Answer Server & Validated Answer TOML (`fix(boot): fix uefi pxe cpio, answer server, and answer toml schema`)

### Step 3.1: Fix `ansible/roles/pve-base/templates/proxmox-answer.toml.j2`
Replace `ansible/roles/pve-base/templates/proxmox-answer.toml.j2` with valid PVE 9.2 kebab-case TOML that quotes all strings, formats `disk-list` as a TOML array of device names (`["sda"]`, stripping `/dev/`), sets `zfs.raid = "raid0"`, caps the OS partition size via `zfs.hdsize` (`{{ item.os_hdsize_gb | default(64) }}`) so the rest of the SSD remains free for the Ceph OSD partition, and caps ZFS ARC at install time (`zfs.arc-max = {{ item.zfs_arc_max_mb }}`):

```toml
# Auto-generated from cluster-manifest.yml via Ansible 00-generate-boot-config.yml
# DO NOT EDIT DIRECTLY — Edit cluster-manifest.yml at root instead

[global]
keyboard = "en-us"
country = "us"
fqdn = "{{ item.name }}.{{ cluster.domain }}"
mailto = "root@{{ cluster.domain }}"
timezone = "{{ cluster.timezone | default('America/New_York') }}"
root-password = "{{ proxmox_root_password | default('ProxmoxDefault123!', true) }}"
{% if proxmox_ssh_public_key | default('', true) | length > 0 %}
root-ssh-keys = [
    "{{ proxmox_ssh_public_key }}"
]
{% endif %}

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "{{ item.os_filesystem | default('zfs') }}"
disk-list = ["{{ item.os_disk | regex_replace('^/dev/', '') }}"]
{% if (item.os_filesystem | default('zfs')) == 'zfs' %}
zfs.raid = "raid0"
zfs.hdsize = {{ item.os_hdsize_gb | default(64) }}
zfs.arc-max = {{ item.zfs_arc_max_mb | default(512) }}
zfs.compress = "zstd"
{% else %}
lvm.hdsize = {{ item.os_hdsize_gb | default(64) }}
lvm.swapsize = 0
lvm.maxvz = 0
{% endif %}
```

### Step 3.2: Add a Lightweight Python HTTP Answer & Asset Server (`boot/server/boot_http_server.py`)
Why: `proxmox-fetch-answer` sends `POST /assets/answers/` (or `POST /answer`) with a JSON body containing `mac_addresses` (PVE 9.x) or `network_interfaces` (PVE 8.x). Static `nginx` cannot parse JSON POST bodies to pick the right `<mac>.toml` file, and returns an HTML directory index on `POST /assets/answers/`.
1. Create `boot/server/boot_http_server.py` using only Python 3 standard library (`http.server`, `json`, ` pathlib`):
   - `GET /<path>` and `HEAD /<path>`: serves static files from `/var/lib/boot` (supporting `Range` requests and streaming for `linux26`, `initrd.img`, `proxmox.iso.cpio`, `autoexec.ipxe`). If a `GET` or `POST` directly requests `/assets/answers/<file>.toml`, returns that `.toml` file with `Content-Type: application/toml`.
   - `POST /assets/answers/`, `POST /assets/answers`, or `POST /answer`:
     - Parses JSON body (if non-empty). Extracts candidate MACs from `data.get("mac_addresses", [])` and `[nic.get("mac") for nic in data.get("network_interfaces", []) if isinstance(nic, dict) and "mac" in nic]`.
     - Normalizes each MAC to lowercase hyphenated (`80-86-f2-18-55-b6.toml`) and colon-separated (`80:86:f2:18:55:b6.toml`) and checks `/var/lib/boot/assets/answers/`.
     - If a matching `<mac>.toml` exists, returns `200 OK` with its TOML content (`Content-Type: application/toml`).
     - Otherwise falls back to `/var/lib/boot/assets/answers/default.toml` (if present) or returns `404 Not Found` with a clear diagnostic log message showing the received MACs!
2. Update `00-generate-boot-config.yml` to also copy `pve01.toml` (or render a `default.toml` template) and render `ansible/inventory/known_hosts` placeholder/entries from `cluster-manifest.yml`.
3. Update `boot/docker-compose.yml` so the `nginx` service (keep service name `nginx` or alias `boot-http` so `just logs nginx` and `just up` keep working) runs `python:3.12-alpine` with `python3 /srv/boot_http_server.py --root /var/lib/boot --port 8080`.

### Step 3.3: Fix UEFI iPXE + `proxmox.iso.cpio` Packaging (`autoexec.ipxe.j2` & `fetch-assets.sh`)
1. Update `ansible/roles/pve-base/templates/autoexec.ipxe.j2`:
   ```ipxe
   #!ipxe
   echo Booting Proxmox VE {{ cluster.pve_version }} automated installer over HTTP...
   kernel http://{{ cluster.boot_server_ip }}:8080/assets/linux26 initrd=initrd.img initrd=proxmox.iso.cpio ramdisk_size=16777216 vga=788 ip=any:dhcp splash=verbose proxmox-start-auto-installer || goto failed
   initrd --name initrd.img http://{{ cluster.boot_server_ip }}:8080/assets/initrd.img || goto failed
   initrd --name proxmox.iso.cpio http://{{ cluster.boot_server_ip }}:8080/assets/proxmox.iso.cpio || goto failed
   boot || goto failed

   :failed
   echo iPXE boot failed. Dropping to shell in 10 seconds...
   sleep 10
   shell
   ```
   *(Why this fixes UEFI PXE: `--name initrd.img` and `--name proxmox.iso.cpio` register virtual EFI files matching `initrd=initrd.img initrd=proxmox.iso.cpio` on the kernel cmdline, and because `proxmox.iso.cpio` has a valid `070701` `newc` CPIO header, the Linux kernel unpacks `/proxmox.iso` into the rootfs RAM disk without needing a single contiguous 1.75 GB buffer or BIOS-only iPXE magic!)*
2. Update `boot/prepare-pxe/prepare-pxe-entrypoint.sh` and `boot/scripts/fetch-assets.sh`:
   - In `prepare-pxe-entrypoint.sh`, after `proxmox-auto-install-assistant prepare-iso` produces the prepared `.iso`:
     - Extract `/boot/linux26` → `vmlinuz` and `/boot/initrd.img`.
     - If `initrd.img` is `zstd`-compressed (`file initrd.img | grep -qi zstd` or `zstd -t initrd.img`), recompress it to `gzip` (`zstd -d -c initrd.img | gzip -1 > initrd.img.gz && mv initrd.img.gz initrd.img`) so all iPXE builds can handle it.
     - Keep a copy of the full prepared ISO at `/assets/proxmox-prepared.iso` (so the user can also `dd` it to a USB drive as a zero-friction fallback that still fetches per-MAC answers over HTTP!).
     - Create a slimmed copy `proxmox.iso` (removing `/boot` via `xorriso -indev ... -outdev ... -rm_r /boot` to save ~100 MiB RAM on the 8 GB nodes) and pack it into `/assets/proxmox.iso.cpio` via `(cd "${PREPARED}" && echo "proxmox.iso" | cpio -H newc -o > "/assets/proxmox.iso.cpio")`.
   - Remove the broken `cpio -H newc -o >> "${ASSETS_DIR}/initrd.img"` concatenation from `boot/scripts/fetch-assets.sh`.

### Step 3.4: Fix `dnsmasq.conf.j2` for Safe LAN Operation
Update `ansible/roles/pve-base/templates/dnsmasq.conf.j2`:
- Change `dhcp-range=...` to static MAC-only mode so `dnsmasq` never answers non-cluster devices on the home LAN:
  ```ini
  interface=eth0
  bind-dynamic
  dhcp-range={{ cluster.management_subnet | ansible.utils.ipaddr('network') }},static,{{ cluster.management_subnet | ansible.utils.ipaddr('netmask') }},12h
  dhcp-ignore=tag:!known
  dhcp-option=option:router,{{ cluster.management_gateway }}
  dhcp-option=option:dns-server,{{ cluster.dns_server }}
  dhcp-option=option:domain-name,{{ cluster.domain }}

  # Proxmox HTTP answer URL via DHCP Option 250 (per-node and global fallback)
  dhcp-option=250,http://{{ cluster.boot_server_ip }}:8080/assets/answers/
  ```
- For each node in `nodes`:
  ```ini
  dhcp-host={{ item.mac }},set:{{ item.name }},{{ item.ip }},{{ item.name }},12h
  ```
- Fix `dhcp-boot` lines (include `{{ cluster.boot_server_ip }}` as `siaddr` and remove the broken quoted `dhcp-option=tag:ipxe,67,"..."` line):
  ```ini
  dhcp-match=set:ipxe,175
  dhcp-match=set:efi-x86_64,option:client-arch,7
  dhcp-match=set:efi-x86_64,option:client-arch,9

  dhcp-boot=tag:!ipxe,tag:!efi-x86_64,undionly.kpxe,,{{ cluster.boot_server_ip }}
  dhcp-boot=tag:!ipxe,tag:efi-x86_64,ipxe.efi,,{{ cluster.boot_server_ip }}
  dhcp-boot=tag:ipxe,http://{{ cluster.boot_server_ip }}:8080/autoexec.ipxe
  ```

---

## Phase 4: Fix Post-Install Ansible Bugs & Economize Resources for Power-Limited Xeon M910q Nodes (`feat(ansible): fix network/corosync/storage bugs and add low-power xeon tuning`)

### Step 4.1: Economize RAM, Disk, and Power in `cluster-manifest.yml` & `group_vars`
1. In `cluster-manifest.yml`:
   - Add `os_filesystem: "zfs"` (with comment noting `"ext4"` can be chosen to save 512–1024 MB of ZFS ARC RAM on 8 GB nodes) and `os_hdsize_gb: 64` to each node in `nodes:` (reserving 64 GiB for Proxmox OS and leaving ~860 GiB of the 1 TB SSD unpartitioned for Ceph OSD).
   - Reduce `zfs_arc_max_mb` on the two 8 GB nodes (`pve02`, `pve03`) from `1024` to `512` (and `1024` on 16 GB `pve01`), freeing **512 MB of RAM** on each 8 GB node for Kubernetes VMs (since VM disks live on Ceph RBD, not local ZFS).
   - Add power/resource economy settings under `cluster:`:
     ```yaml
     cpu_governor: "powersave"          # intel_pstate powersave + balance_power EPP (~8-10W idle on Xeon)
     enable_zram_swap: true             # 2GB zstd compressed RAM swap to prevent OOM during Ceph/K8s spikes
     disable_unused_pve_services: true  # Stop spiceproxy and pve-ha-lrm/crm (K8s handles workload HA)
     ```
2. In `ansible/inventory/group_vars/proxmox_nodes.yml`:
   - Lower `ceph_osd_memory_target` from `"1073741824"` (1 GiB) to `"805306368"` (768 MiB) so Ceph OSD + MON fits comfortably alongside a 4 GB Kubernetes VM on the 8 GB nodes.
   - Set `pve_ha_enabled: false` by default (Kubernetes handles pod/workload failover; disabling `pve-ha-crm` and `pve-ha-lrm` stops constant 10-second disk writes and saves CPU/RAM).

### Step 4.2: Fix `pve-base`, `pve-network`, `pve-storage`, `pve-cluster`, and `01-bootstrap.yml`
1. **`ansible/playbooks/01-bootstrap.yml`:**
   - Replace hardcoded `192.168.50.10..12` in `/etc/hosts` block with a Jinja loop over `groups['proxmox_nodes']` using `hostvars[host]['ansible_host']` and `cluster_domain`.
2. **`ansible/roles/pve-base/tasks/main.yml`:**
   - Fix PVE 9.2 no-subscription repository from `bookworm` to `trixie` (`deb http://download.proxmox.com/debian/pve trixie pve-no-subscription`).
   - Install `zram-tools` and `cpufrequtils` (alongside `frr`, `frr-pythontools`, `ethtool`, `iperf3`, `lm-sensors`).
   - Configure `/etc/default/zramswap` (`ALGO=zstd`, `PERCENT=25`, `PRIORITY=100`) when `enable_zram_swap | default(true)` to give the 8 GB nodes ~2 GB of fast compressed-RAM swap cushion.
   - Set CPU scaling governor to `{{ cpu_governor | default('powersave') }}` across `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` (with `ignore_errors: true` in case a container/VM lacks cpufreq) to keep the 6-core Xeon cool and power-limited at idle.
   - Disable `spiceproxy` (and `pve-ha-crm` / `pve-ha-lrm` when `not pve_ha_enabled`) to save ~150 MB RAM and background CPU wakeups.
   - Fix the `Disable FRR globally` task condition to `when: not pve_sdn_enabled and not ospf_enabled` so it never stops `frr` when OSPF cluster routing is enabled!
3. **`ansible/roles/pve-network/templates/interfaces.j2`:**
   - Fix the Linux bridge configuration so `{{ nic_mgmt }}` is `inet manual` and `vmbr0` holds `inet static`, `address {{ ansible_host }}/{{ management_subnet.split('/')[1] }}`, and `gateway {{ management_gateway }}`.
   - Remove the broken `post-up ip route add {{ ceph_network_cluster }} dev {{ link.iface }} scope link || true` line from the cluster fabric loop (FRR OSPF handles routing across the `/30` mesh links).
4. **`ansible/roles/pve-cluster/templates/corosync.conf.j2`:**
   - Fix line 28 so `ring1_addr` uses `{{ hostvars[host]['corosync_ring1_addr'] }}` instead of `{{ hostvars[host]['ansible_host'] }}`.
5. **`ansible/roles/pve-storage/tasks/main.yml` + `cluster-manifest.yml`:**
   - Because Proxmox ZFS (and LVM EFI) creates partitions 1 (BIOS boot), 2 (EFI ESP), and 3 (OS ZFS `rpool` / LVM capped at `os_hdsize_gb: 64` GiB), update `ceph_osd_partition` in `cluster-manifest.yml` from `/dev/sda2` to `/dev/sda4`, and update `pve-storage/tasks/main.yml` to check for `ceph_osd_partition` (`ansible.builtin.stat: path: "{{ ceph_osd_partition }}"`) and create partition 4 (`parted -s {{ ceph_osd_disk }} -- mkpart ceph-osd {{ os_hdsize_gb | default(64) }}GiB 100%` + `partprobe {{ ceph_osd_disk }}`) when `ceph_osd_partition` does not exist yet!

---

## Phase 5: Offline Mocked Test Suite (`test(mock): add offline mocked test suite for boot server, manifest, and playbooks`)

Create `tests/run-mock-suite.sh` (executable, invoked by `just test` and `just check`) that tests the entire pipeline offline with mocked binaries/containers:

1. **Test 1 — Manifest & Boot Config Rendering (`00-generate-boot-config.yml`):**
   - Runs `ansible-playbook ansible/playbooks/00-generate-boot-config.yml` locally.
   - Asserts `boot/dnsmasq/dnsmasq.conf`, `boot/ipxe/autoexec.ipxe`, `boot/assets/answers/{pve01,pve02,pve03}.toml`, `boot/assets/answers/80-86-f2-18-55-b6.toml`, and `ansible/inventory/host_vars/{pve01,pve02,pve03}.yml` exist.
2. **Test 2 — Proxmox Answer File TOML & Schema Validator:**
   - Runs a Python 3 script using `tomllib` to parse every `.toml` file in `boot/assets/answers/`.
   - Asserts required PVE 9.2 schema fields and types:
     - `global.keyboard`, `global.country`, `global.fqdn`, `global.mailto` (contains `@`), `global.timezone`, `global.root-password` are strings.
     - `network.source == "from-dhcp"`.
     - `disk-setup.filesystem in ("zfs", "ext4", "xfs", "btrfs")`.
     - `disk-setup.disk-list` is a non-empty `list` of strings with no `/dev/` prefix (e.g., `["sda"]`).
     - `disk-setup.zfs.raid in ("raid0", "raid1", "raid10", "raidz-1", "raidz-2", "raidz-3")`.
     - `disk-setup.zfs.hdsize` is an `int` between `16` and `500` (proving space is reserved for Ceph OSD).
3. **Test 3 — `dnsmasq.conf` and `autoexec.ipxe` Invariant Checks:**
   - Asserts `boot/ipxe/autoexec.ipxe` starts with `#!ipxe` on line 1, contains `initrd=initrd.img initrd=proxmox.iso.cpio`, and contains `initrd --name proxmox.iso.cpio`.
   - Asserts `boot/dnsmasq/dnsmasq.conf` uses `static` mode (`dhcp-ignore=tag:!known`), sets DHCP Option `250`, has no quoted URL in `dhcp-boot=tag:ipxe,http://...`, and maps all 3 MAC addresses from `cluster-manifest.yml`.
4. **Test 4 — Live Ephemeral Test of `boot/server/boot_http_server.py` (Mocked PXE & `proxmox-fetch-answer` Client):**
   - Creates dummy `/assets/linux26`, `/assets/initrd.img`, and `/assets/proxmox.iso.cpio` files in a temp root alongside the rendered `autoexec.ipxe` and `assets/answers/*.toml`.
   - Starts `python3 boot/server/boot_http_server.py` on an ephemeral localhost port (`127.0.0.1:<port>`).
   - Simulates iPXE `GET /autoexec.ipxe`, `GET /assets/linux26`, `GET /assets/initrd.img`, `GET /assets/proxmox.iso.cpio`.
   - Simulates `proxmox-fetch-answer` `POST /assets/answers/` with PVE 9.2 JSON body `{"mac_addresses": ["aa:bb:cc:dd:ee:ff", "80:86:f2:18:55:b6"]}` and asserts the HTTP 200 response parses via `tomllib` and has `fqdn == "pve01.cluster.local"`.
   - Simulates `proxmox-fetch-answer` `POST /assets/answers/` for `pve02` (`80:86:f2:18:01:02`) and `pve03` (`80:86:f2:18:01:03`) and asserts each receives its own hostname and disk/RAM config.
   - Simulates an unknown MAC and asserts clean `404` (or `default.toml` fallback if configured).
5. **Test 5 — Mocked `fetch-assets.sh` Execution (No Network / No Real 1.6 GB ISO Needed):**
   - Runs `fetch-assets.sh` in a temporary directory with mocked `curl`/`xorriso`/`proxmox-auto-install-assistant` on `PATH` (generating a synthetic tiny `zstd`-compressed `initrd.img` and dummy `.iso`) and verifies `fetch-assets.sh` produces a `gzip`-compressed `initrd.img` and a valid `070701` CPIO archive `proxmox.iso.cpio` containing `proxmox.iso`!
6. **Test 6 — Ansible Template Rendering & Playbook Syntax Check:**
   - Renders `interfaces.j2`, `frr-ospf.conf.j2`, and `corosync.conf.j2` against the generated `host_vars` for `pve01..03` and asserts:
     - `vmbr0` (not `eth-mgmt`) holds `address 192.168.50.10/24` and `gateway 192.168.50.1`.
     - `interfaces` does **not** contain `ip route add 10.10.0.0/8`.
     - `corosync.conf` has `ring0_addr: 192.168.50.10` and `ring1_addr: 10.10.12.1` (distinct rings!).
   - Runs `ansible-playbook --syntax-check ansible/playbooks/*.yml`.

---

## Phase 6: Document the Hyperconverged K8s + Home Assistant Target Architecture (`docs/k8s-hyperconverged-roadmap.md`)

Add a concise `docs/k8s-hyperconverged-roadmap.md` (and link it from `README.md`) recording the exact resource-economized target architecture for the 3× M910q Xeon cluster (`32 GB` total RAM):

| Node | Host RAM | Host Overhead (PVE + ZFS 512M + Ceph OSD 768M + MON 512M) | K8s VM Allocation (k3s / Talos) | Headroom / zram |
|---|---|---|---|---|
| `pve01` | 16 GB | ~2.8 GB | `k8s-01`: **8 GB RAM**, 4 vCPU (control-plane + worker + Home Assistant / Postgres) | ~5.2 GB + 4 GB zram |
| `pve02` | 8 GB | ~2.6 GB | `k8s-02`: **4 GB RAM**, 3 vCPU (control-plane + worker) | ~1.4 GB + 2 GB zram |
| `pve03` | 8 GB | ~2.6 GB | `k8s-03`: **4 GB RAM**, 3 vCPU (control-plane + worker) | ~1.4 GB + 2 GB zram |

Key architectural rules for Stage 2 (Kubernetes on top):
- **Single Ceph layer:** Use `ceph-csi` RBD inside Kubernetes pointing at the existing Proxmox Ceph `vm-pool`. **Never** deploy a second Rook-Ceph cluster inside the VMs.
- **Single Kubernetes distribution:** Use **k3s** (or **Talos Linux**) with embedded etcd across the 3 VMs, provisioned via OpenTofu (`bpg/proxmox` in `opentofu/`).
- **Home Assistant USB passthrough (Zigbee/Z-Wave/Thread):** Use either a network PoE coordinator (SLZB-06 over LAN, which allows Home Assistant pods to fail over freely across `pve01..03` without USB host pinning) or Proxmox USB passthrough to `k8s-01`.

---

## Final Gate Before Reporting Done

SWE-2 must run and report the output of:
```bash
just check
just test
just doctor
```
All three commands must exit `0` offline without requiring Docker daemons, sudo, Bitwarden vault access, or live Proxmox nodes.
