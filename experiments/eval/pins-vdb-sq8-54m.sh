# eval2-h2.conf pins (H2N_PINS=pins-vdb-sq8-lg12.sh): pins-vdb-sq8.sh with the builds/vdb-loadgen/12 hashes (manifest
# pins-vdb-sq8-54m.sh (2026-10-30) = pins-vdb-sq8-lg12.sh with the 54M dataset: builds/vdb-inputs/5 (pool A 54,000,000 after
# exact doc/vec dedupe, pool B 3,400,000, writes vms2/4/8) and the 54M SQ8 image builds/vdb-index-sq8/2 (user 'approve 54M').
# 6e3149a1..., loadgen 82da28d4..., as pins-vdb-confirm12.sh; loadgen/12 = loadgen/11 + the past-the-knee options).
# Text of pins-vdb-sq8.sh:
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
6e3149a1ff26bddcb62d0c5b80026f53cdc43682d5b16c7c1fdffb34cd60e023  $VDB_LOADGEN_BUILD/manifest.txt
82da28d45a32c68246d5ca0402c3c7dfc28394a165f4bb16dfa167c2c5058927  $VDB_LOADGEN_BUILD/loadgen
88692448ee780398254b5683f07af35769dc1156d778cd50def0b049a1505436  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
bb52e76c5f2bedbe8661e61026cc8c7c267f4c310465cfa29ffddae002bd971f  $H2N_HOST_IMAGE/SHA256SUMS
925e5a0c57bbccdaeab2d4fe17fcf5871559d90c9a1af6af62626aa1a6b05afc  $P/builds/vdb-inputs/5/SHA256SUMS
8ad2e82a3710ef331c50ea8c2fc1f1fad29b536611a0e850030af4c0d9a3e0a1  $VDB_X_WRITES"
