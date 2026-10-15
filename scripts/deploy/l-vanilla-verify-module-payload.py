#!/usr/bin/env python3
"""Verify modules.tar against modules-manifest.json in the same directory.

Generic copy of the P3c verify-module-payload.py (stage = this script's dir).
Checks: archive hash, only regular files/dirs, no build/source links, only
*.ko and top-level modules.* files, every module hash, exact module set.
"""
import hashlib, json, pathlib, tarfile

stage = pathlib.Path(__file__).resolve().parent
manifest = json.loads((stage / 'modules-manifest.json').read_text())


def digest(stream):
    h = hashlib.sha256()
    for b in iter(lambda: stream.read(1048576), b''):
        h.update(b)
    return h.hexdigest()


with (stage / 'modules.tar').open('rb') as f:
    assert digest(f) == manifest['archive_sha256'], 'archive hash changed'
seen = set()
with tarfile.open(stage / 'modules.tar') as archive:
    for item in archive:
        name = item.name.removeprefix('./')
        assert not item.name.startswith('/') and '..' not in pathlib.Path(name).parts
        assert item.isdir() or item.isfile(), 'links/special members prohibited'
        assert name not in ('build', 'source'), 'Host links prohibited'
        if item.isfile():
            assert name.endswith('.ko') or (len(pathlib.Path(name).parts) == 1 and name.startswith('modules.'))
        if item.isfile() and name.endswith('.ko'):
            assert digest(archive.extractfile(item)) == manifest['modules'][name]
            seen.add(name)
assert seen == set(manifest['modules']), 'module set changed'
print(f"module archive and all {len(seen)} module hashes PASS ({manifest['release']})")
