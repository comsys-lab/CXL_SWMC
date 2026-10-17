# H1 plugin: KV store (54M keys, batch 16, Zipf 0.99; reports/KV-V1-packet.md v1.4 blocks). FILL_* after KV-V1 PASS.
# all-HWcc = kv/10 on Megalon 77-hwcc (FULL_COHERENCE flavor; MOT1 v6 §3.1 KV rule), Popcorn = kv/10 + cxl_shm,
# Megalon = kv-megalon/10 on Megalon 77.
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=FILL_kv_harness_root             # recovery/KV-V1-v1.4-pre/harness/CXL_SWMC (frozen) or a new H1 freeze of BUILD_PIN
HOOK_FILE=$HR/experiments/kv/pilot-block.sh
BLOCK_CMD=(bash $HOOK_FILE h1)       # H1 hook = block "h1" in pilot-block.sh (to be added by the KV owner)
BLOCK_ENV=(PIN=FILL_kv_build_pin BUILD_PIN=FILL_kv_build_pin MEGALON_BUILD_N=77 KEYS=54000000
  PLAIN_BUILD=$P/builds/kv/10 MEG_BUILD=$P/builds/kv-megalon/10 LOADGEN_BUILD=$P/builds/kv-loadgen/10
  VM_PLAIN=/home/comsys/kv10 VM_MEG=/home/comsys/kvm10 KV_CFG=FILL_kv_cfg_megalon_yaml
  K8=$KPOP C8=$CPOP GT8=$GTPOP RECV_MODE=$RECV_MODE)
PIN_SHA256="$COMMON_SHA256
FILL_kv10_manifest_sha256  $P/builds/kv/10/manifest.txt
FILL_kvm10_manifest_sha256  $P/builds/kv-megalon/10/manifest.txt
FILL_kvlg10_manifest_sha256  $P/builds/kv-loadgen/10/manifest.txt
FILL_kv_hook_sha256  $HOOK_FILE"
