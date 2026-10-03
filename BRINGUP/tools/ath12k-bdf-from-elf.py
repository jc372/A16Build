#!/usr/bin/env python3
"""Pull the raw BDF out of a Windows/Linux-firmware ath12k board ELF.

The vendor and linux-firmware board payloads are ELF32/ARM wrappers around the actual
BDF: the tool that built them embedded `bdwlan.bin` and left the linker symbols

    _binary_<path>_bin_start / _binary_<path>_bin_end / _binary_<path>_bin_size

so the real board data is that symbol's [start, end) byte range.  Hashing those ranges
is how two wrappers can be compared as *board data* instead of as ELF files.

    a16-bdf-from-elf.py ls   <file.elf>...        # symbols + inner blob size/sha256
    a16-bdf-from-elf.py save <file.elf> <out.bin> # write the inner blob
"""
import hashlib
import struct
import sys


def elf32_symbols(data):
    assert data[:4] == b"\x7fELF" and data[4] == 1, "expected ELF32"
    e_shoff, = struct.unpack_from("<I", data, 0x20)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x2e)
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = \
            struct.unpack_from("<IIIIIIIIII", data, off)
        secs.append({"name": name, "type": typ, "addr": addr, "off": offset,
                     "size": size, "link": link, "entsize": entsize})
    shstr = data[secs[e_shstrndx]["off"]:secs[e_shstrndx]["off"] + secs[e_shstrndx]["size"]]
    for s in secs:
        s["name"] = shstr[s["name"]:shstr.index(b"\0", s["name"])].decode()
    for s in secs:
        if s["type"] == 2:  # SYMTAB
            strtab = secs[s["link"]]
            strs = data[strtab["off"]:strtab["off"] + strtab["size"]]
            out = []
            n = s["size"] // (s["entsize"] or 16)
            for i in range(n):
                st_name, st_value, st_size, st_info, st_other, st_shndx = \
                    struct.unpack_from("<IIIBBH", data, s["off"] + i * (s["entsize"] or 16))
                if st_name:
                    nm = strs[st_name:strs.index(b"\0", st_name)].decode()
                    out.append((nm, st_value, st_size, st_shndx))
            return out, secs
    return [], secs


def vaddr_off(secs, addr):
    """map a symbol address to a file offset through the section that contains it"""
    for s in secs:
        if s["type"] != 8 and s["addr"] and s["addr"] <= addr < s["addr"] + s["size"]:
            return s["off"] + (addr - s["addr"])
    return None


def inner(data):
    syms, secs = elf32_symbols(data)
    starts = {n: v for n, v, _s, _i in syms if n.endswith("_bin_start")}
    ends = {n: v for n, v, _s, _i in syms if n.endswith("_bin_end")}
    sizes = {n: v for n, v, _s, _i in syms if n.endswith("_bin_size")}
    for name, start in starts.items():
        prefix = name[:-len("_bin_start")]
        end = ends.get(prefix + "_bin_end")
        size = sizes.get(prefix + "_bin_size")
        if end is None:
            continue
        off0, off1 = vaddr_off(secs, start), vaddr_off(secs, end)
        if off0 is None or off1 is None:
            continue
        blob = bytes(data[off0:off1])
        return prefix + (" (len %s from the size symbol)" % ("ok" if size == len(blob) else
                                                            "MISMATCH %s vs %d" % (size, len(blob)))), blob, size, syms
    # no symbols: the wrapper may carry the BDF as the whole .data section
    for s in secs:
        if s["name"] == ".data" and s["size"]:
            return ".data (no _binary_*_bin_start symbols; whole section)", \
                bytes(data[s["off"]:s["off"] + s["size"]]), s["size"], syms
    return None, None, None, syms


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    mode = argv[0]
    if mode == "ls":
        for path in argv[1:]:
            data = open(path, "rb").read()
            prefix, blob, size, syms = inner(data)
            if blob is None:
                print("%s: no _binary_*_bin_start symbols (sections: %s)"
                      % (path, ", ".join(s["name"] for s in elf32_symbols(data)[1] if s["name"])))
                continue
            print("%-46s inner=%-7d (%d bytes) sha256=%s\n    symbol prefix: %s  (.bin_size symbol: %s)"
                  % (path.split("/")[-1], len(blob), len(data),
                     hashlib.sha256(blob).hexdigest()[:16], prefix, size))
    elif mode == "save":
        data = open(argv[1], "rb").read()
        _p, blob, _s, _syms = inner(data)
        if blob is None:
            sys.exit("%s: no inner blob" % argv[1])
        open(argv[2], "wb").write(blob)
        print("wrote %s (%d bytes, sha256 %s)" % (argv[2], len(blob),
                                                  hashlib.sha256(blob).hexdigest()[:16]))
    else:
        sys.exit(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
