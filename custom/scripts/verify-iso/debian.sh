#!/usr/bin/env bash
# 驗證一顆 Debian ISO 是不是官方未竄改的版本，全程即時向官方來源下載比對，
# 不在 repo 裡長期保留任何金鑰/雜湊副本：
#   1. 互動式確認要去哪個 mirror 目錄抓 SHA512SUMS / SHA512SUMS.sign
#   2. 下載 Debian CD 簽署金鑰（固定的 3 個 key id，fingerprint 寫死在這支腳本裡
#      當信任根據，下載下來後會核對 fingerprint 是否一致，不一致就拒絕信任）
#   3. 用通過核對的金鑰驗證 SHA512SUMS.sign 對 SHA512SUMS 的 GPG 簽名
#   4. 用 SHA512SUMS 裡對應的那一行驗證 ISO 本體的 sha512
#
# 用法: debian.sh <path/to/debian-xx.x.x-amd64-netinst.iso>
set -euo pipefail

# 目前（依 https://www.debian.org/CD/verify）仍在使用的三把 Debian CD 簽署金鑰。
# fingerprint 是釘在這支腳本原始碼裡的信任根據：金鑰內容每次都重新下載，
# 但下載下來的 fingerprint 必須跟這裡寫的一致，才會被信任。
DEBIAN_CD_KEY_IDS=(988021A964E6EA7D DA87E80D6294BE9B 42468F4009EA8AC3)
DEBIAN_CD_KEY_FINGERPRINTS=(
  10460DAD76165AD81FBC0CE9988021A964E6EA7D
  DF9B9C49EAA9298432589D76DA87E80D6294BE9B
  F41D30342F3546695F65C66942468F4009EA8AC3
)

usage() {
  echo "Usage: $0 <path/to/debian-*.iso>" >&2
  exit 1
}

