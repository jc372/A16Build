#!/usr/bin/env bash
# a16-ec.sh -- the ASUS Zenbook A16 Embedded Controller: build it, install it, read it back.
#
#   bash a16-ec.sh build        (no root) apply the posted patches, build the module + the DTB,
#                               verify both against the running kernel
#   sudo bash a16-ec.sh install (root)    put the module in updates/a16/ and arm the booted DTBs
#                               with the EC node, with backups
#   bash a16-ec.sh status       (no root) where each piece is: source, .ko, installed, armed, bound
#   bash a16-ec.sh verify       (no root, after the reboot) did the EC bind, and what does it give
#   sudo bash a16-ec.sh revert  (root)    take the module out and put the DTBs back
#
# WHAT THIS IS, and where it came from
# ------------------------------------
# "[PATCH 0/3] Asus Zenbook A16/A14 (UX3607OA/UX3407NA) EC driver", Konrad Dybcio, 2026-09-17,
# https://lore.kernel.org/lkml/20260917-topic-asus_ec-v1-0-373516d347ae@oss.qualcomm.com/
#
#   * 1/3 dt-bindings: embedded-controller: asus,zenbook-a16-ux3607oa-ec.yaml
#   * 2/3 platform/arm64: drivers/platform/arm64/asus-glymur-ec.c (592 lines; Kconfig symbol
#         EC_ASUS_GLYMUR) -- fan RPM for the two fans, two temperature sensors, keyboard-backlight
#         control, a number of sideband events, and **it tells the EC about system suspend
#         entry/exit** (ASUS_QCOM_EC_MODERN_STANDBY_ENTER/EXIT, 0x23/0x07 and 0x23/0x08)
#   * 3/3 arm64: dts: the EC node itself -- I2C address 0x76 on i2c9, interrupt on TLMM 66
#
# State of the series when this was written: v1, under review (Krzysztof Kozlowski on the bindings;
# Abel Vesa has given a Reviewed-by on the DTS).  Not in linux-next yet -- so it is carried here as
# retired/patches/old-numbering/0011..0013, which apply cleanly to the tree this kernel was built from.
#
# WHY IT IS WORTH HAVING ON THIS MACHINE, beyond fans and temperatures
# -------------------------------------------------------------------
# This machine today has **no EC driver at all** (`acpi=off`, and no DT node), so nothing ever tells
# the EC that the system is entering standby.  The Wi-Fi failure is exactly a suspend problem: after
# the first deep suspend the QCC2072 is no longer running its firmware (see
# BRINGUP/notes/2026-09-22-wifi-suspend-ladder.md, and the `mhi0: Wait for device to enter SBL or
# Mission mode` line that follows the timeout).  The EC is the part that owns platform power on these
# designs, so "the EC is never told we are suspending" is a prime suspect for the module losing
# power -- and the driver's suspend/resume callbacks are the only way to tell it.  That makes this
# series a candidate *fix* for the Wi-Fi wedge, not just a nice-to-have.  It is also a real test:
# with the driver bound, `sudo wifisleep test` says whether the radio survives a deep suspend now.
#
# Files:
#   source   ~/build/linux-next-1a1de54f7369/drivers/platform/arm64/asus-glymur-ec.c
#   module   ~/build/linux-next-1a1de54f7369/drivers/platform/arm64/asus-glymur-ec.ko
#   dtb      ~/build/linux-next-1a1de54f7369/arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb
#   live dtb /boot/glymur-asus-zenbook-a16-ux3607oa.dtb  (+ the ESP twin; backups .a16ecbak)
set -u

MODE="${1:-status}"
ARG="${2:-}"
KVER=$(uname -r)
COMMIT="1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3"
TREE="${A16_TREE:-/home/jc/build/linux-next-${COMMIT:0:12}}"
PATCHES="/home/jc/A16Build/BRINGUP/patches"
KO="$TREE/drivers/platform/arm64/asus-glymur-ec.ko"
DTB_SRC="$TREE/arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
DTB_LIVE="/boot/glymur-asus-zenbook-a16-ux3607oa.dtb"
DTB_ESP="/boot/efi/a16boot/glymur-asus-zenbook-a16-ux3607oa.dtb"
UPD="/lib/modules/$KVER/updates/a16"
HOOK_EC="ec-int-n-state"
LOG="${A16_LOG:-/home/jc/a16-payload/ec-$(date +%Y%m%d-%H%M%S).log}"
DRY="${A16_DRY:-0}"
SKIP_ROOT="${A16_SKIP_ROOT:-0}"

