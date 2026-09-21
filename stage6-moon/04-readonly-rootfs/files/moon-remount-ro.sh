#!/bin/bash -e
#
# Counterpart of moon-remount-rw.sh: flushes pending writes and returns
# the rootfs to its normal read-only state. Also used by
# tools/moon-deploy.sh after installing a new network file or unit.
sync
mount -o remount,ro /
echo "moon: / is read-only again"
