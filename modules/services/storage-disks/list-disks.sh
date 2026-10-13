#!/usr/bin/env bash
# Prints a JSON array of whole-disk /dev/disk/by-id paths, skipping the disk
# the running system is on. The Neo settings form has a Find disks button.
set -euo pipefail
shopt -s nullglob

declare -A skip=()

mark() {
  local p="$1" real base
  [ -n "$p" ] || return 0
  real=$(readlink -f "$p" 2>/dev/null || true)
  [ -n "$real" ] || return 0
  # Partition -> whole disk (sda1, nvme0n1p1, mmcblk0p1).
  base=$(lsblk -ndo PKNAME "$real" 2>/dev/null || true)
  if [ -n "$base" ]; then
    skip["/dev/$base"]=1
  fi
  skip["$real"]=1
}

root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
root_type=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
if [ "$root_type" = "zfs" ]; then
  rootpool=${root_src%%/*}
  while read -r v; do
    case "$v" in
      /*) mark "$v" ;;
    esac
  done < <(zpool status -P "$rootpool" 2>/dev/null | awk '$1 ~ /^\// { print $1 }')
elif [ -n "$root_src" ]; then
  mark "${root_src%%\[*}"
fi

declare -A best_pri=()
declare -A best_link=()

for link in /dev/disk/by-id/*; do
  base=$(basename "$link")
  case "$base" in
    *-part[0-9]*|wwn-*|nvme-eui.*|dm-*|lvm-*|md-*) continue ;;
  esac
  real=$(readlink -f "$link" 2>/dev/null || true)
  [ -n "$real" ] && [ -b "$real" ] || continue
  [ "$(lsblk -ndo TYPE "$real" 2>/dev/null || true)" = "disk" ] || continue
  [ -n "${skip[$real]:-}" ] && continue
  pri=5
  case "$base" in
    usb-*) pri=1 ;;
    ata-*) pri=2 ;;
    nvme-*) pri=3 ;;
    scsi-*) pri=4 ;;
  esac
  old=${best_pri[$real]:-9}
  if [ "$pri" -lt "$old" ]; then
    best_pri["$real"]=$pri
    best_link["$real"]=$link
  fi
done

if [ "${#best_link[@]}" -eq 0 ]; then
  echo "No extra disks found. The system disk was left out." >&2
  exit 1
fi
out=()
for real in "${!best_link[@]}"; do
  out+=("${best_link[$real]}")
done
IFS=$'\n'
sorted=$(printf '%s\n' "${out[@]}" | sort)
json='['
first=1
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [ "$first" -eq 0 ]; then
    json+=','
  fi
  first=0
  json+="\"$line\""
done <<<"$sorted"
json+=']'
printf '%s\n' "$json"
