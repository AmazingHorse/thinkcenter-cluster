#!/usr/bin/env bash
# prepare-pxe-entrypoint.sh — container entrypoint for the prepare-pxe service.
#
# Called by: docker compose run --rm prepare-pxe <ISO> <ANSWER_URL> <OUT_DIR>
# Arguments:
#   $1  ISO path inside container (e.g. /assets/proxmox-ve_9.2-1.iso)
#   $2  Answer URL (e.g. http://192.168.50.206:8080/assets/answers/)
#   $3  Output directory (e.g. /assets/pxe-prepared)
#
# Requires proxmox-auto-install-assistant with --pxe-loader ipxe support.
# Install from pvetest repo — stable 8.4.6 (pve-no-subscription) does NOT
# have this flag and produces only a small answer-fetch initrd, not the
# self-contained PXE initrd that embeds the full installer squashfs.
#
# --tmp is set to the output dir so all temp files stay on the same filesystem
# as the output (avoiding EXDEV/os-error-18 on Docker bind mounts).

set -euo pipefail

ISO="$1"
ANSWER_URL="$2"
OUT="$3"

if [[ ! -f "${ISO}" ]]; then
  echo "ERROR: ISO not found at ${ISO}" >&2
  exit 1
fi

mkdir -p "${OUT}"

BASE_ARGS=(prepare-iso "${ISO}" --fetch-from http --url "${ANSWER_URL}" --tmp "${OUT}")

echo "  [prepare-iso] running proxmox-auto-install-assistant..."
proxmox-auto-install-assistant --version

if proxmox-auto-install-assistant "${BASE_ARGS[@]}" --pxe-loader ipxe --output "${OUT}"; then
  echo "  [ok] --pxe-loader ipxe (self-contained PXE initrd)"

elif proxmox-auto-install-assistant "${BASE_ARGS[@]}" --pxe --output "${OUT}"; then
  echo "  [ok] --pxe (self-contained PXE initrd)"

else
  # Last resort: prepare ISO, extract boot/ files via 7z.
  # WARNING: the resulting initrd.img will be small (~53 MB) and ONLY contains
  # the HTTP answer-fetch logic. It does NOT embed the installer squashfs.
  # Booting this over PXE will fail with "ISO not found on block device".
  # Fix: rebuild the prepare-pxe Docker image using the pvetest repo.
  echo "  [error] --pxe-loader ipxe / --pxe flags are not supported by this version" >&2
  echo "  [error] The installed proxmox-auto-install-assistant cannot produce a" >&2
  echo "          self-contained PXE initrd. Rebuild boot/prepare-pxe image with:" >&2
  echo "          just build-tools --no-cache" >&2
  echo "  [error] Ensure the Dockerfile uses the pvetest repo, not pve-no-subscription." >&2
  exit 1
fi

# Sanity check: a proper PXE initrd should be several hundred MB (it embeds the
# full squashfs). If we got a tiny file something is wrong.
INITRD_SIZE=0
if [[ -f "${OUT}/initrd.img" ]]; then
  INITRD_SIZE=$(stat -c%s "${OUT}/initrd.img" 2>/dev/null || echo 0)
elif [[ -f "${OUT}/boot/initrd.img" ]]; then
  INITRD_SIZE=$(stat -c%s "${OUT}/boot/initrd.img" 2>/dev/null || echo 0)
fi

# 100 MB threshold — a proper self-contained PXE initrd is ~1.7 GB
MIN_SIZE=$(( 100 * 1024 * 1024 ))
if [[ "${INITRD_SIZE}" -lt "${MIN_SIZE}" ]]; then
  echo "  [warn] initrd.img is only $(( INITRD_SIZE / 1024 / 1024 )) MB — expected several hundred MB" >&2
  echo "  [warn] This may be the answer-fetch-only initrd, not the self-contained PXE one." >&2
  echo "  [warn] PXE boot will likely fail with 'ISO not found on block device'." >&2
fi

echo "  [done] contents of ${OUT}:"
ls -lh "${OUT}/"
