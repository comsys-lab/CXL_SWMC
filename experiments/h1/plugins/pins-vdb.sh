# H1 plugin: vector DB (HNSW 28M, pubmed-a27m-b1m-q10k; reports/VDB-V1-packet.md v1.3.1 blocks, validation PASS
# 2026-10-17 §17). all-HWcc = plain server (no Megalon; MOT1 v6 §3.1), Popcorn = plain server + cxl_shm
# (init_state=shared + preload, recv_mode poll), Megalon = vdb-megalon on Megalon 77 (packed4, 32 MiB vector chunk
# object), mgoff = the same with MEGALON_COH_TIMERS=0. H1-HOOK v2 (CXL_SWMC 9a802a6f3, 935e487ab). Loadgen = vdb-loadgen/6
# (w_start plugin option; built 2026-10-18 from 0dcf987bc, plugin provenance in vdb-manifest.txt).
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=$P/CXL_SWMC                      # live tree; v6-block.sh uses $P/CXL_SWMC/experiments/vectordb itself. Every file it
                                    # runs is hash-pinned below (hook: see the v6-block.sh pin; builds vdb/15, vdb-megalon/14 from 934fa9312)
HOOK_FILE=$HR/experiments/vectordb/v6-block.sh
BLOCK_CMD=(bash $HOOK_FILE)          # H1 hook = H1MODE=r1|cont in v6-block.sh (marker H1-HOOK v2)
BLOCK_ENV=(KPOP=$KPOP GTPOP=$GTPOP CPOP=$CPOP MEG_LIB=$MEG77 MEGALON_LEAN=1 EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  PLAIN_BUILD=$P/builds/vdb/15 VPLAIN=/home/comsys/vdb15
  MEG_BUILD=$P/builds/vdb-megalon/14 VMEG=/home/comsys/vdbm14-28m MEG_CFG=$HR/systems/megalon/vectordb-2vm.yaml
  LOADGEN_BUILD=$P/builds/vdb-loadgen/6)
PIN_SHA256="$COMMON_SHA256
f17c8995c1b2c88f3849b6aec890c848fafe99bb40298cbf4412999858bc59d1  $P/builds/vdb/15/manifest.txt
2097a2e49290849a35d62f474da50bb7e3e4fedb9d0703343c797e9fdabfe525  $P/builds/vdb/15/bin/vdb-server
65fa1fb1077aaac0fd9f1be947d76e90c84c633752d1e279ae1e68937b50e3e5  $P/builds/vdb-megalon/14/manifest.txt
5f1ff99101da18cd7f05d55c77444ea7a7cf94030e17bcf24050e0ebe12c0dbc  $P/builds/vdb-megalon/14/bin/vdb-server
8c59d1808ec569f54a05531610e3b9d18ae4563f9ebb5c264a657bd1edf3a3ac  $P/builds/vdb-megalon/14/lib/libmegalon-objapi.so
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $P/builds/vdb-megalon/14/lib/libmegalon.so
35aba4624362528cad6e4177074328ab200f8c23fd526704d8fe4be9727d7404  $P/builds/vdb-loadgen/6/manifest.txt
d870c74bb5880b7b3d46987baf0437a22572432726b42ab0f3daf36e7a1f1852  $P/builds/vdb-loadgen/6/loadgen
5babcbe75f94e2186f4ca38c0c5df177057dca4e2fc8fe6f76e24be31e72e573  $P/builds/vdb-loadgen/6/vdb-manifest.txt
e9d4942ee33b2f65cf7117d87942296e1365d0234873c2c4159545f40708db54  $P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1/SHA256SUMS
4e4e7134710f9b131368d7b3f71c07ab56d97e72ad329649bda27f893f6d65be  $HR/systems/megalon/vectordb-2vm.yaml
eeb6b23f173d85a3c86ade0fb804b363e3c84a36bf9c0f56a7cbcab25e738b53  $HR/config/cxl_region.yaml
7e8cc73998280bd606598ab26003b1ba80a81dd736c58e3f8207a9482d36f2e6  $HOOK_FILE
27a11c2c75f748fa7b47111496e30170ab5a35c0b65bd56422c6b3b6fb4d7503  $HR/experiments/vectordb/m4-lib.sh
56bb517decbaabf6b50ce22d05e973c46be4858c55c44c56049b746bc6ad1a24  $HR/experiments/vectordb/m4-run.sh
4d917368a0946c0a5052dd0d1e31e5ab900914e74c75bd02d37dc164708b66fb  $HR/experiments/vectordb/m4-precheck.sh
5a4cd27c57b9aebe82a3d9b1652690b0496ddd1e81da4e9479a02d33085f3ad6  $HR/experiments/vectordb/run.sh
1edcdda88f30200fd55c1b5a18cb4b9d6db57aa02647f8ad549e4e7f6aabb31f  $HR/experiments/vectordb/host-gate.sh
1baccf944c1ac66fce65b065c1043529cd72bc08b38f4b42fe43bd2640076031  $HR/experiments/vectordb/pretouch-gate.sh
49ffaf143f484e4548e84105d20f584547fbd06c6cd38c1522ba4dccbd18e8fe  $HR/experiments/vectordb/opsplit.py
070c89107f47abdb9d4534232a0a0c7ee8f664db0fdb4fd850020e3d3e680321  $HR/workloads/vectordb/tests/opcoh_check.py
68327dd3178d7af5b0ad9c614f0a6c41b4d99b2f6a23cf456f7751273996eecf  $HR/scripts/host/measure-env.sh
256445b452eb6373b7bef81ef691f3a4e601d21c77c44b498ba268a01edb57e7  $HR/experiments/vectordb/h1-rates.sh
aed8d7f32871398db375c502152587ee0b25a716dd60d4ff637e189aa3d42420  $HR/scripts/host/measure-run.sh
672ad3c64e2992ba70d1fc5534e2e652c23d6166ad3e107b38597b23caaeb759  $HR/experiments/h1/h1-gate.sh
6470d54b3727164cc765072e9a87b5573264b6b4b2d016d0b71309fbeb2b50e1  $HR/experiments/loadgen/stats_delta.py
eeb0b734b02acf1e6fabc2d91a68e83034bcd04d328407e8679702635e7b6787  $HR/experiments/vectordb/qcoh.py
71137daf35c5ba822d2dbfa06277e5cb4d962b38c7bf75e416c4ad23a31b15d0  $HR/experiments/vectordb/e1_check.py
c4142bdb0aeb0ea66c337b886086ca0b9540dbd0fcc20739529c520adce0f370  $HR/experiments/loadgen/export_csv.py
1f3fe160a17138beb6dba1acd19369e703dc90223bb96d9b0f0f3de93ae5db14  $HR/scripts/host/measure-env-part.sh
b999497276a5a520fe30c50954bcd9d2e875eb6623078f137b71affb015d7ae9  $HR/experiments/loadgen/plot_slo.py"
