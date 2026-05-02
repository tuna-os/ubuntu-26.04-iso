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
        --network=host \
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

# ── QEMU e2e test ──────────────────────────────────────────────────────────────
# Adapts the dakota-iso LUKS e2e pattern for a plain (non-LUKS) Ubuntu install.
# The installed system is ext4 + systemd-boot; no passphrase unlock needed.
#
# Variables (all overridable on the command line):
e2e-disk               := "/var/tmp/ubuntu-26.04-e2e.qcow2"
e2e-ovmf-vars-live      := "/var/tmp/ubuntu-26.04-e2e-live-vars.fd"
e2e-ovmf-vars-installed := "/var/tmp/ubuntu-26.04-e2e-installed-vars.fd"
e2e-monitor-live        := "/tmp/ubuntu-26.04-e2e-live.sock"
e2e-monitor-installed   := "/tmp/ubuntu-26.04-e2e-installed.sock"
e2e-serial-live         := "/tmp/ubuntu-26.04-e2e-live.log"
e2e-serial-installed    := "/tmp/ubuntu-26.04-e2e-installed.log"
e2e-ssh-port            := "2222"

# Live boot smoke test — fast, no install needed, does not require debug=1.
# Boots the ISO in headless QEMU and waits for the UBUNTU26_LIVE_READY marker
# emitted by live-ready.service once the display manager has started.
# Usage: just test-live ubuntu-26.04
test-live target:
    #!/usr/bin/bash
    set -euo pipefail
    ISO="{{output_dir}}/{{target}}-live.iso"
    [[ -f "$ISO" ]] || { echo "No ISO — run: just iso-sd-boot {{target}}"; exit 1; }

    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }

    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found — install ovmf" >&2; exit 1; }
    OVMF_VARS=$(mktemp /tmp/ubuntu-smoke-vars.XXXXXX.fd)
    for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
              /usr/share/edk2/ovmf/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { cp "$f" "$OVMF_VARS"; break; }
    done

    SERIAL=$(mktemp /tmp/ubuntu-smoke-serial.XXXXXX.log)
    MONITOR=$(mktemp /tmp/ubuntu-smoke-monitor.XXXXXX.sock)
    TIMEOUT=480   # 8 min — live env with snap seeding can be slow
    trap "sudo socat - UNIX-CONNECT:$MONITOR <<< 'quit' 2>/dev/null || true; rm -f $OVMF_VARS $SERIAL" EXIT

    echo "==> Booting live ISO (headless): $ISO"
    sudo "$QEMU" \
        -machine q35 -cpu host -m 4096 -smp 2 -accel kvm \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
        -drive "if=none,id=iso,file=${ISO},media=cdrom,readonly=on,format=raw" \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=iso \
        -netdev "user,id=net0" \
        -device virtio-net-pci,netdev=net0 \
        -monitor "unix:${MONITOR},server,nowait" \
        -serial "file:${SERIAL}" \
        -display none \
        -daemonize

    echo "==> Waiting for UBUNTU26_LIVE_READY (timeout: ${TIMEOUT}s)..."
    ELAPSED=0
    while (( ELAPSED < TIMEOUT )); do
        if grep -q "UBUNTU26_LIVE_READY" "$SERIAL" 2>/dev/null; then
            echo ""
            echo "=== LIVE SMOKE TEST PASSED (${ELAPSED}s) ==="
            FAILS=$(grep -E '\[FAILED\] Failed to start|Kernel panic' "$SERIAL" || true)
            [[ -n "$FAILS" ]] && echo "WARNING — failures in serial log:" && echo "$FAILS"
            exit 0
        fi
        sleep 3; (( ELAPSED += 3 ))
        printf "."
    done
    echo ""
    echo "=== LIVE SMOKE TEST FAILED (timeout after ${TIMEOUT}s) ==="
    echo "--- last 50 lines of serial ---"
    tail -50 "$SERIAL" 2>/dev/null || true
    exit 1

# Full end-to-end: build ISO → boot live → fisherman install → boot installed.
# Requires debug=1 so SSH is available in the live session.
# Usage: just debug=1 e2e ubuntu-26.04
e2e target:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "{{debug}}" != "1" ]]; then
        echo "ERROR: e2e requires debug=1 (SSH is needed for the fisherman install step)"
        echo "  Run: just debug=1 e2e {{target}}"
        exit 1
    fi
    echo "=== Step 1: Build ISO (debug=1) ==="
    just debug=1 output_dir={{output_dir}} compression={{compression}} iso-sd-boot {{target}}
    echo "=== Step 2: QEMU end-to-end ==="
    sudo rm -f "{{e2e-disk}}" \
               "{{e2e-ovmf-vars-live}}" "{{e2e-ovmf-vars-installed}}" \
               "{{e2e-monitor-live}}" "{{e2e-monitor-installed}}" \
               "{{e2e-serial-live}}" "{{e2e-serial-installed}}"
    just e2e-qemu {{target}}

