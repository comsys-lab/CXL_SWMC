#!/usr/bin/env python3
"""P3b proposal. Each action requires a recorded workspace-only user grant.

Run with python3 scripts/p3b-build.py ACTION --authorized-p3b-workspace.
The flag acknowledges authorization; it does not provide or infer authorization.
No original writes, clean, network, install outside T, or runtime module loading.
"""
import argparse
import difflib
import gzip
import hashlib
import json
import lzma
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import time

TOWER = Path('/home/comsys/sungsu/destijl-control')
REPO = Path('/home/comsys/sungsu/CXLSHMSWcoherence')
COMMIT = '5733d21adec319bbd2873864fc66fa0e6aa3fbad'
T = TOWER / 'workspaces/p3-5733d21a-v1'
S, O, E = T / 'source', T / 'build', T / 'external'
ROOTS = ('famfs-linux', 'msg_layer_module')
EXCLUDED = ('famfs-linux/tools/testing/selftests/sgx/sign_key.pem',)
DIRTY = ('famfs-linux/Makefile', 'famfs-linux/arch/x86/kvm/mmu/spte.c')
EXPECTED_DIRTY = dict(zip(DIRTY, (
    'bf81a48cbd0af3fd5d8451ce9791f267eacc79e0a54a5dd571cfbd825baab022',
    'b494bb775518d9499b51550a442522d2961116ee6a12adc4ee8fb7b5bfbc5477')))
CONFIG = REPO / 'famfs-linux/.config'
EXPECTED_CONFIG = '954e0b40a29f0c8540be456e5083a6f5ad19761b6e91e6d4a0cdcb642b3ba176'
# Deterministic tool search and no inherited make/compiler/config/helper overrides.
ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C',
       'GIT_OPTIONAL_LOCKS': '0', 'GIT_NO_LAZY_FETCH': '1', 'GIT_CONFIG_NOSYSTEM': '1',
       'GIT_CONFIG_GLOBAL': str(T / 'no-global-git-config'),
       'TMPDIR': str(T / 'tmp'), 'TMP': str(T / 'tmp'), 'TEMP': str(T / 'tmp'),
       'KBUILD_BUILD_USER': 'p3b', 'KBUILD_BUILD_HOST': 'isolated-host'}


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def safe(path, inside=None):
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts, f'unsafe path: {path}')
    if inside:
        require(path == inside or inside in path.parents, f'outside scope: {path}')
    for ancestor in reversed((path, *path.parents)):
        if os.path.lexists(ancestor):
            require(not stat.S_ISLNK(os.lstat(ancestor).st_mode),
                    f'symlink component: {ancestor}')
    return path


