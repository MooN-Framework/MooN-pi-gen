#!/bin/bash -e
#
# Briefly remounts the rootfs read-write. For emergency/maintenance use
# from an interactive SSH session only (deploy of NODE SOFTWARE never
# needs this -- that goes through the .moonpkg package service and
# /boot/firmware, which stays writable independent of this flag).
#
# Always pair with moon-remount-ro.sh afterwards. The system is not
# meant to run for extended periods with rootfs writable.

mount -o remount,rw /
echo "moon: / is now read-write -- remember to run moon-remount-ro.sh when done"