# Run the QEMU e2e test against an already-built ISO (skips the rebuild).
# Expects the ISO at {{output_dir}}/{{target}}-live.iso.
e2e-qemu target:
    #!/usr/bin/bash
    set -euo pipefail
    just e2e-boot-live      {{target}}
    just e2e-install        {{target}}
    just e2e-boot-installed {{target}}

# Boot the live ISO in QEMU (daemonized) with a blank install disk attached.
# Waits for UBUNTU26_LIVE_READY marker then polls SSH until the session is ready.
e2e-boot-live target:
    #!/usr/bin/bash
    set -euo pipefail
    ISO="{{output_dir}}/{{target}}-live.iso"
    [[ -f "$ISO" ]] || { echo "No ISO — run: just debug=1 iso-sd-boot {{target}}" >&2; exit 1; }

    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }

    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found" >&2; exit 1; }
    for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
              /usr/share/edk2/ovmf/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { cp "$f" "{{e2e-ovmf-vars-live}}"; break; }
    done

    [[ -f "{{e2e-disk}}" ]] || qemu-img create -f qcow2 "{{e2e-disk}}" 20G

    echo "==> Booting live ISO: $ISO"
    sudo "$QEMU" \
        -machine q35 -cpu host -m 4096 -smp 2 -accel kvm \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file={{e2e-ovmf-vars-live}}" \
        -drive "if=none,id=iso,file=${ISO},media=cdrom,readonly=on,format=raw" \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=iso \
        -drive "if=none,id=disk,file={{e2e-disk}},format=qcow2" \
        -device virtio-blk-pci,drive=disk \
        -netdev "user,id=net0,hostfwd=tcp::{{e2e-ssh-port}}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -monitor "unix:{{e2e-monitor-live}},server,nowait" \
        -serial "file:{{e2e-serial-live}}" \
        -display none \
        -daemonize
    echo "==> Live QEMU started (monitor: {{e2e-monitor-live}})"

    echo "==> Waiting for UBUNTU26_LIVE_READY (up to 8 min)..."
    for i in $(seq 1 160); do
        if grep -q "UBUNTU26_LIVE_READY" "{{e2e-serial-live}}" 2>/dev/null; then
            echo " ready (${i} × 3s)"
            break
        fi
        [[ "$i" -eq 160 ]] && {
            echo "TIMEOUT: live env not ready after 8 min"
            tail -40 "{{e2e-serial-live}}" || true
            exit 1
        }
        sleep 3
        printf "."
    done

    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o LogLevel=ERROR -o ConnectTimeout=5 -o PreferredAuthentications=password"
    echo "==> Waiting for SSH on port {{e2e-ssh-port}}..."
    for i in $(seq 1 40); do
        sshpass -p live ssh $SSH_OPTS liveuser@127.0.0.1 \
            -p {{e2e-ssh-port}} true 2>/dev/null && { echo "SSH ready"; break; }
        [[ "$i" -eq 40 ]] && { echo "ERROR: SSH timed out"; exit 1; }
        sleep 5
    done

