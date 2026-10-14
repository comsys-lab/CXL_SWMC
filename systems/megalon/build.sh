#!/usr/bin/env bash
# Build one Megalon flavor out of tree (De Stijl 2-VM port).
#
#   systems/megalon/build.sh <flavor> <n> [-j N] [--no-tests] [--wmeta artifact64|packed4]
#     flavor: megalon (SCR + LIMITED_SCR) | hwcc (FULL_COHERENCE; also used for popcorn)
#     wmeta:  HWcc record layout; artifact64 (default, upstream 64 B/record) | packed4 (paper's 4 B record;
#             with flavor megalon the owner key moves to the NR replica, nr feature wmeta-rev)
#     n:      build number -> builds/megalon/<n>/ (n=0 is the upstream baseline; refused)
#
# Output in builds/megalon/<n>/:
#   nr_target/          per-flavor cargo target dir (libnr_hashmap.a + .features tag)
#   (cmake build tree)  libmegalon.so, benchmarks/kv-store, ...
#   ship/bin, ship/lib  what is copied into the VMs (RUNPATH $ORIGIN/../lib)
#   manifest.txt        provenance + hashes + ABI levels
#   build.log           full log of this invocation
#
# Builds are incremental. Never runs the repo's scripts/build.sh or setup
# scripts, never deletes anything inside the source repo, never runs a binary
# that maps memory (only the pure-Rust NR unit tests are executed).
set -euo pipefail

ROOT=/home/comsys/sungsu/destijl-control
SRC=$ROOT/CXL_SWMC/systems/megalon/src
T=$ROOT/workspaces/toolchain
TOOLCHAIN_FILE=$SRC/cmake-variant/toolchains/clang17-gcc.cmake

usage() { echo "usage: $0 <megalon|hwcc> <n> [-j N] [--no-tests] [--wmeta artifact64|packed4]" >&2; exit 2; }
[ $# -ge 2 ] || usage
FLAVOR=$1; N=$2; shift 2
JOBS=60; RUN_TESTS=1; WMETA=artifact64
while [ $# -gt 0 ]; do
    case $1 in
        -j) JOBS=$2; shift 2 ;;
        --no-tests) RUN_TESTS=0; shift ;;
        --wmeta) [ $# -ge 2 ] || usage; WMETA=$2; shift 2 ;;
        *) usage ;;
    esac
done
case $FLAVOR in
    megalon) NR_FEATURES="scr"; NR_RUSTFLAGS="-C target-feature=+clflushopt" ;;
    hwcc)    NR_FEATURES="";    NR_RUSTFLAGS="" ;;
    *) usage ;;
esac
case $WMETA in
    artifact64) ;;
    packed4) if [ "$FLAVOR" = megalon ]; then NR_FEATURES="$NR_FEATURES wmeta-rev"; fi ;;  # must match CMakeLists.txt
    *) usage ;;
esac
[[ $N =~ ^[0-9]+$ ]] || usage
[ "$N" != 0 ] || { echo "refusing builds/megalon/0 (upstream baseline)" >&2; exit 1; }

OUT=$ROOT/builds/megalon/$N
mkdir -p "$OUT"
if [ -f "$OUT/CMakeCache.txt" ]; then
    prev=$(sed -n 's/^MEGALON_FLAVOR:STRING=//p' "$OUT/CMakeCache.txt")
    if [ -n "$prev" ] && [ "$prev" != "$FLAVOR" ]; then
        echo "builds/megalon/$N already holds flavor '$prev'; use another build number" >&2
        exit 1
    fi
    prevw=$(sed -n 's/^MEGALON_WMETA_LAYOUT:STRING=//p' "$OUT/CMakeCache.txt")
    if [ "${prevw:-artifact64}" != "$WMETA" ]; then
        echo "builds/megalon/$N already holds wmeta layout '${prevw:-artifact64}'; use another build number" >&2
        exit 1
    fi
fi
exec > >(tee "$OUT/build.log") 2>&1

# shellcheck disable=SC1091
. "$T/env.sh"
echo "== megalon build: flavor=$FLAVOR wmeta=$WMETA n=$N out=$OUT jobs=$JOBS $(date -Is)"

# ---- provenance ----
COMMIT=$(git -C "$SRC" rev-parse HEAD)
BRANCH=$(git -C "$SRC" rev-parse --abbrev-ref HEAD)
DIRTY_STATUS=$(git -C "$SRC" status --porcelain --untracked-files=normal -- . ':!third-party/nr_rust/ffi/Cargo.lock')
if [ -n "$DIRTY_STATUS" ]; then
    DIRTY_HASH=$( { git -C "$SRC" diff HEAD; git -C "$SRC" status --porcelain --untracked-files=normal; } | sha256sum | cut -d' ' -f1)
    BUILD_ID="${COMMIT:0:12}-dirty-${DIRTY_HASH:0:12}"
