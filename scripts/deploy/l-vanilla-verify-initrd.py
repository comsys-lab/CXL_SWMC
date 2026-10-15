"""Stream newc initramfs records; never extract archive members."""
import gzip, hashlib, io, json, pathlib, stat, sys

image = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
release = manifest['release']
blocked = ('cxl_shm', 'nfit', 'libnvdimm', 'nd_pmem', 'nd_btt', 'dax_pmem')
configs = []; modules = []; names = set()
def take(f, n):
    data = f.read(n)
    if len(data) != n:
        raise RuntimeError('truncated cpio')
    return data
def cpio(f):
    while True:
        header = take(f, 110)
        if header[:6] not in (b'070701', b'070702'):
            raise RuntimeError('unsupported cpio format')
        fields = [int(header[6+i*8:14+i*8],16) for i in range(13)]
        mode, size, nsize = fields[1], fields[6], fields[11]
        if not 1 <= nsize <= 4096:
            raise RuntimeError('unsafe cpio name length')
        name = take(f,nsize).rstrip(b'\0').decode()
        take(f, (-(110+nsize)) % 4)
        if name == 'TRAILER!!!':
            take(f,size); take(f,(-size)%4); return
        name = name.removeprefix('./')
        parts = pathlib.PurePosixPath(name).parts
        if name.startswith('/') or '..' in parts:
            raise RuntimeError('unsafe member path')
        forbidden_parts = {'.ssh','.aws','.gnupg','.netrc','.env','credentials','secrets','keyfile','keyfiles'}
        private_names = {'id_rsa','id_dsa','id_ecdsa','id_ed25519','signing_key.pem','enclave_private.pem'}
        if name.endswith(('.pem','.key','.env')) or any(p in forbidden_parts for p in parts) or pathlib.PurePosixPath(name).name in private_names or 'cryptroot/keyfiles' in name:
            raise RuntimeError('unexpected secret-like member; not read')
        if name in names and stat.S_ISREG(mode):
            raise RuntimeError('duplicate regular member')
        names.add(name)
        if '.ko.' in name:
            raise RuntimeError('unexpected compressed module')
        if 'modules' in parts:
            index = parts.index('modules')
            if index > 0 and parts[index-1] == 'lib' and len(parts) > index+1 and parts[index+1] != release:
                raise RuntimeError('foreign release path')
        ismodule = name.endswith('.ko')
        isconfig = '/modprobe.d/' in name and stat.S_ISREG(mode)
        if ismodule:
            relative = None
            for prefix in ('lib/modules/'+release+'/', 'usr/lib/modules/'+release+'/'):
                if name.startswith(prefix): relative = name[len(prefix):]
            if relative is None or relative not in manifest['modules']:
                raise RuntimeError('foreign/unknown module')
            if pathlib.PurePosixPath(name).stem.replace('-','_') in blocked:
                raise RuntimeError('shared driver included')
            h = hashlib.sha256()
        if isconfig:
            raise RuntimeError('unexpected modprobe configuration')
        config = bytearray()
        remaining = size
        while remaining:
            data = take(f, min(1048576,remaining)); remaining -= len(data)
            if ismodule: h.update(data)
            if isconfig: config.extend(data)
        take(f, (-size)%4)
        if ismodule:
            if h.hexdigest() != manifest['modules'][relative]: raise RuntimeError('module hash mismatch')
            modules.append(relative)
with image.open('rb') as f:
    # Optional uncompressed early microcode archives, then a gzip main archive.
    while True:
        while True:
            at = f.tell(); byte = f.read(1)
            if byte != b'\0': f.seek(at); break
        magic = f.read(6); f.seek(at)
        if magic[:2] == b'\x1f\x8b':
            with gzip.GzipFile(fileobj=f) as compressed:
                cpio(compressed)
                for data in iter(lambda: compressed.read(1048576),b''):
                    if data.strip(b'\0'): raise RuntimeError('extra archive or trailing payload')
            break
        if magic in (b'070701',b'070702'): cpio(f)
        else: raise RuntimeError('missing gzip main archive')
if 'kernel/drivers/block/virtio_blk.ko' not in modules:
    raise RuntimeError('virtio root module missing')
if not {'init','scripts/local'}.issubset(names):
    raise RuntimeError('root initramfs scripts missing')
print('initrd PASS: compatible signed modules, virtio root support, no modprobe configuration, no shared-memory drivers in initramfs')