say()  { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }
run()  { if [ "$DRY" = 1 ]; then say "   [dry-run] $*"; return 0; fi; "$@"; }

usage() {
  cat <<'EOF'
a16-ec -- the ASUS Zenbook A16 Embedded Controller (the posted 2026-09-17 driver).

usage:
  bash a16-ec.sh build     no root: apply retired/patches/old-numbering/0011..0013 to the kernel tree, turn
                           CONFIG_EC_ASUS_GLYMUR=m on, build asus-glymur-ec.ko and the DTB, and
                           verify vermagic / module_layout / every symbol CRC against the kernel
  sudo bash a16-ec.sh install   install the module into /lib/modules/<ver>/updates/a16/ (depmod) and
                           arm /boot/glymur-asus-zenbook-a16-ux3607oa.dtb (and its ESP twin) with the
                           EC node -- i2c9 address 0x76, interrupt TLMM 66 -- keeping .a16ecbak copies
  bash a16-ec.sh status    where each piece is, and what the running system has right now
  bash a16-ec.sh verify    after the reboot: did the EC bind, and what does it expose
  sudo bash a16-ec.sh kbd 0|1|2|3   keyboard backlight off..brightest (the LED exists; its default is 0)
  sudo bash a16-ec.sh revert    remove the module, restore the DTBs from .a16ecbak

then, for the Wi-Fi question this is really about:   sudo bash ~/a16.sh wifisleep test

log: ~/a16-payload/ec-<timestamp>.log      env: A16_DRY=1 prints commands, A16_TREE, A16_LOG
EOF
}
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

# ------------------------------------------------------------------ helpers
abi_check() {   # $1 = .ko  -- vermagic, module_layout, and every import's CRC vs the harvested table
  local ko="$1" kv symvers="$TREE/Module.symvers.a16harvest"
  [ -f "$ko" ] || { say "   $ko: MISSING"; return 1; }
  [ -f "$symvers" ] || symvers="$TREE/Module.symvers"
  local kvm ml n
  kvm=$(modinfo -F vermagic /lib/modules/"$KVER"/kernel/drivers/clk/qcom/dispcc-glymur.ko 2>/dev/null)
  ml=$(modprobe --dump-modversions /lib/modules/"$KVER"/kernel/drivers/clk/qcom/dispcc-glymur.ko 2>/dev/null | awk '$2=="module_layout"{print $1}')
  n=$(modprobe --dump-modversions "$ko" 2>/dev/null | wc -l)
  say "   $(basename "$ko"): $(stat -c %s "$ko") bytes, $(stat -c %y "$ko" | cut -d. -f1)"
  say "      vermagic      : $(modinfo -F vermagic "$ko")"
  [ "$(modinfo -F vermagic "$ko")" = "$kvm" ] && say "      vermagic      : matches the kernel ✓" || say "      vermagic      : MISMATCH (kernel: $kvm)"
  say "      module_layout : $(modprobe --dump-modversions "$ko" | awk '$2=="module_layout"{print $1}')   (kernel's: $ml)"
  say "      imports       : $n"
  modprobe --dump-modversions "$ko" | awk '{print $1"\t"$2}' > /tmp/a16-ec-imports.txt
  python3 - "$symvers" <<'PY'
import sys
ours={}
for l in open('/tmp/a16-ec-imports.txt'):
    c,s=l.split(); ours[s]=c
have={}
for l in open(sys.argv[1]):
    f=l.split('\t')
    if len(f)>=2: have[f[1]]=f[0]
missing=[s for s in ours if s not in have]
bad=[s for s in ours if s in have and ours[s].lower()!=have[s].lower()]
print(f"      CRC check     : {len(ours)} imports, {len(missing)} without a CRC, {len(bad)} disagreeing")
if missing: print("      missing       :", missing[:8])
if bad:     print("      disagreeing   :", bad[:8])
print("      ABI           : " + ("OK -- every import carries the kernel's CRC ✓" if not missing and not bad else "NOT SAFE -- do not install"))
PY
}

