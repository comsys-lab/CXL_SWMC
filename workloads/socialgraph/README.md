# workloads/socialgraph

TAO / LinkBench-style social graph serving on the SNAP com-Orkut graph (experiment socialgraph-serving,
reports/experiments/socialgraph-serving.md). Design: DESIGN.md. Harness entry: experiments/socialgraph/ (runset-sg.sh,
sg-block.sh, sg-run.sh, sg-install.sh, sg_steps.py, clock_offset_log.py, socialgraph.conf).

## Builds (Host, build-wrap.sh)
| Build | Contents | Source |
| --- | --- | --- |
| builds/socialgraph/4 | sg-server (plain backend, libdestijl, --write-route), sg-image-gen, sg-client, tests | server/build.sh |
| builds/socialgraph-loadgen/3 | loadgen (+ socialgraph plugin, write_route=mod\|range), sg-loadgen-mix, -keys-test, -stub | loadgen/build.sh |
| builds/socialgraph-megalon/2-n{2,4,8} | sg-server --backend megalon + Megalon libs (megalon/78-n<N>) | server/build-megalon.sh |
| builds/socialgraph-image/1 | graph.img (10.7 GB), gen.json, manifest.json | tools/make_image.sh |

Pending user decisions (verifier 2026-11-11), implemented as conf options with the current behaviour as default:
SG_START_FALLBACK=0 (1: a ramp failing at --start 1000 is rerun once from SG_START_FALLBACK_RATE=100) and
SG_WRITE_ROUTE=mod (owner VM of slot s = s % N; range = contiguous id ranges per VM; loadgen and servers always get the same
value). Multi-writer page fractions of image 1 per route: tools/sg_page_writers.py (builds/socialgraph-loadgen/3/test/page-writers.txt).

## Guest layout (comsys, below /home/comsys; installed by experiments/socialgraph/sg-install.sh install / image)
| Dir | Build | Region | Systems |
| --- | --- | --- | --- |
| sg4/ | socialgraph/4 | config/cxl_region-ring2m.yaml | hw, pop |
| sg4ds/ | socialgraph/4 | config/cxl_region-destijl.yaml | ds |
| sgm2-n<N>/ | socialgraph-megalon/2-n<N> + lib/ + cfg/megalon.yaml = systems/megalon/socialgraph-<N>vm.yaml | ring2m | mgc |
| sgm2r-n2/ | socialgraph-megalon/2-n2 + cfg/megalon.yaml = socialgraph-2vm-record.yaml | ring2m | mgr |
| sg-image-1/graph.img (+ .sha256) | builds/socialgraph-image/1/graph.img | - | vm0 only |
Each dir: bin/sg-server, bin/sg-node.sh (scripts/guest/sg-node.sh), cfg/cxl_region.yaml.

## Manual smoke (N = 2, one system at a time; the chain workspaces/socialgraph-serving-smoke-chain-v1.sh does the same)
Host, once: `bash CXL_SWMC/experiments/socialgraph/sg-install.sh install --n 2`, then `... image`, then `... verify`
(the image copy is ~10.7 GB scp to vm0 plus a guest-side sha256).
Per system, on the guests (IPs 192.168.122.100 / .101; `APP=$(builds/socialgraph/4/bin/sg-server --nodes 2 --print-app-bytes)`
on the Host; Megalon: `builds/socialgraph-megalon/2-n2/bin/sg-server --backend megalon --object-layout chunk --chunk-bytes
33554432 --nodes 2 --print-app-bytes`; RID = any 0x hex id, the same on both nodes):
1. hw (Popcorn 13 kernel, no cxl_shm):
   - both VMs: `sudo -n chown comsys /dev/dax0.0`
   - vm0: `~/sg4/bin/sg-node.sh copy-image ~/sg4 ~/sg-image-1/graph.img ~/sg4/runs/copy.log` then
     `~/sg4/bin/sg-node.sh verify ~/sg4 ~/sg-image-1/graph.img ~/sg4/runs/verify.log` (COPY DONE / VERIFY PASS)
   - vm k (0, 1): `mkdir -p ~/sg4/runs/s1/stale; ~/sg4/bin/sg-node.sh start ~/sg4 ~/sg4/runs/s1 k $RID $APP --nodes 2
     --query-threads 3 --port 7100 --stale-dir ~/sg4/runs/s1/stale --stale-every 1000`, then `... ready ~/sg4/runs/s1 k 900`
   - Host: `builds/socialgraph/4/bin/sg-client selftest 192.168.122.100:7100 192.168.122.101:7100 1 1500` is NOT for the
     Orkut image (it needs the synthetic hub of tests/host_test.sh); use the loadgen at one fixed rate instead:
     `builds/socialgraph-loadgen/3/loadgen --workload socialgraph --target 192.168.122.100:7100,192.168.122.101:7100
     --out <dir> --stats-op 20 --mix "$(builds/socialgraph-loadgen/3/bin/sg-loadgen-mix 100)" --opt rw=100
     --opt image=builds/socialgraph-image/1/graph.img --opt gen=builds/socialgraph-image/1/gen.json --mode fixed
     --rates 500 --warmup-s 10 --step-warmup-s 3 --step-measure-s 30 --drain-s 5 --slo feed:99:10`
   - vm k: `~/sg4/bin/sg-node.sh stop ~/sg4/runs/s1 k`; both VMs: `sudo -n chown root:root /dev/dax0.0; sudo -n chmod 600 /dev/dax0.0`
