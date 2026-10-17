# H1 plugin: LMDB (1M records, 4 KiB B+tree pages = Megalon objects; reports/LMDB-F1-packet.md v1.5). FILL_* after
# LMDB-F1 PASS. all-HWcc = lmdb/8 plain, Popcorn = lmdb/8 + cxl_shm, Megalon = lmdb-megalon/8 on Megalon 77.
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=FILL_lmdb_harness_root           # recovery/LMDB-F1-v1.5-pre/harness/CXL_SWMC (frozen) or a new H1 freeze
HOOK_FILE=FILL_lmdb_main_block      # LMDB has no SLO/main block yet (f1-block.sh is functional only): owner adds one
BLOCK_CMD=(bash $HOOK_FILE)
BLOCK_ENV=(BUILD_PIN=FILL_lmdb_build_pin MEGALON_BUILD_N=77 EXPECT_K=$KPOP
  PLAIN_BUILD=$P/builds/lmdb/8 MEG_BUILD=$P/builds/lmdb-megalon/8 LOADGEN_BUILD=$P/builds/lmdb-loadgen/7
  LMDB_GUEST_DIR=/home/comsys/lmdb8 IMG=FILL_lmdb_image_dir C8=$CPOP K8=$KPOP GT8=$GTPOP RECV_MODE=$RECV_MODE)
PIN_SHA256="$COMMON_SHA256
FILL_lmdb8_manifest_sha256  $P/builds/lmdb/8/manifest.txt
FILL_lmdbm8_manifest_sha256  $P/builds/lmdb-megalon/8/manifest.txt
FILL_lmdblg7_manifest_sha256  $P/builds/lmdb-loadgen/7/manifest.txt
FILL_lmdb_hook_sha256  $HOOK_FILE"
