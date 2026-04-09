#!/usr/bin/bash
# build-iso.sh <boot-files-tar> <squashfs-img> <output-iso>
#
# Creates a UEFI-bootable systemd-boot live ISO for Ubuntu 26.04.
#
# Boot architecture (no GRUB2, no shim):
#   El Torito EFI entry → EFI/efi.img (FAT ESP image containing):
#     EFI/BOOT/BOOTX64.EFI       systemd-bootx64.efi from Ubuntu
#     loader/loader.conf          systemd-boot configuration
#     loader/entries/ubuntu-26.04-live.conf   boot entry
#     images/pxeboot/vmlinuz      Ubuntu 7.0 kernel
#     images/pxeboot/initrd.img   dmsquash-live initramfs
#   ISO9660 root:
#     EFI/efi.img
#     LiveOS/squashfs.img         squashfs of the full Ubuntu live rootfs
#
# Live boot flow:
#   UEFI → El Torito → FAT ESP → systemd-boot → kernel+initramfs
#   dmsquash-live: scans for CDLABEL=UBUNTU26_LIVE → mounts ISO → squashfs → overlayfs

set -euo pipefail

BOOT_TAR="${1:?Usage: build-iso.sh <boot-files-tar> <squashfs-img> <output-iso>}"
SQUASHFS_SRC="${2:?Usage: build-iso.sh <boot-files-tar> <squashfs-img> <output-iso>}"
OUTPUT_ISO="${3:?Usage: build-iso.sh <boot-files-tar> <squashfs-img> <output-iso>}"
LABEL="UBUNTU26_LIVE"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/iso-build.XXXXXX")
trap "chmod -R u+rwX '${WORK}' 2>/dev/null; rm -rf '${WORK}'" EXIT

BOOT_DIR="${WORK}/boot-files"
ISO_ROOT="${WORK}/iso-root"
ESP_STAGING="${WORK}/esp-staging"

mkdir -p "${BOOT_DIR}" "${ISO_ROOT}/EFI" "${ISO_ROOT}/LiveOS"

echo ">>> Extracting boot files..."
tar -xf "${BOOT_TAR}" -C "${BOOT_DIR}" --no-same-owner

kernel=$(ls "${BOOT_DIR}/usr/lib/modules" | sort -V | tail -1)
echo ">>> Kernel: ${kernel}"

VMLINUZ="${BOOT_DIR}/usr/lib/modules/${kernel}/vmlinuz"
INITRD="${BOOT_DIR}/usr/lib/modules/${kernel}/initramfs.img"
BOOTX64="${BOOT_DIR}/usr/lib/systemd/boot/efi/systemd-bootx64.efi"

for f in "${VMLINUZ}" "${INITRD}" "${BOOTX64}"; do
    [[ -f "${f}" ]] || { echo "ERROR: missing ${f}"; exit 1; }
done
echo ">>> Kernel:    $(du -sh "${VMLINUZ}"  | cut -f1)"
echo ">>> Initramfs: $(du -sh "${INITRD}"   | cut -f1)"

mkdir -p \
    "${ESP_STAGING}/EFI/BOOT" \
    "${ESP_STAGING}/loader/entries" \
    "${ESP_STAGING}/images/pxeboot"

cp "${BOOTX64}" "${ESP_STAGING}/EFI/BOOT/BOOTX64.EFI"
cp "${VMLINUZ}" "${ESP_STAGING}/images/pxeboot/vmlinuz"
cp "${INITRD}"  "${ESP_STAGING}/images/pxeboot/initrd.img"

cat > "${ESP_STAGING}/loader/loader.conf" << 'EOF'
timeout 5
default ubuntu-26.04-live.conf
EOF

# Kernel cmdline for dmsquash-live live boot.
# apparmor=0: disable AppArmor enforcement in the live session to avoid
# profile denials for tools the live user needs (polkit, pkexec, etc.).
cat > "${ESP_STAGING}/loader/entries/ubuntu-26.04-live.conf" << EOF
title   Ubuntu 26.04 Live (Resolute Raccoon)
linux   /images/pxeboot/vmlinuz
initrd  /images/pxeboot/initrd.img
options root=live:CDLABEL=${LABEL} rd.live.image rd.live.overlay.overlayfs=1 apparmor=0 quiet console=ttyS0,115200n8
EOF

INITRD_MB=$(du -m "${INITRD}"  | cut -f1)
VMLINUZ_MB=$(du -m "${VMLINUZ}" | cut -f1)
ESP_MB=$(( INITRD_MB + VMLINUZ_MB + 4 + 32 ))
ESP_IMG="${ISO_ROOT}/EFI/efi.img"

echo ">>> Creating ${ESP_MB} MiB FAT ESP image..."
truncate -s "${ESP_MB}M" "${ESP_IMG}"
mkfs.fat -F 32 -n "ESP" "${ESP_IMG}"

export MTOOLS_SKIP_CHECK=1

mmd -i "${ESP_IMG}" \
    ::/EFI \
    ::/EFI/BOOT \
    ::/loader \
    ::/loader/entries \
    ::/images \
    ::/images/pxeboot

mcopy -i "${ESP_IMG}" "${ESP_STAGING}/EFI/BOOT/BOOTX64.EFI"                      ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "${ESP_IMG}" "${ESP_STAGING}/loader/loader.conf"                         ::/loader/loader.conf
mcopy -i "${ESP_IMG}" "${ESP_STAGING}/loader/entries/ubuntu-26.04-live.conf"      ::/loader/entries/ubuntu-26.04-live.conf
mcopy -i "${ESP_IMG}" "${ESP_STAGING}/images/pxeboot/vmlinuz"                     ::/images/pxeboot/vmlinuz
mcopy -i "${ESP_IMG}" "${ESP_STAGING}/images/pxeboot/initrd.img"                  ::/images/pxeboot/initrd.img

echo ">>> Copying squashfs..."
cp "${SQUASHFS_SRC}" "${ISO_ROOT}/LiveOS/squashfs.img"
echo ">>> Squashfs: $(du -sh "${ISO_ROOT}/LiveOS/squashfs.img" | cut -f1)"

echo ">>> Assembling ISO..."
rm -f "${OUTPUT_ISO}"
touch "${OUTPUT_ISO}"
xorriso \
    -dev "stdio:${OUTPUT_ISO}" \
    -volid "${LABEL}" \
    -rockridge on \
    -joliet on \
    -map "${ISO_ROOT}" / \
    -boot_image any efi_path=EFI/efi.img \
    -boot_image any platform_id=0xef \
    -commit

implantisomd5 "${OUTPUT_ISO}" 2>/dev/null || true

echo ">>> Done: ${OUTPUT_ISO} ($(du -sh "${OUTPUT_ISO}" | cut -f1))"
