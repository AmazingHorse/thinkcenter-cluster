#!/usr/bin/env bash
# fetch-assets.sh — download and verify Proxmox VE ISO + iPXE binaries,
# then use proxmox-auto-install-assistant to produce a prepared vmlinuz +
# initrd.img for PXE HTTP answer fetching.
#
# Boot server OS support:
#   Debian/Ubuntu/Proxmox host: install proxmox-auto-install-assistant natively
#     (apt install proxmox-auto-install-assistant) — no Docker needed.
#   Alpine or any other host: uses the `prepare-pxe` Docker Compose service
#     (boot/prepare-pxe/Dockerfile) which has the tool pre-installed.
#     Run `docker compose build prepare-pxe` once before first use.
#
# Requires: curl, sha256sum
# Native Debian: also needs proxmox-auto-install-assistant (apt install it)
# Alpine/other:  also needs docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(realpath "${SCRIPT_DIR}/../..")"
MANIFEST_FILE="${REPO_ROOT}/cluster-manifest.yml"
ASSETS_DIR="${SCRIPT_DIR}/../assets"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"
mkdir -p "${ASSETS_DIR}"

# ── Parse manifest ────────────────────────────────────────────────────────────
if [[ ! -f "${MANIFEST_FILE}" ]]; then
  echo "ERROR: Manifest file not found at ${MANIFEST_FILE}" >&2
  exit 1
fi

