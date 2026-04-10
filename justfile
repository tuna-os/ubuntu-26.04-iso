# Output directory for built ISOs and intermediate artifacts.
# Override with: just output_dir=/your/path iso-sd-boot ubuntu-26.04
output_dir := "output"

# Set to 1 to enable SSH + passwordless root in the live session for debugging.
# Example: just debug=1 iso-sd-boot ubuntu-26.04
# Never use debug=1 for production/release ISOs.
debug := "0"

# Set to "dev" to pull the tuna-installer dev build (continuous-dev release).
# Example: just installer_channel=dev iso-sd-boot ubuntu-26.04
installer_channel := "stable"

# Squashfs compression preset:
#   fast    (default) — zstd level 3,  128K blocks — quick local builds/CI
#   release           — zstd level 15, 1M blocks   — ~20% smaller, ~5× slower
compression := "fast"

# Build the live installer container image.
container target:
    podman build --cap-add sys_admin --security-opt label=disable \
        --layers \
        --build-arg DEBUG={{debug}} \
        --build-arg INSTALLER_CHANNEL={{installer_channel}} \
        -t {{target}}-installer ./{{target}}

# Build the Debian-based ISO assembly container for the given target.
iso-builder target:
    podman build --security-opt label=disable -t {{target}}-iso-builder \
        -f ./{{target}}/Containerfile.builder ./{{target}}

# Build a debug ISO in the background, writing logs to output/build.log.
# Safe to close the terminal — build continues running.
# Usage:
#   just debug=1 build-bg ubuntu-26.04
#   tail -f output/build.log
build-bg target:
    #!/usr/bin/bash
    set -euo pipefail
    mkdir -p {{output_dir}}
    LOG=$(realpath {{output_dir}})/build.log
    echo "Starting background build → ${LOG}"
    setsid sudo just \
        debug={{debug}} \
        installer_channel={{installer_channel}} \
        output_dir={{output_dir}} \
        compression={{compression}} \
        iso-sd-boot {{target}} \
        > "${LOG}" 2>&1 &
    disown $!
    echo "Build PID $! — tailing log (Ctrl-C is safe, build continues)"
    tail -f "${LOG}"

# Build a systemd-boot UEFI live ISO.
#
# Output: output/<target>-live.iso
iso-sd-boot target:
    #!/usr/bin/bash
    set -euo pipefail

    just debug={{debug}} installer_channel={{installer_channel}} container {{target}}
    mkdir -p {{output_dir}}
    OUTPUT_DIR=$(realpath "{{output_dir}}")

    if [[ $(id -u) -eq 0 ]]; then
        _ns()    { bash -c "$1"; }
        _ns_rm() { rm -rf "$@"; }
    else
        _ns()    { podman unshare bash -c "$1"; }
        _ns_rm() { podman unshare rm -rf "$@"; }
    fi

    PAYLOAD_REF=$(cat "{{target}}/payload_ref" | tr -d '[:space:]')
    SQUASHFS="${OUTPUT_DIR}/{{target}}-rootfs.sfs"
    BOOT_TAR="${OUTPUT_DIR}/{{target}}-boot-files.tar"
    CS_STAGING="${OUTPUT_DIR}/{{target}}-cs-staging"
    SQUASHFS_ROOT="${OUTPUT_DIR}/{{target}}-sfs-root"
    trap "rm -f '${SQUASHFS}' '${BOOT_TAR}' '${OUTPUT_DIR}/{{target}}-payload.oci.tar'; \
          _ns_rm '${CS_STAGING}' '${SQUASHFS_ROOT}' 2>/dev/null || true" EXIT

    echo "Building squashfs and boot tar from localhost/{{target}}-installer..."
    _ns "
        set -euo pipefail
        MOUNT=\$(podman image mount localhost/{{target}}-installer)
        PATH=/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:\$PATH

        PAYLOAD_OCI='${OUTPUT_DIR}/{{target}}-payload.oci.tar'
        CS_STAGING='${CS_STAGING}'
        SQUASHFS_ROOT='${SQUASHFS_ROOT}'
        SQUASHFS_STORAGE=\"\${CS_STAGING}/usr/lib/bootc/storage\"
        LIVE_RUNROOT=\"\$(mktemp -d '${OUTPUT_DIR}'/live-runroot-XXXXXX)\"
        STORAGE_CONF=\"\$(mktemp '${OUTPUT_DIR}'/live-storage-XXXXXX.conf)\"
        mkdir -p \"\${SQUASHFS_STORAGE}\"
        printf '[storage]\ndriver = \"vfs\"\nrunroot = \"%s\"\ngraphroot = \"%s\"\n' \
            \"\${LIVE_RUNROOT}\" \"\${SQUASHFS_STORAGE}\" > \"\${STORAGE_CONF}\"

        echo 'Exporting Ubuntu OCI image to archive...'
        skopeo copy \
            containers-storage:${PAYLOAD_REF} \
            oci-archive:\${PAYLOAD_OCI}:${PAYLOAD_REF}

        echo 'Importing Ubuntu OCI image into squashfs bootc storage...'
        CONTAINERS_STORAGE_CONF=\"\${STORAGE_CONF}\" \
        skopeo copy \
            oci-archive:\${PAYLOAD_OCI}:${PAYLOAD_REF} \
            containers-storage:${PAYLOAD_REF}

        rm -f \"\${PAYLOAD_OCI}\" \"\${STORAGE_CONF}\"
        rm -rf \"\${LIVE_RUNROOT}\"

        echo 'Building unified squashfs source tree...'
        mkdir -p \"\${SQUASHFS_ROOT}\"
        cp -a --reflink=auto \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\" 2>/dev/null || \
            cp -a \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\"
        # bootc ships /usr/lib/bootc/storage as a symlink into /sysroot; replace
        # it with a real directory so we can embed the offline OCI store.
        rm -f \"\${SQUASHFS_ROOT}/usr/lib/bootc/storage\"
        mkdir -p \"\${SQUASHFS_ROOT}/usr/lib/bootc/storage\"
        cp -a \"\${CS_STAGING}/usr/lib/bootc/storage/.\" \
            \"\${SQUASHFS_ROOT}/usr/lib/bootc/storage/\"
        rm -rf \"\${CS_STAGING}\"

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
# SSH forwarded to localhost:2222 when built with debug=1.
# Exit: Ctrl-A then X
boot-iso-serial target:
    #!/usr/bin/bash
    set -euo pipefail
    ISO="{{output_dir}}/{{target}}-live.iso"
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

    echo "Booting ${ISO} via UEFI — serial console below (Ctrl-A X to quit)"
    echo "SSH: localhost:2222 (liveuser / live) if built with debug=1"
    sudo qemu-system-x86_64 \
        -machine q35 \
        -m 8192 \
        -accel kvm \
        -cpu host \
        -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=live-disk \
        -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
        -serial file:{{output_dir}}/serial.log \
        -display none \
        -no-reboot &
    QEMU_PID=$!
    echo "QEMU PID ${QEMU_PID} — tailing serial log (Ctrl-C to stop tail; QEMU keeps running)"
    tail -f "{{output_dir}}/serial.log" &
    wait $QEMU_PID

