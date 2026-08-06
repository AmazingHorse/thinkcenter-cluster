FROM debian:bookworm-slim

# Install proxmox-auto-install-assistant and extraction tools.
# This image is used by `just fetch` / `fetch-assets.sh` to prepare
# PXE kernel + initrd from the Proxmox VE ISO.
#
# We use the pvetest repo to get a version that supports --pxe-loader ipxe.
# The pve-no-subscription (stable) repo has 8.4.6 which predates that flag.
# This only affects the BUILD TOOL — the actual cluster runs stable PVE 9.2.
#
# Build once; rebuild when the image is stale or PVE version changes.

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        xorriso \
        p7zip-full \
    && rm -rf /var/lib/apt/lists/*

# Add Proxmox pvetest repo for a newer proxmox-auto-install-assistant
# that supports --pxe-loader ipxe (added after stable 8.4.6).
RUN curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
        -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg && \
    echo 'deb http://download.proxmox.com/debian/pve bookworm pvetest' \
        > /etc/apt/sources.list.d/pve.list && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends proxmox-auto-install-assistant && \
    rm -rf /var/lib/apt/lists/* && \
    echo "==> proxmox-auto-install-assistant version:" && \
    proxmox-auto-install-assistant --version

WORKDIR /assets

COPY prepare-pxe-entrypoint.sh /usr/local/bin/prepare-pxe
RUN chmod +x /usr/local/bin/prepare-pxe

ENTRYPOINT ["prepare-pxe"]
