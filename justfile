output_dir := "output"
debug := "0"
compression := "fast"

# Build the live installer container image
container target:
    podman build --cap-add sys_admin --security-opt label=disable \
        --layers \
        --build-arg DEBUG={{debug}} \
        -t {{target}}-installer ./{{target}}

# Build the Debian-based ISO assembly container for the given target
iso-builder target:
    podman build --security-opt label=disable -t {{target}}-iso-builder \
        -f ./{{target}}/Containerfile.builder ./{{target}}

# Build a systemd-boot UEFI live ISO.
#
# v1 is a live-only ISO: boots Ubuntu 26.04 GNOME desktop with autologin.
# Installation requires internet — run from terminal:
#   sudo bootc install to-disk --source-imgref ghcr.io/hanthor/ubuntu-26.04-desktop-bootc:latest /dev/sdX
#
# Output: output/<target>-live.iso
iso-sd-boot target:
    #!/usr/bin/bash
    set -euo pipefail

    just debug={{debug}} container {{target}}
    mkdir -p {{output_dir}}
    OUTPUT_DIR=$(realpath "{{output_dir}}")

    if [[ $(id -u) -eq 0 ]]; then
        _ns()    { bash -c "$1"; }
        _ns_rm() { rm -rf "$@"; }
    else
        _ns()    { podman unshare bash -c "$1"; }
        _ns_rm() { podman unshare rm -rf "$@"; }
    fi

    SQUASHFS="${OUTPUT_DIR}/{{target}}-rootfs.sfs"
    BOOT_TAR="${OUTPUT_DIR}/{{target}}-boot-files.tar"
    SQUASHFS_ROOT="${OUTPUT_DIR}/{{target}}-sfs-root"
    trap "rm -f '${SQUASHFS}' '${BOOT_TAR}'; _ns_rm '${SQUASHFS_ROOT}' 2>/dev/null || true" EXIT

    echo "Building squashfs and boot tar from localhost/{{target}}-installer..."
    _ns "
        set -euo pipefail
        MOUNT=\$(podman image mount localhost/{{target}}-installer)

        SQUASHFS_ROOT='${SQUASHFS_ROOT}'
        echo 'Building unified squashfs source tree...'
        mkdir -p \"\${SQUASHFS_ROOT}\"
        cp -a --reflink=auto \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\" 2>/dev/null || \
            cp -a \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\"

        SFS_LEVEL=3; SFS_BLOCK=131072
        [[ '{{compression}}' == 'release' ]] && { SFS_LEVEL=15; SFS_BLOCK=1048576; }
        mksquashfs \"\${SQUASHFS_ROOT}\" '${SQUASHFS}' \
            -noappend -comp zstd -Xcompression-level \${SFS_LEVEL} -b \${SFS_BLOCK} \
            -processors 4 \
            -e proc -e sys -e dev -e run -e tmp

        rm -rf \"\${SQUASHFS_ROOT}\"

        tar -C \"\$MOUNT\" \
            -cf '${BOOT_TAR}' \
            ./usr/lib/modules \
            ./usr/lib/systemd/boot/efi
        podman image umount localhost/{{target}}-installer
    "

    TMPDIR="${OUTPUT_DIR}" \
    PATH="/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}" \
        bash "{{target}}/src/build-iso.sh" "${BOOT_TAR}" "${SQUASHFS}" "${OUTPUT_DIR}/{{target}}-live.iso"

    echo "ISO ready: ${OUTPUT_DIR}/{{target}}-live.iso"

# Boot a built ISO in QEMU via UEFI with serial console output.
# NOTE: Secure Boot is NOT supported — use non-secboot OVMF firmware.
# Exit: Ctrl-A then X
boot-iso-serial target:
    #!/usr/bin/bash
    set -euo pipefail
    ISO="${{output_dir}}/{{target}}-live.iso"
    if [[ ! -f "$ISO" ]]; then
        echo "No ISO found — run: just iso-sd-boot {{target}}" >&2
        exit 1
    fi

    OVMF_CODE=""
    for f in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    if [[ -z "$OVMF_CODE" ]]; then
        echo "OVMF firmware not found — install edk2-ovmf or ovmf" >&2
        exit 1
    fi

    OVMF_VARS_SRC=""
    for f in \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { OVMF_VARS_SRC="$f"; break; }
    done
    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    [[ -n "$OVMF_VARS_SRC" ]] && cp "${OVMF_VARS_SRC}" "${OVMF_VARS}"
    trap "rm -f ${OVMF_VARS}" EXIT

    echo "Booting $ISO via UEFI — serial console below (Ctrl-A X to quit)"
    sudo qemu-system-x86_64 \
        -machine q35 \
        -m 4096 \
        -accel kvm \
        -cpu host \
        -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=live-disk \
        -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
        -serial mon:stdio \
        -display none \
        -no-reboot
