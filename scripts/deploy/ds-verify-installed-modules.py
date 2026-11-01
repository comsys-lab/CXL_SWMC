#!/usr/bin/env python3
"""Verify that an installed /lib/modules/<release> tree is exactly the bundle's install set.

Used by p-destijl-deploy.sh (re-run of a release already installed on the guest):
  ds-verify-installed-modules.py STAGE --dir TREE [--uid N]       walk TREE (guest, root, prepare-guest.sh)
  ds-verify-installed-modules.py STAGE --listing FILE [--uid N]   parse a listing taken on the guest (Host, precheck)
STAGE holds modules.tar + modules-manifest.json (+ kernel.config is not needed: config_sha256 is in the manifest).
Listing format (one line per entry, produced by p-destijl-deploy.sh with find/sha256sum on the guest):
  T <find %y> <uid> <octal mode> <path>     every entry below TREE (no '.')
  H <sha256>  <path>                        every regular file (sha256sum output with an 'H ' prefix)
Accepts the tree only if:
  - every entry is a regular file or a directory (no links, devices, ...), owned by uid N (default 0), not
    group/other-writable;
  - the directories are exactly the modules.tar directories plus build/;
  - every *.ko of the manifest is present with the manifest sha256 (the tar copy has the same hash);
  - every other modules.tar file that depmod does not write (modules.order, modules.builtin,
    modules.builtin.modinfo) is present with its tar sha256;
  - build/.config is present with the manifest config_sha256;
  - the only other files are the depmod outputs (top-level, content not checked: prepare-guest.sh re-runs depmod);
  - nothing else exists.
"""
import argparse, hashlib, json, os, pathlib, stat, sys, tarfile

DEPMOD = {'modules.dep', 'modules.dep.bin', 'modules.alias', 'modules.alias.bin', 'modules.softdep',
          'modules.symbols', 'modules.symbols.bin', 'modules.builtin.bin', 'modules.builtin.alias.bin',
          'modules.devname', 'modules.weakdep'}


def digest(stream):
    h = hashlib.sha256()
    for b in iter(lambda: stream.read(1048576), b''):
        h.update(b)
    return h.hexdigest()


def expected(stage):
    manifest = json.loads((stage / 'modules-manifest.json').read_text())
    with (stage / 'modules.tar').open('rb') as f:
        assert digest(f) == manifest['archive_sha256'], 'modules.tar hash != manifest archive_sha256'
    dirs, files = {'build'}, {'build/.config': manifest['config_sha256']}
    with tarfile.open(stage / 'modules.tar') as archive:
        for item in archive:
            name = item.name.removeprefix('./').rstrip('/')
            assert name and not name.startswith('/') and '..' not in pathlib.Path(name).parts, f'bad member {item.name}'
            if item.isdir():
                dirs.add(name)
            elif item.isfile():
                if name in DEPMOD:
                    continue
                files[name] = digest(archive.extractfile(item))
                if name.endswith('.ko'):
                    assert manifest['modules'].get(name) == files[name], f'tar {name} != manifest'
            else:
                raise AssertionError(f'non-file member {item.name}')
    kos = {n for n in files if n.endswith('.ko')}
    assert kos == set(manifest['modules']), 'tar module set != manifest'
    return manifest['release'], dirs, files


def walk(tree):
    """-> {path: (type letter, uid, mode)}, {path: sha256} for everything below tree (links not followed)."""
    ent, sums = {}, {}
    for top, dnames, fnames in os.walk(tree, followlinks=False):
        for n in dnames + fnames:
            p = pathlib.Path(top) / n
            st = os.lstat(p)
            rel = str(p.relative_to(tree))
            t = 'd' if stat.S_ISDIR(st.st_mode) else 'f' if stat.S_ISREG(st.st_mode) else 'x'
            ent[rel] = (t, st.st_uid, stat.S_IMODE(st.st_mode))
            if t == 'f':
                with open(p, 'rb') as f:
                    sums[rel] = digest(f)
    return ent, sums


def parse(listing):
    ent, sums = {}, {}
    for line in pathlib.Path(listing).read_text().splitlines():
        if line.startswith('T '):
            _, t, uid, mode, rel = line.split(' ', 4)
            assert rel not in ent, f'duplicate {rel}'
            ent[rel] = (t, int(uid), int(mode, 8))
        elif line.startswith('H '):
            h, sep, rel = line[2:].partition('  ')
            assert sep and len(h) == 64 and not h.startswith('\\'), f'bad hash line {line!r}'
            sums[rel] = h
        else:
            raise AssertionError(f'bad listing line {line!r}')
    return ent, sums


def check(stage, ent, sums, uid):
    release, dirs, files = expected(stage)
    bad = []
    for rel, (t, u, mode) in sorted(ent.items()):
        if t not in ('d', 'f'):
            bad.append(f'not a file/dir: {rel} ({t})')
        if u != uid:
            bad.append(f'owner {u} != {uid}: {rel}')
        if mode & 0o022:
            bad.append(f'group/other-writable {oct(mode)}: {rel}')
    have_dirs = {r for r, e in ent.items() if e[0] == 'd'}
    have_files = {r for r, e in ent.items() if e[0] == 'f'}
    bad += [f'missing dir: {d}' for d in sorted(dirs - have_dirs)]
    bad += [f'extra dir: {d}' for d in sorted(have_dirs - dirs)]
    bad += [f'missing file: {f}' for f in sorted(set(files) - have_files)]
    bad += [f'extra file: {f}' for f in sorted(have_files - set(files) - DEPMOD)]
    bad += [f'hash differs: {f}' for f in sorted(set(files) & have_files) if sums.get(f) != files[f]]
    bad += [f'hash without entry: {f}' for f in sorted(set(sums) - have_files)]
    if bad:
        for b in bad[:40]:
            print('FAIL', b)
        print(f'installed modules tree FAIL ({release}): {len(bad)} problems')
        return 1
    print(f'installed modules tree PASS ({release}): {len(dirs)} dirs, {len(files)} files verified, '
          f'{len(have_files & DEPMOD)} depmod outputs')
    return 0


def main():
    a = argparse.ArgumentParser()
    a.add_argument('stage', type=pathlib.Path)
    g = a.add_mutually_exclusive_group(required=True)
    g.add_argument('--dir', type=pathlib.Path)
    g.add_argument('--listing', type=pathlib.Path)
    a.add_argument('--uid', type=int, default=0)
    o = a.parse_args()
    if o.dir is not None:
        st = os.lstat(o.dir)
        assert stat.S_ISDIR(st.st_mode), f'{o.dir} is not a directory (or is a link)'
        ent, sums = walk(o.dir)
    else:
        ent, sums = parse(o.listing)
    try:
        return check(o.stage.resolve(), ent, sums, o.uid)
    except AssertionError as e:
        print(f'installed modules tree FAIL: {e}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
