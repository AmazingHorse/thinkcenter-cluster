FROM debian:trixie-slim

# Install proxmox-auto-install-assistant and extraction tools.
# This image is used by `just fetch` / `fetch-assets.sh` to prepare
# PXE kernel + initrd from the Proxmox VE ISO.
#
# We use Debian Trixie (13) which corresponds to Proxmox VE 9.x.
# This gives us a proxmox-auto-install-assistant version (9.2+) that 
# natively supports the --pxe-loader ipxe flag.
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

# Add Proxmox trixie repo (stable)
RUN curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
        -o /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg && \
    echo 'deb http://download.proxmox.com/debian/pve trixie pve-no-subscription' \
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
