FROM debian:bookworm-slim

# Install proxmox-auto-install-assistant and extraction tools.
# This image is used by `just fetch` / `fetch-assets.sh` to prepare
# PXE kernel + initrd from the Proxmox VE ISO.
#
# Build once; rebuild only when PVE version changes.

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        xorriso \
        p7zip-full \
    && rm -rf /var/lib/apt/lists/*

# Add Proxmox no-subscription repo and install the assistant
RUN curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
        -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg && \
    echo 'deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription' \
        > /etc/apt/sources.list.d/pve.list && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends proxmox-auto-install-assistant && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /assets

COPY prepare-pxe-entrypoint.sh /usr/local/bin/prepare-pxe
RUN chmod +x /usr/local/bin/prepare-pxe

ENTRYPOINT ["prepare-pxe"]
