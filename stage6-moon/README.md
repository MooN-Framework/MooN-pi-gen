# stage6-moon

Custom, final pi-gen stage producing a headless MooN cluster-node image
on top of Raspberry Pi OS Lite (stage0-2). Select it via `STAGE_LIST` in
your `config` (see `../config.moon.sample`).

## Substages

- **00-headless-hardening** — disables WLAN/Bluetooth (device tree
  overlays), disables HDMI, deauthorizes all USB ports at boot via a
  oneshot systemd service. Ethernet and the SD/eMMC boot storage are
  untouched.
- **01-static-network** — replaces NetworkManager/dhcpcd/wpa_supplicant
  with `systemd-networkd` and a single static address on `eth0` (or
  whichever interface `MOON_ETH_IFACE` names).
- **02-ssh-access** — SSH itself is enabled via the stock pi-gen
  `ENABLE_SSH`/`FIRST_USER_PASS` variables; this substage just makes
  sure password auth is on and drops a login banner warning that the
  password is a shared default.
- **03-moon-package-service** — installs the `.moonpkg` package loader
  (`moon-pkg-load.service`) and a placeholder `moon-node.service` that
  starts whatever the package extracts to `/opt/moon` (tmpfs).
- **04-readonly-rootfs** — mounts `/` read-only (via `/etc/fstab`), moves
  `/tmp`, `/var/log`, `/var/tmp` onto tmpfs so ordinary runtime writes
  still work, points journald at volatile storage, disables the
  first-boot partition auto-resize (incompatible with a permanently
  read-only root), and pre-bakes SSH host keys + `/etc/machine-id` at
  build time (both are normally generated on first boot, which needs a
  writable `/etc`). Ships `moon-remount-rw.sh` / `moon-remount-ro.sh` for
  deploy scripts that occasionally need a brief writable window.
- **05-image-integrity** — at *build* time, hashes the security-critical
  files listed in `05-image-integrity/files/manifest-paths.txt` and
  signs the resulting manifest with `MOON_SIGNING_PRIVKEY`. At *boot*
  time, `moon-integrity.service` re-hashes those same files and compares
  them against the signed manifest before the package loader is allowed
  to run.

## Package format (`.moonpkg`)

Plain tar container with three members:

| member            | contents                                              |
|-------------------|--------------------------------------------------------|
| `manifest.json`   | `{"name","version","created","payload_sha256"}`        |
| `manifest.sig`    | raw ed25519 signature of `manifest.json`                |
| `payload.tar.gz`  | extracted verbatim to `/opt/moon` (tmpfs)               |

Build one with `tools/build-moon-package.sh`, deploy it to the target's
boot partition as `/boot/firmware/moon-package.moonpkg` before/at boot.
`moon-pkg-load.service` verifies the signature, then the payload hash,
before extracting anything or letting `moon-node.service` start.

## What's persistent and what isn't

- **Persistent**: the rootfs partition itself (this image, as flashed —
  it just happens to be mounted read-only), and whatever `.moonpkg`
  files sit on `/boot/firmware` (that partition is untouched by the
  read-only setting, deploy tooling can read/write it freely).
- **Not persistent**: everything `moon-pkg-load.service` extracts. Every
  boot re-verifies and re-extracts the current `/boot/firmware/moon-package.moonpkg`
  fresh into `/opt/moon` (tmpfs) — there is no on-disk cache, no A/B
  slot, no rollback. Swapping the `.moonpkg` file and rebooting is the
  entire update mechanism for node software.
- **Briefly writable, by hand only**: `/` itself, via
  `moon-remount-rw.sh` (paired with `moon-remount-ro.sh` afterwards) —
  for maintenance from an interactive SSH session, not part of the
  normal deploy path.

## OS image integrity

This is a **boot-time hash check over a curated file list**, not
dm-verity: cheap at boot, but only covers what's in
`manifest-paths.txt`. Extend that list for more coverage. A mismatch
sets `/run/moon/integrity-failed`, which blocks the package loader (and
therefore the node process) from starting — but does not stop SSH/the
rest of the system, so the box stays reachable for debugging.

## Keys

```
tools/gen-moon-keys.sh ./keys
```

`moon-signing-pub.pem` goes into the image (package + manifest
verification). `moon-signing-key.pem` only needs to touch the build
host during `05-image-integrity` (to sign the rootfs manifest) and
whenever you sign a new package with `tools/build-moon-package.sh`.
Keep it off the image and out of version control.

## Reconfiguring a deployed Pi (`tools/moon-deploy.sh`)

For swapping a node's package and/or static IP after it's already
flashed and running, without rebuilding or reflashing:

```
tools/moon-deploy.sh -H 192.168.10.10 --pkg build/moon-node-v3.moonpkg
tools/moon-deploy.sh -H 192.168.10.10 --ip 192.168.10.42/24 --reboot
tools/moon-deploy.sh -H 192.168.10.10 --pkg build/moon-node-v3.moonpkg --ip 192.168.10.42/24 --reboot
```

Package swaps land on `/boot/firmware` (always writable, untouched by
the read-only rootfs) and are picked up live by restarting
`moon-pkg-load.service`/`moon-node.service` — no reboot needed unless
you also change the IP. IP changes go through
`moon-remount-rw.sh`/`moon-remount-ro.sh` on the target and are
deliberately NOT applied live (see the script's header comment for
why) — pass `--reboot` or apply them yourself over a connection that
survives the address change. Requires `PASSWORDLESS_SUDO=1` (already
in `config.moon.sample`) since it runs `sudo` non-interactively over
SSH. `--dry-run` prints the ssh/scp commands instead of running them.

## Known trade-offs (by design, discussed before building this stage)

- SSH password auth stays on with a hardcoded default password (`123`
  in the sample config) — accepted for an internal test topology, not
  for anything internet-facing.
- No dm-verity / Secure Boot: rootfs integrity relies on mount-level
  read-only (04) plus the signed boot-time hash check over a curated
  file list (05); Secure Boot was ruled out earlier for this project
  due to irreversible OTP fuses. See "why not dm-verity" below.
- SSH host keys and `/etc/machine-id` are baked in at image-build time
  (needed because `/etc` is permanently read-only, so first-boot
  generation can't happen). Every SD card flashed from the *same* built
  image therefore shares host keys and machine-id; a fresh `./build.sh`
  run produces new ones. Fine for a controlled cluster topology, not
  for anything where per-node identity at the crypto/OS level matters —
  flag for later if that changes.
- `/etc/fstab` and `/boot/firmware/cmdline.txt` are intentionally left
  out of the integrity manifest (05) even though this stage edits them:
  pi-gen's own `export-image/04-set-partuuid` step rewrites both
  *after* every custom stage has already run, substituting the real
  PARTUUID for the `ROOTDEV` placeholder. Hashing them here would hash
  content that never actually ships.

### Why not dm-verity

dm-verity would additionally need: the rootfs as its own precisely
block-aligned partition plus a separate hash-tree partition (pi-gen's
`export-image/` builds a single boot+root layout, would need real
surgery); a `veritysetup format` pass against the already-exported
image's loop device (a post-export step, not a normal pi-gen stage);
the resulting root hash wired into the kernel cmdline; and an initramfs
that actually enforces the check before pivoting to the real root
(Raspberry Pi OS boots without an initramfs by default, so one would
have to be built and wired in from scratch). The mount-`ro` + tmpfs
approach here gets the same practical outcome — nothing rootfs-side is
persisted across boots by accident — without any of that, at the cost
of not being a cryptographic block-level guarantee, only a
mount-option one backed by a curated file hash check.
