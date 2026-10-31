# h2n De Stijl v2 pins (H2N_PINS=pins-vdb-ds.sh; template conf h2n-ds.conf): pins-vdb-sq8-lg12.sh with VDB_PLAIN_BUILD =
# builds/vdb/22 (libdestijl vdb-server, -DCXL_REGION_DESTIJL, proc_stats.h with the kernel De Stijl counter list:
# commit e40bc920a of branch destijl-v2-harness, dirty 0; manifest 61d8a5ca..., vdb-server aeb0248a...), without the
# Megalon builds (no mg lifetime in a ds block), plus the De Stijl bundle (packet.sha256 of builds/destijl/1/deploy-v1)
# and the De Stijl region config (H2N_DS_REGION, default this tree's config/cxl_region-destijl.yaml, as runset-h2n.sh).
# Re-pin mechanically when h2n-ds.conf changes one (e.g. the build-4 bundle: H2N_DS_C / H2N_DS_BUNDLE_SHA + this line).
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
DSR=${H2N_DS_REGION:-$(cd "$EVD/../.." && pwd)/config/cxl_region-destijl.yaml}
PIN_SHA256="61d8a5caec9599e078ee6c254b3d7eb8f34cbcf06db13890ba664c7d8d00fd76  $VDB_PLAIN_BUILD/manifest.txt
aeb0248ae7debe3f246e6d40fd51c79ec58bfcf04b24b14e64fc20744c05f63e  $VDB_PLAIN_BUILD/bin/vdb-server
6e3149a1ff26bddcb62d0c5b80026f53cdc43682d5b16c7c1fdffb34cd60e023  $VDB_LOADGEN_BUILD/manifest.txt
82da28d45a32c68246d5ca0402c3c7dfc28394a165f4bb16dfa167c2c5058927  $VDB_LOADGEN_BUILD/loadgen
88692448ee780398254b5683f07af35769dc1156d778cd50def0b049a1505436  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
f656925ab46baa4ce41978f35037fcd657bc023816a9e44bad6bb5ee51ef13ea  $H2N_DS_C/packet.sha256
2271c5285b3406e65c2ad2edad614ab713616e0eacc8ab03cdbfb985612dc2ac  $DSR
47726266e09a8f44f002919bb02de94e46811e7448f1ab0faabf2125897422fb  $H2N_HOST_IMAGE/SHA256SUMS
383ea4900e91a0c12a0a3c5ac7a84dfd9c41832ac537436ed013bbe6defc9561  $P/builds/vdb-inputs/3/SHA256SUMS
7ab229350d29387d01c0b5cdede485bb427bba0de15ea67262d3a77f64b9e081  $VDB_X_WRITES"
