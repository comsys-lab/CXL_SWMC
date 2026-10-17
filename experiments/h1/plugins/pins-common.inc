# Shared pins of every H1 workload plugin (sourced by pins-<W>.sh). Observed 2026-10-17 (reports/KV-V1-packet.md §1.1,
# §1.2; VDB-V1 §1). All three systems run on Popcorn build 12; all-HWcc and Megalon with cxl_shm unloaded.
P=/home/comsys/sungsu/destijl-control
KPOP=6.14.0-famfs-de-stijl+-ds-popcorn-new-12            # popcorn_new f47dcd52e, rel/popcorn-new-12
CPOP=$P/builds/popcorn_new/12/deploy-v1                    # packet.sha256 sha256 0bc610d8ebafadcd369494a114e263b0b629118f9e6bf1c487a82ca3da427de0
GTPOP=/home/comsys/popcorn-12
POP_BUNDLE_SHA=0bc610d8ebafadcd369494a114e263b0b629118f9e6bf1c487a82ca3da427de0
RECV_MODE=poll
MEG77=$P/builds/megalon/77           # libmegalon.so f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda
MEG77HW=$P/builds/megalon/77-hwcc    # libmegalon.so f22c852f5cc83928b2a4852a3aa428197aa70af7bf385defe0a91c18fa622dc7 (KV all-HWcc only)
EXPECT_DAX_UUID=f61e87a2-aaa7-41a7-94d9-5e74fe078049
COMMON_SHA256="0bc610d8ebafadcd369494a114e263b0b629118f9e6bf1c487a82ca3da427de0  $CPOP/packet.sha256
f9c1753f3bef2ab0941153058860227145f2d7b7e33a210bdc3338fad14eacda  $MEG77/ship/lib/libmegalon.so"
