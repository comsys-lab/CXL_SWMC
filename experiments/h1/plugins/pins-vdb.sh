# H1 plugin: vector DB (HNSW 28M, pubmed-a27m-b1m-q10k; reports/VDB-V1-packet.md v1.3.1 blocks, validation PASS
# 2026-10-17 §17). all-HWcc = plain server (no Megalon; MOT1 v6 §3.1), Popcorn = plain server + cxl_shm
# (init_state=shared + preload, recv_mode poll), Megalon = vdb-megalon on Megalon 77 (packed4, 32 MiB vector chunk
# object), mgoff = the same with MEGALON_COH_TIMERS=0. Filled 2026-10-17 (CXL_SWMC eecda9519, H1 hook in v6-block.sh).
. "$(dirname "${BASH_SOURCE[0]}")/pins-common.inc"
HR=$P/CXL_SWMC                      # live tree; v6-block.sh uses $P/CXL_SWMC/experiments/vectordb itself. Every file it
                                    # runs is hash-pinned below (hook eecda9519; builds vdb/15, vdb-megalon/14 from 934fa9312)
HOOK_FILE=$HR/experiments/vectordb/v6-block.sh
BLOCK_CMD=(bash $HOOK_FILE)          # H1 hook = H1MODE=slo|fix in v6-block.sh (marker H1-HOOK v1)
BLOCK_ENV=(KPOP=$KPOP GTPOP=$GTPOP CPOP=$CPOP MEG_LIB=$MEG77 MEGALON_LEAN=1 EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  PLAIN_BUILD=$P/builds/vdb/15 VPLAIN=/home/comsys/vdb15
  MEG_BUILD=$P/builds/vdb-megalon/14 VMEG=/home/comsys/vdbm14-28m MEG_CFG=$HR/systems/megalon/vectordb-2vm.yaml
  LOADGEN_BUILD=$P/builds/vdb-loadgen/5)
PIN_SHA256="$COMMON_SHA256
f17c8995c1b2c88f3849b6aec890c848fafe99bb40298cbf4412999858bc59d1  $P/builds/vdb/15/manifest.txt
2097a2e49290849a35d62f474da50bb7e3e4fedb9d0703343c797e9fdabfe525  $P/builds/vdb/15/bin/vdb-server
65fa1fb1077aaac0fd9f1be947d76e90c84c633752d1e279ae1e68937b50e3e5  $P/builds/vdb-megalon/14/manifest.txt
5f1ff99101da18cd7f05d55c77444ea7a7cf94030e17bcf24050e0ebe12c0dbc  $P/builds/vdb-megalon/14/bin/vdb-server
8c59d1808ec569f54a05531610e3b9d18ae4563f9ebb5c264a657bd1edf3a3ac  $P/builds/vdb-megalon/14/lib/libmegalon-objapi.so
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $P/builds/vdb-megalon/14/lib/libmegalon.so
654c0cbcb6841a98844c6998efb561cf9bf0cc1810c3764ac2a3659dffa15465  $P/builds/vdb-loadgen/5/manifest.txt
76dd2b697acdd8a86787e8aef995c07b3d9ecd864a83b0e8b64ca9982935ec66  $P/builds/vdb-loadgen/5/loadgen
e9d4942ee33b2f65cf7117d87942296e1365d0234873c2c4159545f40708db54  $P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1/SHA256SUMS
4e4e7134710f9b131368d7b3f71c07ab56d97e72ad329649bda27f893f6d65be  $HR/systems/megalon/vectordb-2vm.yaml
eeb6b23f173d85a3c86ade0fb804b363e3c84a36bf9c0f56a7cbcab25e738b53  $HR/config/cxl_region.yaml
3954e666b979fdab999d1d364e2084301d55c26a81a800e71360e672f30f1e46  $HOOK_FILE
9d7fead21754368299e243eb2aee515fa394c022e775e8d0c5c214ef36e48a6b  $HR/experiments/vectordb/m4-lib.sh
6c625aca1acca67badc88891884f67749335a79051c29ea09e48adbbea903bc7  $HR/experiments/vectordb/m4-run.sh
4f107af05c0a062f72ac3de31ce59dbfd0c6b86a63ad4ad62ec84598c75e8a57  $HR/experiments/vectordb/m4-precheck.sh
eca4cd1714887023e06783675a6fba20c5d6f940e04a37b56b0d35003566764c  $HR/experiments/vectordb/run.sh
1edcdda88f30200fd55c1b5a18cb4b9d6db57aa02647f8ad549e4e7f6aabb31f  $HR/experiments/vectordb/host-gate.sh
1baccf944c1ac66fce65b065c1043529cd72bc08b38f4b42fe43bd2640076031  $HR/experiments/vectordb/pretouch-gate.sh
49ffaf143f484e4548e84105d20f584547fbd06c6cd38c1522ba4dccbd18e8fe  $HR/experiments/vectordb/opsplit.py
e81a738fdf1829d9a42f4ab213be07b421b8d9d5b45cb09238a0c66ce1630a5c  $HR/workloads/vectordb/tests/opcoh_check.py
68327dd3178d7af5b0ad9c614f0a6c41b4d99b2f6a23cf456f7751273996eecf  $HR/scripts/host/measure-env.sh"
