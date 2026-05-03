#!/usr/bin/bash
# e2e-install.sh — runs on the live guest via SSH during the e2e test.
# Uses fisherman with composeFsBackend=true and oci:/usr/lib/bootc/storage.
#
# With the fisherman fix (PR #25 + skopeoExportOCI oci: fix), the flow is:
#   1. podman pull oci:/usr/lib/bootc/storage      → VFS store on target disk
#   2. skopeo copy oci:/usr/lib/bootc/storage      → oci-cache on target disk
#   3. podman --root containers-root run oci:cache → bootc install (composefs)
#
# The CONTAINERS_STORAGE_CONF override redirects the VFS graphroot to
# /var/tmp which fisherman bind-mounts to the target disk before pulling.

set -euo pipefail

FISHERMAN=$(find /var/lib/flatpak/app/org.bootcinstaller.Installer \
    -name fisherman -type f 2>/dev/null | head -1)
[[ -z "$FISHERMAN" ]] && FISHERMAN=/usr/local/bin/fisherman
# Use the patched fisherman binary if available (has the oci: source ref fix)
[[ -f /tmp/fisherman-patched ]] && FISHERMAN=/tmp/fisherman-patched
echo "Using fisherman: $FISHERMAN"

# Redirect VFS graphroot to /var/tmp so it lands on the target disk after
# fisherman mounts the scratch (avoids filling the live overlay tmpfs).
cat > /tmp/e2e-storage.conf << 'EOF'
[storage]
driver = "vfs"
graphroot = "/var/tmp/e2e-containers-storage"
runroot = "/run/containers/storage"
EOF

# Fisherman recipe — composeFsBackend:true uses skopeoExportOCI which now
# handles oci: source refs correctly (copies directly, no containers-storage
# name lookup).
cat > /tmp/e2e-recipe.json << 'EOF'
{
  "disk":             "/dev/vda",
  "filesystem":       "xfs",
  "composeFsBackend": true,
  "bootloader":       "systemd",
  "selinuxDisabled":  true,
  "unifiedStorage":   false,
  "hostname":         "ubuntu-e2e-test",
  "image":            "oci:/usr/lib/bootc/storage",
  "flatpaks":         [],
  "encryption":       {"type": "none"}
}
EOF

echo "==> Running fisherman install (composeFsBackend=true)..."
CONTAINERS_STORAGE_CONF=/tmp/e2e-storage.conf "$FISHERMAN" /tmp/e2e-recipe.json
echo "==> Install complete."

# BLS entries are in the EFI partition (vda1 FAT32), NOT the root partition (vda2 XFS).
# Always mount vda1 — fisherman's composefs systemd-boot layout:
#   vda1 = EFI System (2G FAT32, has loader/entries/*.conf)
#   vda2 = Linux root (28G XFS, no boot entries here)
EFI_TMP=$(mktemp -d)
mount /dev/vda1 "$EFI_TMP"
trap "umount '$EFI_TMP' 2>/dev/null || true; rmdir '$EFI_TMP'" EXIT
COUNT=0
for entry in "${EFI_TMP}/loader/entries/"*.conf \
             "${EFI_TMP}/EFI/loader/entries/"*.conf; do
    [[ -f "$entry" ]] || continue
    PATCH=""
    grep -q "console=ttyS0"     "$entry" || PATCH="$PATCH console=ttyS0,115200"
    grep -q "systemd.wants=ssh" "$entry" || PATCH="$PATCH systemd.wants=ssh.service"
    if [[ -n "$PATCH" ]]; then
        sed -i "s|^options .*|&${PATCH}|" "$entry"
        (( ++COUNT ))  # pre-increment: evaluates to new value (≥1), never exits non-zero
    fi
done
echo "==> Patched ${COUNT} BLS entry/entries (console + SSH kargs)."
