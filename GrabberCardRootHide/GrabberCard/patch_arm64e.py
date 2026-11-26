#!/usr/bin/env python3
"""把 thin Mach-O 的 cpusubtype 修补为 CPU_SUBTYPE_ARM64E (2)。"""
import struct, sys

ARM64 = 0x0100000C
ARM64E = 0x00000002

def patch(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    magic = struct.unpack('<I', data[:4])[0]
    if magic != 0xfeedfacf:
        raise SystemExit(f'{path}: 不是 64 位 Mach-O (magic=0x{magic:x})')
    cputype, cpusubtype = struct.unpack('<ii', data[4:12])
    if cputype != ARM64:
        raise SystemExit(f'{path}: 非 arm64 (cputype=0x{cputype:x})')
    if cpusubtype == ARM64E:
        print(f'{path}: 已是 arm64e')
        return
    struct.pack_into('<i', data, 8, ARM64E)
    with open(path, 'wb') as f:
        f.write(data)
    print(f'{path}: cpusubtype 0x{cpusubtype:x} -> 0x{ARM64E:x} (arm64e)')

for p in sys.argv[1:]:
    patch(p)
