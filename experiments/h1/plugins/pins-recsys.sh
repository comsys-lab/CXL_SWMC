# H1 plugin: DLRM recsys (26 tables, 134.2M rows x 576 B = 77.29 GB, direct addressing, MLPerf day-23 trace;
# reports/RECSYS-V1-packet.v1.4.md blocks). all-HWcc = PLAIN plain, Popcorn = PLAIN + cxl_shm build 12
# (init_state=shared + preload, recv_mode poll), Megalon = recsys-megalon/14 on Megalon 77 with ONE OBJECT PER
# EMBEDDING TABLE (MG_RPO_OPT N = MG_TABLE_N = 0; main configuration, reports/PAPER-direction-2026-10-18.md §5.5),
# mgoff = the same with MEGALON_COH_TIMERS=0. The per-row variant (N = 1, "mgrow") is RECSYS-V1 v1.4 only; it is not
# an H1 system (H1-HOOK v2 / check.py / collect.py know hw pop mg mgoff only; open question in H1 packet v0.6.6).
# Mixes = EKKO avg / peak. Re-pinned 2026-10-18 (branch recsys-v14) for the table-object builds.
# TODO(recsys-table): PLAIN = builds/recsys/11 (guest /home/comsys/rs11) unless builds/recsys/12 is built from the
#   merged recsys-table commit (then recsys/12 + /home/comsys/rs12); every FILL_RECSYS_TABLE token below is not a
#   sha256 on purpose, so hook.sh refuses this plugin until the builds exist and the lines are filled.
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=$P/CXL_SWMC                      # live tree (main-block.sh resolves session.sh / v1_check.py / host-gate.sh next to itself)
HOOK_FILE=$HR/experiments/recsys/main-block.sh
BLOCK_CMD=(bash $HOOK_FILE)          # H1 hook = BLOCK=h1 in main-block.sh (marker H1-HOOK v2: H1MODE r1|cont)
BLOCK_ENV=(BLOCK=h1 POP_BUILD=12 POP_BUNDLE_SHA=$POP_BUNDLE_SHA C8=$CPOP K8=$KPOP GT8=$GTPOP RECV_MODE=$RECV_MODE
  D=$P/builds/recsys-inputs/1 PLAIN_BUILD=$P/builds/recsys/11 MEG_BUILD=$P/builds/recsys-megalon/14 MEGALON_BASE=$MEG77
  VM_PLAIN=/home/comsys/rs11 VM_MEG=/home/comsys/rsm14 LOADGEN=$P/builds/recsys-loadgen/9/loadgen XT=7200
  MG_RPO_OPT=--mg-rows-per-object MG_TABLE_N=0
  EXPECT_DAX_UUID=$EXPECT_DAX_UUID)
PIN_SHA256="$COMMON_SHA256
9c330ba688b96019792dee4bb80e91965cfb7e5d5c21265bb3a2e805df3db5a8  $P/builds/recsys-inputs/1/MANIFEST.txt
83e7048cb5d727ae50e5492c8a6c84e123b5190bc8bbbbdc89d71e625fbe522a  $P/builds/recsys-inputs/1/rate-frac0.0043.txt
1df9b01d68d56d4aed1e24538945a44623863bf424c36a56cfa732c6ea16073c  $P/builds/recsys-inputs/1/rate-frac0.000513333333.txt
a88297c0c87b53bdb8dc73c75f912f1cb424d7a5da62bd55053e497e7cd1862f  $P/builds/recsys/11/manifest.txt
8ad5aa7faa8d75b3448f90ef0f328c41dc44c090f84622eceaae59514bc974cb  $P/builds/recsys/11/bin/recsys-server
f6dd0caa69620b46954849c7230584f4b81c0ba0fea2e7cb8720ce968e64c3c9  $P/builds/recsys/11/bin/recsys-rate
FILL_RECSYS_TABLE  $P/builds/recsys-megalon/14/manifest.txt
FILL_RECSYS_TABLE  $P/builds/recsys-megalon/14/bin/recsys-server
FILL_RECSYS_TABLE  $P/builds/recsys-megalon/14/lib/libmegalon-objapi.so
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $P/builds/recsys-megalon/14/lib/libmegalon.so
de2e9a4cd7ee41df5d9a938836802b0ee5186ba69b42252e3ab747f0bfeae193  $P/builds/recsys-loadgen/9/manifest.txt
61bb70687ef15823a33a56c282d53eecdbcc1c1e574589eeba7791b4a65d81c0  $P/builds/recsys-loadgen/9/loadgen
FILL_RECSYS_TABLE  $HOOK_FILE
68c5b9ceaf986e9e05e941d586a9a5cb5bb162b1963181ce02efa5d34cce5b54  $HR/experiments/recsys/session.sh
FILL_RECSYS_TABLE  $HR/experiments/recsys/v1_check.py
32d171199d6a47d15fcfa6971522e253fe21d857e91c9049c201e55a0cdac230  $HR/experiments/recsys/check_breakdown.py
e6b2455d64266df3f2a62f9bc5359b91ddd80588c109a6cae3efde66abceb74c  $HR/experiments/recsys/breakdown.py
f6742a6e473ec417f394cf2acf541f4fd1209d7ac523bbfb253e81c7b5f6f439  $HR/experiments/recsys/precheck.sh
b19dbeb73762a0c3f9a7832a14e229ca4855b71364f1a64ee2b7b1a2a944fe7d  $HR/experiments/recsys/stats_snap.py
1edcdda88f30200fd55c1b5a18cb4b9d6db57aa02647f8ad549e4e7f6aabb31f  $HR/experiments/vectordb/host-gate.sh
1baccf944c1ac66fce65b065c1043529cd72bc08b38f4b42fe43bd2640076031  $HR/experiments/vectordb/pretouch-gate.sh
68327dd3178d7af5b0ad9c614f0a6c41b4d99b2f6a23cf456f7751273996eecf  $HR/scripts/host/measure-env.sh
0edfe4997688007e6281ba1120885ae1eba226dd09602718fd513bf62576ed8c  $HR/experiments/h1/h1-gate.sh
aed8d7f32871398db375c502152587ee0b25a716dd60d4ff637e189aa3d42420  $HR/scripts/host/measure-run.sh
1f3fe160a17138beb6dba1acd19369e703dc90223bb96d9b0f0f3de93ae5db14  $HR/scripts/host/measure-env-part.sh
fb17ee4445d4d5cb105b787d2c6bfeae5956b2ba9f852cb1eadf7caf759a6a8a  $HR/scripts/guest/recsys-node.sh
FILL_RECSYS_TABLE  $HR/systems/megalon/recsys-2vm.yaml
eeb6b23f173d85a3c86ade0fb804b363e3c84a36bf9c0f56a7cbcab25e738b53  $HR/config/cxl_region.yaml
6470d54b3727164cc765072e9a87b5573264b6b4b2d016d0b71309fbeb2b50e1  $HR/experiments/loadgen/stats_delta.py
fe35a89936c8da64a97a468b2429ad61062bd499a0fb775a1a003437366cc701  $HR/experiments/loadgen/export_csv.py"
