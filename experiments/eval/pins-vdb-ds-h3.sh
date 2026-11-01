# H3 vector DB De Stijl v2 pins (H3_PINS=pins-vdb-ds-h3.sh; template conf h3-ds.conf, runset-h3-vdb.sh): pins-vdb.sh
# with VDB_PLAIN_BUILD = builds/vdb/22 (libdestijl vdb-server, commit e40bc920a dirty 0; manifest 61d8a5ca...,
# vdb-server aeb0248a...; fp32 like vdb/17), without the Megalon lines (H3 has no Megalon), plus the De Stijl bundle
# (H3_DS_C packet.sha256) and region config (H3_DS_REGION, default this tree's config/cxl_region-destijl.yaml, as
# lib.sh h3_ds_env). Re-pin mechanically when h3-ds.conf changes one.
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
DSR=${H3_DS_REGION:-$(cd "$EVD/../.." && pwd)/config/cxl_region-destijl.yaml}
PIN_SHA256="61d8a5caec9599e078ee6c254b3d7eb8f34cbcf06db13890ba664c7d8d00fd76  $VDB_PLAIN_BUILD/manifest.txt
aeb0248ae7debe3f246e6d40fd51c79ec58bfcf04b24b14e64fc20744c05f63e  $VDB_PLAIN_BUILD/bin/vdb-server
016141213df76a081c15e4092552d8d913cdffbc9710c8c57793fa02e19cb38f  $VDB_LOADGEN_BUILD/manifest.txt
ce54703ad8c48837ea9bcba745c768f4f729414e2386d40716be6957781afaeb  $VDB_LOADGEN_BUILD/loadgen
88692448ee780398254b5683f07af35769dc1156d778cd50def0b049a1505436  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
f656925ab46baa4ce41978f35037fcd657bc023816a9e44bad6bb5ee51ef13ea  $H3_DS_C/packet.sha256
2271c5285b3406e65c2ad2edad614ab713616e0eacc8ab03cdbfb985612dc2ac  $DSR
e9d4942ee33b2f65cf7117d87942296e1365d0234873c2c4159545f40708db54  $P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1/SHA256SUMS
383ea4900e91a0c12a0a3c5ac7a84dfd9c41832ac537436ed013bbe6defc9561  $P/builds/vdb-inputs/3/SHA256SUMS
7ab229350d29387d01c0b5cdede485bb427bba0de15ea67262d3a77f64b9e081  $VDB_X_WRITES"
