#!/usr/bin/env bash
# prepare-pxe-entrypoint.sh — container entrypoint for the prepare-pxe service.
#
# Called by: docker compose run --rm prepare-pxe <ISO> <ANSWER_URL> <OUT_DIR>
# Arguments:
#   $1  ISO path inside container (e.g. /assets/proxmox-ve_9.2-1.iso)
#   $2  Answer URL (e.g. http://192.168.50.206:8080/assets/answers/)
#   $3  Output directory inside container (e.g. /assets)

set -euo pipefail

ISO="${1:-}"
ANSWER_URL="${2:-}"
OUT="${3:-/assets}"

if [[ -z "${ISO}" || -z "${ANSWER_URL}" ]]; then
  echo "Usage: prepare-pxe <ISO_PATH> <ANSWER_URL> [OUT_DIR]" >&2
  exit 1
fi

if [[ ! -f "${ISO}" ]]; then
  echo "ERROR: ISO not found at ${ISO}" >&2
  exit 1
fi

mkdir -p "${OUT}"
TMP_WORK="${OUT}/.tmp_prepare"
rm -rf "${TMP_WORK}"
mkdir -p "${TMP_WORK}"

echo "  [prepare-iso] running proxmox-auto-install-assistant..."
proxmox-auto-install-assistant --version

PREPARED_ISO="${TMP_WORK}/proxmox-prepared.iso"

# Prepare the ISO with the answer URL baked in for HTTP fetch mode
if proxmox-auto-install-assistant prepare-iso "${ISO}" --fetch-from http --url "${ANSWER_URL}" --tmp "${TMP_WORK}" --output "${PREPARED_ISO}"; then
  echo "  [ok] prepared ISO generated at ${PREPARED_ISO}"
else
  echo "  [error] failed to run proxmox-auto-install-assistant prepare-iso" >&2
  exit 1
fi

# Retain full prepared ISO for USB installation fallback
cp -f "${PREPARED_ISO}" "${OUT}/proxmox-prepared.iso"
echo "  [ok] copied full prepared ISO to ${OUT}/proxmox-prepared.iso (USB fallback)"

# Extract /boot kernel (linux26) and initrd.img from the prepared ISO
echo "  [extract] extracting kernel and initrd from prepared ISO..."
7z x -y -o"${TMP_WORK}/extracted" "${PREPARED_ISO}" boot/ >/dev/null

if [[ -f "${TMP_WORK}/extracted/boot/linux26" ]]; then
  cp -f "${TMP_WORK}/extracted/boot/linux26" "${OUT}/linux26"
elif [[ -f "${TMP_WORK}/extracted/boot/vmlinuz" ]]; then
  cp -f "${TMP_WORK}/extracted/boot/vmlinuz" "${OUT}/linux26"
else
  echo "  [error] could not locate kernel in prepared ISO" >&2
  exit 1
fi

if [[ -f "${TMP_WORK}/extracted/boot/initrd.img" ]]; then
  cp -f "${TMP_WORK}/extracted/boot/initrd.img" "${OUT}/initrd.img"
else
  echo "  [error] could not locate initrd.img in prepared ISO" >&2
  exit 1
fi

# Check compression format: recompress zstd to gzip for universal UEFI / iPXE compatibility
if zstd -t "${OUT}/initrd.img" 2>/dev/null; then
  echo "  [recompress] converting initrd.img from zstd to gzip..."
  zstd -d -c "${OUT}/initrd.img" | gzip -1 > "${OUT}/initrd.img.gz"
  mv "${OUT}/initrd.img.gz" "${OUT}/initrd.img"
  echo "  [ok] initrd.img recompressed to gzip"
fi

# Create slimmed proxmox.iso by removing /boot (saves ~100 MiB RAM during PXE boot)
cp -f "${PREPARED_ISO}" "${TMP_WORK}/proxmox.iso"
if command -v xorriso >/dev/null 2>&1; then
  echo "  [slim] stripping /boot from proxmox.iso..."
  xorriso -indev "${TMP_WORK}/proxmox.iso" -outdev "${TMP_WORK}/proxmox-slim.iso" -rm_r /boot -- -commit 2>/dev/null || true
  if [[ -f "${TMP_WORK}/proxmox-slim.iso" ]]; then
    mv "${TMP_WORK}/proxmox-slim.iso" "${TMP_WORK}/proxmox.iso"
  fi
fi

# Pack proxmox.iso into standalone CPIO archive proxmox.iso.cpio
echo "  [cpio] packing proxmox.iso into proxmox.iso.cpio..."
(cd "${TMP_WORK}" && echo "proxmox.iso" | cpio -H newc -o > "${OUT}/proxmox.iso.cpio")
echo "  [ok] created ${OUT}/proxmox.iso.cpio"

# Clean up temporary work files
rm -rf "${TMP_WORK}"

echo "  [done] PXE assets ready in ${OUT}:"
ls -lh "${OUT}/linux26" "${OUT}/initrd.img" "${OUT}/proxmox.iso.cpio" "${OUT}/proxmox-prepared.iso"
