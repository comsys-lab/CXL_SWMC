#!/bin/bash
# Unit test of experiments/rocksdb/run.sh failure handling (rocks-fix 2026-11-02), Host only, no VM: ssh / scp / virsh /
# numactl are PATH stubs, the loadgen and the Host server are stub scripts, one local TCP listener stands in for the
# server ports. Cases:
#   A  loadgen rc 1 (SLO-search note "confirm failed at three rates"): the servers are NOT stopped before the verify
#      point (one stop per node, after the loadgen), no "error, stopping servers", run.sh exit 1 "loadgen rc=1",
#      check.txt PASS (pilot-run.sh then reports a NOTE, v1-block.sh continues with the next cell)
#   B  loadgen rc 0, a real error after the loadgen (server_cpus check fails): the ERR trap is armed again
#      ("error, stopping servers", servers stopped, run.sh fails)
# usage: bash test/test_run_errtrap.sh   -> "TEST RUN ERRTRAP PASS" (exit 0) or FAIL lines (exit 1)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); RUNSH=${RUNSH:-$HERE/../run.sh}   # RUNSH=<other run.sh>: test another copy
TD=$(mktemp -d /tmp/rocks-errtrap-XXXXXX); trap 'kill $LPID 2>/dev/null; rm -rf "$TD"' EXIT
mkdir -p "$TD/bin"
PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(64)
s.settimeout(120)
while True:
    try: c, _ = s.accept(); c.close()
    except OSError: break' "$PORT" & LPID=$!
sleep 0.5
cat > "$TD/bin/ssh" <<'EOS'
#!/bin/bash
# stub: last argument = remote command; log it, answer the run.sh queries
while [ $# -gt 1 ]; do shift; done; c=$1
echo "SSH $c" >> "$STUB_LOG"
case "$c" in
  *"check = set"*) [ "${FAKE_FAIL_CHECK:-0}" = 1 ] && exit 1; echo "check x session=1 pid=2 threads=1"; echo "pid 2's current affinity list: $SERVER_CPUS";;
  *"set = set"*) echo "set x session=1 pid=2 threads=1"; echo "pid 2's current affinity list: $SERVER_CPUS";;
  *"rocksdb-server: IMAGE"*) k=$(sed -n 's/.*node\([0-9]*\)\.log.*/\1/p' <<< "$c"); echo "rocksdb-server: IMAGE $(( (FAKE_KEYS - k + FAKE_N - 1) / FAKE_N )) keys";;
  *"uname -r"*) echo "6.14.0-stub"; echo aaa; echo bbb; echo ccc; echo "msg_ring: [0, 1]"; echo 4; echo "MemTotal: 1 kB";;
  *"ss -ltn"*) echo "127.0.0.1:$FAKE_PORT";;
  *"/proc/stat"*) echo "cpu 1 2 3 4";;
