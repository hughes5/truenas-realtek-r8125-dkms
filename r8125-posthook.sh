#!/usr/bin/env bash
# TrueNAS SCALE helper: install/cache r8125 DKMS, register PREINIT repair.
#
# Working files live under /data/scripts because /data survives TrueNAS boot-
# environment updates. On --install, Init/Shutdown COMMAND tasks are registered:
#   PREINIT  — offline driver repair before networking
#   SHUTDOWN — refresh offline dep cache (headers for every installed kernel)
# Use Command, not Script — bash is required.
#
#   sudo bash r8125-posthook.sh --install
#   sudo bash r8125-posthook.sh --check
#   sudo bash /data/scripts/r8125-posthook.sh

set -euo pipefail

PACKAGE_NAME="realtek-r8125-dkms"
PACKAGE_VERSION="9.016.01-1"
DKMS_VERSION="${PACKAGE_VERSION%-*}"
PACKAGE_ARCH="amd64"
DKMS_NAME="realtek-r8125"
DEB_URL="https://github.com/hughes5/truenas-realtek-r8125-dkms/releases/download/${PACKAGE_VERSION}/${PACKAGE_NAME}_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb"

SCRIPT_DIR="/data/scripts"
PERSISTENT_SCRIPT="${SCRIPT_DIR}/r8125-posthook.sh"
DEB_FILE="${SCRIPT_DIR}/${PACKAGE_NAME}_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb"
OFFLINE_DEB_DIR="${SCRIPT_DIR}/r8125-offline-debs"
MODULE_NAME="r8125"
BLACKLIST_FILE="/etc/modprobe.d/blacklist-r8169.conf"
LOG_FILE="/var/log/r8125-posthook.log"
PREINIT_CMD="/bin/bash ${PERSISTENT_SCRIPT}"
PREINIT_TIMEOUT=600
SHUTDOWN_CACHE_CMD="/bin/bash ${PERSISTENT_SCRIPT} --refresh-cache"
SHUTDOWN_CACHE_TIMEOUT=900
OFFLINE_DEP_ROOTS=(dkms build-essential fakeroot sudo kmod)

