#!/usr/bin/env python3
"""Generate libvirt domain XMLs for an N-node topology on host socket 0 (reports/VM8-topology-packet.md).

Pure generator: reads a base inactive domain XML, writes one XML per node into --out. Never calls virsh.

Topology rule (user 2026-10-15): all VMs on socket 0 (NUMA node0: cores 0-15, HT siblings c and c+32);
the 16 cores are split evenly, node i gets cores [i*16/N, (i+1)*16/N) with both HT threads, so 32/N vCPUs.
RAM per VM is fixed (default 24 GiB) whatever N; the shared NVDIMM (/dev/dax1.0, 96 GiB) is kept unchanged.
QEMU emulator threads are pinned to socket 1 (NUMA node1) so they never run on a vCPU's core.

usage: vm-topology.py --base cxl_vm0.inactive.xml --nodes 8 --out DIR
                      [--ram-gib 24] [--disk-tmpl /var/lib/libvirt/images/cxl_vm{i}.qcow2]
                      [--existing IDX=XML ...]  (existing domain i: start from its own inactive XML and keep
                                                 its name, uuid, MAC, disk and kernel; only CPUs/RAM change)
"""
import argparse, copy, os, sys
import xml.etree.ElementTree as ET

ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")

CORES, HT_OFF = 16, 32
EMULATOR_CPUS = "16-31,48-63"
KIB = 1024 * 1024  # KiB per GiB


def cpus_for(i, n):
    per = CORES // n
    cores = range(i * per, (i + 1) * per)
    return [c for c in cores] + [c + HT_OFF for c in cores]


def mac_for(i):
    return f"52:54:00:c8:00:{i:02x}"


# CLAUDE.md: every NVDIMM field must be preserved (Host /dev/dax1.0, 96 GiB, node0, 4 KiB align, 16 MiB label, slot 1)
NVDIMM_EXPECT = {
    "./source/path": "/dev/dax1.0", "./source/alignsize": "4", "./target/size": "100663296",
    "./target/node": "0", "./target/label/size": "16384",
}


def check_nvdimm(d):
    nvs = d.findall("./devices/memory[@model='nvdimm']")
    if len(nvs) != 1:
        sys.exit("expected exactly one nvdimm <memory>")
    nv = nvs[0]
    if nv.get("access") != "shared" or nv.find("./source/pmem") is None:
        sys.exit("nvdimm must be access='shared' with <pmem/>")
    for path, want in NVDIMM_EXPECT.items():
        e = nv.find(path)
        if e is None or (e.text or "").strip() != want:
            sys.exit(f"nvdimm {path} = {None if e is None else e.text!r}, expected {want}")
    slot = nv.find("./address")
    if slot is not None and slot.get("slot") not in ("0x1", "1"):
        sys.exit(f"nvdimm slot {slot.get('slot')}, expected 1")


def build(base, i, n, ram_gib, disk, name, mac, keep_uuid):
    d = copy.deepcopy(base)
    d.find("name").text = name
    u = d.find("uuid")
    if u is not None and not keep_uuid:
        d.remove(u)
    nv = d.find("./devices/memory[@model='nvdimm']/target/size")
    if nv is None or nv.get("unit") != "KiB":
        sys.exit("base XML has no nvdimm <memory> with a KiB size")
    check_nvdimm(d)
    ram_kib, nv_kib = ram_gib * KIB, int(nv.text)
    for tag in ("memory", "currentMemory"):
        e = d.find(tag)
        e.set("unit", "KiB")
        e.text = str(ram_kib + nv_kib)
    mm = d.find("maxMemory")
    if mm is not None and int(mm.text) < ram_kib + nv_kib:
        sys.exit("maxMemory smaller than RAM + nvdimm")
    cpus = cpus_for(i, n)
    d.find("vcpu").text = str(len(cpus))
    ct = d.find("cputune")
    for e in list(ct):
        if e.tag in ("vcpupin", "emulatorpin"):
            ct.remove(e)
    for v, c in enumerate(cpus):
        ET.SubElement(ct, "vcpupin", vcpu=str(v), cpuset=str(c))
    ET.SubElement(ct, "emulatorpin", cpuset=EMULATOR_CPUS)
    cell = d.find("./cpu/numa/cell")
    cell.set("cpus", f"0-{len(cpus) - 1}")
    cell.set("memory", str(ram_kib))
    cell.set("unit", "KiB")
    nt = d.find("./numatune/memory")
    if nt is None or nt.get("mode") != "strict" or nt.get("nodeset") != "0":
        sys.exit("base XML must have numatune memory strict nodeset 0")
    disks = d.findall("./devices/disk[@device='disk']")
    if len(disks) != 1:
        sys.exit("base XML must have exactly one disk")
    disks[0].find("source").set("file", disk)
    ifs = d.findall("./devices/interface")
    if len(ifs) != 1:
        sys.exit("base XML must have exactly one interface")
    ifs[0].find("mac").set("address", mac)
    return d, cpus


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--nodes", type=int, required=True, choices=[2, 4, 8])
    ap.add_argument("--out", required=True)
    ap.add_argument("--ram-gib", type=int, default=24)
    ap.add_argument("--disk-tmpl", default="/var/lib/libvirt/images/cxl_vm{i}.qcow2")
    ap.add_argument("--existing", action="append", default=[], help="IDX=inactive XML of an existing domain")
    a = ap.parse_args()
    base = ET.parse(a.base).getroot()
    existing = {}
    for k in a.existing:
        idx, path = k.split("=", 1)
        existing[int(idx)] = ET.parse(path).getroot()
    os.makedirs(a.out, exist_ok=True)
    for i in range(a.nodes):
        if i in existing:
            src = existing[i]
            name = src.find("name").text
            mac = src.find("./devices/interface/mac").get("address")
            disk = src.find("./devices/disk[@device='disk']/source").get("file")
            if src.find("uuid") is None:
                sys.exit(f"{name}: existing domain XML has no uuid")
            d, cpus = build(src, i, a.nodes, a.ram_gib, disk, name, mac, keep_uuid=True)
        else:
            name, mac, disk = f"cxl_vm{i}", mac_for(i), a.disk_tmpl.format(i=i)
            d, cpus = build(base, i, a.nodes, a.ram_gib, disk, name, mac, keep_uuid=False)
        path = os.path.join(a.out, f"{name}.xml")
        ET.ElementTree(d).write(path)
        print(f"{name} mac={mac} disk={disk} vcpus={len(cpus)} cpus={','.join(map(str, cpus))} "
              f"ram={a.ram_gib}GiB -> {path}")


if __name__ == "__main__":
    main()