2. pop: the Popcorn cycle of the bundle (`p-popcorn-shm.sh precheck load chown`), the image copy + verify as in hw, then
   `enable`, receiver writes (recv_mode adaptive, ipoll 0, watch_us 50, s_max_us 50), the servers as in hw, loadgen,
   stop, `status`, `teardown`.
3. ds: the De Stijl cycle (`p-destijl-shm.sh precheck load chown` with LOAD_EXTRA="recv_mode=adaptive fault_poll=0"),
   image copy + verify with ~/sg4ds, `enable`, receiver writes, servers from ~/sg4ds with `ENV:CXL_SYSTEM=ds
   ENV:CXL_DESTIJL_T_US=1000000` before the server args (log line "de stijl staleness T=1000000 us on the image"), loadgen,
   stop, teardown.
4. mgc / mgr: `sudo -n chown comsys /dev/dax0.0`; vm0 first: `~/sgm2-n2/bin/sg-node.sh start ~/sgm2-n2 <run> 0 $RID $APP
   ENV:RACKOBJ_CONFIG=$HOME/sgm2-n2/cfg/megalon.yaml ENV:MEGALON_REINIT=1 --backend megalon --object-layout chunk
   --chunk-bytes 33554432 --nodes 2 --query-threads 3 --start-timeout-ms 900000 --port 7100 --stale-dir <run>/stale
   --image ~/sg-image-1/graph.img`, then vm1 the same without MEGALON_REINIT and --image; ready (node 0 loads 8.15M
   objects in ~60 s for record, Host test); mgr: ~/sgm2r-n2 and `--object-layout record`.
5. Staleness join (Host): `python3 -I workloads/socialgraph/tools/sg_stale_join.py --dir <collected stale dir> --clock
   <clock-offset.tsv> --vm 0=192.168.122.100 --vm 1=192.168.122.101 --t-ms 1000`; clock offsets with
   `python3 -I experiments/socialgraph/clock_offset_log.py --out <tsv> --vm 192.168.122.100 --vm 192.168.122.101
   --period 30 --until-file <stop file>` running during the load.

## Guest sudo commands used (compare: doc §3 scope)
| Command | Where | In §3 scope |
| --- | --- | --- |
| `sudo -n chown comsys /dev/dax0.0`, `chown root:root` + `chmod 600` back | every VM, every lifetime | yes (run-2 set: dax owner for hw / mg; the cxl_shm chown phase) |
| `sudo -n fuser /dev/dax0.0` | every VM (dax in use check) | yes (run-2 set) |
| cxl_shm load / enable / status / teardown via p-popcorn-shm.sh / p-destijl-shm.sh | every VM | yes (cxl_shm load parameters) |
| `sudo -n sh -c 'echo .. > /sys/module/cxl_shm/parameters/{recv_mode,ipoll,watch_us,s_max_us}'` (recv-mode.sh recv_apply) | every VM | yes (run-2 receiver) |
| CPU offline / online (4 vCPU), pretouch chown, VM8 vmN path, deploy install | chains | yes (run-2 set / Host list) |
| Megalon metadata format with MEGALON_REINIT=1 on node 0 | vm0 (no sudo: dax0.0 owned by comsys) | yes |
| image copy into the region (sg-server --copy-image, plain mapping, comsys after the chown) | vm0 | yes ("image copy into the region") |
No guest sudo outside the list. Outside §3 but needed and NOT sudo (main session to confirm): the image file transfer
Host -> vm0 disk (scp, 10.7 GB + guest sha256, ~10.7 GB of vm0's disk; on VM8 every overlay inherits it from vm0's base
disk only if the copy happens BEFORE the switch), and guest install dirs below /home/comsys (sg-install.sh: scp as comsys).
