# Operation

## Flashing and first boot

1. Write the image to the SD card, for example with Raspberry Pi Imager
   ("Use custom", without OS customisation, the image needs none) or with
   `bmaptool copy image.img /dev/sdX`.
2. Mount the boot partition (`bootfs`, VFAT) and copy the node package:
   `cp moon-node-a.moonpkg /media/$USER/bootfs/moon-package.moonpkg`
3. Unmount, insert the card, connect Ethernet, power on.
4. The node comes up with the address from `MOON_ETH_ADDRESS`. When several
   nodes are flashed from the same image, bring them up one at a time and
   assign individual addresses with `moon-deploy.sh --ip` (see below) to avoid
   address conflicts.

There is no first-boot wizard and no partition resize. The node is fully
operational after the first boot.

## Checking a node

```bash
ssh moon@<node>
systemctl status moon-integrity moon-pkg-load moon-node
journalctl -b -u moon-integrity -u moon-pkg-load -u moon-node
ls /run/moon/                 # package-loaded or integrity-failed
findmnt / /opt/moon           # ro, tmpfs
ls /opt/moon                  # extracted payload
```

| `/run/moon` content | Meaning |
|---|---|
| `package-loaded` | integrity check passed, package verified and extracted |
| `integrity-failed` | a tracked OS file or the manifest signature does not match |
| neither | no package on `/boot/firmware`, or the package failed verification |

## tools/moon-deploy.sh

Reconfigures a running node over SSH without rebuilding or reflashing.

```
tools/moon-deploy.sh -H <host> [-u user] [-i ssh-key]
    [--pkg file.moonpkg]
    [--ip CIDR] [--gateway GW] [--dns DNS] [--iface IFACE]
    [--node-unit file.service] [--signing-key key.pem]
    [--reboot] [--dry-run]
```

| Option | Default | Effect |
|---|---|---|
| `-H` | required | address of the node |
| `-u` | `moon` | SSH user |
| `-i` | none | SSH identity file |
| `--pkg` | none | upload a package as `/boot/firmware/moon-package.moonpkg` |
| `--ip`, `--gateway`, `--dns`, `--iface` | `--iface eth0` | write a new static network configuration |
| `--node-unit` | none | replace `/etc/systemd/system/moon-node.service` |
| `--signing-key` | none | with `--node-unit`: update and re-sign the rootfs manifest |
| `--reboot` | off | reboot the node at the end |
| `--dry-run` | off | print the SSH and SCP commands instead of running them |

At least one of `--pkg`, `--ip` or `--node-unit` is required. The target needs
`PASSWORDLESS_SUDO=1`, since all privileged commands are run with a
non-interactive `sudo`.

### Package swap

```bash
tools/moon-deploy.sh -H 192.168.1.22 --pkg build/moon-node-a-1.1.0.moonpkg
```

The package is uploaded to `/tmp`, moved to `/boot/firmware` (always writable),
and `moon-pkg-load.service` and `moon-node.service` are restarted. No reboot is
needed. The script reports whether `moon-node.service` is active afterwards.

### Changing the address

```bash
tools/moon-deploy.sh -H 192.168.1.22 --ip 192.168.1.31/24 --reboot
```

The new `10-eth0-static.network` is installed inside a short writable window
(`moon-remount-rw.sh` / `moon-remount-ro.sh`). The new address is not applied
live on purpose: restarting `systemd-networkd` over the SSH session that is
bound to the old address can hang the session. Use `--reboot` or apply it over
a connection that survives the change. The network file is outside the
integrity manifest, so the next boot passes the check.

### Patching the node unit

```bash
tools/moon-deploy.sh -H 192.168.1.22 \
  --node-unit stage6-moon/03-moon-package-service/files/moon-node.service \
  --signing-key keys/moon-signing-key.pem
```

`moon-node.service` is a tracked file. With `--signing-key` the script fetches
the node's `/etc/moon/rootfs-manifest.json`, updates the SHA-256 of that one
entry, re-signs the manifest locally and installs unit, manifest and signature
together, so the node also passes `moon-integrity.service` on the next boot.
Without `--signing-key` only the live unit is replaced and the script warns
that the next boot will fail the integrity check. The private key never leaves
the local machine.

### Combined

```bash
tools/moon-deploy.sh -H 192.168.1.22 \
  --pkg build/moon-node-b-1.1.0.moonpkg --ip 192.168.1.32/24 --reboot
```

## Setting up a 2oo3 cluster

1. Build one image and flash three cards.
2. Build three packages (`node-a`, `node-b`, `node-c`), each with its own
   `node.toml`, and copy one onto each boot partition.
3. Boot node A, run `moon-deploy.sh -H <default IP> --ip <IP of A> --reboot`.
   Repeat for B and C.
4. After this the cluster only needs `--pkg` for software or configuration
   updates.

Because all cards of one image share SSH host keys, `ssh` will not complain
when switching between nodes on the same address. After a rebuild of the image
it will, and the old entry has to be removed with `ssh-keygen -R <host>`.

## Manual maintenance

```bash
sudo moon-remount-rw.sh
# … change files …
sudo moon-remount-ro.sh
```

The root filesystem should only be writable for short maintenance windows.
Changes to tracked files make the next boot fail the integrity check unless the
manifest is re-signed (only automated for `moon-node.service`, see above).
Changes to untracked files persist and are not detected. For reproducible
nodes, prefer a rebuild of the image over manual changes.

## Troubleshooting

| Observation | Likely cause | Action |
|---|---|---|
| `moon-integrity: MISMATCH …` in the journal | a tracked file differs from the build | reflash, or re-sign the manifest for intended changes |
| integrity fails on a freshly flashed image | a tracked file is rewritten after `05-image-integrity` (see the note on `kernel8.img`/`initramfs8` in [stage6-moon.md](stage6-moon.md)) | remove the affected path from `manifest-paths.txt` and rebuild |
| `moon-pkg-load: ABORT: manifest signature verification FAILED` | package signed with a different key than the image's public key | re-sign with the correct key |
| `payload hash mismatch` | package altered or corrupted after signing | rebuild the package |
| `moon-node.service` skipped, `package-loaded` missing | no package at `/boot/firmware/moon-package.moonpkg`, or loader failed | check the file name and the loader journal |
| node starts before the network is ready | `systemd-networkd-wait-online` not enabled | check `01-static-network`, rebuild |
| SSH login stalls for 20 to 30 s | reverse DNS lookup | `UseDNS no` is set by `02-ssh-access`, check `sshd_config` |
| a service fails with `Read-only file system` | it writes outside the tmpfs paths | add a tmpfs mount in `04-readonly-rootfs` or configure the service to use `/run` |
| write into `~` fails | home directories are on the read-only rootfs | expected, see [architecture.md](architecture.md) |
