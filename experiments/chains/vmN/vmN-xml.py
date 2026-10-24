#!/usr/bin/env python3
"""Generate the N-VM domain XMLs for the H3 fixed-total topology (32 vCPUs / 192 GiB split over N VMs; user decision
2026-10-20, state/PROJECT.md). Pure generator, never calls virsh. Generalised from workspaces/vm8/vm8-xml.py (G-VM8 v2,
evidence-pinned, unchanged); with --n 8 --vcpus 4 --ram-gib 24 the output is byte-identical to vm8-xml.py's.

Inputs: the saved inactive XMLs of cxl_vm0 and cxl_vm1 (before the switch). Output: cxl_vm0..cxl_vm<N-1>.xml,
ids.txt (name uuid mac ip disk cpus emulator machine-id) in --out.
Rules:
  - N in {4, 8}; vCPUs per VM V = 32 / N, RAM per VM R = 192 / N GiB (fixed total; N = 2 uses the original XMLs);
  - every VM: V vCPUs = V/2 whole host cores of node0; vm i gets cores (V/2)*i .. (V/2)*i + V/2 - 1, each with its
    HT sibling (+32); guest topology sockets=1 dies=1 cores=V/2 threads=2; pins in sibling order
    [c, c+32, c+1, c+33, ...] (vCPU 2k and 2k+1 share a host core, as in the live 16-vCPU XMLs);
      N=8: vm i -> cores 2i, 2i+1          N=4: vm i -> cores 4i .. 4i+3
  - RAM R GiB strict on node0 (numatune unchanged), NUMA cell 0-(V-1) / R GiB; memory = currentMemory = RAM + NVDIMM;
  - emulator threads: even i -> 16,48, odd i -> 17,49 (VM8 rule, HOST-measure-part partition unchanged; N=4 puts
    two VMs on each emulator/vhost core pair, N=8 four: stated paper limitation);
  - NVDIMM element byte-identical to the base (asserted: /dev/dax1.0, shared, pmem, 4 KiB align, 96 GiB, node 0,
    16 MiB label, slot 1);
  - disk = qcow2 overlay <overlay-dir>/cxl_vm<i>.qcow2 (backing: frozen /var/lib/libvirt/images/cxl_vm0.qcow2);
  - kernel/initrd = cxl_vm0's (the overlays carry vm0's root fs, so vm0's initrd matches); cmdline = vm0's;
  - cxl_vm0 and cxl_vm1 keep name, uuid, MAC; cxl_vm2.. = vm0's XML with new name, uuid, MAC 52:54:00:c8:00:<i>.
usage: vmN-xml.py --n N --vcpus V --ram-gib R --vm0 before/cxl_vm0.inactive.xml --vm1 before/cxl_vm1.inactive.xml
                  --overlay-dir DIR --out OUT [--ids-from OLD/ids.txt]
       --ids-from reuses uuid + machine-id per domain name of an earlier generation (rows of domains >= N ignored),
       e.g. recovery/VM8-v2.2/topo8/ids.txt for N=4 keeps the cxl_vm2/cxl_vm3 identities (DHCP client ids).
"""
import argparse, copy, os, sys, uuid
import xml.etree.ElementTree as ET

ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
TOTAL_VCPUS, TOTAL_GIB, HOST_SIBLING = 32, 192, 32
NV_KIB = 100663296
BASE_DISK = "/var/lib/libvirt/images/cxl_vm0.qcow2"
NVDIMM_EXPECT = {"./source/path": "/dev/dax1.0", "./source/alignsize": "4", "./target/size": str(NV_KIB),
                 "./target/node": "0", "./target/label/size": "16384"}


def die(m):
    sys.exit("VMNXML FAIL: " + m)


def cpus_for(i, vcpus):
    cores = vcpus // 2
    out = []
    for c in range(cores * i, cores * i + cores):
        out += [c, c + HOST_SIBLING]
    return out


def emu_for(i):
    return "16,48" if i % 2 == 0 else "17,49"


def nvdimm(d):
    nvs = d.findall("./devices/memory[@model='nvdimm']")
    if len(nvs) != 1:
        die("expected exactly one nvdimm")
    nv = nvs[0]
    if nv.get("access") != "shared" or nv.find("./source/pmem") is None:
        die("nvdimm must be access=shared with <pmem/>")
    for p, want in NVDIMM_EXPECT.items():
        e = nv.find(p)
        if e is None or (e.text or "").strip() != want:
            die(f"nvdimm {p}={None if e is None else e.text!r}, want {want}")
    a = nv.find("./address")
    if a is None or a.get("type") != "dimm" or a.get("slot") not in ("1", "0x1"):
        die("nvdimm address must be dimm slot 1")
    return ET.tostring(nv)


