#!/usr/bin/env bash
# 把原始 Debian netinst ISO 解包、塞入 preseed.cfg、改開機參數後重新封裝成一顆新 ISO。
set -euo pipefail

usage() {
  echo "Usage: $0 <source.iso> <preseed.cfg> <output.iso>" >&2
  exit 1
}

[ $# -eq 3 ] || usage

SRC_ISO="$1"
PRESEED="$2"
OUT_ISO="$3"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

MOUNT_DIR="$WORK_DIR/mnt"
EXTRACT_DIR="$WORK_DIR/iso"
mkdir -p "$MOUNT_DIR" "$EXTRACT_DIR"

sudo mount -o loop,ro "$SRC_ISO" "$MOUNT_DIR"
cp -a "$MOUNT_DIR/." "$EXTRACT_DIR/"
sudo umount "$MOUNT_DIR"

chmod -R u+w "$EXTRACT_DIR"
cp "$PRESEED" "$EXTRACT_DIR/preseed.cfg"

# BIOS 開機選單（isolinux）：預設項目自動帶 preseed 參數
ISOLINUX_CFG="$EXTRACT_DIR/isolinux/txt.cfg"
if [ -f "$ISOLINUX_CFG" ]; then
  sed -i \
    -e 's#append \(.*\) ---#append \1 auto=true priority=critical preseed/file=/cdrom/preseed.cfg ---#' \
    "$ISOLINUX_CFG"
fi

# UEFI 開機選單（grub）：同樣帶上 preseed 參數
GRUB_CFG="$EXTRACT_DIR/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
  sed -i \
    -e 's#\(linux[[:space:]]*/install.amd/vmlinuz[^\n]*\)quiet#\1quiet auto=true priority=critical preseed/file=/cdrom/preseed.cfg#' \
    "$GRUB_CFG"
fi

xorriso -as mkisofs \
  -r -V "Debian Preseed" \
  -o "$OUT_ISO" \
  -J -joliet-long \
  -isohybrid-mbr "$EXTRACT_DIR/isolinux/isohdpfx.bin" \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot -isohybrid-gpt-basdat \
  "$EXTRACT_DIR"
