#!/usr/bin/bash
# install-snaps.sh — pre-seed snap packages into /var/lib/snapd/seed/
#
# Reads /tmp/src/snaps (name + channel, one per line) and downloads each snap
# into /var/lib/snapd/seed/ so snapd installs them offline on the first live
# session boot.  `snap download` talks directly to the store API — no running
# snapd daemon is required.
#
# Build cache: /var/cache/snap-dl/ — persisted via --mount=type=cache so
# only changed snaps are re-fetched on subsequent builds.
#
# Called by: Containerfile RUN layer (after dpkg db is restored, apt works)

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

# ── Restore build cache (warm start) ─────────────────────────────────────────
cached=$(find "$SNAP_CACHE/snaps" -maxdepth 1 -name "*.snap" 2>/dev/null | wc -l)
if [[ $cached -gt 0 ]]; then
    echo "==> Restoring $cached cached snap(s)..."
    cp "$SNAP_CACHE/snaps/"*.snap   "$SNAPS_DIR/" 2>/dev/null || true
    cp "$SNAP_CACHE/snaps/"*.assert "$ASSERT_DIR/" 2>/dev/null || true
fi

WORK=$(mktemp -d)

# ── Download helper ───────────────────────────────────────────────────────────
download_snap() {
    local name="$1" channel="${2:-stable}"

    # Already present (any revision) — skip re-download.
    if find "$SNAPS_DIR" -maxdepth 1 -name "${name}_*.snap" 2>/dev/null | grep -q .; then
        echo "  -> $name: already cached"
        return 0
    fi

    echo "  -> snap download $name --channel=$channel"
    if ! snap download --channel="$channel" --target-directory="$WORK" "$name"; then
        echo "WARNING: snap download failed for $name (channel: $channel) — skipping" >&2
        return 0
    fi

    mv "$WORK/${name}_"*.snap   "$SNAPS_DIR/" 2>/dev/null || true
    mv "$WORK/${name}_"*.assert "$ASSERT_DIR/" 2>/dev/null || true
}

# ── Parse snaps file ──────────────────────────────────────────────────────────
# Format: <name> <channel>  (channel required; comments and blank lines ignored)
while IFS= read -r line; do
    # Strip inline comments and leading/trailing whitespace
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    name="${line%% *}"
    rest="${line#* }"
    channel="$( [[ "$rest" != "$name" ]] && echo "$rest" || echo "stable" )"
    channel="${channel#"${channel%%[![:space:]]*}"}"   # ltrim
    channel="${channel%"${channel##*[![:space:]]}"}"   # rtrim

    download_snap "$name" "$channel"
done < /tmp/src/snaps

rm -rf "$WORK"

# ── Generate seed.yaml ────────────────────────────────────────────────────────
SEED_YAML="$SEED_DIR/seed.yaml"
printf 'snaps:\n' > "$SEED_YAML"

for snapfile in "$SNAPS_DIR/"*.snap; do
    [[ -f "$snapfile" ]] || continue
    base=$(basename "$snapfile" .snap)   # e.g. firefox_8107
    name="${base%_*}"                    # e.g. firefox
    assertfile="$ASSERT_DIR/${base}.assert"

    # Extract snap-id from the snap-declaration stanza in the .assert file.
    # Assertion format is key: value; snap-declaration precedes snap-revision.
    snap_id=""
    if [[ -f "$assertfile" ]]; then
        snap_id=$(awk '
            /^type: snap-declaration/ { in_decl=1 }
            in_decl && /^snap-id:/    { print $2; exit }
        ' "$assertfile")
    fi

    if [[ -z "$snap_id" ]]; then
        echo "WARNING: could not extract snap-id for $name — seed entry may be incomplete" >&2
    fi

    # Recover the channel from the snaps file for the seed.yaml entry.
    channel="latest/stable"
    while IFS= read -r line; do
        line="${line%%#*}"
        entry_name="${line%% *}"
        [[ "$entry_name" == "$name" ]] || continue
        rest="${line#* }"
        [[ "$rest" != "$entry_name" ]] && channel="$rest" && break
    done < /tmp/src/snaps
    channel="${channel#"${channel%%[![:space:]]*}"}"
    channel="${channel%"${channel##*[![:space:]]}"}"

    printf '  - name: %s\n'    "$name"                  >> "$SEED_YAML"
    printf '    channel: %s\n' "$channel"                >> "$SEED_YAML"
    printf '    id: %s\n'      "${snap_id:-placeholder}" >> "$SEED_YAML"
    printf '    file: %s\n'    "$(basename "$snapfile")" >> "$SEED_YAML"
done

echo "==> Snap seed (seed.yaml):"
cat "$SEED_YAML"
echo ""
echo "==> Seed sizes:"
du -sh "$SNAPS_DIR" "$ASSERT_DIR"

# ── Save to build cache ───────────────────────────────────────────────────────
cp "$SNAPS_DIR/"*.snap   "$SNAP_CACHE/snaps/" 2>/dev/null || true
cp "$ASSERT_DIR/"*.assert "$SNAP_CACHE/snaps/" 2>/dev/null || true

echo "install-snaps.sh: done"