def run(args, capture=True, input=None):
    result = subprocess.run([str(x) for x in args], env=ENV, input=input,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        detail = result.stderr.decode(errors='replace')[-3000:] if capture else ''
        raise RuntimeError(f'failed ({result.returncode}): {args}\n{detail}')
    return result.stdout if capture else b''


def git(*args):
    safe(REPO)
    safe(REPO / '.git')
    return run(['git', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false',
                '-C', REPO, *args])


def digest(path):
    safe(path)
    require(path.is_file(), f'missing regular file: {path}')
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def save(name, data):
    path = safe(T / name, T)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def load(name):
    return json.loads(safe(T / name, T).read_text())


def write(name, data):
    path = safe(T / name, T)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def source_state():
    head = git('rev-parse', 'HEAD').decode().strip()
    require(head == COMMIT, f'HEAD changed: expected {COMMIT}; found {head}')
    tracked = git('status', '--porcelain=v1', '-z', '--untracked-files=no')
    entries = tracked.rstrip(b'\0').split(b'\0') if tracked else []
    require(sorted(entries) == sorted((' M ' + x).encode() for x in DIRTY),
            'tracked dirty paths/status differ from the two reviewed modifications')
    dirty_hashes = {x: digest(REPO / x) for x in DIRTY}
    require(dirty_hashes == EXPECTED_DIRTY, 'dirty source hashes differ from reviewed proposal')
    return {'head': head,
            'status': tracked.hex(),
            'config_sha256': digest(CONFIG),
            'dirty_sha256': dirty_hashes,
            'diff_sha256': hashlib.sha256(git('diff', '--binary', '--no-ext-diff',
                                             '--no-textconv', 'HEAD', '--', *DIRTY)).hexdigest()}


def secret_name(name):
    parts = PurePosixPath(name).parts
    return any(p.lower() in ('.git', '.ssh', '.aws', '.gnupg', 'credentials',
                             '.env', '.netrc') or
               re.search(r'(?i)(\.(pem|key|p12|pfx|jks|keystore)$|^id_(rsa|dsa|ecdsa|ed25519)$|'
                         r'^(signing_key|private_key)(\.|$))', p) for p in parts)


def path_name(name):
    p = PurePosixPath(name)
    require(not p.is_absolute() and all(x not in ('..', '.') for x in p.parts)
            and str(p) == name and p.parts and p.parts[0] in ROOTS,
            f'unsafe/unexpected member name: {name!r}')
    require(not secret_name(name), f'secret or uncertain key/credential member: {name}')


def tree_screen():
    # Only names/types/object IDs are read first. No archive/blob read precedes screening.
    entries = {}
    raw = git('ls-tree', '-rz', COMMIT, '--', *ROOTS)
    for entry in raw.rstrip(b'\0').split(b'\0'):
        meta, name = entry.split(b'\t', 1)
        name = name.decode('utf-8', errors='strict')
        mode, kind, oid = meta.decode().split()
        if name in EXCLUDED:
            require(kind == 'blob' and mode in ('100644', '100755'),
                    f'changed excluded private-key fixture metadata: {name}')
            continue  # Explicit omitted fixture: never read its blob/archive content.
        path_name(name)
        require(kind == 'blob' and mode in ('100644', '100755', '120000'),
                f'unsupported metadata/member: {name} {mode} {kind}')
        entries[name] = {'mode': mode, 'oid': oid}
    require(entries and all(any(n.startswith(r + '/') for n in entries) for r in ROOTS),
            'missing source roots')
    # Symlink blob contents are targets, only after every pathname passed screening.
    for name, info in entries.items():
        if info['mode'] == '120000':
            target = git('cat-file', 'blob', info['oid']).decode('utf-8', errors='strict')
            require(target and not PurePosixPath(target).is_absolute(),
                    f'absolute/empty symlink: {name}')
            normalized = os.path.normpath(str(PurePosixPath(name).parent / target))
            path_name(normalized)
            require((normalized in entries and entries[normalized]['mode'] != '120000') or
                    any(n.startswith(normalized + '/') for n in entries),
                    f'uncertain symlink target/chain: {name} -> {target}')
            require(not any(str(a) in entries and entries[str(a)]['mode'] == '120000'
                            for a in PurePosixPath(normalized).parents),
                    f'symlink target traverses a symlink ancestor: {name}')
            info['target'] = target
    return entries


def archive_paths(entries):
    # Positive path cover avoids dependence on Git archive exclude-magic support.
    # Expand only ancestors of omitted keys; include all their safe sibling trees.
    result = []
    def cover(prefix):
        if not any(n.startswith(prefix + '/') or n == prefix for n in EXCLUDED):
            result.append(prefix)
            return
        children = sorted({n[len(prefix)+1:].split('/')[0] for n in entries
                           if n.startswith(prefix + '/')})
        for child in children:
            cover(prefix + '/' + child)
    for root in ROOTS:
        cover(root)
    require(all(not any(e == p or e.startswith(p + '/') for e in EXCLUDED)
                for p in result), 'positive archive paths cover excluded key')
    return result


def job_limits(cpus, available):
    """Conservative defaults; explicit jobs may use all nproc CPUs within RAM cap."""
    require(type(cpus) is int and cpus > 0, 'nproc must be a positive integer')
    require(type(available) is int and available >= 8 * 1024**3,
            f'require >=8 GiB effective available memory; found {available} bytes')
    reserve = max(8 * 1024**3, (available + 9) // 10)
    memory_cap = (available - reserve) // (2 * 1024**3)
    require(memory_cap >= 1, 'insufficient memory after reserve for one build job')
    cpu_default = max(1, cpus * 95 // 100)
    return {'cpu_count': cpus, 'default_cpu_cap': cpu_default,
            'memory_reserve_bytes': reserve, 'memory_per_job_bytes': 2 * 1024**3,
            'memory_job_cap': memory_cap,
            'maximum_jobs': min(cpus, memory_cap),
            'default_jobs': min(cpu_default, memory_cap)}


def resources(requested_jobs=None):
    cpus = int(run(['nproc']).decode().strip())
    mem = dict(re.findall(r'^(\w+):\s+(\d+) kB$',
                          Path('/proc/meminfo').read_text(), re.M))
    available = int(mem.get('MemAvailable', '0')) * 1024
    effective = available
    cgroups = []
    # Account for cgroup v2 limits at this process and each exposed ancestor.
    root = Path('/sys/fs/cgroup')
    relative = next((line[3:] for line in Path('/proc/self/cgroup').read_text().splitlines()
                     if line.startswith('0::')), None)
    if relative is not None:
        require(relative.startswith('/') and '..' not in Path(relative).parts,
                'unsafe public cgroup path')
        leaf = root / relative.lstrip('/')
        for directory in (leaf, *leaf.parents):
            if directory != root and root not in directory.parents:
                break
            maximum, current = directory / 'memory.max', directory / 'memory.current'
            if maximum.exists():
                value = safe(maximum, root).read_text().strip()
                if value != 'max':
                    limit = int(value)
                    used = int(safe(current, root).read_text().strip())
                    remaining = max(0, limit - used)
                    effective = min(effective, remaining)
                    cgroups.append({'path': str(directory), 'limit_bytes': limit,
                                    'current_bytes': used, 'remaining_bytes': remaining})
    limits = job_limits(cpus, effective)
    jobs = limits['default_jobs'] if requested_jobs is None else requested_jobs
    require(type(jobs) is int and 1 <= jobs <= limits['maximum_jobs'],
            f'jobs {jobs!r} outside current safe range 1..{limits["maximum_jobs"]}; '
            'stop rather than changing the persisted selection')
    free = shutil.disk_usage(TOWER).free
    require(free >= 40 * 1024**3, f'require >=40 GiB free disk; found {free} bytes')
    return {'available_memory_bytes': available, 'effective_available_memory_bytes': effective,
            'cgroup_memory_limits': cgroups, 'free_disk_bytes': free,
            'jobs': jobs, 'job_policy': limits}


def parallelism(identity):
    selected = identity['jobs']
    require(selected == identity['toolchain']['jobs'], 'persisted jobs identity differs')
    resources(selected)  # Stop on reduced headroom; never silently lower concurrency.
    return f'-j{selected}'


def dependencies(requested_jobs=None):
    required = ('git', 'make', 'flex', 'bison', 'openssl', 'pahole', 'pkg-config',
                'cpio', 'depmod', 'modinfo', 'nm', 'readelf', 'zstd', 'nproc')
    missing = [x for x in required if not shutil.which(x, path=ENV['PATH'])]
    missing += [x for x in ('/usr/bin/gcc-11', '/usr/bin/ld') if not Path(x).is_file()]
    require(not missing, 'missing tools (no installation authorized): ' + ', '.join(missing))
    run(['pkg-config', '--exists', 'libelf', 'openssl', 'zlib'])
    run(['/usr/bin/gcc-11', '-fsyntax-only', '-x', 'c', '-'], input=
        b'#include <libelf.h>\n#include <gelf.h>\n#include <openssl/bio.h>\n#include <zlib.h>\n')
    return {**resources(requested_jobs),
            'gcc': run(['/usr/bin/gcc-11', '--version']).decode(),
            'ld': run(['/usr/bin/ld', '--version']).decode(),
            'gcc_sha256': digest(Path('/usr/bin/gcc-11').resolve()),
            'ld_sha256': digest(Path('/usr/bin/ld').resolve()),
            'host': run(['hostname']).decode().strip(),
            'uname': run(['uname', '-srmo']).decode().strip()}


def config_gate(path):
    text = safe(path).read_text()
    values = dict(re.findall(r'^(CONFIG_\w+)=(.*)$', text, re.M))
    require(values.get('CONFIG_MODULE_SIG_KEY') == '"certs/signing_key.pem"',
            'signing key must be new default output key; no existing/custom key reads')
    for name in ('CONFIG_SYSTEM_TRUSTED_KEYS', 'CONFIG_SYSTEM_REVOCATION_KEYS'):
        require(values.get(name, '""') == '""', f'certificate input requires review: {name}')
    require(values.get('CONFIG_MODULE_SIG_ALL') == 'y', 'require CONFIG_MODULE_SIG_ALL=y')
    require(values.get('CONFIG_MODULE_SIG') == 'y', 'require CONFIG_MODULE_SIG=y')
    require(values.get('CONFIG_MODVERSIONS') != 'y', 'MODVERSIONS differs from reviewed design')


def kb(*args, capture=False):
    safe(S / 'famfs-linux', T)
    safe(O, T)
    safe(E, T)
    return run(['make', '-C', S / 'famfs-linux', f'O={O}', 'ARCH=x86_64',
                'CC=/usr/bin/gcc-11', 'LD=/usr/bin/ld', 'LOCALVERSION=-p3a', *args], capture)


def snapshot_hashes():
    entries = load('tree.json')
    return {n: digest(S / n) if v['mode'] != '120000' else
            hashlib.sha256(os.readlink(S / n).encode()).hexdigest() for n, v in entries.items()}


def workspace():
    safe(T, TOWER)
    identity = load('identity.json')
    require(identity['commit'] == COMMIT and identity['workspace'] == str(T), 'stale workspace identity')
    require(identity['prepared'], 'prepare did not finish; retain workspace for inspection')
    require(source_state() == identity['original'], 'original HEAD/status/config/dirty hashes changed')
    require(snapshot_hashes() == load('source-hashes.json'), 'snapshot source identity changed')
    for p in (O, E, T / 'modules'):
        safe(p, T)
    return identity


def prepare(requested_jobs=None):
    safe(T, TOWER)
    require(not os.path.lexists(T), f'workspace already exists: {T}; do not remove/clean automatically')
    safe(REPO)
    original = source_state()
    require(original['config_sha256'] == EXPECTED_CONFIG, 'config differs from reviewed hash')
    config_gate(CONFIG)
    entries = tree_screen()
    T.mkdir(parents=True, mode=0o700)
    save('identity.json', {'commit': COMMIT, 'workspace': str(T), 'prepared': False,
                           'original': original, 'toolchain': {},
                           'omitted': {n: 'tracked private-key selftest fixture; not read' for n in EXCLUDED},
                           'archive_positive_paths': archive_paths(entries)})
    safe(T / 'tmp', T).mkdir()
    tools = dependencies(requested_jobs)
    identity = load('identity.json')
    identity['toolchain'] = tools
    identity['jobs'] = tools['jobs']
    save('identity.json', identity)
    save('tree.json', entries)
    write('original-dirty.patch', git('diff', '--binary', '--no-ext-diff', '--no-textconv',
                                      'HEAD', '--', *DIRTY))
    for p in (S, O, E, T / 'modules'):
        safe(p, T).mkdir()
    # Complete name/type/link screening above precedes any archive blob reads.
    archive = safe(T / 'snapshot.tar', T)
    with archive.open('wb') as out:
        result = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-C', str(REPO),
                                 'archive', '--format=tar', COMMIT, *archive_paths(entries)], env=ENV, stdout=out)
    require(result.returncode == 0, 'git archive failed')
    seen = set()
    with tarfile.open(archive) as tar:
        for member in tar:
            name = member.name.rstrip('/')
            path_name(name)
            if member.isdir():
                require(any(n.startswith(name + '/') for n in entries), f'unexpected directory: {name}')
                continue
            require(name in entries and name not in seen, f'unknown/duplicate archive member: {name}')
            info = entries[name]
            require((member.issym() and info['mode'] == '120000' and member.linkname == info['target'])
                    or (member.isfile() and info['mode'] != '120000'), f'archive type/target mismatch: {name}')
            seen.add(name)
        require(seen == set(entries), 'archive omitted screened source entries')
    # Write files manually; install screened links last to prevent traversal.
    with tarfile.open(archive) as tar:
        for member in tar:
            if not member.isfile():
                continue
            destination = safe(S / member.name, T)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as src, destination.open('xb') as dst:
                shutil.copyfileobj(src, dst)
            destination.chmod(0o755 if entries[member.name]['mode'] == '100755' else 0o644)
    for name, info in entries.items():
        if info['mode'] == '120000':
            destination = safe(S / name, T)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(info['target'])
    for name in DIRTY:
        shutil.copyfile(safe(REPO / name), safe(S / name, T))
    shutil.copyfile(safe(CONFIG), safe(O / '.config', T))
    require(source_state() == original, 'original changed during snapshot')
    save('source-hashes.json', snapshot_hashes())
    write('config.before', (O / '.config').read_bytes())
    identity = load('identity.json')
    identity['prepared'] = True
    save('identity.json', identity)
    print(f'Prepared {T}; no build performed. Archive retained for failure/provenance review.')


def timed(label, function):
    start = time.monotonic()
    function()
    duration = time.monotonic() - start
    record = load('timings.json') if (T / 'timings.json').exists() else []
    record.append({'step': label, 'seconds': duration})
    save('timings.json', record)


def stage():
    kr = kb('-s', 'kernelrelease', capture=True).decode().strip()
    require(kr and '/' not in kr and '\n' not in kr and kr.endswith('-p3a'), f'unsafe/unexpected release: {kr}')
    number = 1
    while os.path.lexists(T / f'modules/build-{number:04d}'):
        number += 1
    destination = safe(T / f'modules/build-{number:04d}', T)
    destination.mkdir()
    kb(f'INSTALL_MOD_PATH={destination}', 'modules_install')
    kb(f'M={S / "msg_layer_module"}', f'MO={E}',
       f'CONFIG_MODULE_SIG_KEY={O / "certs/signing_key.pem"}',
       f'INSTALL_MOD_PATH={destination}', 'modules_install')
    run(['depmod', '-b', destination, '-F', O / 'System.map', kr], capture=False)
    save('latest-stage.json', {'release': kr, 'path': str(destination), 'verified': False})


def build():
    identity = workspace()
    current_tools = dependencies(identity['jobs'])
    for key in ('gcc_sha256', 'ld_sha256'):
        require(identity['toolchain'][key] == current_tools[key], f'toolchain changed: {key}')
    expected_config = T / ('config.after' if (T / 'config.after').exists() else 'config.before')
    require(digest(O / '.config') == digest(expected_config), 'workspace config changed outside recorded build')
    config_gate(O / '.config')
    timed('olddefconfig', lambda: kb('olddefconfig'))
    config_gate(O / '.config')
    before = (T / 'config.before').read_text()
    after = (O / '.config').read_text()
    write('config.after', after.encode())
    write('config.diff', ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                                   fromfile='config.before', tofile='config.after')).encode())
    # Default key is generated only by this later authorized build in O/certs.
    timed('kernel-modules', lambda: kb(parallelism(identity), 'bzImage', 'modules'))
    timed('external-module', lambda: kb(parallelism(identity), f'M={S / "msg_layer_module"}', f'MO={E}', 'modules'))
    timed('stage', stage)
    require(source_state() == identity['original'], 'original identity changed during build')