def build(base, i, name, uid, mac, disk, k0, vcpus, ram_kib):
    d = copy.deepcopy(base)
    nv_before = nvdimm(d)
    d.find("name").text = name
    d.find("uuid").text = uid
    for tag in ("memory", "currentMemory"):
        e = d.find(tag)
        e.set("unit", "KiB")
        e.text = str(ram_kib + NV_KIB)
    mm = d.find("maxMemory")
    if mm is None or int(mm.text) < ram_kib + NV_KIB:
        die("maxMemory missing or too small")
    cpus = cpus_for(i, vcpus)
    v = d.find("vcpu")
    if v.get("placement") != "static":
        die("vcpu placement must be static")
    v.text = str(vcpus)
    ct = d.find("cputune")
    for e in list(ct):
        if e.tag in ("vcpupin", "emulatorpin"):
            ct.remove(e)
        else:
            die(f"unexpected cputune child {e.tag}")
    for n, c in enumerate(cpus):
        ET.SubElement(ct, "vcpupin", vcpu=str(n), cpuset=str(c))
    ET.SubElement(ct, "emulatorpin", cpuset=emu_for(i))
    nt = d.find("./numatune/memory")
    if nt is None or nt.get("mode") != "strict" or nt.get("nodeset") != "0":
        die("numatune must be strict nodeset 0")
    topo = d.find("./cpu/topology")
    if topo is None:
        die("base has no cpu/topology")
    for k, val in (("sockets", "1"), ("dies", "1"), ("cores", str(vcpus // 2)), ("threads", "2")):
        topo.set(k, val)
    cells = d.findall("./cpu/numa/cell")
    if len(cells) != 1:
        die("expected one numa cell")
    cells[0].set("cpus", f"0-{vcpus - 1}")
    cells[0].set("memory", str(ram_kib))
    cells[0].set("unit", "KiB")
    os_ = d.find("os")
    os_.find("kernel").text = k0["kernel"]
    os_.find("initrd").text = k0["initrd"]
    os_.find("cmdline").text = k0["cmdline"]
    disks = d.findall("./devices/disk[@device='disk']")
    if len(disks) != 1:
        die("expected one disk")
    src = disks[0].find("source")
    if disks[0].find("driver").get("type") != "qcow2":
        die("disk driver must be qcow2")
    src.set("file", disk)
    ifs = d.findall("./devices/interface")
    if len(ifs) != 1 or ifs[0].find("./source").get("network") != "default":
        die("expected one interface on network default")
    if ifs[0].find("./address").get("bus") != "0x01" or ifs[0].find("./address").get("slot") != "0x00":
        die("interface must stay at PCI 01:00.0 (guest name enp1s0)")
    ifs[0].find("mac").set("address", mac)
    if ET.tostring(d.find("./devices/memory[@model='nvdimm']")) != nv_before:
        die("nvdimm changed")
    nvdimm(d)
    return d, cpus


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--vcpus", type=int, required=True)
    ap.add_argument("--ram-gib", type=int, required=True)
    ap.add_argument("--vm0", required=True)
    ap.add_argument("--vm1", required=True)
    ap.add_argument("--overlay-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ids-from")
    a = ap.parse_args()
    n, vcpus = a.n, a.vcpus
    if n not in (4, 8):
        die("--n must be 4 or 8 (N=2 = the original cxl_vm0/cxl_vm1 XMLs)")
    if n * vcpus != TOTAL_VCPUS or n * a.ram_gib != TOTAL_GIB:
        die(f"N x vcpus must be {TOTAL_VCPUS} and N x ram-gib {TOTAL_GIB} (fixed total, user 2026-10-20)")
    if vcpus % 2:
        die("vcpus must be even (whole host cores with both HT threads)")
    ram_kib = a.ram_gib * 1024 * 1024
    b0, b1 = ET.parse(a.vm0).getroot(), ET.parse(a.vm1).getroot()
    if b0.find("name").text != "cxl_vm0" or b1.find("name").text != "cxl_vm1":
        die("--vm0/--vm1 must be cxl_vm0/cxl_vm1")
    for b in (b0, b1):
        if b.find("./devices/disk[@device='disk']/source").get("file") not in (
                BASE_DISK, "/var/lib/libvirt/images/cxl_vm1.qcow2"):
            die("base XML disk is not the original qcow2 (already switched?)")
    o0 = b0.find("os")
    k0 = {t: o0.find(t).text for t in ("kernel", "initrd", "cmdline")}
    old = {}
    if a.ids_from:
        for line in open(a.ids_from):
            f = line.split()
            old[f[0]] = f
    os.makedirs(a.out, exist_ok=True)
    rows = []
    for i in range(n):
        name, ip = f"cxl_vm{i}", f"192.168.122.{100 + i}"
        if i in (0, 1):
            base = b0 if i == 0 else b1
            uid = base.find("uuid").text
            mac = base.find("./devices/interface/mac").get("address")
        else:
            base = b0
            uid = old[name][1] if name in old else str(uuid.uuid4())
            mac = f"52:54:00:c8:00:{i:02x}"
        if i == 0:
            mid = "21a1a314c19942ebbdc85617855ef95d"   # vm0 keeps its own machine-id (overlay unedited)
        else:
            mid = old[name][7] if name in old else uuid.uuid4().hex
        disk = os.path.join(a.overlay_dir, f"{name}.qcow2")
        d, cpus = build(base, i, name, uid, mac, disk, k0, vcpus, ram_kib)
        ET.ElementTree(d).write(os.path.join(a.out, f"{name}.xml"))
        rows.append(f"{name} {uid} {mac} {ip} {disk} {','.join(map(str, cpus))} {emu_for(i)} {mid}")
    with open(os.path.join(a.out, "ids.txt"), "w") as f:
        f.write("\n".join(rows) + "\n")
    print("\n".join(rows))


if __name__ == "__main__":
    main()
