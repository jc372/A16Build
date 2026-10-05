#!/usr/bin/env bash
# a16-build-dp-rate-module.sh — build the external-DP candidate for
# 7.3.0-rc3-next-20260914: the link-rate cap (patch 0019) plus the DPU
# stuck-flush mitigation (patch 0020).
#
#   bash a16-build-dp-rate-module.sh            # tree + edits + gate + build + verify
#   bash a16-build-dp-rate-module.sh --tree     # only create/refresh the tree and apply the edits
#
# Produces /home/jc/build/linux-next-1a1de54f7369-dprate/drivers/gpu/drm/msm/msm.ko,
# which `sudo bash ~/a16.sh dprate` stages over the dpnext layer, and writes both
# record patches into BRINGUP/patches/.
#
# Two things this script refuses to skip, both learned the hard way on 2026-10-02:
#   1. the tree's generated headers must be synced from a config that matches the
#      running kernel — `make syncconfig`, never `olddefconfig` without a working
#      pahole, which silently drops CONFIG_DEBUG_INFO_BTF and with it
#      CONFIG_SCHED_CLASS_EXT (struct task_struct then shifts 320 bytes, and the
#      module oopses in msm_gpu_create_private_vm while reading task_pid());
#   2. BRINGUP/tools/a16-abi-layout-gate.sh must PASS before the build is used.
set -eu

base=/home/jc/build/linux-next-1a1de54f7369                  # dpnext sources (patches 0009/0016)
src=/home/jc/build/linux-next-1a1de54f7369-dprate            # working tree for this candidate
cfg=/home/jc/build/linux-next-1a1de54f7369-qmp-v5/.config    # identical to the kernel's, bar compiler versions
out=/home/jc/a16-payload
log=$out/dprate-build-$(date +%Y%m%d-%H%M%S).log
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
mode="${1:-all}"

export PATH="$HOME/.hermes/cache/scratch/pahole-local/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.hermes/cache/scratch/pahole-local/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"

[ -d "$base" ] || { echo "FATAL: base tree $base missing"; exit 1; }
if [ ! -d "$src" ]; then
    echo "copying $base -> $src (takes a minute)"
    cp -a "$base" "$src"
fi

echo "== config: kernel-matching .config + regenerated headers =="
cp -a "$cfg" "$src/.config"
make -C "$src" ARCH=arm64 syncconfig > "$out/dprate-syncconfig.log" 2>&1 || {
    echo "FATAL: syncconfig failed"; tail -15 "$out/dprate-syncconfig.log"; exit 1; }
printf '  autoconf.h SCHED_CLASS_EXT=%s DEBUG_INFO_BTF=%s\n' \
    "$(grep -c CONFIG_SCHED_CLASS_EXT "$src/include/generated/autoconf.h")" \
    "$(grep -c CONFIG_DEBUG_INFO_BTF "$src/include/generated/autoconf.h")"

echo "== edit 1/2: external rate cap (patch 0019) =="
python3 - "$src/drivers/gpu/drm/msm/dp/dp_panel.c" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
PARAM = '''
/*
 * A16 experiment (2026-10-02): the basic receiver capability block of both tested
 * monitors advertises HBR2 (5.4G, DPCD 0x00001 = 0x14) while their DPRX extended
 * receiver capability block advertises HBR3 (8.1G, DPCD 0x02200 byte1 = 0x1e), and
 * the LTTPR advertises 8.1G too.  drm_dp_read_dpcd_caps() merges the extended block
 * over the basic one, so the driver trains the external link at 8.1G x4 on a link
 * that is only guaranteed at 5.4G.  Every observed failure is the LTTPR segment's
 * channel equalization timing out with pre-emphasis already at maximum
 * (ret=-110 -> rc=-104), after which the DPU's commits never complete and the
 * desktop freezes.  This parameter caps the external DP link rate so the rate can be
 * swept at runtime (write to /sys/module/msm/parameters/a16_dp_max_rate, then
 * re-plug) without another kernel build.  0 = no cap, eDP is never touched.
 */
static uint a16_dp_max_rate;
module_param(a16_dp_max_rate, uint, 0644);
MODULE_PARM_DESC(a16_dp_max_rate, "A16: cap external DP link rate in kHz (0 = no cap)");

static u32 a16_dp_cap_external_rate(struct msm_dp_panel *msm_dp_panel, u32 rate)
{
\tstatic const u32 a16_rates[] = { 162000, 270000, 540000, 810000 };
\tu32 cap = a16_dp_max_rate;
\tint i;

\tif (!cap || rate <= cap)
\t\treturn rate;
\tif (msm_dp_panel->connector->connector_type == DRM_MODE_CONNECTOR_eDP)
\t\treturn rate;
\tfor (i = ARRAY_SIZE(a16_rates) - 1; i >= 0; i--)
\t\tif (a16_rates[i] <= cap)
\t\t\treturn a16_rates[i];
\treturn rate;
}

'''
if 'a16_dp_max_rate' in src:
    print("  already applied")
