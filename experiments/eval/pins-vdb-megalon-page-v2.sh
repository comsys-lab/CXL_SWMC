# pins-vdb-megalon-page-v2.sh (2026-11-07, experiment megalon-page-granularity full run; confs
# workspaces/megalon-page/eval-megalon-page-full-page.conf and -full-chunk.conf): pins-vdb-megalon-page.sh (pilot) with
# the full-run builds: Megalon vdb build builds/vdb-megalon/20-n2 (branch megalon-page-vdb ba7c9d8fd: + shim v5
# wmeta_counts, stats megalon.reclaim_count / allocate_count) on builds/megalon/80-n2 (Megalon 0ad3d29: + GetWmetaCounts).
# One file for both layouts: the init image and Megalon YAML lines follow the conf's H2N_HOST_IMAGE / H2N_MG_CFG_N2 and
# only the two pinned pairs are accepted (page: 4 KiB-page packed image workspaces/megalon-page/image-c4k + c4k YAML;
# chunk: the run-2 chunk image builds/vdb-index-sq8/2/... + the run-2 YAML).
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"})"   # lib.sh exports EVAL_CONF
case ${H2N_HOST_IMAGE#$P/} in   # evalconf.py shell exports absolute paths
  workspaces/megalon-page/image-c4k) _img=91b58320dee04efd37bcfe3e1a1782afa6886861727cee6f4aad5e7e188d00bb
    _cfg=eca135e1491cb12a80f4509fb80ee5f0d2b775f2e7be5189a514091bdf27bebc;;   # c4k YAML
  builds/vdb-index-sq8/2/seg32-c32m-a54m-m16-efc128-sq8) _img=bb52e76c5f2bedbe8661e61026cc8c7c267f4c310465cfa29ffddae002bd971f
    _cfg=4e4e7134710f9b131368d7b3f71c07ab56d97e72ad329649bda27f893f6d65be;;   # run-2 YAML
  *) _img=unpinned-image-$H2N_HOST_IMAGE _cfg=unpinned;;   # any other image fails the pin check
esac
PIN_SHA256="de3d8480fe7fcf606d0190013b879b5ab713b37f29567ca4ec4633889d77ec17  $VDB_PLAIN_BUILD/manifest.txt
bd0365b365542aa2efd78055b7977cea5268daf9348f40c90b2cf9d3603203dd  $VDB_PLAIN_BUILD/bin/vdb-server
6e3149a1ff26bddcb62d0c5b80026f53cdc43682d5b16c7c1fdffb34cd60e023  $VDB_LOADGEN_BUILD/manifest.txt
82da28d45a32c68246d5ca0402c3c7dfc28394a165f4bb16dfa167c2c5058927  $VDB_LOADGEN_BUILD/loadgen
$POP_BUNDLE_SHA  $POP_C/packet.sha256
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
$_img  $H2N_HOST_IMAGE/SHA256SUMS
925e5a0c57bbccdaeab2d4fe17fcf5871559d90c9a1af6af62626aa1a6b05afc  $P/builds/vdb-inputs/5/SHA256SUMS
8ad2e82a3710ef331c50ea8c2fc1f1fad29b536611a0e850030af4c0d9a3e0a1  $VDB_X_WRITES
14667a684229fbe882a37428d210ade9886b057e642d1f25c5236ed23b3288a5  $H2N_MG_BUILD_N2/manifest.txt
a6c4ce356ad08bfc01e005cbc4ceed4cd504d5a3cb93852b3dc1a3ff8e72bf40  $H2N_MG_BUILD_N2/bin/vdb-server
b2e04985143cf3881a64a7112d9ef677bc58951d79af9ccc38d903e5d15a8e40  $H2N_MG_LIB_N2/manifest.txt
$_cfg  $H2N_MG_CFG_N2"
unset _img _cfg
