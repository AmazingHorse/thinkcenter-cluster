#!/usr/bin/env bash
# fetch-assets.sh — download and verify Proxmox VE ISO + iPXE binaries
# Run this before starting the boot stack.
# Requires: curl, sha256sum

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="${SCRIPT_DIR}/../matchbox/assets"
mkdir -p "${ASSETS_DIR}"

# ── Version pin (keep in sync with ansible/inventory/group_vars/all.yml) ─────
PVE_ISO="proxmox-ve_9.2-1.iso"
PVE_URL="https://enterprise.proxmox.com/iso/${PVE_ISO}"
# CONFIGURE: update sha256 from https://www.proxmox.com/en/downloads
PVE_SHA256="REPLACE_WITH_OFFICIAL_SHA256"

IPXE_URL="https://boot.ipxe.org/undionly.kpxe"
IPXE_EFI_URL="https://boot.ipxe.org/ipxe.efi"

# ── Helpers ───────────────────────────────────────────────────────────────────
fetch_if_missing() {
  local url="$1" dest="$2"
  if [[ -f "${dest}" ]]; then
    echo "  [skip] $(basename "${dest}") already present"
  else
    echo "  [fetch] $(basename "${dest}")"
    curl -fL --progress-bar -o "${dest}" "${url}"
  fi
}

verify_sha256() {
  local file="$1" expected="$2"
  if [[ "${expected}" == "REPLACE_WITH_OFFICIAL_SHA256" ]]; then
    echo "  [warn] SHA256 not configured — skipping verification for $(basename "${file}")"
    echo "         Update PVE_SHA256 in this script and re-run to enable verification."
    return 0
  fi
  echo "  [verify] $(basename "${file}")"
  echo "${expected}  ${file}" | sha256sum --check --quiet
  echo "  [ok] checksum verified"
}

# ── Fetch ─────────────────────────────────────────────────────────────────────
echo "==> Fetching Proxmox VE ISO"
fetch_if_missing "${PVE_URL}" "${ASSETS_DIR}/${PVE_ISO}"
verify_sha256 "${ASSETS_DIR}/${PVE_ISO}" "${PVE_SHA256}"

echo "==> Fetching iPXE binaries"
fetch_if_missing "${IPXE_URL}" "${ASSETS_DIR}/undionly.kpxe"
fetch_if_missing "${IPXE_EFI_URL}" "${ASSETS_DIR}/ipxe.efi"

echo ""
echo "Assets ready in ${ASSETS_DIR}:"
ls -lh "${ASSETS_DIR}"
