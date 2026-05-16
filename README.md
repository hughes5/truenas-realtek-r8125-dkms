# TrueNAS SCALE Realtek r8125 DKMS helper

Unofficial fork: packages the Realtek `r8125` DKMS driver and a helper that survives TrueNAS boot-environment updates. Install once; after updates, a **PREINIT** task rebuilds or reloads `r8125` before normal networking when possible.

**Tested on:** not yet verified on hardware.

## Quick start

From a clone of this repo:

```bash
sudo bash r8125-posthook.sh --install
sudo reboot
sudo bash /data/scripts/r8125-posthook.sh --check
```

`--check` prints **READY** when the system is prepared for a WebUI update, or **NOT READY** with what to fix.

## Commands

| Command | Purpose |
|--------|---------|
| `sudo bash r8125-posthook.sh --install` | One-time setup (from repo) |
| `sudo bash /data/scripts/r8125-posthook.sh --check` | Diagnostics only |
| `sudo bash /data/scripts/r8125-posthook.sh` | Manual repair (same as PREINIT) |
| `sudo bash /data/scripts/r8125-posthook.sh --refresh-cache` | Refresh offline deps (same as SHUTDOWN task) |

`--install` copies the script to `/data/scripts/`, downloads the release `.deb`, caches DKMS build dependencies under `/data/scripts/r8125-offline-debs/` (headers for every installed kernel), blacklists `r8169`, installs the package, updates initramfs, loads `r8125`, and registers TrueNAS **Command** tasks at **PREINIT** and **SHUTDOWN**:

```bash
/bin/bash /data/scripts/r8125-posthook.sh
```

If `midclt` registration fails, add under **System Settings → Advanced → Init/Shutdown Scripts** (Type **Command**, not Script):

| When | Timeout | Command |
|------|---------|---------|
| Pre Init | 600 | `/bin/bash /data/scripts/r8125-posthook.sh` |
| Shutdown | 900 | `/bin/bash /data/scripts/r8125-posthook.sh --refresh-cache` |

`--install` also removes legacy `/etc/systemd/system/r8125-posthook.service` if it exists.

**Already set up?** Re-run `--install` once while online so the script on `/data/scripts/` picks up the SHUTDOWN cache task, 600s PREINIT timeout, and multi-kernel offline headers cache.

## After TrueNAS updates

TrueNAS updates ship a **new kernel** in a new boot environment. `/data` (script, driver `.deb`, offline deps) survives; rootfs packages do not. This helper is built for that:

1. **SHUTDOWN** (before reboot) — Refreshes `/data/scripts/r8125-offline-debs/` with DKMS build deps and `linux-headers` for every kernel visible on the system (`/lib/modules`, installed `linux-image-*` packages, and headers already downloaded into `/var/cache/apt/archives/` after a WebUI update). Reboot for the update **after** that shutdown runs so the new kernel’s headers are on `/data`.
2. **PREINIT** (first boot on the new kernel) — Offline repair: blacklist `r8169`, reinstall deps and driver from cache, DKMS-build for the running kernel, load `r8125` (no GitHub or `apt-get`).

Run `--check` before applying a WebUI update; it should be **READY** (cached headers for each kernel version the script knows about). If repair still fails, see `/var/log/r8125-posthook.log`.

## Manual steps (reference)

```bash
sudo /usr/local/libexec/disable-rootfs-protection
sudo mount -o remount,rw /
echo -e "# Prefer r8125.\nblacklist r8169" | sudo tee /etc/modprobe.d/blacklist-r8169.conf
sudo apt-get update
sudo dpkg -i realtek-r8125-dkms_9.016.01-1_amd64.deb
sudo apt install --fix-broken
sudo update-initramfs -u && sudo reboot
```

## Build `.deb`

```bash
sudo apt install devscripts debmake debhelper build-essential dkms dh-dkms
dpkg-buildpackage -b -rfakeroot -us -uc
```

Tags trigger [GitHub Actions](.github/workflows/build-deb.yml) to publish the release `.deb`.

## Links

- [torsten-online notes](https://github.com/torsten-online/truenas-realtek-r8125-dkms)
- [awesometic realtek-r8125-dkms](https://github.com/awesometic/realtek-r8125-dkms)
- [Init/Shutdown API](https://api.truenas.com/v25.10.0/api_methods_initshutdownscript.create.html)