PVE_VERSION=$(grep 'pve_version:'    "${MANIFEST_FILE}" | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
PVE_SHA256=$(grep  'pve_iso_sha256:' "${MANIFEST_FILE}" | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
BOOT_SERVER_IP=$(grep 'boot_server_ip:' "${MANIFEST_FILE}" | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")

[[ -z "${PVE_VERSION}" ]]     && { echo "ERROR: pve_version not found in ${MANIFEST_FILE}" >&2; exit 1; }
[[ -z "${BOOT_SERVER_IP}" ]]  && { echo "ERROR: boot_server_ip not found in ${MANIFEST_FILE}" >&2; exit 1; }

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
    echo "  [warn] SHA256 not configured — skipping verification for $(basename "${file}")"
    return 0
  fi
  echo "  [verify] $(basename "${file}")"
  if echo "${expected}  ${file}" | sha256sum -c > /dev/null 2>&1; then
    echo "  [ok] checksum verified"
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
      echo "  [clean] removing corrupted/partial $(basename "${dest}")"
      rm -f "${dest}" "${ASSETS_DIR}/linux26" "${ASSETS_DIR}/initrd.img"
    fi
  fi
  echo "  [fetch] downloading $(basename "${dest}")"
  curl -fL --progress-bar -C - -o "${dest}" "${url}" || curl -fL --progress-bar -o "${dest}" "${url}"
  verify_sha256 "${dest}" "${expected_sha}"
}

# run_prepare_iso <binary> <iso> <answer_url> <outdir>
# Requires a proxmox-auto-install-assistant that supports --pxe-loader ipxe.
# This flag produces a self-contained PXE initrd (~1.7 GB) with the full
# installer squashfs embedded — no local block device needed at boot time.
# Versions from pve-no-subscription (≤ 8.4.6) do NOT support this flag.
run_prepare_iso() {
  local binary="$1" iso="$2" url="$3" out="$4"
  local base=(prepare-iso "${iso}" --fetch-from http --url "${url}" --tmp "${out}")

  if "${binary}" "${base[@]}" --pxe-loader ipxe --output "${out}" 2>/dev/null; then
    echo "  [ok] prepared with --pxe-loader ipxe (self-contained PXE initrd)"
  elif "${binary}" "${base[@]}" --pxe --output "${out}" 2>/dev/null; then
    echo "  [ok] prepared with --pxe (self-contained PXE initrd)"
  else
    echo "ERROR: proxmox-auto-install-assistant does not support --pxe-loader or --pxe" >&2
    echo "       This version cannot produce a self-contained PXE initrd." >&2
    echo "       PXE boot will fail with 'ISO not found on block device'." >&2
    echo "       Install from pvetest repo to get a supported version:" >&2
    echo "         echo 'deb http://download.proxmox.com/debian/pve bookworm pvetest'" >&2
    echo "           > /etc/apt/sources.list.d/pve.list" >&2
    echo "         apt update && apt install proxmox-auto-install-assistant" >&2
    return 1
  fi
}


# ── Fetch ISO ─────────────────────────────────────────────────────────────────
echo "==> Fetching Proxmox VE ISO (${PVE_ISO})"
fetch_and_verify_iso "${PVE_URL}" "${ASSETS_DIR}/${PVE_ISO}" "${PVE_SHA256}"

echo "==> Fetching iPXE binaries"
fetch_if_missing "${IPXE_URL}"     "${ASSETS_DIR}/undionly.kpxe"
fetch_if_missing "${IPXE_EFI_URL}" "${ASSETS_DIR}/ipxe.efi"
fetch_if_missing "${IPXE_SNP_URL}" "${ASSETS_DIR}/snponly.efi"

# ── Prepare PXE kernel + initrd ───────────────────────────────────────────────
# proxmox-auto-install-assistant embeds HTTP answer-fetch logic into the initrd.
# The stock initrd from the ISO does NOT support HTTP fetching.
#
# Native path: if proxmox-auto-install-assistant is on PATH, run it directly.
# Container path: use the `prepare-pxe` Compose service (boot/prepare-pxe/).
#   Build once with: docker compose -f boot/docker-compose.yml build prepare-pxe
echo "==> Preparing PXE kernel + initrd via proxmox-auto-install-assistant"

if [[ -f "${ASSETS_DIR}/linux26" && -f "${ASSETS_DIR}/initrd.img" ]]; then
  echo "  [skip] linux26 and initrd.img already present (delete to re-prepare)"
else
  echo "  [info] answer URL baked in: ${ANSWER_URL}"
  PREPARED="${ASSETS_DIR}/pxe-prepared"
  mkdir -p "${PREPARED}"

  if command -v proxmox-auto-install-assistant > /dev/null 2>&1; then
    # ── Native path (Debian/Ubuntu/Proxmox boot server) ──────────────────────
    echo "  [native] proxmox-auto-install-assistant found on PATH"
    run_prepare_iso proxmox-auto-install-assistant \
      "${ASSETS_DIR}/${PVE_ISO}" "${ANSWER_URL}" "${PREPARED}"

  else
    # ── Compose service (Alpine or any host without the binary) ───────────────
    echo "  [compose] using prepare-pxe service (boot/prepare-pxe/)"
    echo "  [tip] On Debian/Ubuntu, install natively to skip Docker:"
    echo "        apt install proxmox-auto-install-assistant (Proxmox no-sub repo)"

    docker compose -f "${COMPOSE_FILE}" run --rm prepare-pxe \
      "/assets/${PVE_ISO}" \
      "${ANSWER_URL}" \
      "/assets/pxe-prepared"
  fi

  # ── Move outputs into place ───────────────────────────────────────────────
  
  if [[ -f "${PREPARED}/vmlinuz" ]]; then
    mv "${PREPARED}/vmlinuz" "${ASSETS_DIR}/linux26"
    echo "  [ok] vmlinuz -> linux26"
  elif [[ -f "${PREPARED}/linux26" ]]; then
    mv "${PREPARED}/linux26" "${ASSETS_DIR}/linux26"
    echo "  [ok] linux26 moved"
  elif [[ -f "${PREPARED}/boot/vmlinuz" ]]; then
    mv "${PREPARED}/boot/vmlinuz" "${ASSETS_DIR}/linux26"
    echo "  [ok] boot/vmlinuz -> linux26"
  elif [[ -f "${PREPARED}/boot/linux26" ]]; then
    mv "${PREPARED}/boot/linux26" "${ASSETS_DIR}/linux26"
    echo "  [ok] boot/linux26 -> linux26"
  else
    echo "ERROR: no kernel file found in ${PREPARED}/" >&2
    ls -lhR "${PREPARED}/" >&2
    exit 1
  fi

  if [[ -f "${PREPARED}/initrd.img" ]]; then
    mv "${PREPARED}/initrd.img" "${ASSETS_DIR}/initrd.img"
    echo "  [ok] initrd.img moved"
  elif [[ -f "${PREPARED}/boot/initrd.img" ]]; then
    mv "${PREPARED}/boot/initrd.img" "${ASSETS_DIR}/initrd.img"
    echo "  [ok] boot/initrd.img moved"
  else
    echo "ERROR: no initrd.img found in ${PREPARED}/" >&2
    ls -lhR "${PREPARED}/" >&2
    exit 1
  fi

  # Proxmox 9.2.8 generates boot.ipxe
  if [[ -f "${PREPARED}/boot.ipxe" ]]; then
    mv "${PREPARED}/boot.ipxe" "${ASSETS_DIR}/autoexec.ipxe.generated"
    echo "  [ok] boot.ipxe -> autoexec.ipxe.generated"
  fi
  
  # Proxmox 9.2.8 generates an ISO file alongside it.
  # The Linux kernel EFI stub (used in UEFI boot) CANNOT extract raw ISOs passed via initrd=.
  # It only extracts CPIO archives! So we must wrap the ISO into a CPIO archive.
  if ls "${PREPARED}"/*.iso >/dev/null 2>&1; then
    echo "  [cpio] Appending ISO as CPIO archive directly to initrd.img to save disk space..."
    mv "${PREPARED}"/*.iso "${PREPARED}/proxmox.iso"
    (cd "${PREPARED}" && echo "proxmox.iso" | cpio -H newc -o >> "${ASSETS_DIR}/initrd.img")
    echo "  [ok] ISO successfully packed into initrd.img"
  fi

  rm -rf "${PREPARED}"
  echo "  [ok] PXE kernel + initrd ready"
fi

echo ""
echo "Assets ready in ${ASSETS_DIR}:"
ls -lh "${ASSETS_DIR}"