# Run fisherman install via SSH into the live QEMU VM, then shut down.
# The bootc payload image lives at /usr/lib/bootc/storage in the squashfs
# (separate from the VFS store used for flatpaks at /var/lib/containers/storage).
# We set CONTAINERS_STORAGE_CONF so fisherman + bootc find the image there.
e2e-install target:
    #!/usr/bin/bash
    set -euo pipefail
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o LogLevel=ERROR -o ConnectTimeout=10 -o PreferredAuthentications=password \
              -o ServerAliveInterval=30 -o ServerAliveCountMax=20"
    SSH="sshpass -p live ssh $SSH_OPTS liveuser@127.0.0.1 -p {{e2e-ssh-port}}"
    SCP="sshpass -p live scp $SSH_OPTS -P {{e2e-ssh-port}}"

    # Write the fisherman recipe locally, then SCP it in
    RECIPE=$(mktemp /tmp/ubuntu-e2e-recipe.XXXXXX.json)
    trap "rm -f '$RECIPE'" EXIT
    python3 -c "import json; print(json.dumps({
        'disk':'/dev/vda','filesystem':'ext4','composeFsBackend':True,
        'bootloader':'systemd','selinuxDisabled':True,'unifiedStorage':False,
        'hostname':'ubuntu-e2e-test',
        'image':'localhost/ubuntu-26.04-desktop-bootc:latest',
        'flatpaks':[],'snaps':[],'encryption':{'type':'none'}
    }, indent=2))" > "$RECIPE"

    $SCP "$RECIPE" liveuser@127.0.0.1:/tmp/e2e-recipe.json
    echo "==> Running fisherman install (takes several minutes)..."

    # CONTAINERS_STORAGE_CONF redirects bootc + skopeo to the VFS store embedded
    # in the squashfs at /usr/lib/bootc/storage (the payload image ref is
    # localhost/ubuntu-26.04-desktop-bootc:latest in that store).
    $SSH 'sudo bash -c "
        printf '[storage]\ndriver = vfs\ngraphroot = /usr/lib/bootc/storage\nrunroot = /run/containers/storage\n' > /tmp/bootc-storage.conf
        CONTAINERS_STORAGE_CONF=/tmp/bootc-storage.conf /usr/local/bin/fisherman /tmp/e2e-recipe.json
    "'
    echo "==> Install complete."

    # Patch BLS loader entries so the installed system outputs to ttyS0.
    # Mirrors the dakota-iso pattern; ensures the e2e-boot-installed step
    # can read the serial log for the login prompt.
    echo "==> Patching BLS entries for serial console..."
    $SSH 'sudo bash -c "
        set -euo pipefail
        TMP=\$(mktemp -d)
        trap \"umount \$TMP 2>/dev/null || true; rmdir \$TMP\" EXIT
        mount /dev/vda1 \$TMP
        COUNT=0
        for entry in \$TMP/loader/entries/*.conf \$TMP/EFI/loader/entries/*.conf; do
            [[ -f \"\$entry\" ]] || continue
            if grep -q \"^options \" \"\$entry\" && ! grep -q \"console=ttyS0\" \"\$entry\"; then
                sed -i \"s|^options .*|& console=tty0 console=ttyS0,115200|\" \"\$entry\"
                (( COUNT++ ))
            fi
        done
        echo \"Patched \$COUNT BLS entry/entries\"
    "'

    echo "==> Shutting down live QEMU..."
    echo "system_powerdown" | sudo socat - "UNIX-CONNECT:{{e2e-monitor-live}}" 2>/dev/null || true
    sleep 8
    echo "quit" | sudo socat - "UNIX-CONNECT:{{e2e-monitor-live}}" 2>/dev/null || true

# Boot the installed disk (no ISO) in QEMU and wait for a login prompt.
e2e-boot-installed target:
    #!/usr/bin/bash
    set -euo pipefail
    [[ -f "{{e2e-disk}}" ]] || { echo "No install disk — run e2e-install first" >&2; exit 1; }

    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }

    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found" >&2; exit 1; }
    for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
              /usr/share/edk2/ovmf/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { cp "$f" "{{e2e-ovmf-vars-installed}}"; break; }
    done

    echo "==> Booting installed disk: {{e2e-disk}}"
    sudo "$QEMU" \
        -machine q35 -cpu host -m 4096 -smp 2 -accel kvm \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file={{e2e-ovmf-vars-installed}}" \
        -drive "if=none,id=disk,file={{e2e-disk}},format=qcow2" \
        -device virtio-blk-pci,drive=disk \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        -monitor "unix:{{e2e-monitor-installed}},server,nowait" \
        -serial "file:{{e2e-serial-installed}}" \
        -display none \
        -daemonize
    echo "==> Installed QEMU started (monitor: {{e2e-monitor-installed}})"

    TIMEOUT=300  # 5 min — no snaps to seed on the installed system
    echo "==> Waiting for login prompt (timeout: ${TIMEOUT}s)..."
    ELAPSED=0
    while (( ELAPSED < TIMEOUT )); do
        if grep -qE "login:" "{{e2e-serial-installed}}" 2>/dev/null; then
            echo ""
            echo "=== INSTALLED SYSTEM BOOT TEST PASSED (${ELAPSED}s) ==="
            FAILS=$(grep -E '\[FAILED\] Failed to start|Kernel panic' \
                "{{e2e-serial-installed}}" || true)
            [[ -n "$FAILS" ]] && echo "WARNING — failures detected:" && echo "$FAILS"
            echo "quit" | sudo socat - "UNIX-CONNECT:{{e2e-monitor-installed}}" 2>/dev/null || true
            exit 0
        fi
        sleep 3; (( ELAPSED += 3 ))
        printf "."
    done
    echo ""
    echo "=== INSTALLED SYSTEM BOOT TEST FAILED (timeout after ${TIMEOUT}s) ==="
    echo "--- last 50 lines of serial ---"
    tail -50 "{{e2e-serial-installed}}" 2>/dev/null || true
    echo "quit" | sudo socat - "UNIX-CONNECT:{{e2e-monitor-installed}}" 2>/dev/null || true
    exit 1
