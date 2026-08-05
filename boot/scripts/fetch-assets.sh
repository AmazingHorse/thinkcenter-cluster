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
IPXE_SNP_URL="https://boot.ipxe.org/x86_64-efi/snponly.efi"

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
fetch_if_missing "${IPXE_SNP_URL}" "${ASSETS_DIR}/snponly.efi"

echo "==> Extracting Proxmox kernel & initrd from ISO"
if [[ ! -f "${ASSETS_DIR}/linux26" || ! -f "${ASSETS_DIR}/initrd.img" ]]; then
  if command -v 7z >/dev/null 2>&1; then
    echo "  [extract] extracting boot/linux26 and boot/initrd.img using 7z..."
    7z x -y "${ASSETS_DIR}/${PVE_ISO}" boot/linux26 boot/initrd.img -o"${ASSETS_DIR}" >/dev/null
    mv "${ASSETS_DIR}/boot/linux26" "${ASSETS_DIR}/linux26"
    mv "${ASSETS_DIR}/boot/initrd.img" "${ASSETS_DIR}/initrd.img"
    echo "  [pxe] embedding ISO payload as proxmox.iso into initrd.img (fast zstd)..."
    if command -v cpio >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1; then
      (cd "${ASSETS_DIR}" && ln -f "${PVE_ISO}" proxmox.iso && echo "proxmox.iso" | cpio -H newc -o | zstd -1 -T0 >> "initrd.img" && rm -f proxmox.iso)
      echo "  [ok] proxmox.iso zstd-compressed and appended to initrd.img (size should now be ~1.6GB)"
    else
      echo "  [warn] cpio or zstd not found. Install with: apk add cpio zstd"
    fi
    echo "  [ok] kernel and initrd extracted"
  else
    echo "  [warn] 7z (p7zip) not found. Install with: apk add p7zip"
  fi
else
  echo "  [skip] linux26 and initrd.img already present"
fi

echo ""
echo "Assets ready in ${ASSETS_DIR}:"
ls -lh "${ASSETS_DIR}"
