#!/bin/bash
# De Stijl v2 replica-vs-CXL content check (runs ON a guest, as root: p-destijl-guest.sh replica-check execs it; spec
# DS2-protocol-spec.md section 10.4). For each page index p (managed page index = faultlat --page-offset, the swcc start
# is the managed range start): write "p" to /sys/kernel/swmc/destijl/page_digest, read back one line
#   state=<I|S|SS|M> replica=<pfn|0> crc_cxl=<crc32> crc_replica=<crc32|->
# (computed under the page's fault handle; kernel destijl.c page_digest_show) and classify:
#   no_replica  replica=0
#   matched     replica present, crc_replica == crc_cxl
#   dirty_m     replica present in state M, crc differs (the replica holds the local writes; written back on drop):
#               expected, not a failure
#   stale       replica present, crc differs, state I / S / SS (a reader would see other data than CXL): FAIL
#   error       read failed or unparsable line: FAIL
# Also records replica_pages and replica_pool_full (/sys/kernel/swmc/destijl) at the end: replica_pool_full != 0 is a
# FAIL (a full pool silently maps CXL directly: the run mixes replicated and unreplicated pages; replication review
# 2026-11-01). --expect-replicas N: FAIL if fewer than N sampled pages have a replica (matched + dirty_m + stale).
# usage: ds-replica-check.sh [--out FILE] [--expect-replicas N] (--pages "i j ..." | --range START:COUNT
#        | --sample COUNT [--range START:COUNT] [--seed S])
#   --sample without --range draws from the whole managed range [0, managed_pages) (/sys/kernel/cxl_shm/layout)
# Output: one line per page "p=<i> <kernel line> class=<c>" and a last line
#   "REPLICACHECK PASS|FAIL pages <n> matched <a> dirty_m <b> stale <c> no_replica <d> error <e> replica_pages <r>
#    replica_pool_full <f>"; exit 0 on PASS, 1 on FAIL, 2 on usage errors. Reads and one sysfs index write only.
set -uo pipefail
DS=/sys/kernel/swmc/destijl
OUT= PAGES= RANGE= SAMPLE= SEED=1 EXPECT=0
while [ $# -gt 0 ]; do
  case $1 in
    --out) OUT=${2:?}; shift 2 ;;
    --pages) PAGES=${2:?}; shift 2 ;;
    --range) RANGE=${2:?}; shift 2 ;;
    --sample) SAMPLE=${2:?}; shift 2 ;;
    --seed) SEED=${2:?}; shift 2 ;;
    --expect-replicas) EXPECT=${2:?}; shift 2 ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
  esac
done
die() { echo "REPLICACHECK FAIL usage/setup: $*"; exit 2; }
test "$(id -u)" -eq 0 || die "must run as root (page_digest is root-writable)"
test -w $DS/page_digest || die "no writable $DS/page_digest (kernel without the replica check, De Stijl build < 4?)"
[[ $SEED =~ ^[0-9]+$ ]] && [[ $EXPECT =~ ^[0-9]+$ ]] || die "bad --seed / --expect-replicas"
MP=$(awk '$1 == "managed_pages" {print $2}' /sys/kernel/cxl_shm/layout 2>/dev/null)
[[ $MP =~ ^[0-9]+$ ]] && [ "$MP" -gt 0 ] || die "managed_pages not in /sys/kernel/cxl_shm/layout (cxl_shm not running?)"
START=0 COUNT=$MP
if [ -n "$RANGE" ]; then
  [[ $RANGE =~ ^([0-9]+):([1-9][0-9]*)$ ]] || die "bad --range ($RANGE: START:COUNT)"
  START=${BASH_REMATCH[1]} COUNT=${BASH_REMATCH[2]}
  [ $((START + COUNT)) -le "$MP" ] || die "--range $RANGE beyond managed_pages $MP"
fi
if [ -n "$PAGES" ]; then
  [ -z "$RANGE$SAMPLE" ] || die "--pages excludes --range / --sample"
  LIST=$PAGES
elif [ -n "$SAMPLE" ]; then
  [[ $SAMPLE =~ ^[1-9][0-9]*$ ]] && [ "$SAMPLE" -le "$COUNT" ] || die "bad --sample ($SAMPLE; <= $COUNT)"
  LIST=$(awk -v s="$START" -v c="$COUNT" -v n="$SAMPLE" -v seed="$SEED" 'BEGIN { srand(seed); k = 0
    while (k < n) { p = s + int(rand() * c); if (!(p in u)) { u[p] = 1; k++; print p } } }' | sort -n)
elif [ -n "$RANGE" ]; then
  LIST=$(seq "$START" $((START + COUNT - 1)))
else die "one of --pages, --range, --sample"; fi
exec 3>&1
[ -z "$OUT" ] || exec 3> "$OUT"
n=0 matched=0 dirty=0 stale=0 norep=0 err=0
for p in $LIST; do
  [[ $p =~ ^[0-9]+$ ]] && [ "$p" -lt "$MP" ] || { echo "p=$p class=error (not a page index < $MP)" >&3; err=$((err + 1)); n=$((n + 1)); continue; }
  n=$((n + 1))
  if ! echo "$p" > $DS/page_digest 2>/dev/null || ! line=$(cat $DS/page_digest 2>/dev/null); then
    echo "p=$p class=error (page_digest write/read failed)" >&3; err=$((err + 1)); continue
  fi
  if [[ $line =~ ^state=([A-Z]+)\ replica=([0-9a-fx]+)\ crc_cxl=([0-9a-f]{8})\ crc_replica=([0-9a-f]{8}|-)$ ]]; then
    st=${BASH_REMATCH[1]} rp=${BASH_REMATCH[2]} cc=${BASH_REMATCH[3]} cr=${BASH_REMATCH[4]}
    if [ "$rp" = 0 ]; then c=no_replica norep=$((norep + 1))
    elif [ "$cr" = "$cc" ]; then c=matched matched=$((matched + 1))
    elif [ "$st" = M ]; then c=dirty_m dirty=$((dirty + 1))
    else c=stale stale=$((stale + 1)); fi
  else c=error err=$((err + 1)); fi
  echo "p=$p $line class=$c" >&3
done
rpg=$(cat $DS/replica_pages 2>/dev/null || echo absent) rpf=$(cat $DS/replica_pool_full 2>/dev/null || echo absent)
ok=1
[ "$stale" = 0 ] && [ "$err" = 0 ] && [ "$n" -gt 0 ] || ok=0
[ "$rpf" = 0 ] || ok=0   # absent (kernel without the counter) or > 0: FAIL
[ $((matched + dirty + stale)) -ge "$EXPECT" ] || ok=0
s="pages $n matched $matched dirty_m $dirty stale $stale no_replica $norep error $err replica_pages $rpg replica_pool_full $rpf expect_replicas $EXPECT"
res="REPLICACHECK $([ $ok = 1 ] && echo PASS || echo FAIL) $s"
echo "$res"; [ -z "$OUT" ] || echo "$res" >&3
[ $ok = 1 ]