else
    DIRTY_HASH=none
    BUILD_ID="${COMMIT:0:12}"
fi
echo "source $COMMIT ($BRANCH) dirty_diff_sha256=$DIRTY_HASH build_id=$BUILD_ID"

# ---- NR (Rust) lib, per flavor, out of tree ----
NR_TARGET=$OUT/nr_target
NR_LIB=$NR_TARGET/release/libnr_hashmap.a
feat_args=()
[ -n "$NR_FEATURES" ] && feat_args=(--features "$NR_FEATURES")
echo "== cargo build (features='$NR_FEATURES')"
( cd "$SRC/third-party/nr_rust/ffi" &&
  CARGO_TARGET_DIR=$NR_TARGET RUSTFLAGS="$NR_RUSTFLAGS" cargo build --release "${feat_args[@]}" )
[ -f "$NR_LIB" ] || { echo "missing $NR_LIB" >&2; exit 1; }
printf 'features=%s\nflavor=%s\nwmeta=%s\nbuild_id=%s\n' "$NR_FEATURES" "$FLAVOR" "$WMETA" "$BUILD_ID" > "$NR_LIB.features"

NR_TESTS="not run"
ENTRY_SIZE=unknown
if [ "$RUN_TESTS" = 1 ]; then
    # pure-Rust unit tests of the shared NR log (two in-process nodes, heap memory only)
    echo "== cargo test (NR port tests)"
    tlog=$OUT/nr_tests.log
    if ( cd "$SRC/third-party/nr_rust/ffi" &&
         CARGO_TARGET_DIR=$NR_TARGET RUSTFLAGS="$NR_RUSTFLAGS" LD_LIBRARY_PATH=$T/prefix/lib \
         cargo test --release "${feat_args[@]}" --lib -- --test-threads=1 --nocapture ) > "$tlog" 2>&1; then
        NR_TESTS=$(grep -E '^test result:' "$tlog" | tail -1)
    else
        NR_TESTS="FAILED (see nr_tests.log)"
    fi
    ENTRY_SIZE=$(sed -n 's/.*NR_LOG_ENTRY_SIZE=\([0-9]*\).*/\1/p' "$tlog" | head -1)
    echo "NR tests: $NR_TESTS; NR_LOG_ENTRY_SIZE=$ENTRY_SIZE"
    case $NR_TESTS in FAILED*) tail -40 "$tlog"; exit 1 ;; esac
fi

# ---- C++ (cmake, out of tree) ----
echo "== cmake configure"
cmake -S "$SRC" -B "$OUT" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DMEGALON_FLAVOR="$FLAVOR" \
    -DMEGALON_WMETA_LAYOUT="$WMETA" \
    -DMEGALON_NR_LIB="$NR_LIB" \
    -DMEGALON_BUILD_ID="$BUILD_ID" > "$OUT/cmake.log" 2>&1 || { tail -40 "$OUT/cmake.log"; exit 1; }
grep -E 'MEGALON_FLAVOR=|linking nr lib' "$OUT/cmake.log" || true
echo "== build"
cmake --build "$OUT" -j "$JOBS" > "$OUT/make.log" 2>&1 || { grep -E 'error|Error' "$OUT/make.log" | head -40; exit 1; }
grep -cE 'warning:' "$OUT/make.log" | sed 's/^/compiler warnings: /' || true

# ---- ship dir ----
SHIP=$OUT/ship
case $SHIP in "$ROOT"/builds/megalon/[1-9]*/ship) rm -rf "$SHIP" ;; *) echo "bad ship path" >&2; exit 1 ;; esac
mkdir -p "$SHIP/bin" "$SHIP/lib"
for b in kv-store ycsb_benchmark; do
    [ -f "$OUT/benchmarks/$b" ] && cp -p "$OUT/benchmarks/$b" "$SHIP/bin/"
done
cp -p "$OUT/libmegalon.so" "$SHIP/lib/"
TBB_DIR=$(dirname "$(find "$OUT" -maxdepth 2 -name 'libtbb.so.12' | head -1)")
cp -pL "$TBB_DIR/libtbb.so.12" "$TBB_DIR/libtbbmalloc.so.2" "$SHIP/lib/"
# memkind is no longer used by the port (arenas + private heap); hwloc comes from the toolchain prefix
cp -pL "$T/prefix/lib/libhwloc.so.15" "$SHIP/lib/"
# libatomic is not in a minimal guest image by default; ship the Host (same Ubuntu 22.04) copy
cp -pL /lib/x86_64-linux-gnu/libatomic.so.1 "$SHIP/lib/"

