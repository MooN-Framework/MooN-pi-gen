# Changes relative to upstream pi-gen

Upstream: <https://github.com/RPi-Distro/pi-gen>, branch
[`arm64`](https://github.com/RPi-Distro/pi-gen/tree/arm64) (64-bit Raspberry Pi
OS). The `master` branch builds 32-bit `armhf` images and is not suitable,
because the MooN framework is compiled for `aarch64`.

The fork keeps upstream stages and scripts untouched wherever possible, so
upstream updates can be merged with little conflict. The exact difference can
always be shown with:

```bash
git remote add upstream https://github.com/RPi-Distro/pi-gen.git
git fetch upstream arm64
git diff upstream/arm64 --stat
```

## Added

| Path | Content |
|---|---|
| `stage6-moon/` | MooN stage, see [stage6-moon.md](stage6-moon.md) |
| `tools/gen-moon-keys.sh` | ed25519 key pair generation |
| `tools/build-moon-package.sh` | build and sign `.moonpkg` packages |
| `tools/moon-deploy.sh` | remote reconfiguration of running nodes |
| `keys/` | location of the signing keys (public key only should be versioned) |
| `config.sample` | build configuration template |
| `docs/`, `README.md` | this documentation |

## Modified upstream files

| File | Change | Reason |
|---|---|---|
| `build.sh` | `set -a` / `set +a` around `source config` and around sourcing the `-c` file | upstream only exports the variables it knows. Custom variables (`MOON_*`) set in `config` were invisible to stage scripts, which run as child processes. With `set -a` every variable from the config files is exported. |
| `build-docker.sh` | `binfmt_misc` is only mounted and registered inside the container if it is empty or missing | an unconditional mount inside a `--privileged` container creates a fresh, empty `binfmt_misc` instance and hides the host's `qemu-aarch64` registration, which caused `arm64: not supported` |

## Removed

| Path | Reason |
|---|---|
| upstream `README.md` | replaced by the MooN documentation, which links to the upstream README for generic pi-gen topics |
| `stage2/04-cloud-init/README.txt` | describes cloud-init seeding, cloud-init is purged in `stage6-moon/00-headless-hardening` |

## Unchanged, not used

`stage3`, `stage4` and `stage5` (desktop and full images) remain in the tree
to keep the fork close to upstream. They are excluded by `STAGE_LIST`.
