#!/usr/bin/env bash
# 把原始 Debian netinst ISO 解包、塞入 preseed.cfg（以及其他要注入的檔案，例如預先
# 產生好的 SSH host key），改開機參數後重新封裝成一顆新 ISO。
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
  echo "Usage: $0 <source.iso> <extra_files_dir> <output.iso>" >&2
  echo "  extra_files_dir 底下的每個檔案都會被複製到 ISO 根目錄" \
    "（至少要有 preseed.cfg，late_command 裡用 /cdrom/<檔名> 存取其他檔案）" >&2
  exit 1
}

[ $# -eq 3 ] || usage

SRC_ISO="$1"
EXTRA_FILES_DIR="$2"
OUT_ISO="$3"

if [ ! -f "$EXTRA_FILES_DIR/preseed.cfg" ]; then
  echo "錯誤：$EXTRA_FILES_DIR 底下沒有 preseed.cfg" >&2
  exit 1
fi

ISOHDPFX_BIN="/usr/lib/ISOLINUX/isohdpfx.bin"
if [ ! -f "$ISOHDPFX_BIN" ]; then
  echo "錯誤：找不到 $ISOHDPFX_BIN，請先 task install（install:iso-tools 會裝 isolinux 套件）" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'chmod -R u+w "$WORK_DIR" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

EXTRACT_DIR="$WORK_DIR/iso"
mkdir -p "$EXTRACT_DIR"

# 用 xorriso 唯讀解開 ISO9660 檔案系統，不用 mount，不需要 sudo、不需要 loop device
xorriso -indev "$SRC_ISO" -osirrox on -extract / "$EXTRACT_DIR"

chmod -R u+w "$EXTRACT_DIR"
cp "$EXTRA_FILES_DIR"/* "$EXTRACT_DIR/"

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

# 1c. Debian 安裝選單裡還有一個「無障礙/語音合成安裝」子選單（spkgtk.cfg），
#     它自己又定義了一個 timeout 300（30 秒）+ ontimeout，而且 ontimeout 指向
#     的開機列完全沒有 preseed 參數。menu.cfg 的 include 順序讓它排在最後面，
#     所以它的 timeout/ontimeout 會蓋掉我們在 isolinux.cfg 設的值——實際效果
#     就是卡 30 秒，逾時後還跳進語音合成安裝（探測音效卡畫面），永遠不會自動
#     裝機。把 isolinux.cfg 以外所有 cfg 檔自己定義的 timeout/ontimeout 行拔掉，
#     確保只有 isolinux.cfg 的設定生效。
for f in "$EXTRACT_DIR"/isolinux/*.cfg; do
  [ "$(basename "$f")" = "isolinux.cfg" ] && continue
  sed -i '/^timeout /d; /^ontimeout /d' "$f"
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