def module_bytes(path):
    safe(path, T)
    data = path.read_bytes()
    if path.suffix == '.xz':
        return lzma.decompress(data)
    if path.suffix == '.gz':
        return gzip.decompress(data)
    if path.suffix == '.zst':
        return run(['zstd', '-d', '-q', '-c', path])
    require(path.suffix == '.ko', f'unknown module compression: {path}')
    return data


def verify():
    identity = workspace()
    latest = load('latest-stage.json')
    destination = safe(Path(latest['path']), T / 'modules')
    kr = latest['release']
    require(kb('-s', 'kernelrelease', capture=True).decode().strip() == kr, 'kernel release changed')
    artifacts = [O / x for x in ('vmlinux', 'arch/x86/boot/bzImage', 'System.map', 'Module.symvers', '.config')]
    artifacts += [E / 'Module.symvers', E / 'cxl_shm.ko']
    vmlinux_header = run(['readelf', '-h', safe(O / 'vmlinux', T)]).decode()
    require('ELF64' in vmlinux_header and 'Advanced Micro Devices X86-64' in vmlinux_header,
            'vmlinux architecture mismatch')
    image = safe(O / 'arch/x86/boot/bzImage', T).read_bytes()
    require(len(image) > 4096 and image[0x1fe:0x200] == b'\x55\xaa' and
            image[0x202:0x206] == b'HdrS' and
            int.from_bytes(image[0x206:0x208], 'little') >= 0x20c and
            int.from_bytes(image[0x236:0x238], 'little') & 1,
            'bzImage boot protocol/x86_64 header invalid')
    version_offset = 0x200 + int.from_bytes(image[0x20e:0x210], 'little')
    image_version = image[version_offset:version_offset+512].split(b'\0', 1)[0].decode('ascii')
    require(image_version.startswith(kr + ' '), f'bzImage release mismatch: {image_version}')
    exports = {}
    for symvers in (O / 'Module.symvers', E / 'Module.symvers'):
        for line in safe(symvers, T).read_text().splitlines():
            fields = line.split()
            require(len(fields) >= 4, f'malformed symvers: {symvers}')
            exports[fields[1]] = fields[2]
    certificate = safe(O / 'certs/signing_key.x509', T)
    public_pem = safe(T / 'verification/build-cert.pem', T)
    public_pem.parent.mkdir(parents=True, exist_ok=True)
    run(['openssl', 'x509', '-inform', 'DER', '-in', certificate, '-out', public_pem])
    fingerprint = run(['openssl', 'x509', '-in', public_pem, '-noout', '-fingerprint', '-sha256']).decode().strip()
    key = safe(O / 'certs/signing_key.pem', T)
    require(stat.S_IMODE(key.stat().st_mode) & 0o077 == 0, 'new signing key permissions are too broad')
    modules = sorted(destination.glob(f'lib/modules/{kr}/**/*.ko*'))
    require(modules, 'stage contains no modules')
    records, names = [], set()
    magic = b'~Module signature appended~\n'
    for index, module in enumerate(modules):
        data = module_bytes(module)
        require(data.endswith(magic) and len(data) > len(magic) + 12, f'missing signature: {module}')
        trailer = data[-len(magic)-12:-len(magic)]
        length = int.from_bytes(trailer[8:12], 'big')
        require(trailer[2] == 2 and trailer[3:8] == b'\0' * 5 and
                0 < length < len(data) - len(magic) - 12, f'malformed PKCS7 trailer: {module}')
        unsigned = data[:-len(magic)-12-length]
        signature = data[-len(magic)-12-length:-len(magic)-12]
        unsigned_path = safe(T / 'verification/module.unsigned', T)
        signature_path = safe(T / 'verification/module.p7s', T)
        unsigned_path.write_bytes(unsigned)
        signature_path.write_bytes(signature)
        run(['openssl', 'cms', '-verify', '-binary', '-inform', 'DER', '-in', signature_path,
             '-content', unsigned_path, '-certfile', public_pem, '-nointern', '-noverify',
             '-out', os.devnull])
        header = run(['readelf', '-h', unsigned_path]).decode()
        require('ELF64' in header and 'Advanced Micro Devices X86-64' in header,
                f'module architecture mismatch: {module}')
        fields = {field: run(['modinfo', '-F', field, module]).decode().strip()
                  for field in ('name', 'vermagic', 'depends')}
        require(fields['vermagic'].split()[0] == kr, f'vermagic release mismatch: {module}')
        undefined = run(['nm', '-u', unsigned_path]).decode().splitlines()
        imports = [line.split()[-1] for line in undefined if line.split()[-2:-1] == ['U']]
        missing = sorted(set(imports) - set(exports) - {'_GLOBAL_OFFSET_TABLE_'})
        require(not missing, f'imports missing exact build exports: {module}: {missing}')
        names.add(fields['name'].replace('-', '_'))
        records.append({'path': str(module.relative_to(T)), 'sha256': digest(module), **fields})
    for record in records:
        absent = [x for x in record['depends'].split(',') if x and x.replace('-', '_') not in names]
        require(not absent, f'missing staged dependencies: {record["path"]}: {absent}')
    require(len({x['vermagic'] for x in records}) == 1, 'module vermagic flags differ within exact build')
    require(any(x['name'] == 'cxl_shm' for x in records), 'external cxl_shm missing from stage')
    artifacts += [certificate, destination / f'lib/modules/{kr}/modules.dep',
                  destination / f'lib/modules/{kr}/modules.dep.bin']
    manifest = {'commit': COMMIT, 'original': identity['original'], 'toolchain': identity['toolchain'],
                'source_hashes_file': 'source-hashes.json', 'config_before_sha256': digest(T / 'config.before'),
                'config_after_sha256': digest(O / '.config'), 'release': kr, 'stage': str(destination),
                'public_certificate_fingerprint': fingerprint,
                'vmlinux_elf_header': vmlinux_header, 'bzImage_version': image_version,
                'omitted': identity['omitted'],
                'artifacts': {str(p.relative_to(T)): digest(p) for p in artifacts}, 'modules': records,
                'limits': ['guest key trust unproven', 'MODVERSIONS disabled', 'no runtime/module load tested']}
    save(f'manifests/{destination.name}.json', manifest)
    latest['verified'] = True
    save('latest-stage.json', latest)
    require(source_state() == identity['original'], 'original changed during verification')
    print(f'Verified {len(records)} staged modules and artifacts; manifest for {destination.name}.')


