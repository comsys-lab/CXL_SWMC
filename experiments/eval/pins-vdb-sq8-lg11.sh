# eval2-h2.conf pins (H2N_PINS=pins-vdb-sq8-lg11.sh): pins-vdb-sq8.sh with the builds/vdb-loadgen/11 hashes (manifest
# a4317882..., loadgen 902decfc..., as pins-vdb-confirm11.sh). Text of pins-vdb-sq8.sh:
# h2n SQ8 run sets pins (runset-h2n.sh with EVAL_CONF=h2n-sq8.conf, H2N_PINS=pins-vdb-sq8.sh): the non-code inputs of
# the SQ8 variant (builds of branch vdb-sq8, loadgen, Popcorn bundle, region, data, writes, the 28M SQ8 image).
# Megalon per-N builds are checked by h2n-block.sh (megalon_build / node count) and recorded in the run manifest; the
# N = 2 Megalon build is pinned here. Re-pin mechanically when h2n-sq8.conf changes one.
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
PIN_SHA256="cce76a593daefbf5d6b96a8dd22cd4b83284f18e1393c0981d36e8f94052a779  $VDB_PLAIN_BUILD/manifest.txt
50b149d8332110d4bd2efe46152545fd29f47abdf65a86526b1ef2a1a7834cd5  $VDB_PLAIN_BUILD/bin/vdb-server
8cd3d31e55dc45f23e9ceea00f90e67aadcdc2ba71764d15ffa1cd0152a1bcfa  $H2N_MG_BUILD_N2/manifest.txt
f2126c7e21c4bde44503a4ebc20e0b23d52a70bda81c64796b17b174db8fa7a7  $H2N_MG_BUILD_N2/bin/vdb-server
ddee8a19ecbefa25d7c8c45969e7b2037e5cc54b6afcefff95915e70f9a51ba7  $H2N_MG_BUILD_N4/manifest.txt
f2126c7e21c4bde44503a4ebc20e0b23d52a70bda81c64796b17b174db8fa7a7  $H2N_MG_BUILD_N4/bin/vdb-server
71923cff1fe56b547922274f113937d764ddf8eecbed88cc96e192e779ae6bd9  $H2N_MG_BUILD_N8/manifest.txt
f2126c7e21c4bde44503a4ebc20e0b23d52a70bda81c64796b17b174db8fa7a7  $H2N_MG_BUILD_N8/bin/vdb-server
a4317882d0667cb18f6e75c6641d6bdc574ae1bdcb81eee22d9291940c375e9d  $VDB_LOADGEN_BUILD/manifest.txt
902decfcd7aeb8cfdede862260025eae968d042b9bbb45564125db936499b2bf  $VDB_LOADGEN_BUILD/loadgen
88692448ee780398254b5683f07af35769dc1156d778cd50def0b049a1505436  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
47726266e09a8f44f002919bb02de94e46811e7448f1ab0faabf2125897422fb  $H2N_HOST_IMAGE/SHA256SUMS
383ea4900e91a0c12a0a3c5ac7a84dfd9c41832ac537436ed013bbe6defc9561  $P/builds/vdb-inputs/3/SHA256SUMS
7ab229350d29387d01c0b5cdede485bb427bba0de15ea67262d3a77f64b9e081  $VDB_X_WRITES"
