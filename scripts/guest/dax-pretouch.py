#!/usr/bin/env python3
"""One-time pre-touch of a whole device-DAX device inside a guest (packet reports/ENV-pretouch-packet.md).

After a VM (QEMU) start, the first guest touch of each 4 KiB page of the NVDIMM costs ~+6 us (inferred: Host
devdax fault of QEMU's /dev/dax1.0 mapping + EPT violation; reports/P-popcorn-instr-cost.md section 4.8). This tool
touches every 4 KiB page once, content-preserving: it reads one byte of the page and writes the same byte back,
so both the Host PTE and the EPT entry become present and writable.

Run as: python3 -B dax-pretouch.py [--chunk-mib N] [--warm-mib N]
Rules:
  - refuses when cxl_shm is loaded (/proc/modules): with page coherence on, the touches would be coherence faults;
  - the caller guarantees that nobody else maps the device (no concurrent writer on either VM): the
    read + write-back of one byte is not atomic against another writer;
  - device size from /sys/bus/dax/devices/<dev>/size, mapping granularity from .../align; chunks (default 1 GiB)
    are multiples of align, so every mmap offset and length is aligned;
  - prints one line per chunk (pages, seconds, ns/page; the first pass is the first-touch cost) and a second,
    timed pass over the first --warm-mib MiB (default 1024) as the warm reference.
--test-device / --test-modules are for Host unit tests only (a regular temp file, a fake /proc/modules).
Python 3 standard library only; no output files.
"""
import argparse
import mmap
import os
import sys
import time

PAGE = 4096
SUB = 2 << 20          # read/write-back granularity inside a chunk: 512 pages, then the next 2 MiB


def die(msg):
    print("PRETOUCH FAIL: " + msg, flush=True)
    sys.exit(1)


def cxl_shm_loaded(path):
    with open(path) as f:
        return any(l.split(" ", 1)[0] == "cxl_shm" for l in f)


def touch(mm, length):
    """Read one byte of every 4 KiB page and write it back; returns pages touched (content unchanged)."""
    n = 0
    for s in range(0, length, SUB):
        e = min(s + SUB, length)
        b = mm[s:e:PAGE]           # one read per page (first byte)
        mm[s:e:PAGE] = b           # the same bytes back: one write per page
        n += len(b)
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dax", default="dax0.0", help="device-DAX name (default dax0.0)")
    ap.add_argument("--chunk-mib", type=int, default=1024, help="mmap chunk size in MiB (default 1024)")
    ap.add_argument("--warm-mib", type=int, default=1024, help="second timed pass over the first N MiB (0: none)")
    ap.add_argument("--test-device", help="TESTING ONLY: a regular file instead of /dev/<dax> (size = file size)")
    ap.add_argument("--test-modules", help="TESTING ONLY: path read instead of /proc/modules")
    ap.add_argument("--test-align", type=int, default=PAGE, help="TESTING ONLY: align for --test-device")
    a = ap.parse_args()

    mods = a.test_modules or "/proc/modules"
    if cxl_shm_loaded(mods):
        die("cxl_shm is loaded (%s): unload it first" % mods)
    if a.test_device:
        if a.test_device.startswith("/dev/"):
            die("--test-device must be a regular file, not " + a.test_device)
        dev = a.test_device
        size = os.stat(dev).st_size
        align = a.test_align
    else:
        if a.test_align != PAGE:
            die("--test-align only with --test-device")
        dev = "/dev/" + a.dax
        sysd = "/sys/bus/dax/devices/%s/" % a.dax
        size = int(open(sysd + "size").read())
        align = int(open(sysd + "align").read())
    if align <= 0 or align % PAGE or size <= 0 or size % align:
        die("size %d / align %d: size must be a positive multiple of align, align a multiple of 4096" % (size, align))
    chunk = a.chunk_mib << 20
    if chunk <= 0 or chunk % align or chunk % SUB:
        die("chunk %d B must be a positive multiple of align %d and of 2 MiB" % (chunk, align))
    warm = min(a.warm_mib << 20, size)
    if warm < 0 or warm % align:
        die("warm range %d B must be a multiple of align %d" % (warm, align))

    fd = os.open(dev, os.O_RDWR)
    print("device=%s size=%d align=%d chunk=%d pages_expected=%d pid=%d" % (dev, size, align, chunk, size // PAGE,
          os.getpid()), flush=True)

    def run_pass(name, end):
        total, t_all, off, i = 0, time.monotonic_ns(), 0, 0
        while off < end:
            ln = min(chunk, end - off)
            t0 = time.monotonic_ns()
            mm = mmap.mmap(fd, ln, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=off)
            n = touch(mm, ln)
            mm.close()
            dt = time.monotonic_ns() - t0
            if n != ln // PAGE:
                die("%s chunk %d: touched %d pages, want %d" % (name, i, n, ln // PAGE))
            print("%s chunk=%d offset=%d pages=%d ns=%d ns_per_page=%.0f" % (name, i, off, n, dt, dt / n), flush=True)
            total += n; off += ln; i += 1
        dt = time.monotonic_ns() - t_all
        print("%s total pages=%d chunks=%d elapsed_s=%.3f ns_per_page=%.0f" % (name, total, i, dt / 1e9,
              dt / total if total else 0), flush=True)
        return total

    total = run_pass("first", size)
    if total != size // PAGE:
        die("first pass touched %d pages, want %d" % (total, size // PAGE))
    if warm:
        run_pass("warm", warm)
    os.close(fd)
    if cxl_shm_loaded(mods):
        die("cxl_shm appeared during the run (%s)" % mods)
    print("PRETOUCH DONE pages=%d" % total, flush=True)


if __name__ == "__main__":
    main()
