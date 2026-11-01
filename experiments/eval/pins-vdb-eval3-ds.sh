# pins-vdb-eval3-ds.sh (2026-11-02, experiment de-stijl-evaluation-run1; confs eval3-a.conf, eval3-b2.conf,
# eval3-e-vdb-ds.conf): the inputs of pins-vdb-ds-54m.sh (vdb/22 libdestijl server, loadgen/12, ring2m + De Stijl
# regions, 54M SQ8 image, builds/vdb-inputs/5 data + writes) with the Popcorn and De Stijl bundles pinned through the
# conf's POP_BUNDLE_SHA / H2N_DS_BUNDLE_SHA (runset-h2n.sh checks the same values), so a new deploy-v<N> bundle
# (one per De Stijl deploy) is a conf-only re-pin. The N = 4 / 8 writes files are checked by h2n-block.sh (targets).
P=/home/comsys/sungsu/destijl-control
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
DSR=${H2N_DS_REGION:-$(cd "$EVD/../.." && pwd)/config/cxl_region-destijl.yaml}
PIN_SHA256="61d8a5caec9599e078ee6c254b3d7eb8f34cbcf06db13890ba664c7d8d00fd76  $VDB_PLAIN_BUILD/manifest.txt
aeb0248ae7debe3f246e6d40fd51c79ec58bfcf04b24b14e64fc20744c05f63e  $VDB_PLAIN_BUILD/bin/vdb-server
6e3149a1ff26bddcb62d0c5b80026f53cdc43682d5b16c7c1fdffb34cd60e023  $VDB_LOADGEN_BUILD/manifest.txt
82da28d45a32c68246d5ca0402c3c7dfc28394a165f4bb16dfa167c2c5058927  $VDB_LOADGEN_BUILD/loadgen
$POP_BUNDLE_SHA  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
$H2N_DS_BUNDLE_SHA  $H2N_DS_C/packet.sha256
2271c5285b3406e65c2ad2edad614ab713616e0eacc8ab03cdbfb985612dc2ac  $DSR
bb52e76c5f2bedbe8661e61026cc8c7c267f4c310465cfa29ffddae002bd971f  $H2N_HOST_IMAGE/SHA256SUMS
925e5a0c57bbccdaeab2d4fe17fcf5871559d90c9a1af6af62626aa1a6b05afc  $P/builds/vdb-inputs/5/SHA256SUMS
8ad2e82a3710ef331c50ea8c2fc1f1fad29b536611a0e850030af4c0d9a3e0a1  $VDB_X_WRITES"
