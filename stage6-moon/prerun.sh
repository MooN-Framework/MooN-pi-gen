#!/bin/bash -e
#
# Start from the finished stage2 rootfs (Raspberry Pi OS Lite) unless this
# stage's rootfs already exists (incremental rebuild). To re-run
# stage6-moon on a clean copy, delete work/<IMG_NAME>/stage6-moon.

if [ ! -d "${ROOTFS_DIR}" ]; then
	copy_previous
fi