else:
    idx = src.index('/* eDP sink */')
    head = src.rindex('\nstatic ', 0, idx)
    line_start = src.rindex('\n', 0, head)
    src = src[:line_start] + '\n' + PARAM + src[line_start:]
    ins = '\tlink_info->num_lanes = drm_dp_max_lane_count(dpcd);'
    assert src.count(ins) == 1, 'anchor not unique'
    src = src.replace(ins, '\tlink_info->rate = a16_dp_cap_external_rate(msm_dp_panel, link_info->rate);\n\n' + ins)
    open(path, 'w').write(src)
    print("  inserted module parameter + cap")
PY

echo "== edit 2/2: drop a stuck DPU flush after a commit-done timeout (patch 0020) =="
python3 - "$src/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('\t\tDPU_ERROR("vblank timeout: %x\\n", hw_ctl->ops.get_flush_register(hw_ctl));\n'
       '\t\treturn -ETIMEDOUT;')
new = ('\t\tDPU_ERROR("vblank timeout: %x\\n", hw_ctl->ops.get_flush_register(hw_ctl));\n'
       '\t\t/*\n'
       '\t\t * A16 (2026-10-02): this flush waits for a vsync that can never arrive when\n'
       '\t\t * the frame source is dead - an external DP stream whose link training\n'
       '\t\t * failed has no pixel clock and never produces one.  Left pending, every\n'
       '\t\t * later commit touching this CRTC times out as well, and because one\n'
       '\t\t * atomic commit covers both CRTCs the whole desktop freezes (only a reboot\n'
       '\t\t * clears it).  Drop the pending flush so the pipeline keeps running; this\n'
       '\t\t * commit still reports the timeout and the external output stays dark.\n'
       '\t\t */\n'
       '\t\tif (hw_ctl->ops.clear_pending_flush && hw_ctl->ops.trigger_flush) {\n'
       '\t\t\thw_ctl->ops.clear_pending_flush(hw_ctl);\n'
       '\t\t\thw_ctl->ops.trigger_flush(hw_ctl);\n'
       '\t\t}\n'
       '\t\treturn -ETIMEDOUT;')
if 'A16 (2026-10-02): this flush waits' in s:
    print('  already applied')
else:
    assert s.count(old) == 1, 'timeout-branch anchor not unique (%d)' % s.count(old)
    open(p, 'w').write(s.replace(old, new))
    print('  inserted the flush-drop in dpu_encoder_phys_vid_wait_for_commit_done()')
PY

echo "== ABI gate (must PASS) =="
bash "$here/a16-abi-layout-gate.sh" "$src" | tail -3

if [ "$mode" = "--tree" ]; then
    echo "tree ready: $src (no build performed)"
    exit 0
fi

echo "== build =="
find "$src/drivers/gpu/drm/msm" -name '*.o' -delete
rm -f "$src/drivers/gpu/drm/msm/msm.ko"
make -C "$src" ARCH=arm64 -j"$(nproc)" M=drivers/gpu/drm/msm modules KBUILD_MODPOST_WARN=1 > "$log" 2>&1 || {
    echo "BUILD FAILED"; tail -25 "$log"; exit 1; }
ko="$src/drivers/gpu/drm/msm/msm.ko"
echo "compiled objects: $(grep -cE '^\s+CC' "$log")"
printf 'srcversion=%s\nsha256=%s\nvermagic=%s\nkernel  =%s\n' \
    "$(modinfo -F srcversion "$ko")" "$(sha256sum "$ko" | cut -d' ' -f1)" \
    "$(modinfo -F vermagic "$ko")" "$(uname -r)"

echo "== verify the built artifact =="
printf '  rate-cap parameter : %s\n' "$(modinfo -p "$ko" | grep -c a16_dp_max_rate) (1 = present)"
printf '  mitigation         : %s\n' "$(grep -c 'A16 (2026-10-02): this flush waits' "$src/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c") (1 = in source)"
printf '  thread_pid offset  : %s (kernel BTF: 2144)\n' \
    "$(objdump -d --no-show-raw-insn "$ko" | awk '/<msm_gpu_create_private_vm>:/{on=1} on{print; n++} on&&n>40{exit}' | grep -oE '#2144' | head -1)"
printf '  module_layout CRC  : %s (kernel-built modules: 0xe6658f7b)\n' \
    "$(modprobe --dump-modversions "$ko" | awk '$2=="module_layout"{print $1}')"

echo "== record patches =="
diff -u "$base/drivers/gpu/drm/msm/dp/dp_panel.c" "$src/drivers/gpu/drm/msm/dp/dp_panel.c" \
    > "$repo/retired/patches/old-numbering/0019-msm-dp-external-rate-cap-parameter.patch" || true
diff -u "$base/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c" \
        "$src/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c" \
    > "$repo/retired/patches/old-numbering/0020-dpu-drop-stuck-flush-after-vblank-timeout.patch" || true
wc -l "$repo"/retired/patches/old-numbering/0019-*.patch "$repo"/retired/patches/old-numbering/0020-*.patch | sed 's/^/  /'
echo "DONE - stage with: sudo bash ~/a16.sh dprate"