# every NEEDED lib must be shipped or a guest system lib
SYSTEM_LIBS="libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1 libnuma.so.1 libpthread.so.0 libdl.so.2 librt.so.1 ld-linux-x86-64.so.2 libudev.so.1"
MISSING=""
for f in "$SHIP"/bin/* "$SHIP"/lib/*; do
    for need in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        [ -f "$SHIP/lib/$need" ] && continue
        case " $SYSTEM_LIBS " in *" $need "*) continue ;; esac
        MISSING="$MISSING $(basename "$f"):$need"
    done
done

maxver() { objdump -T "$1" 2>/dev/null | grep -oE "\b$2_[0-9]+(\.[0-9]+)*" | sort -V | tail -1; }
NUMEXEC=$(sed -n 's/^pub const NUM_EXEC: usize = \([0-9]*\);.*/\1/p' "$SRC/third-party/nr_rust/ffi/constants.rs")
LNN_RS=$(sed -n 's/^pub const LOGICAL_NODE_NUM: usize = \([0-9]*\);.*/\1/p' "$SRC/third-party/nr_rust/ffi/constants.rs")
KEY_RS=$(sed -n 's/^pub const KEY_SIZE: usize = \([0-9]*\);.*/\1/p' "$SRC/third-party/nr_rust/ffi/constants.rs")
LNN_H=$(sed -n 's/^#define LOGICAL_NODE_NUM \([0-9]*\).*/\1/p' "$SRC/src/common/constants.h")
cache() { sed -n "s/^$1:[A-Z]*=//p" "$OUT/CMakeCache.txt"; }

# ---- manifest ----
M=$OUT/manifest.txt
{
    echo "# Megalon build manifest (systems/megalon/build.sh)"
    echo "date=$(date -Is)"
    echo "host=$(hostname)"
    echo "flavor=$FLAVOR"
    echo "wmeta_layout=$WMETA"
    echo "build_dir=$OUT"
    echo "source_repo=$SRC"
    echo "source_branch=$BRANCH"
    echo "source_commit=$COMMIT"
    echo "source_dirty_diff_sha256=$DIRTY_HASH"
    echo "build_id=$BUILD_ID"
    echo "build_sh=$(realpath "$0")"
    echo "build_sh_sha256=$(sha256sum "$(realpath "$0")" | cut -d' ' -f1)"
    echo "clang=$(clang++-17 --version | head -1)"
    echo "rustc=$(cd "$SRC/third-party/nr_rust/ffi" && rustc --version)"
    echo "cmake=$(cmake --version | head -1)"
    grep -E '^-- MEGALON_FLAVOR=' "$OUT/cmake.log" | sed 's/^-- /cmake_effective=/'
    echo "nr_features=$NR_FEATURES"
    echo "nr_rustflags=$NR_RUSTFLAGS"
    echo "nr_lib=$NR_LIB"
    echo "nr_lib_sha256=$(sha256sum "$NR_LIB" | cut -d' ' -f1)"
    echo "nr_cargo_lock_sha256=$(sha256sum "$SRC/third-party/nr_rust/ffi/Cargo.lock" | cut -d' ' -f1)"
    echo "nr_log_entry_size=$ENTRY_SIZE"
    echo "nr_port_tests=$NR_TESTS"
    echo "constants_rs_LOGICAL_NODE_NUM=$LNN_RS"
    echo "constants_rs_NUM_EXEC=$NUMEXEC"
    echo "constants_rs_KEY_SIZE=$KEY_RS"
    echo "constants_h_LOGICAL_NODE_NUM=$LNN_H"
    echo "runpath_setting=$(cache MEGALON_RUNPATH)"
    for f in "$SHIP"/bin/* "$SHIP"/lib/*; do
        rel=${f#"$SHIP"/}
        echo "sha256[$rel]=$(sha256sum "$f" | cut -d' ' -f1)"
    done
    for f in "$SHIP"/bin/* "$SHIP/lib/libmegalon.so"; do
        rel=${f#"$SHIP"/}
        echo "runpath[$rel]=$(readelf -d "$f" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"
        echo "abi_max[$rel]=$(maxver "$f" GLIBC) $(maxver "$f" GLIBCXX) $(maxver "$f" CXXABI)"
    done
    echo "unshipped_non_system_needed=${MISSING:-none}"
    echo "methodology_note=kv-store warmup: each node warms the whole key space (KV_WRITERS=node0: only node 0 warms and writes); nodes align at NodeBarrier(1) after warmup"
} > "$M"
echo "== manifest $M"
cat "$M"
[ -z "$MISSING" ] || { echo "ERROR: unshipped NEEDED libs:$MISSING" >&2; exit 1; }
