#!/usr/bin/env bash
# fetch-assets.sh — download and verify Proxmox VE ISO + iPXE binaries
# Reads version and SHA256 directly from cluster-manifest.yml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${SCRIPT_DIR}/../../cluster-manifest.yml"
ASSETS_DIR="${SCRIPT_DIR}/../matchbox/assets"
mkdir -p "${ASSETS_DIR}"

# ── Parse manifest ────────────────────────────────────────────────────────────
if [[ -f "${MANIFEST_FILE}" ]]; then
  PVE_VERSION=$(grep 'pve_version:' "${MANIFEST_FILE}" | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
  PVE_SHA256=$(grep 'pve_iso_sha256:' "${MANIFEST_FILE}" | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
else
  PVE_VERSION="9.2"
  PVE_SHA256="REPLACE_WITH_OFFICIAL_SHA256"
fi

PVE_ISO="proxmox-ve_${PVE_VERSION}-1.iso"
PVE_URL="https://enterprise.proxmox.com/iso/${PVE_ISO}"

IPXE_URL="https://boot.ipxe.org/undionly.kpxe"
IPXE_EFI_URL="https://boot.ipxe.org/x86_64-efi/ipxe.efi"

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
  if [[ "${expected}" == "REPLACE_WITH_OFFICIAL_SHA256" || -z "${expected}" ]]; then
    echo "  [warn] SHA256 not configured in cluster-manifest.yml — skipping verification for $(basename "${file}")"
    echo "         Update pve_iso_sha256 in cluster-manifest.yml to enable verification."
    return 0
  fi
  echo "  [verify] $(basename "${file}")"
  echo "${expected}  ${file}" | sha256sum -c > /dev/null
  echo "  [ok] checksum verified"
}

# ── Fetch ─────────────────────────────────────────────────────────────────────
echo "==> Fetching Proxmox VE ISO (${PVE_ISO})"
fetch_if_missing "${PVE_URL}" "${ASSETS_DIR}/${PVE_ISO}"
verify_sha256 "${ASSETS_DIR}/${PVE_ISO}" "${PVE_SHA256}"

echo "==> Fetching iPXE binaries"
fetch_if_missing "${IPXE_URL}" "${ASSETS_DIR}/undionly.kpxe"
fetch_if_missing "${IPXE_EFI_URL}" "${ASSETS_DIR}/ipxe.efi"

echo ""
echo "Assets ready in ${ASSETS_DIR}:"
ls -lh "${ASSETS_DIR}"
