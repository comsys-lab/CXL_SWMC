# pins-vdb-megalon-page.sh (2026-11-06, experiment megalon-page-granularity; conf
# workspaces/megalon-page/eval-megalon-page-u50.conf): the run-2 vector DB pins (pins-vdb-run2.sh: plain server
# builds/vdb/24, loadgen/12, Popcorn bundle, region, builds/vdb-inputs/5 data + writes) with the page-layout inputs
# instead of the chunk ones: Megalon vdb build builds/vdb-megalon/18-n2 (branch megalon-page-vdb d0d84225f, on
# builds/megalon/79-n2 = Megalon c803c64 with the lookup histogram), the 4 KiB-page packed init image
# workspaces/megalon-page/image-c4k (relayout of builds/vdb-index-sq8/2, same graph) and the c4k Megalon YAML.
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
PIN_SHA256="de3d8480fe7fcf606d0190013b879b5ab713b37f29567ca4ec4633889d77ec17  $VDB_PLAIN_BUILD/manifest.txt
bd0365b365542aa2efd78055b7977cea5268daf9348f40c90b2cf9d3603203dd  $VDB_PLAIN_BUILD/bin/vdb-server
6e3149a1ff26bddcb62d0c5b80026f53cdc43682d5b16c7c1fdffb34cd60e023  $VDB_LOADGEN_BUILD/manifest.txt
82da28d45a32c68246d5ca0402c3c7dfc28394a165f4bb16dfa167c2c5058927  $VDB_LOADGEN_BUILD/loadgen
$POP_BUNDLE_SHA  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
bab74d2ee37e688f9201a2b559140050bc7fcade008b24fecc73e77b642c259c  $H2N_HOST_IMAGE/SHA256SUMS
925e5a0c57bbccdaeab2d4fe17fcf5871559d90c9a1af6af62626aa1a6b05afc  $P/builds/vdb-inputs/5/SHA256SUMS
8ad2e82a3710ef331c50ea8c2fc1f1fad29b536611a0e850030af4c0d9a3e0a1  $VDB_X_WRITES
cddc1dfe1ff6f509c4f9ffa97c1d5bd0e2985a1266b07fbdc88eb7ca791c4909  $H2N_MG_BUILD_N2/manifest.txt
2ff5d68ccb41acd33d01d09ddb6a8e25ac5a52b633e02a3a62c2cc40aeef773d  $H2N_MG_BUILD_N2/bin/vdb-server
4f8e85dccd7c5626303434a955ccc8f857be20cbc30272ba523bc6f2a32e4c5f  $H2N_MG_LIB_N2/manifest.txt
eca135e1491cb12a80f4509fb80ee5f0d2b775f2e7be5189a514091bdf27bebc  $H2N_MG_CFG_N2"
