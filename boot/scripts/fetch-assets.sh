#!/usr/bin/env bash
# fetch-assets.sh — download and verify Proxmox VE ISO + iPXE binaries,
# then use proxmox-auto-install-assistant inside a Debian container to
# produce a prepared vmlinuz + initrd.img for PXE HTTP answer fetching.
#
# Requires: docker, curl, sha256sum
# No longer requires: 7z, cpio, zstd, xorriso (all moved into the container)

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

ANSWER_URL="http://${BOOT_SERVER_IP}:8080/assets/answers/"

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
      rm -f "${ASSETS_DIR}/linux26" "${ASSETS_DIR}/initrd.img"
    fi
  fi

  echo "  [fetch] downloading $(basename "${dest}")"
  curl -fL --progress-bar -C - -o "${dest}" "${url}" || curl -fL --progress-bar -o "${dest}" "${url}"
  verify_sha256 "${dest}" "${expected_sha}"
}

# ── Fetch ISO ─────────────────────────────────────────────────────────────────
echo "==> Fetching Proxmox VE ISO (${PVE_ISO})"
fetch_and_verify_iso "${PVE_URL}" "${ASSETS_DIR}/${PVE_ISO}" "${PVE_SHA256}"

echo "==> Fetching iPXE binaries"
fetch_if_missing "${IPXE_URL}"     "${ASSETS_DIR}/undionly.kpxe"
fetch_if_missing "${IPXE_EFI_URL}" "${ASSETS_DIR}/ipxe.efi"
fetch_if_missing "${IPXE_SNP_URL}" "${ASSETS_DIR}/snponly.efi"

# ── Prepare PXE kernel + initrd via proxmox-auto-install-assistant ────────────
# The stock ISO's initrd.img does NOT support HTTP answer fetching.
# proxmox-auto-install-assistant prepare-iso --pxe produces a vmlinuz/initrd.img
# pair that has the fetch-from-http logic compiled in.
#
# We run it inside a debian:bookworm container so the host only needs Docker.
echo "==> Preparing PXE kernel + initrd via proxmox-auto-install-assistant"

if [[ -f "${ASSETS_DIR}/linux26" && -f "${ASSETS_DIR}/initrd.img" ]]; then
  echo "  [skip] linux26 and initrd.img already present (delete to re-prepare)"
else
  echo "  [info] answer URL baked in: ${ANSWER_URL}"
  echo "  [info] pulling debian:bookworm and installing proxmox-auto-install-assistant..."

  # Absolute host path that Docker can mount (resolve symlinks)
  HOST_ASSETS="$(realpath "${ASSETS_DIR}")"

  docker run --rm \
    -v "${HOST_ASSETS}:/assets" \
    debian:bookworm \
    bash -c "
      set -euo pipefail
      apt-get update -qq
      apt-get install -y -qq curl xorriso ca-certificates gnupg 2>/dev/null

      # Add Proxmox no-subscription repo for proxmox-auto-install-assistant
      curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
        -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
      echo 'deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription' \
        > /etc/apt/sources.list.d/pve.list
      apt-get update -qq
      apt-get install -y -qq proxmox-auto-install-assistant 2>/dev/null

      echo '  [prepare-iso] running proxmox-auto-install-assistant...'
      proxmox-auto-install-assistant prepare-iso \
        /assets/${PVE_ISO} \
        --fetch-from http \
        --url '${ANSWER_URL}' \
        --pxe \
        --output /assets/pxe-prepared/

      echo '  [done] prepared files:'
      ls -lh /assets/pxe-prepared/
    "

  # The tool outputs vmlinuz + initrd.img (and optionally a .ipxe snippet)
  # Rename to the filenames our Nginx + iPXE script already expect.
  PREPARED="${ASSETS_DIR}/pxe-prepared"
  if [[ -f "${PREPARED}/vmlinuz" ]]; then
    mv "${PREPARED}/vmlinuz" "${ASSETS_DIR}/linux26"
    echo "  [ok] vmlinuz -> linux26"
  elif [[ -f "${PREPARED}/linux26" ]]; then
    mv "${PREPARED}/linux26" "${ASSETS_DIR}/linux26"
    echo "  [ok] linux26 moved"
  else
    echo "ERROR: proxmox-auto-install-assistant did not produce a kernel file" >&2
    ls -lh "${PREPARED}/" >&2
    exit 1
  fi

  if [[ -f "${PREPARED}/initrd.img" ]]; then
    mv "${PREPARED}/initrd.img" "${ASSETS_DIR}/initrd.img"
    echo "  [ok] initrd.img moved"
  else
    echo "ERROR: proxmox-auto-install-assistant did not produce initrd.img" >&2
    ls -lh "${PREPARED}/" >&2
    exit 1
  fi

  # Keep any generated .ipxe snippet for reference, clean up temp dir
  rm -rf "${PREPARED}"
  echo "  [ok] PXE kernel + initrd ready"
fi

echo ""
echo "Assets ready in ${ASSETS_DIR}:"
ls -lh "${ASSETS_DIR}"
