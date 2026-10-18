# H1 plugin: DLRM recsys (26 tables, 134.2M rows x 576 B = 77.29 GB, direct addressing, MLPerf day-23 trace;
# reports/RECSYS-V1-packet.v1.4.md blocks). all-HWcc = PLAIN plain, Popcorn = PLAIN + cxl_shm build 12
# (init_state=shared + preload, recv_mode poll), Megalon = recsys-megalon/14 on Megalon 77 with ONE OBJECT PER
# EMBEDDING TABLE (MG_RPO_OPT N = MG_TABLE_N = 0; main configuration, reports/PAPER-direction-2026-10-18.md §5.5),
# mgoff = the same with MEGALON_COH_TIMERS=0. The per-row variant (N = 1, "mgrow") is RECSYS-V1 v1.4 only; it is not
# an H1 system. v0.6.7 (user decision 2026-10-18 "그냥 recsys는 megalon 측정 하지마"): H1 RecSys measures hw and pop
# only (experiments/h1/h1sys.py -> H1_SYSTEMS="hw pop"); the Megalon settings below stay pinned but no mg / mgoff
# lifetime runs; the Megalon RecSys numbers come from RECSYS-V1 v1.4.
# Mixes = EKKO avg / peak. Re-pinned 2026-10-18 (branch recsys-v14) for the table-object builds.
# Re-pinned 2026-10-18 (H1 v0.6.8, branch h1-v068): main-block.sh (h1_slo loadgen --tol 0.02) and v1_check.py (updater
# keep-up judged against updates sent, not the nominal offered rate); builds and inputs unchanged.
# Plain = builds/recsys/12 (same source 77ba0fa69 as recsys-megalon/14; server.cc is shared, so the older plain build
# is not used), guest dirs /home/comsys/rs12 and /home/comsys/rsm14 (installed by RECSYS-V1 v1.4). --mg-rows-per-object
# has no default and is required with --backend megalon (main-block.sh passes MG_RPO_OPT MG_TABLE_N to mg and mgoff).
# MG_COH_SAMPLE=1: every Megalon section timed (RECSYS-V1 v1.4 user decision 2026-10-18 for the table objects, ~26
# write sections per round; user: every-section timing also in H1, Q-H5 decided; unused while recsys has no Megalon).
# Re-pinned 2026-10-18 (H1 v0.6.9, branch h1-v069; user decision "T=1로 바로 가는게 좋아보여"): publication period
# T = 1 s (RS_T_MS=1000) with the T = 1 s Ekko calibration builds/recsys-calib/1 (v0.6.10: calib/2, same update sample rates as T = 60 s:
# avg 14.7233, peak 188.7608 samples/s; rows_per_round_target avg 2,044, peak 19,192); main-block.sh (RS_T_MS,
# RATE_T_DIR) and v1_check.py (short-T rules) re-pinned; builds and builds/recsys-inputs/1 unchanged.
# Re-pinned 2026-10-18 (H1 v0.6.10, branch recsys-mid; user decision "3점 등비"): RATE_T_DIR = builds/recsys-calib/2
# (avg/peak files byte-identical to calib/1, plus the three intermediate Ekko points f087 / f149 / f253 and their
# T = 60 s references); main-block.sh (ekko_set points, EKKO_REF) re-pinned. The extra mixes run only through
# h1-main.sh --add-mixes (experiments/h1/h1-plan-extra.tsv); builds and builds/recsys-inputs/1 unchanged.
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=$P/CXL_SWMC                      # live tree (main-block.sh resolves session.sh / v1_check.py / host-gate.sh next to itself)
HOOK_FILE=$HR/experiments/recsys/main-block.sh
BLOCK_CMD=(bash $HOOK_FILE)          # H1 hook = BLOCK=h1 in main-block.sh (marker H1-HOOK v2: H1MODE r1|cont)
BLOCK_ENV=(BLOCK=h1 POP_BUILD=12 POP_BUNDLE_SHA=$POP_BUNDLE_SHA C8=$CPOP K8=$KPOP GT8=$GTPOP RECV_MODE=$RECV_MODE
  D=$P/builds/recsys-inputs/1 PLAIN_BUILD=$P/builds/recsys/12 MEG_BUILD=$P/builds/recsys-megalon/14 MEGALON_BASE=$MEG77
  VM_PLAIN=/home/comsys/rs12 VM_MEG=/home/comsys/rsm14 LOADGEN=$P/builds/recsys-loadgen/9/loadgen XT=7200
  MG_RPO_OPT=--mg-rows-per-object MG_TABLE_N=0 MG_COH_SAMPLE=1
  RS_T_MS=1000 RATE_T_DIR=$P/builds/recsys-calib/2
  EXPECT_DAX_UUID=$EXPECT_DAX_UUID)
