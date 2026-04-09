# Ubuntu 26.04 Live ISO

Live bootable ISO for **Ubuntu 26.04 "Resolute Raccoon"** desktop, based on the
[`ghcr.io/hanthor/ubuntu-26.04-desktop-bootc`](https://github.com/hanthor/ubuntu-26.04-desktop-bootc)
bootc image. Uses the same [dakota-iso](https://github.com/tuna-os/dakota-iso)
systemd-boot + dmsquash-live pipeline.

## What it is

- Boots to **GNOME 50** desktop with automatic login (`liveuser`)
- **x86_64 UEFI only** — Secure Boot is not supported in v1
- **Online install** — requires internet access to install to disk

## Download

```
https://download.tunaos.org/ubuntu-26.04/ubuntu-26.04-live-latest.iso
```

## Installing to disk

Boot the ISO, open a terminal, and run:

```bash
sudo bootc install to-disk \
  --source-imgref ghcr.io/hanthor/ubuntu-26.04-desktop-bootc:latest \
  /dev/sda
```

Replace `/dev/sda` with your target drive. **This will erase the target drive.**

## Building locally

```bash
# Build the ISO (requires podman, just, mksquashfs, xorriso, mtools)
just iso-sd-boot ubuntu-26.04

# Boot the ISO in QEMU (requires qemu-kvm, OVMF)
just boot-iso-serial ubuntu-26.04
```

Build options:

| Variable | Default | Description |
|---|---|---|
| `output_dir` | `output` | Where to write the ISO |
| `debug` | `0` | Set to `1` for SSH-enabled debug ISO |
| `compression` | `fast` | `fast` (zstd/3) or `release` (zstd/15, ~20% smaller) |

## CI / R2 upload

GitHub Actions builds and uploads the ISO to Cloudflare R2 on every push to
`main` and weekly on Mondays. Uses org-level secrets:
`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET`.

## Known limitations (v1)

- **Secure Boot:** unsigned systemd-boot — use non-secboot OVMF for testing
- **Offline install:** not supported; install pulls image from GHCR
- **USB boot:** tested via QEMU optical path only; USB mass-storage path untested
- **Architecture:** x86_64 only
