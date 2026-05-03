#!/usr/bin/bash
# e2e-install.sh — runs on the live guest via SSH during the e2e test.
# Finds the fisherman binary in the installed tuna-installer Flatpak,
# sets up CONTAINERS_STORAGE_CONF to point at the bootc payload image
# embedded in the squashfs at /usr/lib/bootc/storage, and installs.

set -euo pipefail

FISHERMAN=$(find /var/lib/flatpak/app/org.bootcinstaller.Installer \
    -name fisherman -type f 2>/dev/null | head -1)
[[ -z "$FISHERMAN" ]] && FISHERMAN=/usr/local/bin/fisherman
echo "Using fisherman: $FISHERMAN"

# The bootc payload image was imported into /usr/lib/bootc/storage during
# the ISO build (separate from the VFS store flatpaks use).
# Redirect containers-storage so fisherman + bootc find it there.
cat > /tmp/bootc-storage.conf << 'EOF'
[storage]
driver = vfs
graphroot = /usr/lib/bootc/storage
runroot = /run/containers/storage
EOF

CONTAINERS_STORAGE_CONF=/tmp/bootc-storage.conf "$FISHERMAN" /tmp/e2e-recipe.json