[ $# -eq 1 ] || usage
ISO_PATH="$1"
[ -f "$ISO_PATH" ] || { echo "錯誤：找不到 ISO 檔案 $ISO_PATH" >&2; exit 1; }

ISO_DIR="$(cd "$(dirname "$ISO_PATH")" && pwd)"
ISO_NAME="$(basename "$ISO_PATH")"

# 用 current（永遠指向目前穩定版），不釘版本號——這樣如果 Debian 已經出了新版本，
# 下面抓下來的 SHA512SUMS 會找不到你手上這顆舊檔名的紀錄，順便提醒你有新版本可以換
DEFAULT_BASE="https://cdimage.debian.org/debian-cd/current/"
SUGGESTED_URL="${DEFAULT_BASE}amd64/iso-cd/"
if [[ "$ISO_NAME" =~ ^debian-[0-9.]+-([a-z0-9]+)-netinst\.iso$ ]]; then
  SUGGESTED_URL="${DEFAULT_BASE}${BASH_REMATCH[1]}/iso-cd/"
fi

echo "這顆 ISO 的 SHA512SUMS / SHA512SUMS.sign 預期會在這個 mirror 目錄下："
echo "  $SUGGESTED_URL"
read -r -p "直接按 Enter 使用上面這個網址，或貼上你要用的網址: " input_url
MIRROR_URL="${input_url:-$SUGGESTED_URL}"
[[ "$MIRROR_URL" == */ ]] || MIRROR_URL="${MIRROR_URL}/"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "== 下載 SHA512SUMS / SHA512SUMS.sign =="
if ! curl -fsSL "${MIRROR_URL}SHA512SUMS" -o "$WORK_DIR/SHA512SUMS"; then
  echo "錯誤：抓不到 ${MIRROR_URL}SHA512SUMS" >&2
  echo "      有可能是最新版本的 ISO 已經變更了（current 指向的版本/目錄結構跟你這顆 ISO 不一樣），" >&2
  echo "      去 https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ 看一下現在的實際路徑。" >&2
  exit 1
fi
if ! curl -fsSL "${MIRROR_URL}SHA512SUMS.sign" -o "$WORK_DIR/SHA512SUMS.sign"; then
  echo "錯誤：抓不到 ${MIRROR_URL}SHA512SUMS.sign" >&2
  exit 1
fi

echo "== 拿 https://www.debian.org/CD/verify 頁面上公告的 fingerprint 交叉比對腳本裡釘住的值 =="
VERIFY_PAGE_TEXT="$WORK_DIR/verify_page.txt"
if ! curl -fsSL "https://www.debian.org/CD/verify" 2>/dev/null | sed 's/<[^>]*>//g' > "$VERIFY_PAGE_TEXT"; then
  echo "錯誤：抓不到 https://www.debian.org/CD/verify，無法交叉比對 fingerprint，別信任這顆 ISO。" >&2
  exit 1
fi
for i in "${!DEBIAN_CD_KEY_IDS[@]}"; do
  key_id="${DEBIAN_CD_KEY_IDS[$i]}"
  pinned_fpr="${DEBIAN_CD_KEY_FINGERPRINTS[$i]}"
  page_fpr="$(grep -A1 "/${key_id} " "$VERIFY_PAGE_TEXT" | grep "Key fingerprint" | sed -E 's/.*= //' | tr -d ' \r')"
  if [ -z "$page_fpr" ]; then
    echo "錯誤：在 debian.org/CD/verify 頁面上找不到 $key_id 的 fingerprint，別信任這顆 ISO。" >&2
    exit 1
  fi
  if [ "$page_fpr" != "$pinned_fpr" ]; then
    echo "錯誤：$key_id 在 debian.org/CD/verify 上公告的 fingerprint（$page_fpr）" >&2
    echo "      跟這支腳本裡釘住的值（$pinned_fpr）不一致，別信任這顆 ISO。" >&2
    echo "      請自己去 https://www.debian.org/CD/verify 核對，並檢查 debian.sh 裡的 DEBIAN_CD_KEY_FINGERPRINTS 是否需要更新。" >&2
    exit 1
  fi
  echo "  一致：$key_id（$page_fpr）"
done

echo "== 下載並核對 Debian CD 簽署金鑰 =="
KEYRING="$WORK_DIR/debian-cd-keyring.gpg"
: > "$KEYRING"
for i in "${!DEBIAN_CD_KEY_IDS[@]}"; do
  key_id="${DEBIAN_CD_KEY_IDS[$i]}"
  expected_fpr="${DEBIAN_CD_KEY_FINGERPRINTS[$i]}"
  key_file="$WORK_DIR/$key_id.asc"
  curl -fsSL "https://www.debian.org/CD/key-$key_id.txt" -o "$key_file"
  fpr="$(gpg --with-colons --show-keys "$key_file" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
  if [ "$fpr" != "$expected_fpr" ]; then
    echo "錯誤：$key_id 下載下來的 fingerprint（$fpr）跟腳本裡釘住的（$expected_fpr）不一致，拒絕信任" >&2
    exit 1
  fi
  echo "  信任：$key_id（$fpr）"
  gpg --dearmor < "$key_file" >> "$KEYRING"
done

echo "== 驗證 SHA512SUMS 的 GPG 簽名 =="
if ! gpgv --keyring "$KEYRING" "$WORK_DIR/SHA512SUMS.sign" "$WORK_DIR/SHA512SUMS"; then
  echo "錯誤：SHA512SUMS 的簽名驗證失敗，不是用已知的 Debian CD 簽署金鑰簽的，別信任這顆 ISO。" >&2
  exit 1
fi

echo "== 驗證 ISO 本體的 SHA512 =="
FILTERED_SUMS="$WORK_DIR/SHA512SUMS.filtered"
grep -F "  $ISO_NAME" "$WORK_DIR/SHA512SUMS" > "$FILTERED_SUMS" || {
  echo "錯誤：SHA512SUMS 裡找不到 $ISO_NAME 這個檔名的紀錄。" >&2
  echo "      有可能是最新版本的 ISO 已經變更了（current 現在指向比你手上這顆更新的版本），" >&2
  echo "      去 https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ 看看是不是該換一顆新的 ISO。" >&2
  exit 1
}

if ! (cd "$ISO_DIR" && sha512sum -c "$FILTERED_SUMS"); then
  echo "錯誤：ISO 的 SHA512 跟官方記錄不一致，檔案可能損毀或被竄改，別信任這顆 ISO。" >&2
  exit 1
fi

echo "== 通過：$ISO_NAME 是未經竄改的官方 Debian ISO =="
