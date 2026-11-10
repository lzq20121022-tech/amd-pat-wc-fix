#!/bin/bash
# Fix the write-combining slot in the AMD_Vanilla "Fix PAT" kernel patch (OpenCore), so macOS write-combined
# mappings are write-combined again instead of uncached. Changes ONE byte of the patch's Replace data.
#
#   sudo ./apply_pat_wc.sh /Volumes/EFI/EFI/OC/config.plist on     # PA6 = WC  (what XNU itself programs)
#   sudo ./apply_pat_wc.sh /Volumes/EFI/EFI/OC/config.plist off    # back to the original AMD_Vanilla bytes
#
# The entry is found by its Find/Mask bytes (not by index or comment), and is only changed when its Replace
# bytes are one of the two known values. A timestamped backup of config.plist is written next to it first.
# Takes effect on the next boot. If the Mac does not boot: boot Recovery (or another entry), mount the EFI
# partition and copy the backup over config.plist.
set -uo pipefail
C="${1:?usage: $0 <config.plist> on|off}"; MODE="${2:?usage: $0 <config.plist> on|off}"
FIND="icCB4v//AP+BygAAAAAPMA=="          # 89c0 81e2ffff00ff 81ca???????? 0f30   (XNU _mtrr_update_action PAT write)
MASK="/////////////wAAAAD//w=="
ORIG="icC4BgEHALoGAQcADzCQkA=="          # 89c0 b806010700 ba06010700 0f30 9090    PAT = 0x0007010600070106 (PA6 = UC-)
FIXED="icC4BgEHALoGAQEADzCQkA=="         # 89c0 b806010700 ba06010100 0f30 9090    PAT = 0x0001010600070106 (PA6 = WC)
[ -f "$C" ] || { echo "STOP: no such file: $C"; exit 1; }
case "$MODE" in on) want=$FIXED; from=$ORIG ;; off) want=$ORIG; from=$FIXED ;; *) echo "usage: $0 <config.plist> on|off"; exit 1 ;; esac
n=$(plutil -extract Kernel.Patch raw -o - "$C" 2>/dev/null) || { echo "STOP: no Kernel.Patch array in $C"; exit 1; }
idx=""
for ((i = 0; i < n; i++)); do
  [ "$(plutil -extract "Kernel.Patch.$i.Find" raw -o - "$C" 2>/dev/null)" = "$FIND" ] || continue
  [ "$(plutil -extract "Kernel.Patch.$i.Mask" raw -o - "$C" 2>/dev/null)" = "$MASK" ] || continue
  idx=$i; break
done
[ -n "$idx" ] || { echo "STOP: no AMD_Vanilla 'Fix PAT' entry (_mtrr_update_action) found in $C"; exit 1; }
cur=$(plutil -extract "Kernel.Patch.$idx.Replace" raw -o - "$C")
echo "Kernel.Patch.$idx: $(plutil -extract "Kernel.Patch.$idx.Comment" raw -o - "$C" 2>/dev/null)"
[ "$cur" = "$want" ] && { echo "OK: already '$MODE', nothing changed"; exit 0; }
[ "$cur" = "$from" ] || { echo "STOP: Replace bytes are not a known value ($cur); nothing changed"; exit 1; }
B="$C.backup-$(date +%Y%m%d-%H%M%S)"; cp -p "$C" "$B" || { echo "STOP: cannot write backup"; exit 1; }
plutil -replace "Kernel.Patch.$idx.Replace" -data "$want" "$C"
if ! plutil -lint "$C" >/dev/null || [ "$(plutil -extract "Kernel.Patch.$idx.Replace" raw -o - "$C")" != "$want" ]; then
  cp -p "$B" "$C"; echo "STOP: write check failed, config restored from $B"; exit 1
fi
echo "DONE: PA6 is now $([ "$MODE" = on ] && echo 'WC (write-combining)' || echo 'UC- (original AMD_Vanilla value)'). Backup: $B. Reboot to apply."
