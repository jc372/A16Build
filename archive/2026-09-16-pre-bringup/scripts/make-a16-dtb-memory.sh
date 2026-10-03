#!/usr/bin/env bash
# Add a /memory node to the A16 device tree.
#
# Why: the Glymur device tree shipped by linux-next has no /memory node at all
# (unlike hamoa.dtsi on X1E, which carries a zero-sized placeholder "for the
# bootloader to fill in"). Booting such a tree with GRUB's `devicetree` command
# gives the kernel no RAM, so it dies before any console exists — no output at
# all, even with earlycon=efifb.
#
# Two modes:
#   placeholder        add the upstream X1E-style node, size 0, in case the
#                      loader/firmware fills the size in
#   ranges "b:s ..."   bake the real usable-RAM ranges (base:size, hex) into
#                      one memory@ node per range
set -Eeuo pipefail

IN="${1:?usage: $0 <in.dtb> <out.dtb> [placeholder | ranges \"base:size ...\"]}"
OUT="${2:?usage: $0 <in.dtb> <out.dtb> [placeholder | ranges \"base:size ...\"]}"
MODE="${3:-placeholder}"

for cmd in dtc fdtdump; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
[[ -f "$IN" ]] || { echo "No such DTB: $IN" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

dtc -I dtb -O dts -o "$WORK/in.dts" "$IN" 2>/dev/null

DTS="$WORK/in.dts"
python3 - "$DTS" "$MODE" "${4:-}" <<'PY'
import re, sys

dts_path, mode, ranges = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(dts_path).read()

def mem_node(addr, size):
    if size:
        return ("\tmemory@%x {\n\t\tdevice_type = \"memory\";\n"
                "\t\treg = <0x00 0x%x 0x00 0x%x>;\n\t};\n\n" % (addr, addr, size))
    return ("\tmemory@%x {\n\t\tdevice_type = \"memory\";\n"
            "\t\t/* size filled in by the bootloader */\n"
            "\t\treg = <0x00 0x%x 0x00 0x0>;\n\t};\n\n" % (addr, addr))

if mode == "placeholder":
    block = mem_node(0x80000000, 0)
elif mode == "ranges":
    if not ranges:
        sys.exit("ranges mode needs \"base:size ...\"")
    parts = []
    for pair in ranges.split():
        base, size = pair.split(":")
        parts.append(mem_node(int(base, 16), int(size, 16)))
    block = "".join(parts)
else:
    sys.exit("unknown mode: %s" % mode)

if re.search(r"^\tmemory@", text, re.M):
    sys.exit("tree already has a /memory node; refusing to add a second one")

# Insert before /reserved-memory when present, else after the root model line.
anchor = re.search(r"^\treserved-memory \{", text, re.M)
if anchor:
    idx = anchor.start()
else:
    m = re.search(r'^\tmodel = "[^\n]*\n', text, re.M)
    if not m:
        sys.exit("could not find an insertion point in the tree")
    idx = m.end()

open(dts_path, "w").write(text[:idx] + block + text[idx:])
print("inserted memory node(s), mode=%s" % mode)
PY

dtc -I dts -O dtb -o "$OUT" "$DTS" 2>"$WORK/dtc.err" || { cat "$WORK/dtc.err" >&2; exit 1; }
fdtdump "$OUT" | grep -E 'memory@|device_type = "memory"' | head
printf '%s -> %s (%s bytes)\n' "$IN" "$OUT" "$(stat -c%s "$OUT")"
