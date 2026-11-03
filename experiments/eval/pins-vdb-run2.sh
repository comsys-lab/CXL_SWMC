# pins-vdb-run2.sh (2026-11-03, experiment de-stijl-evaluation-run2; confs eval-run2-vdb*.conf): ONE vector DB server
# for hw, pop and ds = builds/vdb/23 (slot-zero + stale-header guard, libdestijl; branch run2-vdb-slotfix 0c673b714),
# Megalon = builds/vdb-megalon/17-n2 / -n4 / -n8 (same source, megalon 78-n*), loadgen/12, 54M SQ8 image,
# builds/vdb-inputs/5 data + writes. Bundles through the conf's POP_BUNDLE_SHA / H2N_DS_BUNDLE_SHA (re-pin = conf only);
# the Megalon and De Stijl lines join only when the conf names them (a ds conf has no H2N_MG_*, a hw/pop/mg conf no
# H2N_DS_*). The N = 4 / 8 writes files are checked by h2n-block.sh (targets).
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
PIN_SHA256="e0c05ac2723845a49327073300bf88ee1464dba50fe4e857640209e81a4d5bf2  $VDB_PLAIN_BUILD/manifest.txt
6cea12e938bd052424788e77b8533cf675689151e2042bd68ca6b444d8f76fc4  $VDB_PLAIN_BUILD/bin/vdb-server
6e3149a1ff26bddcb62d0c5b80026f53cdc43682d5b16c7c1fdffb34cd60e023  $VDB_LOADGEN_BUILD/manifest.txt
82da28d45a32c68246d5ca0402c3c7dfc28394a165f4bb16dfa167c2c5058927  $VDB_LOADGEN_BUILD/loadgen
$POP_BUNDLE_SHA  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
bb52e76c5f2bedbe8661e61026cc8c7c267f4c310465cfa29ffddae002bd971f  $H2N_HOST_IMAGE/SHA256SUMS
925e5a0c57bbccdaeab2d4fe17fcf5871559d90c9a1af6af62626aa1a6b05afc  $P/builds/vdb-inputs/5/SHA256SUMS
8ad2e82a3710ef331c50ea8c2fc1f1fad29b536611a0e850030af4c0d9a3e0a1  $VDB_X_WRITES"
_mgm() { case $1 in 2) echo c7545ddf505cfa575573df08e49bb43ed4c223ad0a38d6bbb377e26d27a9b61c;;
  4) echo ad318cb81f029338bd3707771d5649448037bc9fc7d6865622bc8dc710faa099;;
  8) echo 21cdf320bf07f25e19c124d20b295d6e3385fa86c219e0cc3b4eadb4f77a1c9d;; esac; }
for _n in 2 4 8; do
  _b=H2N_MG_BUILD_N$_n
  [ -n "${!_b:-}" ] || continue
  PIN_SHA256+="
$(_mgm $_n)  ${!_b}/manifest.txt
80cce6fd3efaac1dfb4fefcce39afc8f78a521d0e951d0beb875d941ff0fc6e2  ${!_b}/bin/vdb-server"
done
if [ -n "${H2N_DS_C:-}" ]; then
  DSR=${H2N_DS_REGION:-$(cd "$EVD/../.." && pwd)/config/cxl_region-destijl.yaml}
  PIN_SHA256+="
$H2N_DS_BUNDLE_SHA  $H2N_DS_C/packet.sha256
2271c5285b3406e65c2ad2edad614ab713616e0eacc8ab03cdbfb985612dc2ac  $DSR"
fi
