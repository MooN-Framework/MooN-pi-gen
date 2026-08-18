#!/bin/bash -e
sync
mount -o remount,ro /
echo "moon: / is read-only again"
