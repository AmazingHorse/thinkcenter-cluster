# fetch-assets.sh → justfile Migration Plan

## TL;DR: Is it a good fit?

**Partially.** The top-level structure maps naturally to `just` recipes with dependency
chains. But three parts of the current script are a bad fit for inline `just` recipes
and should stay in dedicated shell helpers.

---

## What `just` is good at here

| Script section | just suitability | Why |
|---|---|---|
| Downloading ISO + sha256 verify | ✅ Good | Simple curl + sha256sum, 5-10 lines |
| Downloading iPXE binaries | ✅ Good | 3 `curl` calls, trivially inline |
| Idempotency skip guards | ✅ Good | `[[ -f file ]] && echo skip || ...` |
| Dependency ordering | ✅ Great | `just prepare-pxe: fetch-iso fetch-ipxe` |
| User-facing recipe names | ✅ Great | `just fetch-iso`, `just prepare-pxe` |
| YAML manifest parsing (grep/awk) | ⚠️ Doable | Ugly but works with `$(...)` |
| `run_prepare_iso` helper function | ❌ Bad fit | `just` has no reusable functions |
| Docker heredoc with nested escaping | ❌ Bad fit | Gets unreadable very fast |
| Multi-level PXE flag fallback chain | ❌ Bad fit | Complex conditionals → shell script |

**Verdict:** Split into a thin `justfile` orchestration layer + focused shell helpers.
The Docker + fallback logic stays in shell. Simple fetch/verify moves inline.

---

## Proposed structure

```
boot/
  scripts/
    prepare-pxe.sh     ← NEW: extracted from fetch-assets.sh (lines 107–250)
                          Contains: run_prepare_iso(), native vs container logic,
                          all Docker heredoc, 7z extraction, file moves.
                          Called by: just prepare-pxe
    fetch-assets.sh    ← DELETED (or kept as thin wrapper calling just internally)
  assets/
    ...
```

The root `justfile` gains these new recipes, replacing the single `fetch` recipe:

```just
# ── Manifest values ─────────────────────────────────────────────────────────
# just supports loading values from a dotenv file. Rather than parsing YAML
# in every recipe, a one-time `just manifest-env` recipe writes .env from
# cluster-manifest.yml, then `set dotenv-load` picks it up automatically.
set dotenv-load

# Generate .env from cluster-manifest.yml (run once, or after manifest changes)
manifest-env:
    #!/usr/bin/env bash
    set -euo pipefail
    PVE_VERSION=$(grep 'pve_version:'     cluster-manifest.yml | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    PVE_SHA256=$(grep  'pve_iso_sha256:'  cluster-manifest.yml | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    BOOT_IP=$(grep     'boot_server_ip:'  cluster-manifest.yml | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    printf 'PVE_VERSION=%s\nPVE_SHA256=%s\nBOOT_SERVER_IP=%s\n' \
        "${PVE_VERSION}" "${PVE_SHA256}" "${BOOT_IP}" > .env
    echo "  [ok] .env written from cluster-manifest.yml"

# Download and verify the Proxmox VE ISO
fetch-iso:
    #!/usr/bin/env bash
    set -euo pipefail
    ISO="boot/assets/proxmox-ve_${PVE_VERSION}-1.iso"
    URL="https://enterprise.proxmox.com/iso/proxmox-ve_${PVE_VERSION}-1.iso"
    if [[ -f "${ISO}" ]]; then
        echo "${PVE_SHA256}  ${ISO}" | sha256sum -c > /dev/null 2>&1 \
            && echo "  [skip] ISO already present and verified" && exit 0 \
            || { echo "  [clean] removing bad ISO"; rm -f "${ISO}"; }
    fi
    echo "  [fetch] proxmox-ve_${PVE_VERSION}-1.iso"
    curl -fL --progress-bar -C - -o "${ISO}" "${URL}" \
        || curl -fL --progress-bar -o "${ISO}" "${URL}"
    echo "${PVE_SHA256}  ${ISO}" | sha256sum -c

# Download iPXE binary assets (EFI + legacy BIOS)
fetch-ipxe:
    #!/usr/bin/env bash
    set -euo pipefail
    fetch_if() { [[ -f "$2" ]] && echo "  [skip] $2" || { echo "  [fetch] $2"; curl -fL --progress-bar -o "$2" "$1"; }; }
    fetch_if https://boot.ipxe.org/undionly.kpxe               boot/assets/undionly.kpxe
    fetch_if https://boot.ipxe.org/x86_64-efi/ipxe.efi         boot/assets/ipxe.efi
    fetch_if https://boot.ipxe.org/x86_64-efi/snponly.efi      boot/assets/snponly.efi

# Prepare PXE kernel + initrd (calls shell helper for Docker/fallback logic)
prepare-pxe: fetch-iso
    bash boot/scripts/prepare-pxe.sh

# Fetch everything: ISO, iPXE, and prepared PXE kernel/initrd
fetch: fetch-ipxe prepare-pxe

# Full boot stack bring-up (replaces current standup)
standup: fetch render up
```

---

## What stays in `prepare-pxe.sh`

The following logic is too complex for inline `just` recipes and should be
extracted into `boot/scripts/prepare-pxe.sh`:

- `run_prepare_iso()` function (with PXE flag fallback chain)
- Native vs Docker branch detection
- The full `docker run ... bash -c "..."` heredoc
- File move/rename logic (`vmlinuz → linux26`)
- Error handling for missing output files

`prepare-pxe.sh` reads `PVE_ISO`, `ANSWER_URL`, `ASSETS_DIR` from environment
(set by `just` via `.env` dotenv) rather than re-parsing YAML.

---

## Migration steps

1. **Create `boot/scripts/prepare-pxe.sh`**
   - Extract lines 107–252 from current `fetch-assets.sh`
   - Replace manifest parsing with env var reads (`${PVE_VERSION}`, `${BOOT_SERVER_IP}`)
   - Add `set -euo pipefail` + guard for required env vars

2. **Add `manifest-env` recipe to root `justfile`**
   - Writes `.env` from `cluster-manifest.yml`
   - Add `.env` to `.gitignore`

3. **Add `set dotenv-load` to root `justfile`**
   - `just` automatically loads `.env` into recipe environments

4. **Split `fetch` recipe into `fetch-iso`, `fetch-ipxe`, `prepare-pxe`**
   - `fetch-iso` and `fetch-ipxe` become inline bash shebang recipes
   - `prepare-pxe` delegates to `boot/scripts/prepare-pxe.sh`

5. **Delete `boot/scripts/fetch-assets.sh`**
   - Or keep as thin wrapper: `just manifest-env && just fetch`

6. **Update `standup` dependency**: `standup: fetch render up` (unchanged)

---

## Open questions / decisions for implementation

> [!IMPORTANT]
> **dotenv source of truth**: `just` needs static values at recipe-parse time for
> variable interpolation (`{{PVE_VERSION}}`), but `.env` is runtime. Shell shebang
> recipes (`#!/usr/bin/env bash`) side-step this — they read env vars at execution
> time, which is fine. Confirm this approach is acceptable before migrating.

> [!NOTE]
> **`.env` in git**: The generated `.env` should be in `.gitignore`. If the repo is
> cloned fresh, `just manifest-env` must be run before `just fetch`. Consider making
> `standup` depend on `manifest-env` to make this automatic.

> [!NOTE]
> **`prepare-pxe.sh` vs inline**: The Docker heredoc with nested variable escaping
> (`\\\"\\${OUT}\\\"`) is already hard to read in a bash script. In a `just` recipe
> it would gain another escaping layer (`{{{{` for literal braces). Keep it in shell.
