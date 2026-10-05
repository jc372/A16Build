#!/usr/bin/env python3
"""Print where each segment of an initramfs starts: "<offset> <kind>" per line.

An initramfs is a sequence of cpio archives, later ones usually compressed; the kernel
walks them by magic.  This is the same walk, and it is deliberately the only thing it
does: a plain cpio segment is stepped record by record to its TRAILER, the zeros after
it are skipped, and the next magic says what follows.  Nothing is decompressed.

It exists because lsinitramfs and unmkinitramfs print nothing and exit 0 for the
archive mkinitramfs wrote on this machine -- silently -- so the caller lists the
members itself, segment by segment, with GNU cpio.

    a16-camera-initrd-segments.py <initramfs>

exit 0 = walked, 2 = malformed, 1 = unreadable.
"""
import sys

MAGICS = ((b"\x28\xb5\x2f\xfd", "zstd"), (b"\x1f\x8b", "gzip"), (b"\xfd7zXZ\x00", "xz"))
CPIO = (b"070701", b"070702")
ZERO_LIMIT = 1 << 20


def align4(n):
    return (n + 3) & ~3


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 1
    try:
        f = open(sys.argv[1], "rb")
    except OSError as e:
        print(f"UNREADABLE: {e}", file=sys.stderr)
        return 1

    with f:
        while True:
            off = f.tell()
            head = f.read(6)
            if not head:
                return 0
            if head.strip(b"\x00") == b"":
                zeros = len(head)
                while True:
                    c = f.read(1)
                    if not c:
                        head = b""
                        break
                    zeros += 1
                    if c != b"\x00":
                        f.seek(-1, 1)
                        head = f.read(6)
                        break
                    if zeros > ZERO_LIMIT:
                        print("MALFORMED: more than 1 MiB of zeros", file=sys.stderr)
                        return 2
                if not head:
                    return 0
                off = f.tell() - 6

            if head[:6] in CPIO:
                f.seek(-6, 1)
                while True:
                    h = f.read(110)
                    if len(h) < 110 or h[:6] not in CPIO:
                        print(f"MALFORMED: broken cpio header at {f.tell()}", file=sys.stderr)
                        return 2
                    size = int(h[6 + 6 * 8:14 + 6 * 8], 16)
                    namesize = int(h[6 + 11 * 8:14 + 11 * 8], 16)
                    if namesize < 1 or namesize > 4096:
                        print(f"MALFORMED: name size {namesize}", file=sys.stderr)
                        return 2
                    name = f.read(namesize)[:-1]
                    pad = align4(110 + namesize) - (110 + namesize)
                    if pad:
                        f.read(pad)
                    if name == b"TRAILER!!!":
                        break
                    f.seek(size, 1)
                    pad = align4(size) - size
                    if pad:
                        f.read(pad)
                print(off, "cpio")
                continue

            kind = "unknown"
            for magic, k in MAGICS:
                if head.startswith(magic[:len(head)]):
                    kind = k
                    break
            print(off, kind)
            return 0


if __name__ == "__main__":
    sys.exit(main())
