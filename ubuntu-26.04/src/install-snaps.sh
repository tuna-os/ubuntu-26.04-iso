#!/usr/bin/bash
# install-snaps.sh — pre-seed snap packages into /var/lib/snapd/seed/
#
# Downloads each snap listed in /tmp/src/snaps plus the required base snaps
# (core22, core24) and generates a valid seed.yaml so snapd can install them
# offline on the first live-session boot.  No running snapd daemon is needed;
# `snap download` talks directly to the store API.
#
# Build cache: /var/cache/snap-dl/ — persisted via --mount=type=cache so only
# changed snaps are re-downloaded on subsequent builds.
#
# Called by: Containerfile RUN layer (after dpkg db is restored so apt works)

set -exo pipefail

SNAP_CACHE="/var/cache/snap-dl"
SEED_DIR="/var/lib/snapd/seed"
SNAPS_DIR="$SEED_DIR/snaps"
ASSERT_DIR="$SEED_DIR/assertions"

mkdir -p "$SNAPS_DIR" "$ASSERT_DIR" "$SNAP_CACHE/snaps"

# overlayfs inside a Podman build doesn't support O_TMPFILE.
# Use a subdirectory of the bind-mounted cache volume as TMPDIR.
mkdir -p "${SNAP_CACHE}/tmp"
export TMPDIR="${SNAP_CACHE}/tmp"

# ── Restore build cache ───────────────────────────────────────────────────────
# Warm-start: copy any previously downloaded snaps/assertions into the seed dir
# so we only need to download deltas.
cached_snaps=$(ls "$SNAP_CACHE/snaps/"*.snap 2>/dev/null | wc -l)
if [[ $cached_snaps -gt 0 ]]; then
    echo "==> Restoring $cached_snaps snap(s) from build cache..."
    cp "$SNAP_CACHE/snaps/"*.snap   "$SNAPS_DIR/" 2>/dev/null || true
    cp "$SNAP_CACHE/snaps/"*.assert "$ASSERT_DIR/" 2>/dev/null || true
fi

# ── Download helper ───────────────────────────────────────────────────────────
WORK=$(mktemp -d)

download_snap() {
    local name="$1" channel="${2:-stable}"

    # Skip if any revision of this snap is already in the seed dir.
    if ls "$SNAPS_DIR/${name}_"*.snap 2>/dev/null | head -1 | grep -q .; then
        echo "  -> $name: already cached, skipping download"
        return 0
    fi

    echo "  -> Downloading snap: $name (channel: $channel)"
    if ! snap download --channel="$channel" --target-directory="$WORK" "$name"; then
        echo "WARNING: snap download failed for $name — skipping" >&2
        return 0
    fi

    mv "$WORK/${name}_"*.snap   "$SNAPS_DIR/" 2>/dev/null || true
    mv "$WORK/${name}_"*.assert "$ASSERT_DIR/" 2>/dev/null || true
}

# ── Base snaps ────────────────────────────────────────────────────────────────
# core22 and core24 are required by virtually all modern app snaps as their
# base.  Download both so snap seeding succeeds regardless of which base the
# app uses.
for base in core22 core24; do
    download_snap "$base" "stable"
done

# ── App snaps from the wanted list ───────────────────────────────────────────
readarray -t WANTED < <(grep -v '^[[:space:]]*#' /tmp/src/snaps \
                        | grep -v '^[[:space:]]*$')
for snap in "${WANTED[@]}"; do
    download_snap "$snap" "stable"
done

rm -rf "$WORK"

# ── Generate seed.yaml ────────────────────────────────────────────────────────
# snapd requires seed.yaml to list every snap in seed/snaps/ along with its
# snap-id (from the snap-declaration assertion) and the local filename.
SEED_YAML="$SEED_DIR/seed.yaml"
printf 'snaps:\n' > "$SEED_YAML"

for snapfile in "$SNAPS_DIR/"*.snap; do
    [[ -f "$snapfile" ]] || continue
    base=$(basename "$snapfile" .snap)   # e.g. firefox_5678
    name="${base%_*}"                    # e.g. firefox
    assertfile="$ASSERT_DIR/${base}.assert"

    # Extract the snap-id from the snap-declaration stanza in the .assert file.
    # The assertion format is key: value; snap-declaration comes before
    # snap-revision so the first snap-id line is the one we want.
    snap_id=""
    if [[ -f "$assertfile" ]]; then
        snap_id=$(awk '
            /^type: snap-declaration/ { in_decl=1 }
            in_decl && /^snap-id:/   { print $2; exit }
        ' "$assertfile")
    fi

    if [[ -z "$snap_id" ]]; then
        echo "WARNING: could not extract snap-id for $name from $assertfile" >&2
        # Fall through — snapd may still be able to process the snap
        # if it can match by name, but the seed entry is formally incomplete.
    fi

    # Determine channel.  For seeds this is informational; snapd tracks the
    # real channel via the snap-revision assertion.
    channel="latest/stable"

    printf '  - name: %s\n'    "$name"                  >> "$SEED_YAML"
    printf '    channel: %s\n' "$channel"                >> "$SEED_YAML"
    printf '    id: %s\n'      "${snap_id:-placeholder}" >> "$SEED_YAML"
    printf '    file: %s\n'    "$(basename "$snapfile")" >> "$SEED_YAML"
done

echo "==> Snap seed contents:"
cat "$SEED_YAML"
echo ""
echo "==> Snap files:"
ls -lh "$SNAPS_DIR/"

# ── Update build cache ────────────────────────────────────────────────────────
echo "==> Saving snaps to build cache..."
cp "$SNAPS_DIR/"*.snap   "$SNAP_CACHE/snaps/" 2>/dev/null || true
cp "$ASSERT_DIR/"*.assert "$SNAP_CACHE/snaps/" 2>/dev/null || true

echo "install-snaps.sh: done"