def object_times():
    return {str(p.relative_to(T)): p.stat().st_mtime_ns for root in (O, E) for p in root.rglob('*.o')}


def incremental():
    identity = workspace()
    current_tools = dependencies(identity['jobs'])
    for key in ('gcc_sha256', 'ld_sha256'):
        require(identity['toolchain'][key] == current_tools[key], f'toolchain changed: {key}')
    latest = load('latest-stage.json')
    require(latest['verified'], 'verify initial build before incremental experiment')
    before = object_times()
    def rebuild():
        kb(parallelism(identity), 'bzImage', 'modules')
        kb(parallelism(identity), f'M={S / "msg_layer_module"}', f'MO={E}', 'modules')
    timed('incremental-noop', rebuild)
    after = object_times()
    # Kbuild regenerates the timestamp object even without source changes.
    changed = sorted(n for n in set(before) | set(after) if before.get(n) != after.get(n))
    require(all(n == 'build/init/version-timestamp.o' or n == 'build/vmlinux.o'
                or (n.startswith('build/.vmlinux') and '/' not in n[6:]) for n in changed),
            f'no-op rebuilt unexpected object files: {changed[:20]}')
    selected = safe(S / 'famfs-linux/init/main.c', T)
    obj = safe(O / 'init/main.o', T)
    require(selected.is_file() and obj.is_file(), 'mtime probe requires init/main.c and init/main.o')
    content = digest(selected)
    old_object_time = obj.stat().st_mtime_ns
    stamp = max(time.time_ns(), old_object_time + 2_000_000_000)
    os.utime(selected, ns=(stamp, stamp))
    timed('incremental-mtime', rebuild)
    require(obj.stat().st_mtime_ns > old_object_time, 'mtime-only source probe did not recompile init/main.o')
    require(digest(selected) == content and snapshot_hashes() == load('source-hashes.json'),
            'mtime probe changed source content')
    timed('incremental-stage', stage)
    save('incremental.json', {'no_op_changed_objects': changed, 'source': str(selected),
                             'content_sha256': content, 'object_recompiled': True,
                             'scope': 'mtime-only staged source; no behavior/content-edit claim'})
    require(source_state() == identity['original'], 'original changed during incremental verification')
    print('Incremental checks passed; fresh stage requires verify action.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'build', 'verify', 'incremental'))
    parser.add_argument('--authorized-p3b-workspace', action='store_true',
                        help='acknowledge previously recorded explicit grant; not an authorization source')
    parser.add_argument('--jobs', type=int,
                        help='prepare only: positive jobs bounded by nproc and memory; persisted for all builds')
    args = parser.parse_args()
    require(args.jobs is None or args.action == 'prepare', '--jobs is configurable only during prepare')
    require(args.jobs is None or args.jobs > 0, '--jobs must be positive')
    require(args.authorized_p3b_workspace, 'stop: recorded explicit P3b workspace authorization required')
    os.umask(0o077)
    try:
        if args.action == 'prepare':
            prepare(args.jobs)
        else:
            globals()[args.action]()
    except Exception as exc:
        if os.path.lexists(T):
            safe(T, TOWER)
            save(f'failures/{args.action}-{time.time_ns()}.json',
                 {'action': args.action, 'error': str(exc), 'workspace_retained': True})
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'STOP: {exc}', flush=True)
        raise SystemExit(1)
