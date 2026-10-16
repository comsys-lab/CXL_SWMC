# Host and VM setup for measurements

How the Host (cloudcxl2) and the two KVM guests (cxl_vm0, cxl_vm1) must be configured so that latency and
throughput measurements are not distorted by power management or by other work on the guests' CPUs. Every item is
marked APPLIED (in place today), REQUIRED (must be in place during every measurement), or PROPOSED (not applied;
needs a decision and a grant). Status as of 2026-10-16.

## 1. Topology (observed 2026-10-16)
- Host: 2 sockets × 16 cores × 2 threads = 64 CPUs. NUMA node0 = CPUs 0-15, 32-47; node1 = 16-31, 48-63. SMT
  siblings are n and n+32 (`/sys/devices/system/cpu/cpuN/topology/thread_siblings_list`).
- Shared device /dev/dax1.0 (NVDIMM backing of both guests) is on node0.
- Host kernel cmdline: `... modprobe.blacklist=kmem memmap=2G!320G` (no CPU isolation parameters).
  Host kernel has CONFIG_NO_HZ_FULL=y, CONFIG_RCU_NOCB_CPU=y, CONFIG_CPUSETS=y (cgroup v2 cpusets).
- Guest RAM: 96 GiB per VM, `numatune memory mode='strict' nodeset='0'`, backed by transparent huge pages
  (Host THP = madvise; AnonHugePages ≈ 101 GiB in use), no explicit hugepages.

## 2. CPU pinning
### 2.1 vCPU pinning — APPLIED
Each vCPU is pinned 1:1 to one Host CPU (XML `<cputune><vcpupin>`), all on node0, no CPU shared by the two VMs:
| VM | vCPU 0-7 | vCPU 8-15 |
|---|---|---|
| cxl_vm0 | CPUs 0,2,…,14 | CPUs 32,34,…,46 (SMT siblings of 0,2,…,14) |
| cxl_vm1 | CPUs 1,3,…,15 | CPUs 33,35,…,47 (SMT siblings of 1,3,…,15) |
So each VM owns 8 physical cores (both hyperthreads), and vCPU i and vCPU i+8 share a physical core. The guest
is not told this (no `<topology>` in `<cpu>`), so its scheduler treats the 16 vCPUs as independent CPUs.
libvirt: "The optional vcpupin element specifies which of host's physical CPUs the domain vCPU will be pinned to."
(https://libvirt.org/formatdomain.html#cpu-tuning)

### 2.2 Emulator, I/O and vhost threads — PROPOSED (needed)
Not pinned today: the QEMU processes have affinity 0-63, and their non-vCPU threads (main loop, IO, vhost-net,
VNC) were observed running on CPUs 1, 9 (cxl_vm1's vCPU cores), 46 (a cxl_vm0 vCPU core), 21, 26, 48. A packet's
virtio-net processing or QEMU's own work can therefore preempt a vCPU of either VM.
- Fix: `<emulatorpin cpuset='…'/>` (and `<iothreadpin>` if IOThreads are defined) on Host CPUs that no vCPU uses.
  libvirt places the vhost-net kernel threads in the emulator's cgroup, so emulatorpin also confines them (to be
  checked after applying). libvirt: "The optional emulatorpin element specifies which of host physical CPUs the
  'emulator', a subset of a domain not including vCPU or iothreads will be pinned to."; "The optional iothreadpin
  element specifies which of host physical CPUs the IOThreads will be pinned to."
- All node0 CPUs are vCPUs, so the emulator threads must go to node1 (proposal: CPUs 16-17 + 48-49 for cxl_vm0,
  18-19 + 50-51 for cxl_vm1). Live change, no reboot: `virsh emulatorpin <vm> <cpuset> --live`; persistent:
  `--config` (XML change = VM configuration grant).

### 2.3 Keep Host work off the vCPU CPUs — PROPOSED (needed)
Host processes (loadgen, shells, agents, system services) may run on node0 CPUs today (affinity 0-63).
- Runtime, reversible (preferred first): restrict Host cgroups to node1 during measurements, e.g.
  `systemctl set-property --runtime system.slice AllowedCPUs=16-31,48-63` (same for user.slice and init.scope;
  the machine.slice holding the VMs keeps node0), and pin loadgen explicitly (`taskset -c <node1 CPUs>`), on CPUs
  disjoint from the emulator CPUs of §2.2. Undo: set AllowedCPUs back to 0-63.
- Host IRQs off vCPU CPUs at runtime: write node1 masks to `/proc/irq/*/smp_affinity_list` (irqbalance stopped
  for the measurement); undo by restoring the recorded masks.
- Boot-time alternative (Host reboot, all VMs down; separate decision): `isolcpus=`, `nohz_full=`, `rcu_nocbs=`,
  `irqaffinity=` on the Host cmdline. The kernel documentation itself steers away from boot-time domain isolation:
  "performing domain isolation this way is irreversible … Use cpusets for a dynamic configuration which can be
  altered at runtime." (Documentation/admin-guide/kernel-parameters.txt, isolcpus=;
  https://docs.kernel.org/admin-guide/kernel-parameters.html). nohz_full: "set the specified list of CPUs whose
  tick will be stopped whenever possible"; irqaffinity: "Set the default irq affinity mask". Apply only if the
  runtime cpuset/IRQ steps leave measurable noise.

## 3. Power management
### 3.1 Host deep C-states — REQUIRED off during measurements
Measured 2026-10-16 (reports/KV-idle-check.md, recovery/KV-idle-check-v1): with Host intel_idle C1E (2 µs) and C6
(290 µs exit latency) enabled, KV all-HWcc p99 at 500 req/s is 0.466 ms vs 0.141 ms at 12k req/s (U-shaped curve);
with C1E and C6 disabled p99 is flat at 0.13-0.15 ms from 500 to 12k req/s. Warm-up was ruled out (a 500 req/s step
after 12k gives the same 0.45 ms). Cause: wake-up from deep idle between requests at low rates.
- Disable (Host sudo): for every CPU, write 1 to `/sys/devices/system/cpu/cpu*/cpuidle/state<i>/disable` for the
  states named C1E and C6 (POLL and C1 stay enabled). Record all `disable` values first; restore exactly those
  values after the measurement and diff against the record.
- Every measurement block must record the C-state settings and refuse to start if C1E/C6 are enabled (harness
  change pending).
### 3.2 Other knobs (APPLIED / as found)
- Host cpufreq governor: performance (APPLIED). Turbo is on (not fixed); frequency can vary with load (note in
  results; fixing it is PROPOSED only if run-to-run variance requires it).
- KVM halt polling: `halt_poll_ns` = 200000 (default; as found).
- Guest: no cpuidle driver (`current_driver` = none), idle = HLT exit to the Host (as found).

## 4. Memory
- Guest RAM on node0 (strict), THP-backed (APPLIED). Explicit 1 GiB/2 MiB hugepages are PROPOSED only if THP
  splitting/compaction shows up in measurements.
- NVDIMM (/dev/dax1.0, 96 GiB, node0, 4 KiB align, 16 MiB label, slot 1) must stay exactly as configured
  (CLAUDE.md "Deployment").

## 5. Checklist per measurement block
1. No Host build running (`workspaces/MEASUREMENT.lock`, host-gate.sh).
2. Host C1E/C6 disabled, settings recorded (§3.1).
3. (when applied) emulator threads pinned to node1 (§2.2), Host slices on node1 and loadgen pinned (§2.3).
4. After the block: restore C-states (and slices/IRQ masks) to the recorded values and diff.
