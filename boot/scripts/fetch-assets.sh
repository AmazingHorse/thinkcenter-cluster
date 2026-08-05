#!/usr/bin/env bash
# fetch-assets.sh — download and verify Proxmox VE ISO + iPXE binaries
# Reads version and SHA256 directly from cluster-manifest.yml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${SCRIPT_DIR}/../../cluster-manifest.yml"
ASSETS_DIR="${SCRIPT_DIR}/../assets"
mkdir -p "${ASSETS_DIR}"

# ── Parse manifest ────────────────────────────────────────────────────────────
if [[ ! -f "${MANIFEST_FILE}" ]]; then
  echo "ERROR: Manifest file not found at ${MANIFEST_FILE}" >&2
  echo "Please create cluster-manifest.yml at repo root before running fetch-assets.sh." >&2
  exit 1
fi

PVE_VERSION=$(grep 'pve_version:' "${MANIFEST_FILE}" | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
PVE_SHA256=$(grep 'pve_iso_sha256:' "${MANIFEST_FILE}" | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
BOOT_SERVER_IP=$(grep 'boot_server_ip:' "${MANIFEST_FILE}" | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")

if [[ -z "${PVE_VERSION}" ]]; then
  echo "ERROR: pve_version not found in ${MANIFEST_FILE}" >&2
  exit 1
fi

if [[ -z "${BOOT_SERVER_IP}" ]]; then
  echo "ERROR: boot_server_ip not found in ${MANIFEST_FILE}" >&2
  exit 1
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
    curl -fL --progress-bar -C - -o "${dest}" "${url}" || curl -fL --progress-bar -o "${dest}" "${url}"
  fi
}

verify_sha256() {
  local file="$1" expected="$2"
  if [[ "${expected}" == "REPLACE_WITH_OFFICIAL_SHA256" || -z "${expected}" ]]; then
    echo "  [warn] SHA256 not configured in cluster-manifest.yml — skipping verification for $(basename "${file}")"
    return 0
  fi
  echo "  [verify] $(basename "${file}")"
  if echo "${expected}  ${file}" | sha256sum -c > /dev/null 2>&1; then
    echo "  [ok] checksum verified"
    return 0
  else
    echo "  [fail] checksum mismatch for $(basename "${file}")"
    return 1
  fi
}

fetch_and_verify_iso() {
  local url="$1" dest="$2" expected_sha="$3"
  if [[ -f "${dest}" ]]; then
    if verify_sha256 "${dest}" "${expected_sha}"; then
      echo "  [skip] $(basename "${dest}") already present and verified"
      return 0
    else
      echo "  [clean] removing corrupted/partial file $(basename "${dest}")"
      rm -f "${dest}"
      # Also remove extracted kernel/initrd so they are re-extracted from valid ISO
      rm -f "${ASSETS_DIR}/linux26" "${ASSETS_DIR}/initrd.img"
    fi
  fi

  echo "  [fetch] downloading $(basename "${dest}")"
  curl -fL --progress-bar -C - -o "${dest}" "${url}" || curl -fL --progress-bar -o "${dest}" "${url}"
  verify_sha256 "${dest}" "${expected_sha}"
}

# ── Fetch ─────────────────────────────────────────────────────────────────────
echo "==> Fetching Proxmox VE ISO (${PVE_ISO})"
fetch_and_verify_iso "${PVE_URL}" "${ASSETS_DIR}/${PVE_ISO}" "${PVE_SHA256}"

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
    echo "  [pxe] embedding ISO payload & proxmox-auto-installer-mode into initrd.img (fast zstd)..."
    cat <<EOF > "${ASSETS_DIR}/proxmox-auto-installer-mode"
mode = "http"

[http]
url = "http://${BOOT_SERVER_IP}:8080/assets/answers/"
EOF
    if command -v cpio >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1; then
      (cd "${ASSETS_DIR}" && ln -f "${PVE_ISO}" proxmox.iso && printf "proxmox.iso\n" | cpio -H newc -o | zstd -1 -T0 >> "initrd.img" && printf "proxmox-auto-installer-mode\n" | cpio -H newc -o >> "initrd.img" && rm -f proxmox.iso proxmox-auto-installer-mode)
      echo "  [ok] proxmox.iso & proxmox-auto-installer-mode appended to initrd.img"
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