esac
exit 0
EOS
cat > "$TD/bin/scp" <<'EOS'
#!/bin/bash
# stub collect: write node<k>.log with clean-stop stats (k from the remote path)
src=$2; dst=${!#}; k=$(sed -n 's/.*node\([0-9]*\)\.\*.*/\1/p' <<< "$src")
{ echo "rocksdb-server: stopping"; echo "remote_errors=0"; echo "get_errors=0"; echo "update_errors=0"; echo "get_retry_limit=0"
  for ((j = 0; j < FAKE_N; j++)); do [ $j = $k ] || { echo "remote$j.gets=1"; echo "remote$j.errors=0"; echo "remote$j.catchup_errors=0"; }; done
  echo "pools.extents_free=9999"; echo "pools.blocks_free=999"; } > "$dst/node$k.log"
EOS
printf '#!/bin/bash\nexit 0\n' > "$TD/bin/virsh"
printf '#!/bin/bash\nshift 2; exec "$@"\n' > "$TD/bin/numactl"
cat > "$TD/loadgen" <<'EOS'
#!/bin/bash
# stub loadgen: --out DIR; summary + one step; rc FAKE_LG_RC
while [ $# -gt 0 ]; do [ "$1" = --out ] && out=$2; shift; done
mkdir -p "$out"; echo "LOADGEN" >> "$STUB_LOG"
echo '{"step":1,"phase":"ramp","offered_x":500,"x":500,"pass":true,"streams":{"mixed":{"p99_ms":0.1}}}' > "$out/steps.jsonl"
echo '{"mode":"slo","note":"confirm failed at three rates; the knee is noisy (longer --confirm-s?)","workload_finish":"ok"}' > "$out/summary.json"
echo "not_found=0" > "$out/rocksdb.txt"
exit "${FAKE_LG_RC:-0}"
EOS
printf '#!/bin/bash\necho 4096\n' > "$TD/server"
chmod +x "$TD/bin/"* "$TD/loadgen" "$TD/server"
fails=0
runcase() {  # <case> <lg rc> <fail check 0|1>
  local c=$1 out rc
  export STUB_LOG=$TD/$c.ssh.log; : > "$STUB_LOG"
  out=$(env PATH="$TD/bin:$PATH" SYSTEM=all-HWcc V=/home/comsys/stub HOST_SERVER=$TD/server LOADGEN=$TD/loadgen \
    SERVER_ARGS="--nodes 2 --keys 4 --threads 1" NODES="127.0.0.1 127.0.0.1" PORT=$PORT RUN_KIND=functional STATS_OP=0 VERIFY=0 \
    SERVER_CPUS=0-3 FAKE_LG_RC=$2 FAKE_FAIL_CHECK=$3 FAKE_KEYS=4 FAKE_N=2 FAKE_PORT=$PORT \
    bash "$RUNSH" "case$c" "$TD/out" -- --opt keys=4 2>&1); rc=$?
  echo "$out" > "$TD/$c.out"
  OUT=$out RC=$rc
}
bad() { echo "FAIL case $1: $2"; fails=$((fails + 1)); }
# ---- A
runcase A 1 0
[ $RC = 1 ] || bad A "run.sh rc $RC != 1"
grep -q "error, stopping servers" <<< "$OUT" && bad A "ERR trap fired on the loadgen rc"
grep -q "run caseA: loadgen rc=1" <<< "$OUT" || bad A "no 'loadgen rc=1' line"
grep -q "^check: PASS$" "$TD/out/caseA/check.txt" || bad A "check.txt not PASS ($(grep FAIL "$TD/out/caseA/check.txt" | head -2))"
n=$(grep -c "rocksdb-node.sh stop" "$STUB_LOG"); [ "$n" = 2 ] || bad A "$n server stops (want 2, one per node)"
lg=$(grep -n '^LOADGEN$' "$STUB_LOG" | cut -d: -f1); st=$(grep -n 'rocksdb-node.sh stop' "$STUB_LOG" | head -1 | cut -d: -f1)
[ -n "$lg" ] && [ -n "$st" ] && [ "$st" -gt "$lg" ] || bad A "a stop before the loadgen finished"
sc=$(grep -n 'check = set' "$STUB_LOG" | head -1 | cut -d: -f1)
[ -n "$sc" ] && [ "$sc" -lt "$st" ] || bad A "post-loadgen steps (server_cpus check) did not run before the stop"
# ---- B
runcase B 0 1
[ $RC != 0 ] || bad B "run.sh rc 0 after a failing server_cpus check"
grep -q "error, stopping servers" <<< "$OUT" || bad B "ERR trap not armed after the loadgen"
grep -q "rocksdb-node.sh stop" "$STUB_LOG" || bad B "servers not stopped"
if [ $fails = 0 ]; then echo "TEST RUN ERRTRAP PASS"; exit 0; fi
echo "outputs: $TD/A.out $TD/B.out (kept)"; trap 'kill $LPID 2>/dev/null' EXIT; exit 1
