#!/usr/bin/env bash
# fetch-assets.sh — download and verify Proxmox VE ISO + iPXE binaries,
# then use proxmox-auto-install-assistant to produce a prepared vmlinuz +
# initrd.img for PXE HTTP answer fetching.
#
# Boot server OS support:
#   Debian/Ubuntu/Proxmox host: install proxmox-auto-install-assistant natively
#     (apt install proxmox-auto-install-assistant) — no Docker needed.
#   Alpine or any other host: this script uses a debian:bookworm Docker
#     container automatically when the binary is not found on PATH.
#
# Requires: curl, sha256sum
# Native Debian: also needs proxmox-auto-install-assistant (apt install it)
# Alpine/other:  also needs docker + p7zip

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
# proxmox-auto-install-assistant prepare-iso embeds the fetch-from-http logic.
#
# PXE output: tool tries --pxe-loader ipxe (≥some version) then --pxe.
# If neither is supported, it falls back to producing a modified ISO and
# extracting boot/vmlinuz + boot/initrd.img from it via 7z.
#
# On Debian/Ubuntu/Proxmox: install natively (no Docker):
#   echo 'deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription' \
#     > /etc/apt/sources.list.d/pve.list
#   curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
#     -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
#   apt update && apt install proxmox-auto-install-assistant
# On Alpine/other: this script uses a debian:bookworm Docker container.
echo "==> Preparing PXE kernel + initrd via proxmox-auto-install-assistant"

if [[ -f "${ASSETS_DIR}/linux26" && -f "${ASSETS_DIR}/initrd.img" ]]; then
  echo "  [skip] linux26 and initrd.img already present (delete to re-prepare)"
else
  echo "  [info] answer URL baked in: ${ANSWER_URL}"

  HOST_ASSETS="$(realpath "${ASSETS_DIR}")"
  PREPARED="${ASSETS_DIR}/pxe-prepared"
  mkdir -p "${PREPARED}"

  # run_prepare_iso <binary> <iso> <url> <outdir>
  # Tries --pxe-loader ipxe, then --pxe, then ISO-only + 7z extraction.
  run_prepare_iso() {
    local binary="$1" iso="$2" url="$3" out="$4"
    local base_args=(prepare-iso "${iso}" --fetch-from http --url "${url}" --output "${out}")

    if "${binary}" "${base_args[@]}" --pxe-loader ipxe 2>/dev/null; then
      echo "  [ok] prepared with --pxe-loader ipxe"
    elif "${binary}" "${base_args[@]}" --pxe 2>/dev/null; then
      echo "  [ok] prepared with --pxe"
    else
      # Neither PXE flag accepted — prepare modified ISO, extract via 7z
      echo "  [warn] --pxe-loader/--pxe unsupported; preparing ISO + extracting via 7z"
      "${binary}" "${base_args[@]}"
      local found_iso
      found_iso=$(find "${out}" -name "*.iso" | head -n1)
      if [[ -z "${found_iso}" ]]; then
        echo "ERROR: prepare-iso did not produce an ISO in ${out}" >&2
        return 1
      fi
      echo "  [extract] extracting boot/ files from ${found_iso}"
      7z x -y "${found_iso}" boot/vmlinuz boot/linux26 boot/initrd.img -o"${out}" > /dev/null 2>&1 || true
    fi
  }

  if command -v proxmox-auto-install-assistant > /dev/null 2>&1; then
    # ── Native path (Debian/Ubuntu/Proxmox boot server) ──────────────────────
    echo "  [native] proxmox-auto-install-assistant found on PATH — running natively"
    run_prepare_iso proxmox-auto-install-assistant \
      "${ASSETS_DIR}/${PVE_ISO}" "${ANSWER_URL}" "${PREPARED}"

  else
    # ── Container fallback (Alpine or any host without the binary) ────────────
    echo "  [container] proxmox-auto-install-assistant not found — using debian:bookworm"
    echo "  [tip] On Debian/Ubuntu, install natively to skip this container step:"
    echo "        apt install proxmox-auto-install-assistant (Proxmox no-sub repo)"

    docker run --rm \
      -v "${HOST_ASSETS}:/assets" \
      debian:bookworm \
      bash -c "
        set -euo pipefail
        apt-get update -qq
        apt-get install -y -qq curl xorriso ca-certificates gnupg p7zip-full 2>/dev/null

        curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
          -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
        echo 'deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription' \
          > /etc/apt/sources.list.d/pve.list
        apt-get update -qq
        apt-get install -y -qq proxmox-auto-install-assistant 2>/dev/null

        OUT=/assets/pxe-prepared
        BASE=(prepare-iso /assets/${PVE_ISO} --fetch-from http --url '${ANSWER_URL}' --output \"\${OUT}\")

        echo '  [prepare-iso] running...'
        if proxmox-auto-install-assistant \"\${BASE[@]}\" --pxe-loader ipxe 2>/dev/null; then
          echo '  [ok] --pxe-loader ipxe'
        elif proxmox-auto-install-assistant \"\${BASE[@]}\" --pxe 2>/dev/null; then
          echo '  [ok] --pxe'
        else
          echo '  [warn] PXE flags unsupported; preparing ISO + extracting via 7z'
          proxmox-auto-install-assistant \"\${BASE[@]}\"
          FOUND=\$(find \"\${OUT}\" -name '*.iso' | head -n1)
          7z x -y \"\${FOUND}\" boot/vmlinuz boot/linux26 boot/initrd.img -o\"\${OUT}\" > /dev/null 2>&1 || true
        fi

        echo '  [done]'
        ls -lh \"\${OUT}/\"
      "
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

  rm -rf "${PREPARED}"
  echo "  [ok] PXE kernel + initrd ready"
fi

echo ""
echo "Assets ready in ${ASSETS_DIR}:"
ls -lh "${ASSETS_DIR}"
