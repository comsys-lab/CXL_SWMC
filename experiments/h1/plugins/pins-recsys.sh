# H1 plugin: DLRM recsys (26 tables, 167.7M rows x 576 B, MLPerf day-23 trace; reports/RECSYS-V1-packet.md v1.2.7
# blocks). all-HWcc = recsys/9 plain, Popcorn = recsys/9 + cxl_shm build 12 (init_state=shared + preload, recv_mode
# poll), Megalon = recsys-megalon/11 on Megalon 77 (one object per 576 B row), mgoff = the same with
# MEGALON_COH_TIMERS=0. Mixes = EKKO avg / peak (two; draft §1 has no balanced DLRM mix). Filled 2026-10-17 (H1 hook =
# main-block.sh BLOCK=h1, branch recsys-h1-hook; valid once that branch is merged into the live tree after RECSYS-V1
# v1.2.7 ran — every file the block runs is hash-pinned below, so an unmerged or changed tree is refused by hook.sh).
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=$P/CXL_SWMC                      # live tree (main-block.sh resolves session.sh / v1_check.py / host-gate.sh next to itself)
HOOK_FILE=$HR/experiments/recsys/main-block.sh
BLOCK_CMD=(bash $HOOK_FILE)          # H1 hook = BLOCK=h1 in main-block.sh (marker H1-HOOK v1)
BLOCK_ENV=(BLOCK=h1 POP_BUILD=12 POP_BUNDLE_SHA=$POP_BUNDLE_SHA C8=$CPOP K8=$KPOP GT8=$GTPOP RECV_MODE=$RECV_MODE
  D=$P/builds/recsys-inputs/1 PLAIN_BUILD=$P/builds/recsys/9 MEG_BUILD=$P/builds/recsys-megalon/11 MEGALON_BASE=$MEG77
  VM_PLAIN=/home/comsys/rs9 VM_MEG=/home/comsys/rsm11 LOADGEN=$P/builds/recsys-loadgen/7/loadgen XT=7200
  EXPECT_DAX_UUID=$EXPECT_DAX_UUID)
PIN_SHA256="$COMMON_SHA256
9c330ba688b96019792dee4bb80e91965cfb7e5d5c21265bb3a2e805df3db5a8  $P/builds/recsys-inputs/1/MANIFEST.txt
83e7048cb5d727ae50e5492c8a6c84e123b5190bc8bbbbdc89d71e625fbe522a  $P/builds/recsys-inputs/1/rate-frac0.0043.txt
1df9b01d68d56d4aed1e24538945a44623863bf424c36a56cfa732c6ea16073c  $P/builds/recsys-inputs/1/rate-frac0.000513333333.txt
14a14a3e78f44f7762b6cd7c5b007091a9484bd95bf4caa35ae7f5ace3d46442  $P/builds/recsys/9/manifest.txt
baac2252d78571f1cbbb7914cc5f749210cf64061a5e7cff2c11a53f3e2afeb3  $P/builds/recsys/9/bin/recsys-server
405abcccbee81778a1bdca6be917a24c385a5708068934a929a2975c31fd72ae  $P/builds/recsys/9/bin/recsys-rate
0436890b9f36f95de85037b358a721f5ca428e3f7e656c506bb634355ac36082  $P/builds/recsys-megalon/11/manifest.txt
5150764f44b659b707e985502405544f15c56266fc23907ab57343628e902311  $P/builds/recsys-megalon/11/bin/recsys-server
eca0ba184cec64224f9fcf1241737132c49412dfde7ce011716ba7392598f5a5  $P/builds/recsys-megalon/11/lib/libmegalon-objapi.so
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $P/builds/recsys-megalon/11/lib/libmegalon.so
73c93ce02d57837f09e1b5f8d0d59142b3c7d30735bd69492dc898bd76019583  $P/builds/recsys-loadgen/7/manifest.txt
d2633e8df70e7eb0b832e205a16f7749485097d3005ce758a3ff08843caa1447  $P/builds/recsys-loadgen/7/loadgen
341e3ace830662f80fe3a86567845ec07e97e79d97d43e4a581cee5266b06934  $HOOK_FILE
2c1dcfc371063781639e04c2bd986406a0aa17ff64191ee5c9147c11772fd1e7  $HR/experiments/recsys/session.sh
252cb04dafd899b837d7f5bf1e190de9d7a5c2ec4a8fca2b81ff74f63dc6c06f  $HR/experiments/recsys/v1_check.py
32d171199d6a47d15fcfa6971522e253fe21d857e91c9049c201e55a0cdac230  $HR/experiments/recsys/check_breakdown.py
e6b2455d64266df3f2a62f9bc5359b91ddd80588c109a6cae3efde66abceb74c  $HR/experiments/recsys/breakdown.py
f6742a6e473ec417f394cf2acf541f4fd1209d7ac523bbfb253e81c7b5f6f439  $HR/experiments/recsys/precheck.sh
b19dbeb73762a0c3f9a7832a14e229ca4855b71364f1a64ee2b7b1a2a944fe7d  $HR/experiments/recsys/stats_snap.py
1edcdda88f30200fd55c1b5a18cb4b9d6db57aa02647f8ad549e4e7f6aabb31f  $HR/experiments/vectordb/host-gate.sh
1baccf944c1ac66fce65b065c1043529cd72bc08b38f4b42fe43bd2640076031  $HR/experiments/vectordb/pretouch-gate.sh
68327dd3178d7af5b0ad9c614f0a6c41b4d99b2f6a23cf456f7751273996eecf  $HR/scripts/host/measure-env.sh
fb17ee4445d4d5cb105b787d2c6bfeae5956b2ba9f852cb1eadf7caf759a6a8a  $HR/scripts/guest/recsys-node.sh
f2fe8c045490a26ad5b01631ca896b997b1fdad6f08ee20d1b314f64fe6fcc1e  $HR/systems/megalon/recsys-2vm.yaml
eeb6b23f173d85a3c86ade0fb804b363e3c84a36bf9c0f56a7cbcab25e738b53  $HR/config/cxl_region.yaml
6470d54b3727164cc765072e9a87b5573264b6b4b2d016d0b71309fbeb2b50e1  $HR/experiments/loadgen/stats_delta.py
c4142bdb0aeb0ea66c337b886086ca0b9540dbd0fcc20739529c520adce0f370  $HR/experiments/loadgen/export_csv.py"
