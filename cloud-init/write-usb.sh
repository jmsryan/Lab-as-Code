#!/bin/bash
#
# write-usb.sh — write cloud-init NoCloud seed files to a USB thumb drive.
#
# Lists attached external/removable disks, lets you pick one, erases it as
# FAT32 with volume label CIDATA (what cloud-init's NoCloud datasource scans
# for), and copies user-data/meta-data (and network-config/vendor-data if
# present) to its root.
#
# Usage: ./write-usb.sh [path-to-cloud-init-dir]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${1:-$SCRIPT_DIR}"

VOLUME_LABEL="CIDATA"
REQUIRED_FILES=(user-data meta-data)
OPTIONAL_FILES=(network-config vendor-data)

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: this script only supports macOS (it drives diskutil)." >&2
  exit 1
fi

for f in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$SRC_DIR/$f" ]]; then
    echo "Error: required file '$f' not found in $SRC_DIR" >&2
    exit 1
  fi
done

echo "Source cloud-init files ($SRC_DIR):"
for f in "${REQUIRED_FILES[@]}" "${OPTIONAL_FILES[@]}"; do
  [[ -f "$SRC_DIR/$f" ]] && echo "  - $f"
done
echo

# ---- Discover external/removable disks ----
DISK_IDS=()
while IFS= read -r id; do
  DISK_IDS+=("$id")
done < <(diskutil list external physical 2>/dev/null | grep -Eo '^/dev/disk[0-9]+' | sed 's|/dev/||')

if [[ ${#DISK_IDS[@]} -eq 0 ]]; then
  echo "No external/removable disks found. Plug in a thumb drive and try again." >&2
  exit 1
fi

echo "Attached external drives:"
echo
MENU_IDS=()
i=1
for id in "${DISK_IDS[@]}"; do
  info=$(diskutil info "$id")
  name=$(echo "$info" | awk -F': +' '/Device \/ Media Name/ {print $2}')
  size=$(echo "$info" | awk -F': +' '/Disk Size/ {print $2}' | sed 's/ (.*//')
  proto=$(echo "$info" | awk -F': +' '/Protocol/ {print $2}')
  printf "  %d) /dev/%-8s %-25s %-10s %s\n" "$i" "$id" "${name:-Unknown}" "${size:-?}" "${proto:-}"
  MENU_IDS+=("$id")
  i=$((i + 1))
done
echo

read -r -p "Select a drive [1-${#MENU_IDS[@]}]: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MENU_IDS[@]} )); then
  echo "Invalid selection." >&2
  exit 1
fi

TARGET="${MENU_IDS[$((CHOICE - 1))]}"
TARGET_INFO=$(diskutil info "$TARGET")
TARGET_NAME=$(echo "$TARGET_INFO" | awk -F': +' '/Device \/ Media Name/ {print $2}')
TARGET_SIZE=$(echo "$TARGET_INFO" | awk -F': +' '/Disk Size/ {print $2}' | sed 's/ (.*//')

echo
echo "You selected: /dev/$TARGET — ${TARGET_NAME:-Unknown} (${TARGET_SIZE:-?})"
echo "THIS WILL ERASE ALL DATA ON /dev/$TARGET and format it FAT32 as '$VOLUME_LABEL'."
echo
read -r -p "Type the disk identifier ('$TARGET') to confirm: " CONFIRM
if [[ "$CONFIRM" != "$TARGET" ]]; then
  echo "Confirmation did not match. Aborting." >&2
  exit 1
fi

echo
echo "Erasing and formatting /dev/$TARGET as FAT32 ($VOLUME_LABEL)..."
diskutil eraseDisk FAT32 "$VOLUME_LABEL" MBRFormat "$TARGET"

MOUNT_POINT="/Volumes/$VOLUME_LABEL"
if [[ ! -d "$MOUNT_POINT" ]]; then
  echo "Error: expected volume not mounted at $MOUNT_POINT" >&2
  exit 1
fi

echo "Copying cloud-init files to $MOUNT_POINT..."
for f in "${REQUIRED_FILES[@]}" "${OPTIONAL_FILES[@]}"; do
  if [[ -f "$SRC_DIR/$f" ]]; then
    cp "$SRC_DIR/$f" "$MOUNT_POINT/"
    echo "  copied $f"
  fi
done

echo "Ejecting /dev/$TARGET..."
diskutil eject "$TARGET"

echo
echo "Done. '$VOLUME_LABEL' USB seed drive is ready to plug into the hypervisor."
