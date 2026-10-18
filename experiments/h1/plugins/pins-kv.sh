# H1 plugin: KV store (54M keys, batch 16, Zipf 0.99, p99 < 1 ms per request; KV-V1 v1.5 PASS 2026-10-17 21:27,
# recovery/KV-V1-v1.5-run). all-HWcc = kv/10 on Megalon 77-hwcc (FULL_COHERENCE flavor; MOT1 v6 §3.1 KV rule), Popcorn =
# kv/10 + cxl_shm build 12, Megalon = kv-megalon/10 on Megalon 77 (timers on), mgoff = the same with MEGALON_COH_TIMERS=0.
# Builds from BUILD_PIN 934fa9312; installs = the KV-V1 v1.5 guest dirs kv10 / kvm10 (Q10 reuse; the block's precheck
# compares every installed file with the builds). Loadgen kv-loadgen/13 (LOADGEN_PIN = PIN 9f3cdfbc4: H1 v0.6.5 confirm fallback; before kv-loadgen/12 9e2dc0974 "A+C", on top of
# kv-loadgen/11's plugin state_in/state_out
# across the parts of one lifetime). Hook = block h1 of pilot-block.sh, H1-HOOK v2 (experiments/kv/h1v2-lib.sh) at f8bf42142 (live tree, every file
# the block runs hash-pinned below). Filled 2026-10-17.
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=$P/CXL_SWMC
HOOK_FILE=$HR/experiments/kv/pilot-block.sh
BLOCK_CMD=(bash $HOOK_FILE h1)       # H1 hook = block "h1" (marker H1-HOOK v2)
BLOCK_ENV=(PIN=9f3cdfbc48213c568b49c0bda85e6fbded94243d BUILD_PIN=934fa9312c38eeaf2845605cf22d2ef1cfe15fc4 MEGALON_BUILD_N=77 KEYS=54000000
  PLAIN_BUILD=$P/builds/kv/10 MEG_BUILD=$P/builds/kv-megalon/10 LOADGEN_BUILD=$P/builds/kv-loadgen/13 LOADGEN_PIN=9f3cdfbc48213c568b49c0bda85e6fbded94243d
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
ed5be76e39374ccba1a2a74beb7fa3db9c94077e1de08fd0ec26778d1a9c2679  $P/builds/kv-loadgen/13/manifest.txt
7173567f2abf2b074c53af0e6517f75a9b2e4639ef3f12b2af15b952954dc6e8  $P/builds/kv-loadgen/13/kv-manifest.txt
d2a34bda9fefe6d8f4acd96cd38153a99e88cd352a818428cdbc3966325d0b84  $P/builds/kv-loadgen/13/loadgen
48c5f02c0546af9b22cf0a4ce2172177193ffcc6d502d9fb0fdeb51863bb9f17  $P/recovery/KV-V1-v1.5-run/install.log.megalon.yaml
6df0d4913d86355f0c60ba020d49618b02902995d05532da96f5b5eb186d1b82  $HOOK_FILE
fbfb125195d2c862ab33c56da7e251c940973e03bd19ffaa35361002fdd1d895  $HR/experiments/kv/h1v2-lib.sh
8fb253c93f01a11043f20dec7b941d6172cf0e973ba1285e38abde86fa82d9e9  $HR/experiments/kv/pilot-run.sh
3c730903718325d010c0a7c31fa2b53019fae0674308fa1c95cf6256cb1faf91  $HR/experiments/kv/run.sh
8435ef222785be5d7a6dd6a97572b1404017822c63f3f766c45562efc8ae35ca  $HR/experiments/kv/precheck.sh
de9d4a99916fbd60b66f6142d0cbc69cd88068e19c9ca08609380241801e76f7  $HR/experiments/kv/v1-check.py
cbd6d75e743f149633a461e525bff6c69108407bcc0d7b9dc8f443dc72a6690f  $HR/experiments/kv/pretouch-check.sh
1edcdda88f30200fd55c1b5a18cb4b9d6db57aa02647f8ad549e4e7f6aabb31f  $HR/experiments/vectordb/host-gate.sh
68327dd3178d7af5b0ad9c614f0a6c41b4d99b2f6a23cf456f7751273996eecf  $HR/scripts/host/measure-env.sh
0edfe4997688007e6281ba1120885ae1eba226dd09602718fd513bf62576ed8c  $HR/experiments/h1/h1-gate.sh
aed8d7f32871398db375c502152587ee0b25a716dd60d4ff637e189aa3d42420  $HR/scripts/host/measure-run.sh
1f3fe160a17138beb6dba1acd19369e703dc90223bb96d9b0f0f3de93ae5db14  $HR/scripts/host/measure-env-part.sh
ea8417418975f9a363d2c133f43a0a84bac5bd5f86eb0953305cea2864629327  $HR/scripts/guest/kv-node.sh
7195fe79fa952cc61a5c95d275e924b004fcfd8a98a97baba640b51c6494e621  $HR/workloads/kv/tools/opsplit.py
6470d54b3727164cc765072e9a87b5573264b6b4b2d016d0b71309fbeb2b50e1  $HR/experiments/loadgen/stats_delta.py
fe35a89936c8da64a97a468b2429ad61062bd499a0fb775a1a003437366cc701  $HR/experiments/loadgen/export_csv.py
eeb6b23f173d85a3c86ade0fb804b363e3c84a36bf9c0f56a7cbcab25e738b53  $HR/config/cxl_region.yaml"
