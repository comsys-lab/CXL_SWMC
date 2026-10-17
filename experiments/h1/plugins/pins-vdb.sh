# H1 plugin: vector DB (HNSW 28M, pubmed-a27m-b1m-q10k; reports/VDB-V1-packet.md v1.3.1 blocks). FILL_* after VDB-V1 PASS.
# all-HWcc = plain server (no Megalon; MOT1 v6 §3.1), Popcorn = plain server + cxl_shm (init_state=shared + preload,
# recv_mode poll), Megalon = vdb-megalon on Megalon 77 (packed4, 32 MiB vector chunk object).
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=FILL_vdb_harness_root            # frozen harness snapshot or CXL_SWMC at the pinned commit (VDB-V1 v1.3.1: a8c7fa77a or later)
HOOK_FILE=$HR/experiments/vectordb/v6-block.sh
BLOCK_CMD=(bash $HOOK_FILE)          # H1 hook = H1MODE=slo|fix in v6-block.sh (to be added by the vector DB owner)
BLOCK_ENV=(KPOP=$KPOP GTPOP=$GTPOP CPOP=$CPOP MEG_LIB=$MEG77 MEGALON_LEAN=1 EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  PLAIN_BUILD=$P/builds/vdb/15 VPLAIN=/home/comsys/vdb15
  MEG_BUILD=$P/builds/vdb-megalon/14 VMEG=/home/comsys/vdbm14-28m MEG_CFG=$HR/systems/megalon/vectordb-2vm.yaml
  LOADGEN_BUILD=$P/builds/vdb-loadgen/5)
PIN_SHA256="$COMMON_SHA256
FILL_vdb15_manifest_sha256  $P/builds/vdb/15/manifest.txt
FILL_vdbm14_manifest_sha256  $P/builds/vdb-megalon/14/manifest.txt
FILL_vdb_hook_sha256  $HOOK_FILE"
