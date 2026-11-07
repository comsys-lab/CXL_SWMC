# pins-vdb-megalon-ideal.sh (2026-11-08, experiment megalon-ideal-record; confs
# workspaces/megalon-ideal/eval-megalon-ideal-{u50,u10,u90}.conf): pins-vdb-megalon-page-v2.sh with the element-object
# build builds/vdb-megalon/21-n2 (branch megalon-ideal c770e0fad) on builds/megalon/80-n2 (unchanged), the ideal YAML
# systems/megalon/vectordb-2vm-ideal.yaml, the Megalon region config/cxl_region-megalon-ideal.yaml (H2N_MG_REGION) and
# the 4 KiB-page packed image workspaces/megalon-page/image-c4k (the only accepted image). REGION stays the run-2
# ring2m region (plain install + Popcorn ring check).
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
case ${H2N_HOST_IMAGE#$P/} in   # evalconf.py shell exports absolute paths
  workspaces/megalon-page/image-c4k) _img=91b58320dee04efd37bcfe3e1a1782afa6886861727cee6f4aad5e7e188d00bb;;
  *) _img=unpinned-image-$H2N_HOST_IMAGE;;   # any other image fails the pin check
esac
PIN_SHA256="de3d8480fe7fcf606d0190013b879b5ab713b37f29567ca4ec4633889d77ec17  $VDB_PLAIN_BUILD/manifest.txt
bd0365b365542aa2efd78055b7977cea5268daf9348f40c90b2cf9d3603203dd  $VDB_PLAIN_BUILD/bin/vdb-server
6e3149a1ff26bddcb62d0c5b80026f53cdc43682d5b16c7c1fdffb34cd60e023  $VDB_LOADGEN_BUILD/manifest.txt
82da28d45a32c68246d5ca0402c3c7dfc28394a165f4bb16dfa167c2c5058927  $VDB_LOADGEN_BUILD/loadgen
$POP_BUNDLE_SHA  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
421b445cf5fa4bf5b043974d47c2e2ad9f6a5c3d81b3fa8de12c6047ad8a431a  ${H2N_MG_REGION:-unset-H2N_MG_REGION}
$_img  $H2N_HOST_IMAGE/SHA256SUMS
925e5a0c57bbccdaeab2d4fe17fcf5871559d90c9a1af6af62626aa1a6b05afc  $P/builds/vdb-inputs/5/SHA256SUMS
8ad2e82a3710ef331c50ea8c2fc1f1fad29b536611a0e850030af4c0d9a3e0a1  $VDB_X_WRITES
d37c34e5c9d35349246b1e43331d975a89630aa920a2308e6af61dbbe749cd63  $H2N_MG_BUILD_N2/manifest.txt
2fb12b9afe6ccbf585020263837fb07b1ba569b8a89a1e8f883c86d023a5b42d  $H2N_MG_BUILD_N2/bin/vdb-server
b2e04985143cf3881a64a7112d9ef677bc58951d79af9ccc38d903e5d15a8e40  $H2N_MG_LIB_N2/manifest.txt
7336464397484f00e80006c55d7ddba42b4f0657b63b9a419c30d9f095038da7  $H2N_MG_CFG_N2"
unset _img