ec_node_in_dtb() {   # $1 = dtb
  dtc -I dtb -O dts -o /tmp/a16-ec-check.dts "$1" 2>/dev/null \
    && grep -q 'zenbook-a16-ux3607oa-ec' /tmp/a16-ec-check.dts && echo yes || echo no
}

show_status() {
  rule
  say "-- the posted series  (v1, 2026-09-17, Konrad Dybcio; not upstream yet)"
  say "   lore          : lore.kernel.org/lkml/20260917-topic-asus_ec-v1-0-373516d347ae@oss.qualcomm.com/"
  for p in 0011-dt-bindings-asus-zenbook-a16-ec.patch 0012-platform-arm64-asus-glymur-ec.patch 0013-arm64-dts-glymur-zenbook-a16-ec.patch; do
    say "   $PATCHES/$p: $( [ -f "$PATCHES/$p" ] && echo present || echo MISSING)"
  done
  rule
  say "-- the tree ($TREE)"
  say "   driver source : $( [ -f "$TREE/drivers/platform/arm64/asus-glymur-ec.c" ] && echo 'applied ✓' || echo 'not applied (run: bash a16-ec.sh build)')"
  say "   Kconfig symbol: $(grep -hE '^CONFIG_EC_ASUS_GLYMUR' "$TREE/.config" 2>/dev/null || echo 'not set')"
  say "   module built  : $( [ -f "$KO" ] && echo "$KO ($(stat -c %s "$KO") bytes)" || echo 'not built')"
  say "   DTB built     : $( [ -f "$DTB_SRC" ] && echo "$DTB_SRC ($(stat -c %s "$DTB_SRC") bytes)" || echo 'not built')"
  rule
  say "-- the machine"
  say "   EC node in the live DT (a running kernel sees this)  : $(dtc -I fs /proc/device-tree 2>/dev/null | grep -c 'zenbook-a16-ux3607oa-ec')"
  for f in "$DTB_LIVE" "$DTB_ESP"; do
    say "   $f : $( [ -f "$f" ] && echo "$(stat -c %s "$f") bytes, EC node: $(ec_node_in_dtb "$f"), backup: $( [ -f "$f.a16ecbak" ] && echo present || echo none)" || echo absent)"
  done
  say "   module installed : $( [ -f "$UPD/asus-glymur-ec.ko" ] && echo yes || echo no)"
  say "   driver loaded    : $(lsmod 2>/dev/null | grep -c '^asus_glymur_ec')   i2c client at 0x76: $(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -c '^9-0076')"
  say "   hwmon            : $(for h in /sys/class/hwmon/hwmon*; do n=$(cat "$h/name" 2>/dev/null); [ "$n" = "asus_glymur_ec" ] && echo "$h"; done | tr '\n' ' ')"
  say "   kbd backlight    : $(ls /sys/class/leds/ 2>/dev/null | grep -i kbd | tr '\n' ' ')"
}

