#!/usr/bin/env python3
"""initramfs hook helper: drop modprobe.d and shared-memory drivers from the
initramfs staging root (argv[1]); they load later from the root fs as usual.

Generic copy of the P3c sanitize-initrd.py (stage = this script's dir).
"""
import os, pathlib, shutil, sys

stage = pathlib.Path(__file__).resolve().parent
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
if not root.is_relative_to(stage / 'tmp') or root.is_symlink():
    raise RuntimeError('unexpected initramfs staging root')
blocked = ('cxl_shm', 'nfit', 'libnvdimm', 'nd_pmem', 'nd_btt', 'dax_pmem')
for relative in ('etc/modprobe.d', 'usr/lib/modprobe.d', 'lib/modprobe.d'):
    path = root / relative
    if not path.resolve().is_relative_to(root):
        raise RuntimeError('modprobe path escapes staging')
    if path.is_symlink():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)
for base, dirs, files in os.walk(root, followlinks=False):
    for name in files:
        if name.endswith('.ko') and name[:-3].replace('-', '_') in blocked:
            path = pathlib.Path(base) / name
            if not path.resolve().is_relative_to(root):
                raise RuntimeError('module path escapes staging')
            path.unlink()
