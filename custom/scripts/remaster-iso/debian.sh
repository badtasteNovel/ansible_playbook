#!/usr/bin/env bash
# 把原始 Debian netinst ISO 解包、塞入 preseed.cfg、改開機參數後重新封裝成一顆新 ISO。
#
# 開機自動化靠兩層修改：
#   1. 把 preseed 參數加到實際會被自動選中的那個開機選單項目的 kernel append 行
#      （BIOS: isolinux/gtk.cfg 的 installgui、isolinux/txt.cfg 的 install；
#       UEFI: boot/grub/grub.cfg 的第一個 menuentry）
#   2. 把「選單逾時」從預設的「永遠等按鍵」改成很短的時間，否則光改第 1 點，
#      VM 還是會卡在開機選單等人按 Enter，不會自動往下跑
#      （isolinux.cfg 的 `timeout 0` 在 syslinux 裡是「停用逾時＝永遠等」的
#      特殊值，不是「0 秒後開機」；grub.cfg 則是完全沒設 timeout/default）
set -euo pipefail

usage() {
  echo "Usage: $0 <source.iso> <preseed.cfg> <output.iso>" >&2
  exit 1
}

[ $# -eq 3 ] || usage

SRC_ISO="$1"
PRESEED="$2"
OUT_ISO="$3"

ISOHDPFX_BIN="/usr/lib/ISOLINUX/isohdpfx.bin"
if [ ! -f "$ISOHDPFX_BIN" ]; then
  echo "錯誤：找不到 $ISOHDPFX_BIN，請先 task install（install:iso-tools 會裝 isolinux 套件）" >&2
  exit 1
fi

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

PRESEED_KARGS='auto=true priority=critical preseed/file=/cdrom/preseed.cfg'

# BIOS 開機選單（isolinux）
# 1a. 把逾時從「永遠等按鍵」改成很短的時間，開機後自動往下跑，不用人按 Enter
ISOLINUX_CFG="$EXTRACT_DIR/isolinux/isolinux.cfg"
if [ -f "$ISOLINUX_CFG" ]; then
  sed -i 's/^timeout 0$/timeout 1/' "$ISOLINUX_CFG"
fi
# 1b. gtk.cfg 的 installgui 是實際上有 `menu default` 標記、真正會被自動選中的
#     項目；txt.cfg 的 install 是文字模式退路。兩個都加上 preseed 參數比較保險。
for f in "$EXTRACT_DIR/isolinux/gtk.cfg" "$EXTRACT_DIR/isolinux/txt.cfg"; do
  if [ -f "$f" ]; then
    sed -i -e "s#append \(.*\) ---#append \1 ${PRESEED_KARGS} ---#" "$f"
  fi
done

# UEFI 開機選單（grub）：完全沒設 timeout/default，要自己補上，
# 並且只改「第一個」menuentry（對應 `set default=0`），不要動到其他 19 個
# rescue/語音/深色主題等選單項目
GRUB_CFG="$EXTRACT_DIR/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
  sed -i '0,/^menuentry/{s/^menuentry/set timeout=1\nset default=0\n\nmenuentry/}' "$GRUB_CFG"
  sed -i "0,/\(linux[[:space:]]*\/install.amd\/vmlinuz[^\n]*\)quiet/{s#\(linux[[:space:]]*/install.amd/vmlinuz[^\n]*\)quiet#\1quiet ${PRESEED_KARGS}#}" "$GRUB_CFG"
fi

xorriso -as mkisofs \
  -r -V "Debian Preseed" \
  -o "$OUT_ISO" \
  -J -joliet-long \
  -isohybrid-mbr "$ISOHDPFX_BIN" \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot -isohybrid-gpt-basdat \
  "$EXTRACT_DIR"