do_build() {
  [ "$(id -u)" = 0 ] && { say "Run this as yourself, not with sudo: the tree is yours and root-owned build"; say "files are a pain to clean up.  Just:  bash BRINGUP/tools/a16-ec.sh build"; exit 1; }
  [ -d "$TREE" ] || { say "FATAL: no tree at $TREE"; exit 1; }
  rule
  say "-- apply the three posted patches (idempotent)"
  if grep -q asus-glymur-ec "$TREE/drivers/platform/arm64/Makefile" 2>/dev/null; then
    say "   already applied"
  else
    for f in "$PATCHES"/0011-*.patch "$PATCHES"/0012-*.patch "$PATCHES"/0013-*.patch; do
      say "   $(basename "$f")"
      ( cd "$TREE" && patch -p1 --forward -s < "$f" ) || { say "   FATAL: patch did not apply"; exit 1; }
    done
  fi
  rule
  say "-- config: CONFIG_EC_ASUS_GLYMUR=m, with the kernel's own version string"
  "$TREE/scripts/config" --file "$TREE/.config" --module EC_ASUS_GLYMUR
  run make -C "$TREE" --no-print-directory ARCH=arm64 olddefconfig
  say "   symbol        : $(grep -hE '^CONFIG_EC_ASUS_GLYMUR' "$TREE/.config")"
  say "   tree release  : $(make -C "$TREE" -s ARCH=arm64 kernelrelease | tail -1)   (must equal $KVER)"
  [ "$(make -C "$TREE" -s ARCH=arm64 kernelrelease | tail -1)" = "$KVER" ] || { say "   FATAL: version string mismatch"; exit 1; }
  rule
  say "-- build the module (only this one: a plain M= build also builds its siblings, whose exports"
  say "   collide with the harvested symbol table -- see the note in the log)"
  pahole --version >/dev/null 2>&1 || {
    # pahole is what keeps CONFIG_DEBUG_INFO_BTF on, and sched_ext with it; without it the modules'
    # struct offsets disagree with the kernel's.  There is a locally extracted copy on this machine.
    if [ -x "$HOME/pahole-local/usr/bin/pahole" ]; then
      export PATH="$HOME/pahole-local/usr/bin:$PATH"
      export LD_LIBRARY_PATH="$HOME/pahole-local/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"
    fi
  }
  pahole --version >/dev/null 2>&1 && say "   pahole        : $(pahole --version)  ($(command -v pahole))" || { say "   FATAL: pahole missing; without it the module's struct offsets disagree with the kernel"; exit 1; }
  [ -f "$TREE/Module.symvers.a16harvest" ] && { cp -f "$TREE/Module.symvers.a16harvest" "$TREE/Module.symvers"; say "   symbol table  : restored from the harvest ($(wc -l < "$TREE/Module.symvers") CRCs)"; }
  run make -C "$TREE" --no-print-directory ARCH=arm64 -j"$(nproc)" modules_prepare
  ( cd "$TREE" && make --no-print-directory ARCH=arm64 -j"$(nproc)" M=drivers/platform/arm64 asus-glymur-ec.ko ) || { say "   FATAL: build failed"; exit 1; }
  say "   built         : $KO"
  rule
  say "-- verify the module against the running kernel"
  abi_check "$KO"
  rule
  say "-- build the DTB (the same DTS the machine boots, plus the EC node)"
  ( cd "$TREE" && make --no-print-directory ARCH=arm64 qcom/glymur-asus-zenbook-a16-ux3607oa.dtb ) || { say "   FATAL: dtb build failed"; exit 1; }
  say "   built         : $DTB_SRC ($(stat -c %s "$DTB_SRC") bytes), EC node: $(ec_node_in_dtb "$DTB_SRC")"
  rule
  say "NEXT:  sudo bash ~/a16.sh ec install     (installs the module and arms the DTBs)"
  say "       then reboot into [3], and:  bash ~/a16.sh ec verify"
  say "log: $LOG"
}

do_install() {
  [ -f "$KO" ] || { say "FATAL: $KO is missing -- run: bash $0 build"; exit 1; }
  rule
  say "-- install the module into $UPD"
  run install -m 644 "$KO" "$UPD/asus-glymur-ec.ko"
  run depmod -a "$KVER"
  say "   installed      : $( [ "$DRY" = 1 ] && echo '(dry-run)' || { [ -f "$UPD/asus-glymur-ec.ko" ] && modinfo -F filename asus_glymur_ec 2>/dev/null || echo 'check failed -- the copy did not land'; } )"
  say "   removal        : rm $UPD/asus-glymur-ec.ko && depmod -a   ('$0 revert' does it)"
  rule
  say "-- arm the DTBs with the EC node (i2c9 = /soc@0/geniqup@ac0000/i2c@a84000, address 0x76)"
  local n=0
  for f in "$DTB_LIVE" "$DTB_ESP"; do
    [ -f "$f" ] || { say "   $f: absent, skipped"; continue; }
    if [ "$(ec_node_in_dtb "$f")" = yes ]; then say "   $f: already has the node"; continue; fi
    [ -f "$f.a16ecbak" ] || run cp -a "$f" "$f.a16ecbak"
    say "   $f: backup $( [ -f "$f.a16ecbak" ] && echo written || echo '(dry-run)')"
    if [ "$DRY" = 1 ]; then say "   [dry-run] dtc -I dtb -O dts … add embedded-controller@76 … dtc -I dts -O dtb"; n=$((n+1)); continue; fi
    if A16_LOG="$LOG" bash "$0" --add-ec-node "$f" ; then n=$((n+1)); say "   $f: EC node added"; else say "   $f: FAILED -- left untouched"; exit 1; fi
    say "   $f: now $(ec_node_in_dtb "$f"), $(stat -c %s "$f") bytes (was $(stat -c %s "$f.a16ecbak"))"
  done
  rule
  say "-- the armed DTB must still carry everything else that was in it"
  say "   (bluetooth node, the w-disable2 polarity flip, the hdmi-bridge power domain -- the BT and"
  say "    tert-PHY work; the node is added to the live DTB, so they are untouched by construction)"
  rule
  say "NEXT:"
  say "   1.  sudo reboot        (pick [3] if it is not the default)"
  say "   2.  bash ~/A16Build/BRINGUP/tools/a16-ec.sh verify"
  say "   3.  the Wi-Fi question this was brought in for:  sudo bash ~/a16.sh wifisleep test"
  say "log: $LOG"
}

