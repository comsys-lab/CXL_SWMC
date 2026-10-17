# H1 plugin: KV store (54M keys, batch 16, Zipf 0.99, p99 < 1 ms per request; KV-V1 v1.5 PASS 2026-10-17 21:27,
# recovery/KV-V1-v1.5-run). all-HWcc = kv/10 on Megalon 77-hwcc (FULL_COHERENCE flavor; MOT1 v6 §3.1 KV rule), Popcorn =
# kv/10 + cxl_shm build 12, Megalon = kv-megalon/10 on Megalon 77 (timers on), mgoff = the same with MEGALON_COH_TIMERS=0.
# Builds from BUILD_PIN 934fa9312; installs = the KV-V1 v1.5 guest dirs kv10 / kvm10 (Q10 reuse; the block's precheck
# compares every installed file with the builds). Hook = block h1 of pilot-block.sh at f941da2fd; pilot-run.sh re-pinned after the wmeta_reclaim NOTE rule (live tree, every file
# the block runs hash-pinned below). Filled 2026-10-17.
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=$P/CXL_SWMC
HOOK_FILE=$HR/experiments/kv/pilot-block.sh
BLOCK_CMD=(bash $HOOK_FILE h1)       # H1 hook = block "h1" (marker H1-HOOK v1)
BLOCK_ENV=(PIN=f941da2fd7b28ba5ca2ce984932b55f3601219b4 BUILD_PIN=934fa9312c38eeaf2845605cf22d2ef1cfe15fc4 MEGALON_BUILD_N=77 KEYS=54000000
  PLAIN_BUILD=$P/builds/kv/10 MEG_BUILD=$P/builds/kv-megalon/10 LOADGEN_BUILD=$P/builds/kv-loadgen/10
  VM_PLAIN=/home/comsys/kv10 VM_MEG=/home/comsys/kvm10 KV_CFG=$P/recovery/KV-V1-v1.5-run/install.log.megalon.yaml
  K8=$KPOP C8=$CPOP GT8=$GTPOP RECV_MODE=$RECV_MODE EXPECT_DAX_UUID=$EXPECT_DAX_UUID)
PIN_SHA256="$COMMON_SHA256
64feff0dbd8777ff1afb77ce25eef512ec8782bfcdd12d77003599c7abb34a11  $P/builds/kv/10/manifest.txt
91bc6cc2d3a03d029a0183f27c4ff0aa22c9a83d57937a1d3f06510320be591d  $P/builds/kv/10/bin/kv-server
67d686370293baaf477519bac63612504d503b215d6b4285cde68c866c6a400c  $P/builds/kv/10/lib/libkv-megalon.so
f22c852f5cc83928b2a4852a3aa428197aa70af7bf385defe0a91c18fa622dc7  $P/builds/kv/10/lib/libmegalon.so
75efa2493ef1b304a8276739ba4ac9f05c32841f1a68572de691c10abee65003  $P/builds/kv-megalon/10/manifest.txt
dc96d5d784d3bd92d9a4d90ecaba92d036a4a37cefc9b17bf18354be8767be34  $P/builds/kv-megalon/10/lib/libkv-megalon.so
d97d3844fe6464c03b94c816a5836dae30f16c356920969d36c7fcf62f6f2a15  $P/builds/kv-megalon/10/lib/libmegalon-objapi.so
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $P/builds/kv-megalon/10/lib/libmegalon.so
2e299f162de5701d83e2f776326416cf258f0e55dce11f500fafe26c0985773c  $P/builds/kv-loadgen/10/manifest.txt
68a642f425d1082f389d57acc9119cca2998f33cc8371fe1834f735c927bdea6  $P/builds/kv-loadgen/10/kv-manifest.txt
5ebc87703788fddd6e93e8cbd6a85dc0f118610775fdfdbaf50b98018aae954a  $P/builds/kv-loadgen/10/loadgen
48c5f02c0546af9b22cf0a4ce2172177193ffcc6d502d9fb0fdeb51863bb9f17  $P/recovery/KV-V1-v1.5-run/install.log.megalon.yaml
7f2c385ad563d26b6aa3da3e798d66f4f0e214e6c10be107bd52865e468cacb9  $HOOK_FILE
c7742c6a2fe8163a6ef12ce12f4504edd1f613401808b21e1b79921e370927a4  $HR/experiments/kv/pilot-run.sh
7c5a94a337171ce8ca3ee867710746d46a81b70c99938c864d2bc63d1ce07ab9  $HR/experiments/kv/run.sh
8435ef222785be5d7a6dd6a97572b1404017822c63f3f766c45562efc8ae35ca  $HR/experiments/kv/precheck.sh
f074f4dc5df208f2ddd0b38f01d75c00240d6bf74c1eb6115ef04cb07fba6092  $HR/experiments/kv/v1-check.py
cbd6d75e743f149633a461e525bff6c69108407bcc0d7b9dc8f443dc72a6690f  $HR/experiments/kv/pretouch-check.sh
1edcdda88f30200fd55c1b5a18cb4b9d6db57aa02647f8ad549e4e7f6aabb31f  $HR/experiments/vectordb/host-gate.sh
68327dd3178d7af5b0ad9c614f0a6c41b4d99b2f6a23cf456f7751273996eecf  $HR/scripts/host/measure-env.sh
ea8417418975f9a363d2c133f43a0a84bac5bd5f86eb0953305cea2864629327  $HR/scripts/guest/kv-node.sh
7195fe79fa952cc61a5c95d275e924b004fcfd8a98a97baba640b51c6494e621  $HR/workloads/kv/tools/opsplit.py
6470d54b3727164cc765072e9a87b5573264b6b4b2d016d0b71309fbeb2b50e1  $HR/experiments/loadgen/stats_delta.py
c4142bdb0aeb0ea66c337b886086ca0b9540dbd0fcc20739529c520adce0f370  $HR/experiments/loadgen/export_csv.py
eeb6b23f173d85a3c86ade0fb804b363e3c84a36bf9c0f56a7cbcab25e738b53  $HR/config/cxl_region.yaml"
