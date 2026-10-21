# Confirm-rule test pins (confirm-test.conf H2N_PINS): pins-vdb.sh with the loadgen of builds/vdb-loadgen/10 (branch
# confirm-rule c8b9224f7: --confirm-rule / --confirm-full); every other line unchanged. Text of pins-vdb.sh:
# Evaluation run set "vdb" pins (sourced by experiments/h1/hook.sh when EVAL_RUN is set; runset-vdb.sh). Same block and
# hook as the H1 vector DB plugin (v6-block.sh, H1-HOOK v2), with the evaluation's builds, region and Popcorn bundle
# from eval.conf (user decisions 2026-10-20: 28m-x pool B, 2 MiB message ring, threads = vCPUs via m4-run.sh EVAL_RUN).
# Code integrity: runset-vdb.sh requires a clean live CXL_SWMC and records its commit; the hashes below pin the
# non-code inputs (builds, data, region, Megalon config, Popcorn bundle). Re-pin mechanically when eval.conf changes one.
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
HOOK_FILE=$P/CXL_SWMC/experiments/vectordb/v6-block.sh   # v6-block.sh calls the live tree's m4-run.sh itself
BLOCK_CMD=(bash $HOOK_FILE)
BLOCK_ENV=(KPOP=$POP_K GTPOP=$POP_GT CPOP=$POP_C MEG_LIB=$MEG_LIB MEGALON_LEAN=1 EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  PLAIN_BUILD=$VDB_PLAIN_BUILD VPLAIN=$VDB_VPLAIN MEG_BUILD=$VDB_MEG_BUILD VMEG=$VDB_VMEG MEG_CFG=$VDB_MEG_CFG
  LOADGEN_BUILD=$VDB_LOADGEN_BUILD)
PIN_SHA256="ac9fd1cf9a2416a8df0f0fd98c95dca60a51d633cdd44bd3d0c05a95b7f7cc93  $VDB_PLAIN_BUILD/manifest.txt
cf02a2b44c3db84cb0c46497a3e227c6569276b8964fbe1de16a8b0e458feeb4  $VDB_PLAIN_BUILD/bin/vdb-server
65fa1fb1077aaac0fd9f1be947d76e90c84c633752d1e279ae1e68937b50e3e5  $VDB_MEG_BUILD/manifest.txt
5f1ff99101da18cd7f05d55c77444ea7a7cf94030e17bcf24050e0ebe12c0dbc  $VDB_MEG_BUILD/bin/vdb-server
8c59d1808ec569f54a05531610e3b9d18ae4563f9ebb5c264a657bd1edf3a3ac  $VDB_MEG_BUILD/lib/libmegalon-objapi.so
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $VDB_MEG_BUILD/lib/libmegalon.so
fa7fc9c2f9bc47cb5ba28286227c35f47c5c4b4b68a0bc8e0f55b915b87e251e  $VDB_LOADGEN_BUILD/manifest.txt
50c1334cd6a98f2f2e2f26dd81d430af53edf821ce309a0f08211991c538e0b0  $VDB_LOADGEN_BUILD/loadgen
88692448ee780398254b5683f07af35769dc1156d778cd50def0b049a1505436  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
4e4e7134710f9b131368d7b3f71c07ab56d97e72ad329649bda27f893f6d65be  $VDB_MEG_CFG
e9d4942ee33b2f65cf7117d87942296e1365d0234873c2c4159545f40708db54  $P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1/SHA256SUMS
383ea4900e91a0c12a0a3c5ac7a84dfd9c41832ac537436ed013bbe6defc9561  $P/builds/vdb-inputs/3/SHA256SUMS
7ab229350d29387d01c0b5cdede485bb427bba0de15ea67262d3a77f64b9e081  $VDB_X_WRITES"
