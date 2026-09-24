# Building the image

Generic build host requirements, all standard pi-gen variables and the Docker
build are documented in the
[upstream pi-gen README](https://github.com/RPi-Distro/pi-gen/blob/arm64/README.md).
This page covers the MooN-specific configuration and the pitfalls observed
while developing `stage6-moon`.

## Build host

* Debian or Ubuntu based Linux, x86_64 or aarch64
* packages from `depends` (see the upstream README for the `apt install` line)
  plus `jq` and `openssl` on the host, which `05-image-integrity` and the tools
  use
* repository path without spaces (debootstrap limitation)
* working `binfmt_misc` registration for `qemu-aarch64` when building on x86_64

A native build (`sudo ./build.sh`) is the recommended path. The Docker build
(`./build-docker.sh`) works on a native Linux host but has proven unreliable
under WSL2, see below.

## Configuration

`build.sh` sources `./config` (and additionally a file given with `-c`).
Copy `config.sample` and adjust it. `config` itself is listed in `.gitignore`
because it contains passwords and host-specific paths.

### Standard pi-gen variables as used for MooN

| Variable | Value | Purpose |
|---|---|---|
| `IMG_NAME` | `moon-node` | image and work directory name |
| `RELEASE` | `trixie` | Debian 13 base |
| `STAGE_LIST` | `"stage0 stage1 stage2 stage6-moon"` | Lite base plus MooN stage, skips desktop stages |
| `FIRST_USER_NAME` | `moon` | login user, also the default user of `moon-deploy.sh` |
| `FIRST_USER_PASS` | shared default password | SSH password authentication |
| `DISABLE_FIRST_BOOT_USER_RENAME` | `1` | no interactive user wizard on first boot |
| `ENABLE_SSH` | `1` | enables `ssh.service` |
| `PASSWORDLESS_SUDO` | `1` | required by `tools/moon-deploy.sh` |
| `TARGET_HOSTNAME` | `moon-node` | hostname, identical on all nodes |

### MooN variables

| Variable | Required | Used in | Meaning |
|---|---|---|---|
| `MOON_ETH_IFACE` | no, default `eth0` | 01 | interface for the static address |
| `MOON_ETH_ADDRESS` | **yes** | 01 | IPv4 address in CIDR notation |
| `MOON_ETH_GATEWAY` | no | 01 | default gateway |
| `MOON_ETH_DNS` | no | 01 | DNS server, leave empty in the cluster |
| `MOON_SIGNING_PUBKEY` | **yes** | 03 | public key, copied into the image |
| `MOON_SIGNING_PRIVKEY` | **yes** | 05 | private key, used on the host to sign the rootfs manifest |

Key paths may be absolute or relative to the repository root. Both
`03-moon-package-service` and `05-image-integrity` resolve relative paths
against `BASE_DIR`.

`MOON_ETH_ADDRESS` becomes the address of every card flashed from the image.
Individual addresses are assigned afterwards with `tools/moon-deploy.sh --ip`,
see [operations.md](operations.md).

## Running the build

```bash
sudo ./build.sh                 # uses ./config
sudo ./build.sh -c other.conf   # additional config file
```

Output in `deploy/`:

| File | Content |
|---|---|
| `image_<date>-moon-node-moon.zip` | the MooN image (export of `stage6-moon`) |
| `image_<date>-moon-node-lite.zip` | plain Lite image (export of `stage2`, a side effect of its `EXPORT_IMAGE`) |
| `*.info`, `*.bmap`, `build.log` | package list, block map, build log |

To avoid the extra Lite export, create an empty file `stage2/SKIP_IMAGES`
(ignored by git).

## Incremental rebuilds

pi-gen keeps every stage's rootfs in `work/moon-node/<stage>/rootfs` and skips
a stage whose rootfs already exists. After changing only `stage6-moon`, rebuild
just that stage:

```bash
sudo rm -rf work/moon-node/stage6-moon
sudo ./build.sh
```

`prerun.sh` copies the unchanged `stage2` rootfs again and all MooN substages
run on a clean copy. Do not delete single files inside `work/` or re-run a
substage on an already modified rootfs. Several scripts check the initial
state of a file (for example the `fstab` root line) and assume the upstream
state.

A full clean build (`CLEAN=1 sudo ./build.sh` or `sudo rm -rf work/`) is only
needed when earlier stages change or after an aborted build left a busy mount
behind.

## Known pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| A substage is silently skipped, the log shows only a skip line | the `NN-run.sh` lost its executable bit (for example after a ZIP export or a checkout on Windows) | `chmod +x` and commit the mode with `git update-index --chmod=+x <file>` |
| `MOON_*` variables are empty inside stage scripts | upstream `build.sh` exports only its own known variables | fixed in this fork by `set -a` / `set +a` around sourcing the config, see [upstream-changes.md](upstream-changes.md) |
| `MOON_SIGNING_PUBKEY … not found` with a relative path | stage scripts run inside their substage directory | fixed by resolving against `BASE_DIR`, use the variables as documented |
| `root entry not in the expected format` in 04 | `fstab` was modified by something other than this stage | clean rebuild of `stage6-moon` |
| `debootstrap` fails to execute binaries in the chroot (WSL2) | WSL2 has no systemd, the `binfmt` registration of `qemu-user-binfmt` is not triggered | register manually with the `F` (fix-binary) flag, see below |
| `arm64: not supported` inside Docker | Docker Desktop on WSL2 runs in its own VM with its own `binfmt_misc` | build natively, or see the `binfmt_misc` handling in `build-docker.sh` |
| `mv` into `/boot/firmware` fails | VFAT has no Unix ownership, `mv` across filesystems tries to preserve it | use `cp` (or `install`) when the target is `/boot/firmware` |

### Manual binfmt registration on WSL2

```bash
sudo update-binfmts --enable qemu-aarch64 || true
cat /proc/sys/fs/binfmt_misc/qemu-aarch64    # flags line must contain F
```

If the entry is missing or has no `F` flag, re-register it with
`update-binfmts --install … --fix-binary yes` for the `qemu-aarch64-static`
interpreter. The `F` flag makes the kernel open the interpreter at
registration time, so it also works inside the debootstrap chroot where the
interpreter path does not exist.

## Cross-compiling the node binary

The framework binary is not built by pi-gen. It is built separately and put
into a package.

```bash
rustup target add aarch64-unknown-linux-gnu
sudo apt install gcc-aarch64-linux-gnu
# .cargo/config.toml of the framework:
# [target.aarch64-unknown-linux-gnu]
# linker = "aarch64-linux-gnu-gcc"
cargo build --release --target aarch64-unknown-linux-gnu
```

This native toolchain is used instead of `cross`, which depends on Docker and
shares the WSL2 problems described above.
