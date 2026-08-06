#!/usr/bin/env bash
# prepare-pxe-entrypoint.sh — container entrypoint for the prepare-pxe service.
#
# Called by: docker compose run --rm prepare-pxe <ISO> <ANSWER_URL> <OUT_DIR>
# Arguments:
#   $1  ISO path inside container (e.g. /assets/proxmox-ve_9.2-1.iso)
#   $2  Answer URL (e.g. http://192.168.50.206:8080/assets/answers/)
#   $3  Output directory (e.g. /assets/pxe-prepared)
#
# Tries --pxe-loader ipxe, then --pxe, then ISO-only + 7z extraction.
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

if proxmox-auto-install-assistant "${BASE_ARGS[@]}" --pxe-loader ipxe --output "${OUT}" 2>/dev/null; then
  echo "  [ok] --pxe-loader ipxe"

elif proxmox-auto-install-assistant "${BASE_ARGS[@]}" --pxe --output "${OUT}" 2>/dev/null; then
  echo "  [ok] --pxe"

else
  echo "  [warn] PXE flags unsupported (v8.4.x); preparing modified ISO + extracting via 7z"
  echo "  [note] functionally identical: prepared initrd has HTTP fetch logic embedded"
  PREPARED_ISO="${OUT}/proxmox-prepared.iso"
  proxmox-auto-install-assistant "${BASE_ARGS[@]}" --output "${PREPARED_ISO}"
  if [[ ! -f "${PREPARED_ISO}" ]]; then
    echo "ERROR: prepare-iso did not produce ${PREPARED_ISO}" >&2
    exit 1
  fi
  echo "  [extract] extracting boot/ files from ${PREPARED_ISO}"
  7z x -y "${PREPARED_ISO}" boot/vmlinuz boot/linux26 boot/initrd.img -o"${OUT}" > /dev/null 2>&1 || true
  rm -f "${PREPARED_ISO}"
fi

echo "  [done] contents of ${OUT}:"
ls -lh "${OUT}/"
