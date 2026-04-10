#!/usr/bin/env bash
# zfs-install — partition a disk and install Ubuntu 26.04 bootc image onto ZFS root.
#
# Usage:
#   sudo zfs-install /dev/sdX [--pool-name rpool] [--imgref ghcr.io/hanthor/ubuntu-26.04-desktop-bootc:latest]
#
# What this does:
#   1. Wipes disk and creates a GPT partition table with EFI + ZFS data partitions
#   2. Creates a ZFS pool with sensible defaults (lz4, acltype=posixacl, xattr=sa)
#   3. Creates rpool/root, rpool/var, rpool/home datasets
#   4. Mounts everything under /mnt/target
#   5. Runs: bootc install to-filesystem --source-imgref <ref> /mnt/target
#
# ZFS kernel args written to the BLS entry by bootc:
#   root=ZFS=rpool/root  (via --karg)
#
# The installed system's dracut initramfs includes the 'zfs' module (added via
# zfs-dracut package + dracut.conf.d config in the bootc image), which handles
# `zpool import` before pivot_root.

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_cmd() {
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
    done
}

cleanup() {
    info "Cleaning up mounts..."
    umount -R /mnt/target 2>/dev/null || true
    zpool export "${POOL_NAME}" 2>/dev/null || true
}

# ── argument parsing ──────────────────────────────────────────────────────────

DISK=""
POOL_NAME="rpool"
IMGREF=""
ENCRYPTION=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --pool-name) POOL_NAME="$2"; shift 2 ;;
        --imgref)    IMGREF="$2";    shift 2 ;;
        --encrypt)   ENCRYPTION=1;   shift   ;;
        -*)          die "Unknown option: $1" ;;
        *)           DISK="$1";      shift   ;;
    esac
done

[[ -n "${DISK}" ]]      || die "Usage: zfs-install /dev/sdX [--pool-name rpool] [--imgref <ref>] [--encrypt]"
[[ -b "${DISK}" ]]      || die "Not a block device: ${DISK}"
[[ "${EUID}" -eq 0 ]]   || die "Must run as root"

require_cmd sgdisk mkfs.fat zpool zfs bootc

# Derive partition names (handles /dev/sdX → /dev/sdX1, /dev/nvme0n1 → /dev/nvme0n1p1)
if [[ "${DISK}" =~ nvme|mmcblk|loop ]]; then
    EFI_PART="${DISK}p1"
    ZFS_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ZFS_PART="${DISK}2"
fi

# Default imgref: read from /etc/bootc-installer/images.json if present
if [[ -z "${IMGREF}" ]]; then
    if [[ -f /etc/bootc-installer/images.json ]]; then
        IMGREF=$(python3 -c "
import json, sys
d = json.load(open('/etc/bootc-installer/images.json'))
print(d['local_imgref'])
" 2>/dev/null) || true
    fi
    [[ -n "${IMGREF}" ]] || IMGREF="ghcr.io/hanthor/ubuntu-26.04-desktop-bootc:latest"
fi

# ── confirmation ──────────────────────────────────────────────────────────────

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  Ubuntu 26.04 ZFS root installer                           │"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │  Disk:      ${DISK}"
echo "  │  Pool:      ${POOL_NAME}"
echo "  │  Image:     ${IMGREF}"
echo "  │  Encrypt:   $([ ${ENCRYPTION} -eq 1 ] && echo yes || echo no)"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  WARNING: All data on ${DISK} will be DESTROYED!"
echo ""
read -r -p "  Type 'yes' to continue: " CONFIRM
[[ "${CONFIRM}" == "yes" ]] || die "Aborted."

trap cleanup EXIT

# ── 1. Partition ──────────────────────────────────────────────────────────────

info "Partitioning ${DISK}..."
sgdisk --zap-all "${DISK}"
sgdisk -n1:0:+512M  -t1:ef00 -c1:"EFI System"  "${DISK}"
sgdisk -n2:0:0      -t2:bf00 -c2:"ZFS"          "${DISK}"
partprobe "${DISK}" && sleep 1

info "Formatting EFI partition ${EFI_PART}..."
mkfs.fat -F32 -n EFI "${EFI_PART}"

# ── 2. Create ZFS pool ────────────────────────────────────────────────────────

info "Creating ZFS pool '${POOL_NAME}' on ${ZFS_PART}..."

ZFS_CREATE_OPTS=(
    -f
    -o ashift=12
    -O compression=lz4
    -O acltype=posixacl
    -O xattr=sa
    -O relatime=on
    -O normalization=formD
    -O dnodesize=auto
    -O canmount=off
    -O mountpoint=none
)

if [[ ${ENCRYPTION} -eq 1 ]]; then
    info "Encryption enabled — you will be prompted for a passphrase."
    ZFS_CREATE_OPTS+=(
        -O encryption=aes-256-gcm
        -O keylocation=prompt
        -O keyformat=passphrase
    )
fi

zpool create "${ZFS_CREATE_OPTS[@]}" "${POOL_NAME}" "${ZFS_PART}"

# ── 3. Create datasets ────────────────────────────────────────────────────────

info "Creating ZFS datasets..."
zfs create -o mountpoint=/ -o canmount=noauto "${POOL_NAME}/root"
zfs create -o mountpoint=/var                  "${POOL_NAME}/var"
zfs create -o mountpoint=/home                 "${POOL_NAME}/home"

# Write pool bootfs property so the kernel cmdline is a fallback
zpool set bootfs="${POOL_NAME}/root" "${POOL_NAME}"

# ── 4. Mount ──────────────────────────────────────────────────────────────────

info "Mounting target filesystem at /mnt/target..."
mkdir -p /mnt/target
zfs mount -o mountpoint=/mnt/target "${POOL_NAME}/root"
mkdir -p /mnt/target/{var,home,boot/efi}
mount -t zfs "${POOL_NAME}/var"  /mnt/target/var
mount -t zfs "${POOL_NAME}/home" /mnt/target/home
mount "${EFI_PART}" /mnt/target/boot/efi

# ── 5. Install bootc image ────────────────────────────────────────────────────

info "Installing bootc image '${IMGREF}' to /mnt/target..."
info "(This will take several minutes.)"

bootc install to-filesystem \
    --source-imgref "${IMGREF}" \
    --karg "root=ZFS=${POOL_NAME}/root" \
    --karg "rootfstype=zfs" \
    /mnt/target

# Write /etc/zfs/zpool.cache for reliable import on subsequent boots
info "Saving pool cache to installed system..."
mkdir -p /mnt/target/etc/zfs
zpool set cachefile=/mnt/target/etc/zfs/zpool.cache "${POOL_NAME}"

info ""
info "Installation complete!"
info "  Pool:        ${POOL_NAME}"
info "  Boot entry:  root=ZFS=${POOL_NAME}/root rootfstype=zfs"
info ""
info "Reboot and remove the live media to boot into the installed system."