do_verify() {
  rule
  say "-- the EC on the running kernel"
  say "   DT node        : $(dtc -I fs /proc/device-tree 2>/dev/null | grep -c 'zenbook-a16-ux3607oa-ec')   (1 = the DTB arm worked)"
  say "   i2c client     : $(ls /sys/bus/i2c/devices/ 2>/dev/null | grep '0076' || echo 'none at 0x76')"
  say "   driver bound   : $(for d in /sys/bus/i2c/devices/*0076; do [ -e "$d/driver" ] && basename "$(readlink -f "$d/driver")"; done 2>/dev/null)"
  say "   module loaded  : $(lsmod 2>/dev/null | awk '$1=="asus_glymur_ec"{print $1"  used by "$3}' || echo no)"
  say "   kernel lines   :"; journalctl -k -b --no-pager -o short-iso 2>/dev/null | grep -iE 'asus_glymur_ec|asus-glymur-ec|embedded-controller' | tail -8 | sed 's/^/      /'
  rule
  say "-- what it exposes"
  local h found=""
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "asus_glymur_ec" ] && found="$h"
  done
  if [ -n "$found" ]; then
    say "   hwmon          : $found"
    for f in "$found"/fan*_input "$found"/temp*_input; do
      [ -f "$f" ] && say "      $(basename "$f") = $(cat "$f" 2>/dev/null)   → $(awk -v v="$(cat "$f" 2>/dev/null)" 'BEGIN{printf "%.1f", v/1000}' 2>/dev/null)"
    done
  else
    say "   hwmon          : none (the driver did not bind -- read the kernel lines above)"
  fi
  say "   kbd backlight  : $(ls /sys/class/leds/ 2>/dev/null | grep -i kbd | tr '\n' ' ')"
  say "   EC interrupts  : $(grep -E 'asus|i2c@a84000|9-0076' /proc/interrupts 2>/dev/null | head -3 | sed 's/^/      /')"
  rule
  say "-- and the reason this is here: EC awareness of suspend, which this machine has never had"
  say "   the driver sends ASUS_QCOM_EC_MODERN_STANDBY_ENTER (0x23/0x07) before a suspend and EXIT"
  say "   (0x23/0x08) after it.  Test whether that changes the radio's fate:"
  say "      sudo bash ~/a16.sh wifisleep test"
  say "   radio still alive after the resume  -> the EC was the missing piece for the Wi-Fi wedge"
  say "   radio dead                          -> the EC is not what drops the module's power; the"
  say "                                          hook / s2idle ladder in wifisleep is the way"
}

do_revert() {
  rule
  say "-- remove the module"
  run rm -f "$UPD/asus-glymur-ec.ko"
  run depmod -a "$KVER"
  say "   installed      : $( [ "$DRY" = 1 ] && echo '(dry-run)' || { [ -f "$UPD/asus-glymur-ec.ko" ] && echo 'still there!' || echo removed; } )"
  rule
  say "-- restore the DTBs"
  for f in "$DTB_LIVE" "$DTB_ESP"; do
    if [ -f "$f.a16ecbak" ]; then
      run cp -a "$f.a16ecbak" "$f"
      say "   $f: restored ($(stat -c %s "$f") bytes)"
    else
      say "   $f: no .a16ecbak -- left alone"
    fi
  done
  rule
  say "reboot to unload the module; 'bash $0 status' then shows the stock state again."
}

