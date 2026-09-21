# MooN-pi-gen

Raspberry Pi OS image builder for nodes of the MooN fault-tolerance framework
(`swb_fault_tolerance`). The repository produces a headless, read-only,
integrity-checked 64-bit Raspberry Pi OS Lite image. Node software, node
configuration and node identity are not part of the image. They are delivered
separately as a signed package (`.moonpkg`) on the boot partition, which makes
one image usable for every node of any M-out-of-N topology (for example 2oo3).

This repository is a fork of the official Raspberry Pi image builder
[pi-gen](https://github.com/RPi-Distro/pi-gen), branch
[`arm64`](https://github.com/RPi-Distro/pi-gen/tree/arm64). Everything that is
generic pi-gen behaviour (stages 0 to 5, `export-image`, the full list of build
variables, Docker builds, troubleshooting of the build host) is documented
upstream in the
[pi-gen README](https://github.com/RPi-Distro/pi-gen/blob/arm64/README.md) and
is not repeated here. This documentation only covers what the fork adds or
changes.

## At a glance

| Property | Value |
|---|---|
| Base | Raspberry Pi OS Lite (pi-gen `stage0` to `stage2`), Debian 13 Trixie, `arm64` |
| Target hardware | Raspberry Pi 4 / 5 (`aarch64`) |
| Custom stage | [`stage6-moon`](stage6-moon/) |
| Root filesystem | permanently mounted read-only, runtime state on tmpfs |
| Integrity | ed25519-signed hash manifest over a curated file list, checked at every boot |
| Software delivery | signed `.moonpkg` on `/boot/firmware`, extracted to tmpfs at every boot |
| Network | `systemd-networkd`, single static IPv4 address on Ethernet, no DHCP, no WLAN/BT |
| Access | SSH with password authentication (internal test network only) |
| Update path | `tools/moon-deploy.sh` over SSH, no reflash needed |

## Quick start

```bash
# 1. Build host dependencies (Debian/Ubuntu), see the upstream README for details
sudo apt install coreutils quilt parted qemu-user-binfmt debootstrap zerofree zip \
  dosfstools e2fsprogs libarchive-tools libcap2-bin grep rsync xz-utils file git \
  curl bc gpg pigz xxd arch-test bmap-tools kmod jq openssl

# 2. Signing keypair (once)
tools/gen-moon-keys.sh ./keys

# 3. Build configuration
cp config.sample config
$EDITOR config            # IP address, user, password, key paths

# 4. Build the image (native build recommended, see docs/build.md)
sudo ./build.sh
# result: deploy/image_<date>-moon-node-moon.zip (plus a -lite export of stage2)

# 5. Build and sign a node package
tools/build-moon-package.sh -k keys/moon-signing-key.pem \
  -n moon-node -v 1.0.0 -p ./payload -o moon-node.moonpkg

# 6. Flash the image, copy the package to the boot partition as
#    /boot/firmware/moon-package.moonpkg, boot the Pi
```

## Documentation

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Design goals, image/package split, boot sequence, filesystem layout |
| [docs/stage6-moon.md](docs/stage6-moon.md) | Reference of every substage, installed file and systemd unit |
| [docs/package-format.md](docs/package-format.md) | The `.moonpkg` format, signing and verification |
| [docs/security.md](docs/security.md) | Trust chain, key handling, threat model, accepted trade-offs, rejected alternatives |
| [docs/build.md](docs/build.md) | Build host setup, configuration variables, incremental rebuilds, known pitfalls |
| [docs/operations.md](docs/operations.md) | Flashing, first boot, `moon-deploy.sh`, maintenance, troubleshooting |
| [docs/upstream-changes.md](docs/upstream-changes.md) | Every change relative to upstream pi-gen |

## Repository layout

```
.
├── build.sh, build-docker.sh   pi-gen entry points (patched, see docs/upstream-changes.md)
├── config.sample               build configuration template for MooN images
├── keys/                       ed25519 signing keys (private key must not be committed)
├── stage0 … stage5             unchanged upstream pi-gen stages
├── stage6-moon/                MooN stage (headless, network, SSH, packages, read-only, integrity)
├── tools/                      host-side tools: key generation, package build, remote deploy
├── scripts/                    upstream pi-gen helper functions
└── docs/                       this documentation
```

## License

The pi-gen parts are licensed under the BSD-style license of the upstream
project, see [LICENSE](LICENSE). The MooN additions (`stage6-moon/`, `tools/`,
`docs/`) were developed as part of a master's thesis at Ostfalia Hochschule
für angewandte Wissenschaften (2026).
