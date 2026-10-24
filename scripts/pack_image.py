#!/usr/bin/env python3
"""Read and rebuild Harman's 83_IMAGE firmware container.

83_IMAGE is a container: a small header with a partition table, followed by
each partition's data back to back. Each table entry (64 bytes) holds:

    +0x00  name        16 bytes, NUL padded ("block0", "rootfs", ...)
    +0x10  size        u64 LE, length of this partition's data in the file
    +0x18  crc         u32 LE, zlib CRC32 of that data
    +0x28  start       u32 LE, partition start on the NAND, in 128 KiB blocks
    +0x2c  blocks      u32 LE, partition size on the NAND, in 128 KiB blocks

The global header holds the magic (0xd2ada3f1) at +0x00, the entry size at
+0x14 and the entry count at +0x1c; entries begin at +0x40 and the data
begins right after the last entry. U-Boot's l2nand command checks every CRC
before writing, so after replacing the rootfs we must update its size and
CRC.

The rootfs partition data is a squashfs image followed by a few bytes of
padding; we keep that padding as-is.

Usage:
    pack_image.py extract-rootfs <83_IMAGE> <out.squashfs>
    pack_image.py build <83_IMAGE> <new.squashfs> <out_83_IMAGE>
"""
import struct
import sys
import zlib

MAGIC = 0xD2ADA3F1
NAND_BLOCK = 0x20000


def parse(img):
    magic, = struct.unpack_from("<I", img, 0x00)
    if magic != MAGIC:
        raise SystemExit("not an Invoke firmware container (bad magic)")
    entry_size, = struct.unpack_from("<I", img, 0x14)
    count, = struct.unpack_from("<I", img, 0x1C)
    off = 0x40 + count * entry_size
    parts = []
    for i in range(count):
        e = 0x40 + i * entry_size
        name = img[e:e + 16].split(b"\0", 1)[0].decode()
        size, = struct.unpack_from("<Q", img, e + 0x10)
        crc, = struct.unpack_from("<I", img, e + 0x18)
        blocks, = struct.unpack_from("<I", img, e + 0x2C)
        parts.append(dict(name=name, entry=e, size=size, crc=crc,
                          blocks=blocks, off=off))
        off += size
    return parts, off


def verify(img, label):
    parts, end = parse(img)
    for p in parts:
        data = img[p["off"]:p["off"] + p["size"]]
        if len(data) != p["size"]:
            raise SystemExit("%s: partition %s is truncated" % (label, p["name"]))
        if zlib.crc32(data) & 0xFFFFFFFF != p["crc"]:
            raise SystemExit("%s: CRC mismatch in partition %s" % (label, p["name"]))
    return parts, end


def rootfs_of(parts):
    for p in parts:
        if p["name"] == "rootfs":
            return p
    raise SystemExit("no rootfs partition in container")


def squashfs_len(data):
    if data[:4] != b"hsqs":
        raise SystemExit("rootfs partition does not start with a squashfs image")
    used, = struct.unpack_from("<Q", data, 40)  # superblock bytes_used
    return used


def extract_rootfs(img_path, out_path):
    img = open(img_path, "rb").read()
    parts, _ = verify(img, "input")
    r = rootfs_of(parts)
    data = img[r["off"]:r["off"] + r["size"]]
    open(out_path, "wb").write(data[:squashfs_len(data)])
    print("extracted rootfs squashfs (%d bytes)" % squashfs_len(data))


def build(img_path, sq_path, out_path):
    img = open(img_path, "rb").read()
    parts, end = verify(img, "input")
    r = rootfs_of(parts)
    old = img[r["off"]:r["off"] + r["size"]]
    pad = old[squashfs_len(old):]
    new_sq = open(sq_path, "rb").read()
    squashfs_len(new_sq)
    new = new_sq + pad
    cap = r["blocks"] * NAND_BLOCK
    if len(new) > cap:
        raise SystemExit("new rootfs (%d bytes) exceeds its partition (%d bytes)"
                         % (len(new), cap))

    out = bytearray(img[:r["off"]] + new + img[r["off"] + r["size"]:])
    struct.pack_into("<Q", out, r["entry"] + 0x10, len(new))
    struct.pack_into("<I", out, r["entry"] + 0x18, zlib.crc32(new) & 0xFFFFFFFF)

    # Re-parse and re-check every partition in the result.
    verify(bytes(out), "output")
    open(out_path, "wb").write(out)
    print("rootfs: %d -> %d bytes (partition capacity %d)" % (r["size"], len(new), cap))
    print("wrote %s (%d bytes); all partition CRCs verified" % (out_path, len(out)))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "extract-rootfs":
        extract_rootfs(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 5 and sys.argv[1] == "build":
        build(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        raise SystemExit(__doc__)
