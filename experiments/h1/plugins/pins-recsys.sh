# H1 plugin: DLRM recsys (26 tables, 167.7M rows x 576 B, MLPerf day-23 trace; reports/RECSYS-V1-packet.md v1.2.1).
# FILL_* after RECSYS-V1 PASS. all-HWcc = recsys/9 plain, Popcorn = recsys/9 + cxl_shm (preload), Megalon =
# recsys-megalon/11 on Megalon 77 (one object per 576 B row). Mixes = EKKO avg / peak (two; draft §1 has no balanced mix).
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=FILL_recsys_harness_root
HOOK_FILE=$HR/experiments/recsys/main-block.sh
BLOCK_CMD=(bash $HOOK_FILE)          # H1 hook = BLOCK=h1 in main-block.sh (to be added by the recsys owner)
BLOCK_ENV=(BLOCK=h1 POP_BUILD=12 POP_BUNDLE_SHA=$POP_BUNDLE_SHA C8=$CPOP K8=$KPOP GT8=$GTPOP RECV_MODE=$RECV_MODE
  D=$P/builds/recsys-inputs/1 PLAIN_BUILD=$P/builds/recsys/9 MEG_BUILD=$P/builds/recsys-megalon/11 MEGALON_BASE=$MEG77
  VM_PLAIN=/home/comsys/rs9 VM_MEG=/home/comsys/rsm11 LOADGEN=$P/builds/recsys-loadgen/7/loadgen XT=7200)
PIN_SHA256="$COMMON_SHA256
9c330ba688b96019792dee4bb80e91965cfb7e5d5c21265bb3a2e805df3db5a8  $P/builds/recsys-inputs/1/MANIFEST.txt
FILL_recsys9_manifest_sha256  $P/builds/recsys/9/manifest.txt
FILL_recsysm11_manifest_sha256  $P/builds/recsys-megalon/11/manifest.txt
FILL_recsys_hook_sha256  $HOOK_FILE"
