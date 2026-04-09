#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Taken from raw.githubusercontent.com/ublue-os/container-storage-action/0a5a22f1bf116da1683702017185093140526814/mount_btrfs.sh
# Original license: Apache-2.0

set -eo pipefail

# Check if /mnt is a separate mount point; if not, skip this script
if ! mountpoint -q /mnt; then
  echo "/mnt is not a separate mount point, skipping btrfs setup"
  exit 0
fi

BTRFS_TARGET_DIR="${BTRFS_TARGET_DIR:-/var/lib/containers}"
BTRFS_MOUNT_OPTS=${BTRFS_MOUNT_OPTS:-"compress=zstd:1"}
BTRFS_LOOPBACK_FILE=${BTRFS_LOOPBACK_FILE:-/mnt/btrfs_loopbacks/$(systemd-escape -p "$BTRFS_TARGET_DIR")}
BTRFS_LOOPBACK_FREE=${BTRFS_LOOPBACK_FREE:-"0.8"}

btrfs_pdir="$(dirname "$BTRFS_LOOPBACK_FILE")"

sudo apt-get install -y btrfs-progs

MIN_SPACE=$((60 * 1000 * 1000 * 1000))
AVAILABLE=$(findmnt /mnt --bytes --df --json | jq -r '.filesystems[0].avail')
AVAILABLE_HUMAN=$(findmnt /mnt --df --json | jq -r '.filesystems[0].avail')

if [[ "$AVAILABLE" -ge "$MIN_SPACE" ]]; then
  echo "Enough space available: $AVAILABLE_HUMAN"
else
  echo "/mnt doesn't have the desired capacity ($AVAILABLE_HUMAN), continuing without btrfs mount..."
  exit 0
fi

sudo mkdir -p "$btrfs_pdir" && sudo chown "$(id -u)":"$(id -g)" "$btrfs_pdir"
_final_size=$(
    findmnt --target "$btrfs_pdir" --bytes --df --json |
        jq -r --arg freeperc "$BTRFS_LOOPBACK_FREE" \
            '.filesystems[0].avail * ($freeperc | tonumber) | round'
)
truncate -s "$_final_size" "$BTRFS_LOOPBACK_FILE"
unset -v _final_size

sudo mkfs.btrfs -f -r "$BTRFS_TARGET_DIR" "$BTRFS_LOOPBACK_FILE"
sudo systemd-mount "$BTRFS_LOOPBACK_FILE" "$BTRFS_TARGET_DIR" \
    ${BTRFS_MOUNT_OPTS:+ --options="${BTRFS_MOUNT_OPTS}"}