PIN_SHA256="$COMMON_SHA256
9c330ba688b96019792dee4bb80e91965cfb7e5d5c21265bb3a2e805df3db5a8  $P/builds/recsys-inputs/1/MANIFEST.txt
83e7048cb5d727ae50e5492c8a6c84e123b5190bc8bbbbdc89d71e625fbe522a  $P/builds/recsys-inputs/1/rate-frac0.0043.txt
1df9b01d68d56d4aed1e24538945a44623863bf424c36a56cfa732c6ea16073c  $P/builds/recsys-inputs/1/rate-frac0.000513333333.txt
00509e86af9a7391dbb2dd78821d8f15711fca4f9432e7b474652bb1368d5a22  $P/builds/recsys-calib/2/MANIFEST.txt
15a20f7c01314a3b44c6b4e2561379146321aeea4c732017e16fe723b9aa28ce  $P/builds/recsys-calib/2/rate-T1000-peak.txt
3b70e3e27b2f703916eccc535ab45bab7b8290b2373d56429ed2674881a6ea3c  $P/builds/recsys-calib/2/rate-T1000-avg.txt
a7389cd13e9d2b1e60e160e34862197aafb6e0ed7925e90e23dd5a001a590463  $P/builds/recsys-calib/2/rate-T1000-f087.txt
6a43d3ae7479b308ddf028fdb2a08c63169e5adacb214b35af85a220650920e8  $P/builds/recsys-calib/2/rate-T1000-f149.txt
ac8181e9c34d31a7d094812298834f269002fcd35ba6d8f093734aaaee7b5965  $P/builds/recsys-calib/2/rate-T1000-f253.txt
286172345cafe1e06180696a1a531f0a30ca6fc37b8582b27e71904e4e186568  $P/builds/recsys-calib/2/rate-frac0.000874.txt
451d588553b83f746bc1b048740526f9f613860852e26a1aa56d07d1141d4e4f  $P/builds/recsys-calib/2/rate-frac0.00149.txt
c817114a34c0cb83886b5fb286f9956117affdeb6fb049209ab8ac8a017a8550  $P/builds/recsys-calib/2/rate-frac0.00253.txt
564c1b823ce144f02565f6404c221b56a362c275ae787d1ad67076c9a26ca684  $P/builds/recsys/12/manifest.txt
1b502b6220ff1ba17cd944d0884ddee6a1dceeda5c8579298b27736294660cd3  $P/builds/recsys/12/bin/recsys-server
9ba94ba5e75982ab0eb9ba6aa5d4b9fcb784518bc271a50ce0245720342442a5  $P/builds/recsys/12/bin/recsys-rate
8cb4c809fcf332e606ecf16a5846f664109ad0db2ba8837018fdadc5d5ee7a4f  $P/builds/recsys-megalon/14/manifest.txt
0c67cca57e08e1a74f0c845bea0fbd5445160d12a2c49c212d0f8ed4e3216f2a  $P/builds/recsys-megalon/14/bin/recsys-server
7ffaa297b593d04e67943f92c4f880bf02b439be74c409adc2febcd780d4b4af  $P/builds/recsys-megalon/14/lib/libmegalon-objapi.so
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $P/builds/recsys-megalon/14/lib/libmegalon.so
de2e9a4cd7ee41df5d9a938836802b0ee5186ba69b42252e3ab747f0bfeae193  $P/builds/recsys-loadgen/9/manifest.txt
61bb70687ef15823a33a56c282d53eecdbcc1c1e574589eeba7791b4a65d81c0  $P/builds/recsys-loadgen/9/loadgen
f7f0bbeb567b89c766d913f7f98becd29768a15e2ae900778471874a77f12ac7  $HOOK_FILE
68c5b9ceaf986e9e05e941d586a9a5cb5bb162b1963181ce02efa5d34cce5b54  $HR/experiments/recsys/session.sh
0bd4d06ea0b0678b77d1276aec2f13db70a8eceed7e7ab11f61905052e8ac4ac  $HR/experiments/recsys/v1_check.py
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
d744237dab0c8f84e7ccbf6395a7de83ef09306a7923a0f3323120e3ecd46dce  $HR/systems/megalon/recsys-2vm.yaml
eeb6b23f173d85a3c86ade0fb804b363e3c84a36bf9c0f56a7cbcab25e738b53  $HR/config/cxl_region.yaml
6470d54b3727164cc765072e9a87b5573264b6b4b2d016d0b71309fbeb2b50e1  $HR/experiments/loadgen/stats_delta.py
fe35a89936c8da64a97a468b2429ad61062bd499a0fb775a1a003437366cc701  $HR/experiments/loadgen/export_csv.py"
