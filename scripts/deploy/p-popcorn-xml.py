#!/usr/bin/env python3
"""Derive direct-boot candidate domain XMLs for a kernel variant (Popcorn).

usage: p-popcorn-xml.py <current-inactive.xml> <images-dir> <release> <outdir>

Writes <outdir>/rollback-inactive.xml (byte copy of the input),
candidate-normal.xml and candidate-restricted.xml (= normal + init=/bin/sh).
Only the three <os> lines <kernel>, <initrd>, <cmdline> change; every other
byte (memory, vCPUs, NUMA, every NVDIMM field) stays identical, which the
script checks with a line diff. The cmdline keeps root=/ro/console from the
current one and drops parameters of other variants (page_replication_ext is
De Stijl's; this tree does not parse it).
"""
import difflib, pathlib, re, sys

src, images, release, out = sys.argv[1:5]
text = pathlib.Path(src).read_text()
if not re.fullmatch(r'/var/lib/libvirt/images/[A-Za-z0-9._-]+', images):
    raise SystemExit('images dir must be a new dir directly under /var/lib/libvirt/images')
if not re.fullmatch(r'6\.14\.0-[A-Za-z0-9.+-]+', release):
    raise SystemExit('unexpected release string')


def one(pattern):
    m = re.findall(pattern, text)
    if len(m) != 1:
        raise SystemExit(f'expected exactly one match for {pattern}, got {len(m)}')
    return m[0]


old_kernel = one(r'    <kernel>[^<]*</kernel>\n')
old_initrd = one(r'    <initrd>[^<]*</initrd>\n')
old_cmdline = one(r'    <cmdline>[^<]*</cmdline>\n')
args = re.search(r'<cmdline>([^<]*)</cmdline>', old_cmdline).group(1).split()
keep = [a for a in args if a.split('=')[0] in ('root', 'ro', 'console')]
if not any(a.startswith('root=') for a in keep) or 'ro' not in keep:
    raise SystemExit('current cmdline lacks root= or ro')
cmdline = ' '.join(keep)

normal = (text.replace(old_kernel, f'    <kernel>{images}/bzImage</kernel>\n')
              .replace(old_initrd, f'    <initrd>{images}/initrd.img-{release}</initrd>\n')
              .replace(old_cmdline, f'    <cmdline>{cmdline}</cmdline>\n'))
restricted = normal.replace(f'<cmdline>{cmdline}</cmdline>', f'<cmdline>{cmdline} init=/bin/sh</cmdline>')

for name, cand in (('candidate-normal.xml', normal), ('candidate-restricted.xml', restricted)):
    changed = [l for l in difflib.ndiff(text.splitlines(), cand.splitlines()) if l[:1] in '+-']
    tags = sorted({re.search(r'<(kernel|initrd|cmdline)>', l).group(1) for l in changed
                   if re.search(r'<(kernel|initrd|cmdline)>', l)})
    if len(changed) != 6 or tags != ['cmdline', 'initrd', 'kernel']:
        raise SystemExit(f'{name}: unexpected diff {changed}')

o = pathlib.Path(out)
o.mkdir(parents=True, exist_ok=False)
(o / 'rollback-inactive.xml').write_text(text)
(o / 'candidate-normal.xml').write_text(normal)
(o / 'candidate-restricted.xml').write_text(restricted)
print(f'{o}: kernel {images}/bzImage, initrd {images}/initrd.img-{release}, cmdline "{cmdline}"')