# Boot a built ISO in libvirt with UEFI, a blank install disk, SSH, and VNC.
# Always build with debug=1 first:
#   just debug=1 iso-sd-boot ubuntu-26.04
#   just boot-libvirt-debug ubuntu-26.04
#
# Connect:
#   ssh liveuser@<GUEST_IP>   (password: live)
#   vncviewer localhost:5900   (or whatever port virsh domdisplay reports)
#
# Cleanup:
#   sudo virsh destroy ubuntu26-debug && sudo virsh undefine ubuntu26-debug --nvram
boot-libvirt-debug target:
    #!/usr/bin/bash
    set -euo pipefail

    VM_NAME="ubuntu26-debug"
    VM_RAM=8192
    VM_CPUS=4
    DISK_SIZE=64

    ISO="{{output_dir}}/{{target}}-live.iso"
    if [[ ! -f "$ISO" ]]; then
        echo "No ISO found — build first with: just debug=1 iso-sd-boot {{target}}" >&2
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
    OVMF_VARS=""
    for f in \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { OVMF_VARS="$f"; break; }
    done
    if [[ -z "$OVMF_CODE" ]]; then
        echo "OVMF firmware not found — install edk2-ovmf or ovmf" >&2
        exit 1
    fi

    sudo cp "$ISO" /var/lib/libvirt/images/${VM_NAME}.iso

    if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "VM '${VM_NAME}' already exists — swapping ISO and rebooting..."
        sudo virsh destroy "$VM_NAME" 2>/dev/null || true
        CDROM_DEV=$(sudo virsh domblklist "$VM_NAME" \
            | awk 'NR>2 && ($2 ~ /\.iso$/ || $2 == "-") {print $1; exit}')
        sudo virsh change-media "$VM_NAME" "$CDROM_DEV" \
            /var/lib/libvirt/images/${VM_NAME}.iso --force
        sudo virsh start "$VM_NAME"
    else
        echo "Creating VM: ${VM_NAME} (${VM_RAM}M RAM, ${VM_CPUS} vCPUs, ${DISK_SIZE}G disk)"
        sudo virt-install \
            --name "$VM_NAME" \
            --memory "$VM_RAM" --vcpus "$VM_CPUS" \
            --boot loader="${OVMF_CODE}",loader.readonly=yes,loader.type=pflash,nvram.template="${OVMF_VARS}" \
            --cdrom /var/lib/libvirt/images/${VM_NAME}.iso \
            --disk size=${DISK_SIZE},format=qcow2 \
            --network network=default \
            --graphics vnc,listen=127.0.0.1,password=live \
            --video virtio \
            --os-variant ubuntu24.04 \
            --tpm none \
            --noautoconsole
    fi

    MAC=$(sudo virsh domiflist "$VM_NAME" | awk '/network/{print $5}')
    echo "VM started. MAC: ${MAC}"
    echo "Waiting for DHCP lease (30–90s while ISO boots)..."

    GUEST_IP=""
    for i in $(seq 1 60); do
        GUEST_IP=$(sudo virsh net-dhcp-leases default 2>/dev/null \
            | awk -v mac="$MAC" 'tolower($3) == tolower(mac) {split($5, a, "/"); print a[1]}' \
            | head -1)
        [[ -n "$GUEST_IP" ]] && break
        sleep 3
    done

    VNC_DISPLAY=$(sudo virsh domdisplay "$VM_NAME" 2>/dev/null || echo "unavailable")

    echo ""
    echo "════════════════════════════════════════"
    if [[ -n "$GUEST_IP" ]]; then
        echo "  SSH:  ssh liveuser@${GUEST_IP}"
        echo "        password: live"
    else
        echo "  WARNING: no DHCP lease yet — try:"
        echo "    sudo virsh net-dhcp-leases default"
    fi
    echo "  VNC:  ${VNC_DISPLAY}  (password: live)"
    echo "        vncviewer ${VNC_DISPLAY#vnc://}"
    echo "  Serial: sudo virsh console ${VM_NAME}"
    echo "  Cleanup: sudo virsh destroy ${VM_NAME}"
    echo "           sudo virsh undefine ${VM_NAME} --nvram"
    echo "════════════════════════════════════════"