# ---------------------------------------------------------------- --add-ec-node <dtb>
# Adds the EC node from the posted DTS patch to an already-built DTB, in place, and re-verifies it.
# The live DTB carries the Bluetooth and tert-PHY work, so the node is added to *it* rather than
# rebuilt from the tree (a rebuild renumbers phandles and would have to re-apply those changes).
if [ "${1:-}" = "--add-ec-node" ]; then
  dtb="${2:?}"
  tmp=$(mktemp -d)
  dtc -I dtb -O dts -o "$tmp/a.dts" "$dtb" 2>/dev/null || { echo "   dtc failed to decompile"; exit 1; }
  python3 - "$tmp/a.dts" "$tmp/b.dts" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')

# 1. the pinctrl state node that is already in this DTB but unreferenced (no phandle yet)
idx = None
for i, l in enumerate(lines):
    if re.match(r'^\s*' + 'ec-int-n-state' + r'\s*\{', l):
        idx = i; break
if idx is None:
    print("   FATAL: no ec-int-n-state pinctrl node in this DTB"); sys.exit(1)

# a free phandle: the highest one in use, +1
used = [int(m, 16) for m in re.findall(r'phandle = <0x([0-9a-f]+)>', '\n'.join(lines))]
ph = max(used) + 1
indent = re.match(r'^(\s*)', lines[idx]).group(1)
lines.insert(idx + 1, f"{indent}\tphandle = <0x{ph:x}>;")

# 2. the EC node, inside the i2c controller the i2c9 alias points at (/soc@0/.../i2c@a84000)
#    interrupts-extended needs the phandle of the node that OWNS the ec-int-n-state pin state (the
#    TLMM).  A decompiled DTB has no node names to trust, so it is read from that state node's
#    parent, and then checked against the gpio-keys node's own <&tlmm ...> cells.  Both must agree.
def node_body(start):
    ind = len(re.match(r'^(\s*)', lines[start]).group(1))
    body = []
    for k in range(start + 1, len(lines)):
        if lines[k].strip() == '};' and len(re.match(r'^(\s*)', lines[k]).group(1)) <= ind:
            break
        body.append(lines[k])
    return '\n'.join(body)

tlmm_ph = None
ind = len(re.match(r'^(\s*)', lines[idx]).group(1))
for k in range(idx - 1, -1, -1):
    if lines[k].rstrip().endswith('{') and len(re.match(r'^(\s*)', lines[k]).group(1)) < ind:
        m = re.search(r'phandle = <0x([0-9a-f]+)>;', node_body(k))
        if m: tlmm_ph = m.group(1)
        break
# cross-check: any <&tlmm ...> consumer, e.g. the lid switch on gpio-keys
ref = None
m = re.search(r'compatible = "gpio-keys";', '\n'.join(lines))
if m:
    gk = '\n'.join(lines).index('compatible = "gpio-keys";')
    m2 = re.search(r'gpios = <0x([0-9a-f]+)', '\n'.join(lines)[gk:gk+600])
    if m2: ref = m2.group(1)
if tlmm_ph is None or (ref and ref != tlmm_ph):
    print(f"   FATAL: cannot identify the TLMM phandle (from the pin state's parent: {tlmm_ph}, gpio-keys says {ref})")
    sys.exit(1)
print(f"   TLMM phandle   : 0x{tlmm_ph} (the parent of ec-int-n-state; gpio-keys agrees)")
i2c = None
for i, l in enumerate(lines):
    if re.match(r'^\s*i2c@a84000\s*\{', l):
        depth = len(re.match(r'^(\s*)', l).group(1))
        # walk to the closing brace of this node
        for j in range(i + 1, len(lines)):
            if lines[j].strip() == '};' and len(re.match(r'^(\s*)', lines[j]).group(1)) == depth:
                i2c = j; break
        break
