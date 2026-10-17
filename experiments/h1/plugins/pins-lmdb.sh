# H1 plugin: LMDB (1M records, 4 KiB B+tree pages = Megalon objects, p99 < 1 ms per request; LMDB-F1 v1.7.1 BLOCK DONE
# 2026-10-17, recovery/LMDB-F1-v1.7.1-run). all-HWcc = lmdb/8 plain, Popcorn = lmdb/8 + cxl_shm build 12, Megalon =
# lmdb-megalon/8 on Megalon 77 (timers on), mgoff = the same with MEGALON_COH_TIMERS=0. Builds from BUILD_PIN 934fa9312;
# install = the LMDB-F1 v1.7.1 guest dir /home/comsys/lmdb8b incl. img-1000000 on node 0 (Q10 reuse; the block checks
# every installed file, the config and the image against the pins). Hook = experiments/lmdb/h1-block.sh, H1-HOOK v2 (experiments/kv/h1v2-lib.sh) at f8bf42142
# (live tree, every file the block runs hash-pinned below). Filled 2026-10-17.
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=$P/CXL_SWMC
HOOK_FILE=$HR/experiments/lmdb/h1-block.sh
BLOCK_CMD=(bash $HOOK_FILE)          # H1 hook (marker H1-HOOK v2)
BLOCK_ENV=(BUILD_PIN=934fa9312c38eeaf2845605cf22d2ef1cfe15fc4 MEGALON_BUILD_N=77 EXPECT_K=$KPOP EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  PLAIN_BUILD=$P/builds/lmdb/8 MEG_BUILD=$P/builds/lmdb-megalon/8 LOADGEN_BUILD=$P/builds/lmdb-loadgen/7
  LMDB_GUEST_DIR=/home/comsys/lmdb8b LMDB_MEG_CFG=$P/recovery/LMDB-F1-v1.7.1-run/install.log.megalon.yaml
  IMG=$P/workspaces/lmdb-img-1m-b8-v171 C8=$CPOP K8=$KPOP GT8=$GTPOP RECV_MODE=$RECV_MODE)
PIN_SHA256="$COMMON_SHA256
0733c99ef26b1bbc7936e3148e5bbb113778e9b98274d2dacc92532a3543c980  $P/builds/lmdb/8/manifest.txt
c123066638582aa0e5ec1112b96dbdb88ecf8e9ce0751646b0172f15b670811d  $P/builds/lmdb/8/bin/lmdb-server
cff4271e2cf29c33f6aa981404ca954e63ad72f3126d42338095effdcd228031  $P/builds/lmdb-megalon/8/manifest.txt
f2796288194dac8848ea14f926583d1e917e4e5325ab2175d4414639e011c254  $P/builds/lmdb-megalon/8/bin/lmdb-server
55cbfc03fee0a94790bddd7a80f32b7963d58e39607623dfaf95d6173c1aa221  $P/builds/lmdb-megalon/8/lib/libmegalon-objapi.so
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $P/builds/lmdb-megalon/8/lib/libmegalon.so
3cebe72e8fde8164b5eabde3c59740777ee17bcc6ac6da432fa0a00f7f617bb5  $P/builds/lmdb-loadgen/7/manifest.txt
26ce2b2b4fa55b94c4ca0da79cbe79a31e7608f69d3343de97fd48af61e6b01d  $P/builds/lmdb-loadgen/7/loadgen
e45baa9b8d2e211b7418f2ddad5612364df92162fe651e015415f3043bd66514  $P/recovery/LMDB-F1-v1.7.1-run/install.log.megalon.yaml
d127ac3c498ebac7f3e5c1860c9903876c49f42815720d8222ee080d5524a071  $P/workspaces/lmdb-img-1m-b8-v171/pages.bin
0930ab5e9a8add069305f259ff10aa94a3818b705f364c134cfbda23aada18b7  $P/workspaces/lmdb-img-1m-b8-v171/meta.txt
90cb9e6920e79aa2ff0d00decb054867ecb7adba4edf5fcbd63200d29b55a460  $HOOK_FILE
fbfb125195d2c862ab33c56da7e251c940973e03bd19ffaa35361002fdd1d895  $HR/experiments/kv/h1v2-lib.sh
461f6230308d698a8fc529316e76b4ba152498506b31a2291d7ab85a47b6375d  $HR/experiments/lmdb/pilot-run.sh
c70f6c2b579dab38b5cfd9e992e174507567ba10ec4ecc32c1aeb7e8d2614020  $HR/experiments/lmdb/run.sh
3edf6f2d4c5df8b33da9ac249466f8b41042eebe0ca509b7befd3e9fad456a82  $HR/experiments/lmdb/lmdb-node.sh
8435ef222785be5d7a6dd6a97572b1404017822c63f3f766c45562efc8ae35ca  $HR/experiments/kv/precheck.sh
de9d4a99916fbd60b66f6142d0cbc69cd88068e19c9ca08609380241801e76f7  $HR/experiments/kv/v1-check.py
cbd6d75e743f149633a461e525bff6c69108407bcc0d7b9dc8f443dc72a6690f  $HR/experiments/kv/pretouch-check.sh
1edcdda88f30200fd55c1b5a18cb4b9d6db57aa02647f8ad549e4e7f6aabb31f  $HR/experiments/vectordb/host-gate.sh
68327dd3178d7af5b0ad9c614f0a6c41b4d99b2f6a23cf456f7751273996eecf  $HR/scripts/host/measure-env.sh
0edfe4997688007e6281ba1120885ae1eba226dd09602718fd513bf62576ed8c  $HR/experiments/h1/h1-gate.sh
aed8d7f32871398db375c502152587ee0b25a716dd60d4ff637e189aa3d42420  $HR/scripts/host/measure-run.sh
1f3fe160a17138beb6dba1acd19369e703dc90223bb96d9b0f0f3de93ae5db14  $HR/scripts/host/measure-env-part.sh
7195fe79fa952cc61a5c95d275e924b004fcfd8a98a97baba640b51c6494e621  $HR/workloads/kv/tools/opsplit.py
83731292c83fcd5359c3ebb628b71bcbfcf3c3dd12e5e189e0b44bba3ad9508b  $HR/workloads/lmdb/tools/check_log.py
a9b8dece1a553049959ba2c2512f69c03f60047988391a2cdb2fbfca159177ea  $HR/workloads/lmdb/tools/lmdb_ctl.py
6470d54b3727164cc765072e9a87b5573264b6b4b2d016d0b71309fbeb2b50e1  $HR/experiments/loadgen/stats_delta.py
c4142bdb0aeb0ea66c337b886086ca0b9540dbd0fcc20739529c520adce0f370  $HR/experiments/loadgen/export_csv.py
eeb6b23f173d85a3c86ade0fb804b363e3c84a36bf9c0f56a7cbcab25e738b53  $HR/config/cxl_region.yaml"