log()  { mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
kernel() { uname -r; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root."; exit 1; }; }

mod_loaded() { [[ -d "/sys/module/${MODULE_NAME}" ]] || lsmod | grep -q "^${MODULE_NAME}[[:space:]]"; }
r8169_loaded() { lsmod | grep -q "^r8169[[:space:]]"; }
mod_built() {
    find "/lib/modules/$(kernel)" \( -name "${MODULE_NAME}.ko" -o -name "${MODULE_NAME}.ko.xz" -o -name "${MODULE_NAME}.ko.zst" \) 2>/dev/null | grep -q .
}
headers_ok() { [[ -e "/lib/modules/$(kernel)/build" ]]; }
pkg_installed() { [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true)" == ii* ]]; }

writable_root() {
    if [[ -x /usr/local/libexec/disable-rootfs-protection ]]; then
        log "Disabling TrueNAS rootfs protection."
        /usr/local/libexec/disable-rootfs-protection || warn "disable-rootfs-protection failed; continuing."
    fi
    mount -o remount,rw / >/dev/null 2>&1 || true
    mountpoint -q /boot && mount -o remount,rw /boot >/dev/null 2>&1 || true
}

valid_deb() {
    [[ -s "$DEB_FILE" ]] || return 1
    have dpkg-deb || return 1
    [[ "$(dpkg-deb -f "$DEB_FILE" Package 2>/dev/null)" == "$PACKAGE_NAME" ]] &&
        [[ "$(dpkg-deb -f "$DEB_FILE" Version 2>/dev/null)" == "$PACKAGE_VERSION" ]] &&
        [[ "$(dpkg-deb -f "$DEB_FILE" Architecture 2>/dev/null)" == "$PACKAGE_ARCH" ]]
}

headers_cached_for() {
    compgen -G "${OFFLINE_DEB_DIR}/linux-headers-${1}_"*.deb >/dev/null ||
        compgen -G "${OFFLINE_DEB_DIR}/linux-headers-${1}-"*.deb >/dev/null
}

# Kernels we may boot into: running, staged under /lib/modules, dpkg, apt download cache.
kernel_versions() {
    local -A seen=()
    local k pkg ver deb

    seen["$(kernel)"]=1
    for k in /lib/modules/*/; do
        [[ -d "$k" ]] || continue
        k=$(basename "$k")
        [[ "$k" == source ]] && continue
        if [[ -e "/lib/modules/$k/modules.dep" || -e "/lib/modules/$k/modules.builtin" ]]; then
            seen[$k]=1
        fi
    done
    while read -r pkg; do
        [[ -n "$pkg" ]] || continue
        seen[${pkg#linux-image-}]=1
    done < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null || true)
    shopt -s nullglob
    for deb in /var/cache/apt/archives/linux-headers_*.deb /var/cache/apt/archives/linux-headers-*.deb; do
        pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null) || continue
        ver=${pkg#linux-headers-}
        [[ -n "$ver" ]] && seen[$ver]=1
    done
    shopt -u nullglob
    printf '%s\n' "${!seen[@]}" | sort -u
}

all_headers_cached() {
    local k
    [[ -d "$OFFLINE_DEB_DIR" ]] || return 1
    while read -r k; do
        [[ -n "$k" ]] || continue
        headers_cached_for "$k" || return 1
    done < <(kernel_versions)
}

cached_deps_ok() {
    [[ -d "$OFFLINE_DEB_DIR" ]] &&
        compgen -G "$OFFLINE_DEB_DIR/*.deb" >/dev/null &&
        all_headers_cached
}

dkms_ok() {
    dkms status -m "$DKMS_NAME" -k "$(kernel)" 2>/dev/null | grep -q ': installed'
}

download_deb() {
    mkdir -p "$SCRIPT_DIR"
    if valid_deb; then
        log "Using cached package at $DEB_FILE."
        return 0
    fi
    have wget || die "wget missing and no cached .deb at $DEB_FILE."
    log "Downloading ${PACKAGE_NAME} ${PACKAGE_VERSION}."
    local tmp="${DEB_FILE}.tmp"
    rm -f "$tmp"
    wget -q -O "$tmp" "$DEB_URL" || { rm -f "$tmp"; die "Download failed."; }
    mv "$tmp" "$DEB_FILE"
    valid_deb || die "Downloaded package metadata mismatch."
    log "Cached package at $DEB_FILE."
}

copy_apt_archives_to_cache() {
    local dest="$1" p deb copied=0
    [[ -d "$dest" ]] || return 0
    if [[ -s "$dest/PACKAGES" ]]; then
        while read -r p; do
            [[ -n "$p" ]] || continue
            shopt -s nullglob
            for deb in "/var/cache/apt/archives/${p}"_*.deb "/var/cache/apt/archives/${p}-"*.deb; do
                [[ -e "$deb" ]] || continue
                cp -n "$deb" "$dest/" && copied=$((copied + 1))
            done
            shopt -u nullglob
        done < "$dest/PACKAGES"
    fi
    shopt -s nullglob
    for deb in /var/cache/apt/archives/linux-headers_*.deb /var/cache/apt/archives/linux-headers-*.deb; do
        cp -n "$deb" "$dest/" && copied=$((copied + 1))
    done
    shopt -u nullglob
    [[ $copied -gt 0 ]] && log "Seeded $copied package(s) from /var/cache/apt/archives."
}

offline_pkg_list() {
    local roots=("${OFFLINE_DEP_ROOTS[@]}")
    local k h
    while read -r k; do
        [[ -n "$k" ]] || continue
        h="linux-headers-$k"
        apt-cache show --no-all-versions "$h" 2>/dev/null | grep -q '^Package:' && roots+=("$h")
    done < <(kernel_versions)
    {
        printf '%s\n' "${roots[@]}"
        apt-cache depends --recurse --important "${roots[@]}" 2>/dev/null | awk '
            /^[[:space:]]*(Pre)?Depends:/ { gsub(/[|<>]/, "", $2); print $2; next }
            /^[[:alnum:]][[:alnum:]_.+:-]*$/ { print $1 }
        '
    } | sed -E 's/:.*$//' | sort -u | while read -r p; do
        [[ -n "$p" ]] && apt-cache show --no-all-versions "$p" 2>/dev/null | grep -q '^Package:' && echo "$p"
    done
}

cache_offline_deps() {
    have apt-get apt-cache dpkg-deb || { warn "APT unavailable; skipping offline dep cache."; return 1; }
    apt-get update -qq || { warn "apt-get update failed."; return 1; }

    local tmp="${OFFLINE_DEB_DIR}.tmp" failed=0
    rm -rf "$tmp" && mkdir -p "$tmp"
    offline_pkg_list > "$tmp/PACKAGES" || { rm -rf "$tmp"; return 1; }
    [[ -s "$tmp/PACKAGES" ]] || { warn "No dependency packages resolved."; rm -rf "$tmp"; return 1; }

    log "Downloading $(wc -l < "$tmp/PACKAGES" | tr -d ' ') packages for offline cache."
    while read -r p; do
        [[ -n "$p" ]] || continue
        (cd "$tmp" && apt-get download "$p" >/dev/null 2>&1) || { warn "Download failed: $p"; failed=1; }
    done < "$tmp/PACKAGES"
    [[ "$failed" -eq 0 ]] || { rm -rf "$tmp"; return 1; }

    copy_apt_archives_to_cache "$tmp"

    rm -rf "${OFFLINE_DEB_DIR}.old" "$tmp/PACKAGES"
    [[ -d "$OFFLINE_DEB_DIR" ]] && mv "$OFFLINE_DEB_DIR" "${OFFLINE_DEB_DIR}.old"
    mv "$tmp" "$OFFLINE_DEB_DIR"
    rm -rf "${OFFLINE_DEB_DIR}.old"
    log "Cached offline dependencies in $OFFLINE_DEB_DIR."
}

seed_cache_from_apt_archives() {
    [[ -d "$OFFLINE_DEB_DIR" ]] || mkdir -p "$OFFLINE_DEB_DIR"
    copy_apt_archives_to_cache "$OFFLINE_DEB_DIR"
}

refresh_cache() {
    log "=== r8125 offline cache refresh (kernel: $(kernel)) ==="
    if cache_offline_deps; then
        log "=== cache refresh complete ==="
        return 0
    fi
    warn "Full cache refresh failed; trying apt archives only."
    seed_cache_from_apt_archives
    if all_headers_cached; then
        log "=== cache refresh complete (archives only) ==="
        return 0
    fi
    warn "Offline cache still missing headers for some kernels."
    return 1
}

offline_deps_pending() {
    local deb pkg
    shopt -s nullglob
    for deb in "$OFFLINE_DEB_DIR"/*.deb; do
        pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null) || continue
        pkg_installed "$pkg" || { shopt -u nullglob; return 0; }
    done
    shopt -u nullglob
    return 1
}

install_offline_deps() {
    [[ -d "$OFFLINE_DEB_DIR" ]] || { warn "No offline cache at $OFFLINE_DEB_DIR."; return 1; }
    have dpkg dpkg-deb || return 1
    offline_deps_pending || { log "Cached offline dependencies already installed."; return 0; }

    writable_root
    local pass files=() deb pkg
    for pass in 1 2 3; do
        files=()
        shopt -s nullglob
        for deb in "$OFFLINE_DEB_DIR"/*.deb; do
            pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null) || continue
            pkg_installed "$pkg" || files+=("$deb")
        done
        shopt -u nullglob
        [[ ${#files[@]} -eq 0 ]] && return 0
        log "Installing ${#files[@]} cached package(s) (pass $pass)."
        dpkg -i "${files[@]}" 2>/dev/null || true
    done
    offline_deps_pending && return 1
    return 0
}

dkms_rebuild() {
    have dkms || return 1
    headers_ok || return 1
    log "DKMS build $DKMS_NAME/$DKMS_VERSION for $(kernel)."
    dkms install -m "$DKMS_NAME" -v "$DKMS_VERSION" -k "$(kernel)"
}

dpkg_install_driver() {
    local online="${1:-0}" force="${2:-}"
    local opts=(-i)
    [[ -n "$force" ]] && opts=(--force-reinstall -i)
    if dpkg "${opts[@]}" "$DEB_FILE"; then
        return 0
    fi
    [[ "$online" == 1 ]] || return 1
    have apt-get || return 1
    warn "dpkg failed; running apt --fix-broken."
    apt-get update -qq && apt-get install --fix-broken -y -qq
}

ensure_driver() {
    local online="${1:-0}"

    if valid_deb; then
        log "Using cached package at $DEB_FILE."
    elif [[ "$online" == 1 ]]; then
        download_deb
    else
        die "No cached .deb at $DEB_FILE (boot repair is offline-only)."
    fi

    writable_root
    install_offline_deps || [[ "$online" == 1 ]] || warn "Cached dependencies missing or incomplete."

    if ! headers_ok; then
        if [[ "$online" != 1 ]] && ! headers_cached_for "$(kernel)"; then
            die "No linux-headers-$(kernel) in offline cache (needed for DKMS after update)."
        fi
        warn "Kernel headers missing for $(kernel); DKMS may fail."
    fi

    if pkg_installed "$PACKAGE_NAME" && mod_built; then
        log "Driver already built for $(kernel)."
        return 0
    fi

    if pkg_installed "$PACKAGE_NAME"; then
        dkms_rebuild && { depmod -a "$(kernel)" || true; return 0; }
        warn "DKMS rebuild failed; reinstalling package."
        dpkg_install_driver "$online" force || die "Package reinstall failed; run --install while online."
    else
        log "Installing $DEB_FILE."
        dpkg_install_driver "$online" || die "Package install failed; run --install while online."
    fi
    depmod -a "$(kernel)" || warn "depmod failed."
}

blacklist_r8169() {
    grep -q '^[[:space:]]*blacklist[[:space:]]\+r8169' "$BLACKLIST_FILE" 2>/dev/null && return 1
    mkdir -p "$(dirname "$BLACKLIST_FILE")"
    log "Blacklisting r8169 in $BLACKLIST_FILE."
    printf '%s\n' "# Prefer DKMS r8125 for RTL8125." "blacklist r8169" >> "$BLACKLIST_FILE"
}

update_initramfs() {
    have update-initramfs || { warn "update-initramfs unavailable."; return 1; }
    writable_root
    log "Updating initramfs for $(kernel)."
    update-initramfs -u
}

load_r8125() {
    mod_loaded && { log "r8125 already loaded."; return 0; }
    if r8169_loaded; then
        warn "Unloading r8169 before loading r8125."
        modprobe -r r8169 || warn "Could not unload r8169."
    fi
    log "Loading r8125."
    modprobe "$MODULE_NAME"
}

preinit_registered() {
    have midclt || return 1
    midclt call initshutdownscript.query '[["command","=","/bin/bash /data/scripts/r8125-posthook.sh"],["when","=","PREINIT"]]' 2>/dev/null \
        | grep -Fq "$PREINIT_CMD"
}

register_preinit() {
    have midclt || { warn "midclt missing; add PREINIT Command manually: $PREINIT_CMD"; return 1; }
    preinit_registered && { log "PREINIT Command already registered."; return 0; }

    log "Registering PREINIT Command (timeout ${PREINIT_TIMEOUT}s)."
    if midclt call initshutdownscript.create "{\"type\":\"COMMAND\",\"command\":\"/bin/bash /data/scripts/r8125-posthook.sh\",\"when\":\"PREINIT\",\"enabled\":true,\"timeout\":${PREINIT_TIMEOUT},\"comment\":\"Restore Realtek r8125 DKMS driver before network startup\"}" >/dev/null; then
        log "PREINIT Command registered."
        return 0
    fi
    warn "Auto-registration failed; add manually under Init/Shutdown Scripts."
    return 1
}

shutdown_cache_registered() {
    have midclt || return 1
    midclt call initshutdownscript.query '[["command","=","/bin/bash /data/scripts/r8125-posthook.sh --refresh-cache"],["when","=","SHUTDOWN"]]' 2>/dev/null \
        | grep -Fq "$SHUTDOWN_CACHE_CMD"
}

register_shutdown_cache() {
    have midclt || { warn "midclt missing; add SHUTDOWN Command manually: $SHUTDOWN_CACHE_CMD"; return 1; }
    shutdown_cache_registered && { log "SHUTDOWN cache Command already registered."; return 0; }

    log "Registering SHUTDOWN cache Command (timeout ${SHUTDOWN_CACHE_TIMEOUT}s)."
    if midclt call initshutdownscript.create "{\"type\":\"COMMAND\",\"command\":\"/bin/bash /data/scripts/r8125-posthook.sh --refresh-cache\",\"when\":\"SHUTDOWN\",\"enabled\":true,\"timeout\":${SHUTDOWN_CACHE_TIMEOUT},\"comment\":\"Cache r8125 DKMS deps for next boot (incl. new kernels)\"}" >/dev/null; then
        log "SHUTDOWN cache Command registered."
        return 0
    fi
    warn "SHUTDOWN cache registration failed; add manually under Init/Shutdown Scripts."
    return 1
}

remove_legacy_systemd() {
    local unit="/etc/systemd/system/r8125-posthook.service"
    [[ -e "$unit" ]] || return 0
    warn "Removing legacy systemd unit $unit."
    writable_root
    have systemctl && systemctl disable --now r8125-posthook.service >/dev/null 2>&1 || true
    rm -f "$unit" || warn "Could not remove $unit."
    have systemctl && systemctl daemon-reload >/dev/null 2>&1 || true
}

repair() {
    local online="${1:-0}"
    local changed=0 installed=0

    log "=== r8125 repair (kernel: $(kernel)) ==="
    blacklist_r8169 && changed=1

    if mod_loaded; then
        [[ $changed -eq 1 ]] && update_initramfs || warn "Reboot after initramfs update."
        log "=== repair complete ==="
        return 0
    fi

    if mod_built; then
        log "r8125 module present for $(kernel)."
    else
        log "r8125 missing for $(kernel); installing/rebuilding driver."
        ensure_driver "$online"
        installed=1
    fi

    [[ $changed -eq 1 || $installed -eq 1 ]] && update_initramfs || warn "Reboot may be needed after initramfs update."

    if load_r8125; then
        log "SUCCESS: r8125 loaded."
    else
        warn "Load failed; rebuilding driver and retrying once."
        ensure_driver "$online"
        update_initramfs || true
        load_r8125 || die "r8125 still not loaded; check dmesg and /var/log/r8125-posthook.log"
        log "SUCCESS: r8125 loaded after rebuild."
    fi
    log "=== repair complete ==="
}

run_install() {
    echo "=== r8125-posthook install ==="
    mkdir -p "$SCRIPT_DIR"

    local self
    self=$(realpath "$0")
    if [[ "$self" != "$PERSISTENT_SCRIPT" ]]; then
        cp "$self" "$PERSISTENT_SCRIPT"
        echo "Copied to $PERSISTENT_SCRIPT"
    fi
    chmod +x "$PERSISTENT_SCRIPT"

    download_deb
    cache_offline_deps || warn "Offline dep cache not refreshed; boot repair may need network."
    repair 1
    update_initramfs || warn "Reboot may be required."
    register_preinit
    register_shutdown_cache
    remove_legacy_systemd

    cat <<EOF

Install complete.
  Script:   $PERSISTENT_SCRIPT
  Package:  $DEB_FILE
  Deps:     $OFFLINE_DEB_DIR
  PREINIT:  $PREINIT_CMD
  SHUTDOWN: $SHUTDOWN_CACHE_CMD

Reboot, then: sudo bash $PERSISTENT_SCRIPT --check
Before a WebUI update, --check should be READY (headers cached for every kernel on the system).
EOF
}

blacklisted() {
    grep -q '^[[:space:]]*blacklist[[:space:]]\+r8169' "$BLACKLIST_FILE" 2>/dev/null
}

run_check() {
    local issues=() missing_hdrs=()
    local loaded built blacklisted_ok headers deb deps preinit shutdown dkms k

    loaded=$(mod_loaded && echo yes || echo no)
    built=$(mod_built && echo yes || echo no)
    blacklisted_ok=$(blacklisted && echo yes || echo no)
    headers=$(headers_ok && echo yes || echo no)
    deb=$(valid_deb && echo yes || echo no)
    deps=$(cached_deps_ok && echo yes || echo no)
    preinit=$(preinit_registered && echo yes || echo no)
    shutdown=$(shutdown_cache_registered && echo yes || echo no)
    dkms=$(dkms_ok && echo yes || echo no)
    while read -r k; do
        [[ -n "$k" ]] || continue
        headers_cached_for "$k" || missing_hdrs+=("$k")
    done < <(kernel_versions)

    yn() { [[ "$1" == yes ]] && echo YES || echo NO; }

    echo "Kernel:          $(kernel)"
    echo "Module loaded:   $(yn "$loaded")"
    echo "Module built:    $(yn "$built")"
    echo "r8169 loaded:    $(r8169_loaded && echo YES || echo NO)"
    echo "r8169 blacklist: $(yn "$blacklisted_ok")"
    echo "Kernel headers:  $(yn "$headers")"
    echo "Cached .deb:     $(yn "$deb")"
    echo "Cached deps:     $(yn "$deps")"
    if [[ ${#missing_hdrs[@]} -gt 0 ]]; then
        echo "  missing hdrs:  ${missing_hdrs[*]}"
    fi
    echo "PREINIT task:    $(yn "$preinit")"
    echo "SHUTDOWN cache:  $(yn "$shutdown")"
    echo "DKMS ($(kernel)): $(yn "$dkms")"
    if [[ "$dkms" == yes ]]; then
        dkms status -m "$DKMS_NAME" -k "$(kernel)" 2>/dev/null | sed 's/^/  /'
    fi

    [[ "$loaded" == yes ]] || issues+=("r8125 is not loaded")
    [[ "$built" == yes ]] || issues+=("r8125 module is not built for this kernel")
    r8169_loaded && issues+=("r8169 is still loaded (conflicts with r8125)")
    [[ "$blacklisted_ok" == yes ]] || issues+=("r8169 is not blacklisted")
    [[ "$headers" == yes ]] || issues+=("kernel headers are missing for $(kernel)")
    [[ "$deb" == yes ]] || issues+=("driver .deb is not cached at $DEB_FILE")
    if [[ "$deps" != yes ]]; then
        if [[ ${#missing_hdrs[@]} -gt 0 ]]; then
            issues+=("offline cache missing linux-headers for: ${missing_hdrs[*]}")
        else
            issues+=("offline dependency cache is missing or empty")
        fi
    fi
    [[ "$preinit" == yes ]] || issues+=("PREINIT boot task is not registered")
    [[ "$shutdown" == yes ]] || issues+=("SHUTDOWN cache refresh task is not registered")
    [[ "$dkms" == yes ]] || issues+=("DKMS driver is not installed for $(kernel)")

    echo
    if [[ ${#issues[@]} -eq 0 ]]; then
        echo "READY: System is prepared for a TrueNAS update."
        exit 0
    fi

    echo "NOT READY:"
    printf '  - %s\n' "${issues[@]}"
    echo
    echo "Fix with: sudo bash $PERSISTENT_SCRIPT --install"
    exit 1
}

case "${1:-}" in
    --install)        require_root; run_install ;;
    --check)          run_check ;;
    --refresh-cache)  require_root; refresh_cache ;;
    *)                require_root; repair 0 ;;
esac