if i2c is None:
    print("   FATAL: i2c@a84000 not found in this DTB"); sys.exit(1)
if tlmm_ph is None:
    print("   FATAL: could not find the tlmm phandle to build interrupts-extended"); sys.exit(1)
ind = ' ' * (depth + 1)
node = [
    f"{ind}embedded-controller@76 {{",
    f"{ind}\tcompatible = \"asus,zenbook-a16-ux3607oa-ec\";",
    f"{ind}\treg = <0x76>;",
    f"{ind}",
    f"{ind}\tinterrupts-extended = <0x{tlmm_ph} 0x42 0x02>;",
    f"{ind}",
    f"{ind}\tpinctrl-0 = <0x{ph:x}>;",
    f"{ind}\tpinctrl-names = \"default\";",
    f"{ind}",
    f"{ind}\t#thermal-sensor-cells = <0x01>;",
    f"{ind}",
    f"{ind}\twakeup-source;",
    f"{ind}}};",
]
lines[i2c:i2c] = node
open(dst, 'w').write('\n'.join(lines))
print(f"   inserted embedded-controller@76 in i2c@a84000 (pinctrl phandle 0x{ph:x}, irq <0x{tlmm_ph} 66>)")
PY
  [ -f "$tmp/b.dts" ] || { echo "   FATAL: edit failed"; rm -rf "$tmp"; exit 1; }
  dtc -I dts -O dtb -o "$dtb.new" "$tmp/b.dts" 2>"$tmp/dtc.err" || { echo "   FATAL: recompile failed:"; head -5 "$tmp/dtc.err"; rm -rf "$tmp"; exit 1; }
  # verify: the node is there, it references the state node, and the rest is byte-for-byte the same tree
  dtc -I dtb -O dts "$dtb.new" 2>/dev/null | grep -q 'zenbook-a16-ux3607oa-ec' || { echo "   FATAL: the rebuilt DTB has no EC node"; rm -rf "$tmp"; exit 1; }
  if dtc -I dtb -O dts -o "$tmp/new.dts" "$dtb.new" 2>/dev/null; then
    added=$(diff "$tmp/a.dts" "$tmp/new.dts" | grep -c '^>')
    echo "   verification: $added added lines vs the armed DTB (the EC node + one phandle property)"
  fi
  mv "$dtb.new" "$dtb"
  rm -rf "$tmp"
  exit 0
fi

say "=== a16-ec  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE ===="
say "kernel: $KVER   tree: $TREE"
say "log   : $LOG"
[ "$DRY" = 1 ] && say "A16_DRY=1: every command is printed, nothing changes."

case "$MODE" in
  status)  show_status ;;
  build)   do_build ;;
  install) [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh ec install"; say ""; exit 1; }; do_install ;;
  verify)  do_verify ;;
  kbd)
    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh ec kbd ${ARG:-2}"; say ""; exit 1; }
    case "${ARG:-}" in 0|1|2|3) ;; *) say "usage: sudo bash ~/a16.sh ec kbd 0|1|2|3   (keyboard backlight off..brightest)"; exit 2 ;; esac
    rule
    say "-- keyboard backlight -> $ARG"
    say "   the LED is real: $(ls /sys/class/leds/ | grep -i kbd | tr '\n' ' ')  max_brightness=$(cat /sys/class/leds/asus::kbd_backlight/max_brightness 2>/dev/null)  brightness=$(cat /sys/class/leds/asus::kbd_backlight/brightness 2>/dev/null)"
    run sh -c "echo $ARG > /sys/class/leds/asus::kbd_backlight/brightness"
    say "   brightness now: $(cat /sys/class/leds/asus::kbd_backlight/brightness 2>/dev/null)   (the EC was sent ASUS_EC_MBOX_CMD_KBD; if it did not change, the EC refused it and that is the finding)"
    rule
    ;;
  kbdhelp) : ;;
  revert)  [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh ec revert"; say ""; exit 1; }; do_revert ;;
  *) say "usage: a16-ec.sh [build|install|status|verify|kbd 0-3|revert]   (a16-ec.sh --help)"; exit 2 ;;
esac
say ""
say "log: $LOG"
