# stage6-moon reference

`stage6-moon` is a custom pi-gen stage that runs after `stage2` (Raspberry Pi
OS Lite). It is selected with `STAGE_LIST="stage0 stage1 stage2 stage6-moon"`,
which skips the desktop stages 3 to 5 entirely. The general mechanics of a
pi-gen stage (`prerun.sh`, numbered substages, `00-packages`, `NN-run.sh`,
`on_chroot`, `EXPORT_IMAGE`) are described in the
[upstream README](https://github.com/RPi-Distro/pi-gen/blob/arm64/README.md#how-the-build-process-works).

Two facts about that mechanism matter for every script in this stage.

* `NN-run.sh` runs **on the build host** with the working directory set to the
  substage directory (pi-gen `pushd`es into it). Relative paths from `config`
  therefore have to be resolved against `BASE_DIR`, the repository root that
  `build.sh` exports.
* Everything inside `on_chroot <<EOF … EOF` runs **inside the target rootfs**
  via QEMU user emulation.

## Stage files

| File | Purpose |
|---|---|
| `prerun.sh` | copies the rootfs of `stage2` into this stage's work directory if it does not exist yet (`copy_previous`) |
| `EXPORT_IMAGE` | tells pi-gen to export an image after this stage, file suffix `-moon` (`-moon-qemu` with `USE_QEMU=1`) |

Substages run in lexical order. Their order is significant, in particular
`05-image-integrity` must stay last because it hashes the finished rootfs.

## 00-headless-hardening

Removes all interfaces a node does not need.

| Action | How |
|---|---|
| WLAN and Bluetooth off | `dtoverlay=disable-wifi`, `dtoverlay=disable-bt` appended to `config.txt` |
| HDMI off, no splash | `hdmi_blanking=2`, `hdmi_ignore_hotplug=1`, `disable_splash=1` in `config.txt` |
| USB off | `moon-disable-usb.service` runs `moon-disable-usb.sh` once per boot |
| cloud-init removed | `apt-get purge cloud-init rpi-cloud-init-mods`, the three seed files on `/boot/firmware` are deleted |

USB is disabled by writing `0` to `authorized` of every root hub
(`/sys/bus/usb/devices/usb*`) and to `authorized_default`, so hot-plugged
devices stay unauthorized as well. This is used instead of blacklisting the
host controller driver because the controller is shared with other on-SoC
functions on some Pi revisions, and because it can be reverted at runtime for
field debugging (`echo 1 > /sys/bus/usb/devices/usbN/authorized`).

cloud-init is purged instead of masked. It keeps its state in `/var/lib/cloud`,
fails on a read-only rootfs and has no function here since network and software
provisioning are handled by `01-static-network` and the package loader.

Ethernet, the SD card / eMMC and the serial console are not touched.

| Installed file | Mode |
|---|---|
| `/etc/systemd/system/moon-disable-usb.service` | 644, enabled |
| `/usr/local/sbin/moon-disable-usb.sh` | 755 |

## 01-static-network

Replaces dynamic network management with a single static address.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `MOON_ETH_IFACE` | no | `eth0` | interface to configure |
| `MOON_ETH_ADDRESS` | **yes** | none | IPv4 address in CIDR notation, e.g. `192.168.1.22/24` |
| `MOON_ETH_GATEWAY` | no | empty | default gateway, not needed for on-link multicast |
| `MOON_ETH_DNS` | no | empty | DNS server, written to a static `/etc/resolv.conf` |

The script renders `files/10-eth0-static.network.template` into
`/etc/systemd/network/10-eth0-static.network`, removes empty lines left by
unset optional values, masks `NetworkManager`, `dhcpcd` and `wpa_supplicant`,
and enables `systemd-networkd` together with `systemd-networkd-wait-online`.
The latter is required because `moon-node.service` waits for
`network-online.target`, which would otherwise be reached immediately and let
the node start before `eth0` has its address.

IPv6 router advertisements and link-local addressing are disabled. There is
deliberately no `systemd-resolved`, nodes talk to each other by address only.

The file name keeps the `eth0` prefix even when `MOON_ETH_IFACE` is different.
`tools/moon-deploy.sh` writes the same file name and must stay in sync with
the template.

## 02-ssh-access

SSH itself and the first user are set up by upstream pi-gen from `ENABLE_SSH`,
`FIRST_USER_NAME` and `FIRST_USER_PASS`. This substage adjusts
`/etc/ssh/sshd_config`.

| Setting | Value | Reason |
|---|---|---|
| `PasswordAuthentication` | `yes` | explicit, in case upstream disabled it |
| `PermitRootLogin` | `no` | root is only reachable via `sudo` |
| `UseDNS` | `no` | no DNS server is configured, the reverse lookup would stall every login by the resolver timeout (about 20 to 30 s) |

It also installs `/etc/motd`, a banner stating that the node uses a shared
default password and must stay on the internal test network.

## 03-moon-package-service

Installs the package loader and the node service. Additional packages from
`00-packages`: `jq`, `openssl`.

| Variable | Required | Meaning |
|---|---|---|
| `MOON_SIGNING_PUBKEY` | **yes** | ed25519 public key (PEM) on the build host, absolute or relative to the repository root |

| Installed file | Mode | Role |
|---|---|---|
| `/etc/moon/moon-signing-pub.pem` | 644 | trust anchor for packages and for the rootfs manifest |
| `/opt/moon/` | 755 | mount point only, the content is tmpfs at runtime |
| `/usr/local/sbin/moon-pkg-load.sh` | 755 | verifies and extracts the package |
| `/etc/systemd/system/opt-moon.mount` | 644, enabled | tmpfs on `/opt/moon` (`mode=0755,nosuid`) |
| `/etc/systemd/system/moon-pkg-load.service` | 644, enabled | oneshot, runs the loader |
| `/etc/systemd/system/moon-node.service` | 644, enabled | starts the node process |

### moon-pkg-load.sh

1. Removes `/run/moon/package-loaded` so a stale flag can never survive.
2. Aborts if `/run/moon/integrity-failed` exists.
3. Aborts if the package or the public key is missing.
4. Extracts `manifest.json`, `manifest.sig` and `payload.tar.gz` into a
   temporary directory below `/run`.
5. Verifies `manifest.sig` over `manifest.json` with
   `openssl pkeyutl -verify -rawin` (pure ed25519).
6. Compares `payload_sha256` from the manifest with the SHA-256 of
   `payload.tar.gz`.
7. Empties `/opt/moon`, extracts the payload into it.
8. Logs package name and version and creates `/run/moon/package-loaded`.

The package path can be overridden with `MOON_PKG_PATH`, the default is
`/boot/firmware/moon-package.moonpkg`. Details of the format are in
[package-format.md](package-format.md).

### moon-node.service

```
ExecStart=/opt/moon/bin/node --config /opt/moon/config/node.toml --log-dir /opt/moon/logs/
Restart=no
ProtectSystem=strict
ReadWritePaths=/opt/moon /run/moon
```

The payload therefore has to provide `bin/node` and `config/node.toml`.
`Restart=no` is intentional. Automatic restarts (previously
`Restart=on-failure`) interfered with testing. A node process that terminated
stays down until it is restarted explicitly. `ProtectSystem=strict` makes the whole file
hierarchy read-only for the process except the two listed paths, in addition
to the read-only rootfs.

## 04-readonly-rootfs

Makes the root filesystem permanently read-only and moves every path that
needs to be written at runtime to RAM.

| Change | Detail |
|---|---|
| `/etc/fstab` root entry | `defaults,noatime` becomes `ro,noatime` |
| First-boot resize | `rpi-resize.service` masked, `resize` removed from `cmdline.txt` |
| tmpfs mounts | `tmp.mount`, `var-log.mount`, `var-tmp.mount`, `var-lib.mount`, `var-cache.mount` |
| journald | `Storage=volatile`, `RuntimeMaxUse=5%` via `journald.conf.d/10-moon-volatile.conf` |
| SSH host keys | regenerated at build time with `ssh-keygen -A` |
| `/etc/machine-id` | generated at build time with `systemd-machine-id-setup` |
| Maintenance helpers | `/usr/local/sbin/moon-remount-rw.sh`, `/usr/local/sbin/moon-remount-ro.sh` |

The fstab edit is guarded. The stage still sees the pi-gen placeholder
`ROOTDEV` (the real PARTUUID is substituted later by
`export-image/04-set-partuuid`). If the root line already reads `ro,noatime`
the script treats it as its own earlier output and continues. Any other format
aborts the build instead of guessing.

All of `/var/lib` and `/var/cache` are on tmpfs, not individual
subdirectories. Every systemd unit that declares `StateDirectory=`,
`CacheDirectory=` or `LogsDirectory=` creates its directory on start and would
fail on a read-only rootfs (observed with cloud-init and `systemd-logind`).
Mounting the parent directories covers all present and future units at once.

Host keys and machine-id are pre-generated because `/etc` is never writable at
runtime. All cards flashed from the same image file share them. A new build
produces new ones. See [security.md](security.md).

The rootfs size is not grown on first boot, so the image has to fit the
target medium as built. The unused space on the card stays unpartitioned.

## 05-image-integrity

Creates and installs the signed rootfs manifest. Additional packages from
`00-packages`: `jq`, `openssl`.

| Variable | Required | Meaning |
|---|---|---|
| `MOON_SIGNING_PRIVKEY` | **yes** | ed25519 private key (PEM) on the build host, absolute or relative to the repository root |

Build time (on the host):

1. Installs `manifest-paths.txt`, `moon-integrity-check.sh` and
   `moon-integrity.service` into the rootfs.
2. Reads `/etc/moon/manifest-paths.txt` from the rootfs, skips comments and
   empty lines and computes the SHA-256 of every listed file. Missing files
   produce a warning and are left out.
3. Writes `rootfs-manifest.json`
   (`{"generated": "<UTC>", "files": [{"path": …, "sha256": …}, …]}`) and
   validates it as JSON.
4. Signs it with `openssl pkeyutl -sign -rawin` and installs manifest and
   signature to `/etc/moon/`.

Boot time (`moon-integrity.service`, before `sysinit.target`):

1. Checks that manifest, signature and public key exist.
2. Verifies the signature.
3. Re-hashes every listed file and logs each `MISSING` or `MISMATCH`.
4. On any failure writes `/run/moon/integrity-failed` and exits with status 1.

Tracked files (`files/manifest-paths.txt`):

| Path | Why |
|---|---|
| `usr/local/sbin/moon-pkg-load.sh` | package verification logic |
| `usr/local/sbin/moon-disable-usb.sh` | USB lock |
| `etc/systemd/system/moon-pkg-load.service` | loader ordering and gating |
| `etc/systemd/system/moon-node.service` | node command line and sandboxing |
| `etc/systemd/system/opt-moon.mount` | tmpfs for the payload |
| `etc/systemd/system/moon-disable-usb.service` | USB lock activation |
| `etc/ssh/sshd_config` | remote access policy |
| `etc/moon/moon-signing-pub.pem` | trust anchor |
| `boot/firmware/config.txt` | radios, HDMI, boot configuration |
| `boot/firmware/kernel8.img` | kernel (status: see note below) |
| `boot/firmware/initramfs8` | initramfs (status: see note below) |

Deliberately not tracked:

| Path | Why |
|---|---|
| `etc/fstab`, `boot/firmware/cmdline.txt` | rewritten by `export-image/04-set-partuuid` after all stages, the hash would never match the shipped file |
| `etc/systemd/network/10-eth0-static.network` | per-node parameter, changed by `moon-deploy.sh --ip` |

Note on `kernel8.img` and `initramfs8`: these entries were added to cover the
boot chain. Their boot-time check did not pass reliably in testing. A likely
cause is that the export step or a kernel package trigger regenerates these
files after `05-image-integrity` has hashed them, the same class of problem as
`fstab` and `cmdline.txt`. Remove both lines if the integrity check fails on a
freshly flashed image.

The check covers a curated list only. Files outside the list can be modified
(after a manual `moon-remount-rw.sh`) without detection. Extend the list for
more coverage.
