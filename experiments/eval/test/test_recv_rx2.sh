#!/bin/bash
# Unit test (Host only, no VM): recv-mode.sh RECV_SPIN_US / RECV_SMIN_US (recsys-amx-2way De Stijl receiver variant,
# 2026-11-19). Unset keys must behave exactly as before (plan text, readback wants, sysfs writes); set keys must be
# validated, written after s_max_us (spin_us, then s_min_us) and asserted in the readback.
# usage: bash experiments/eval/test/test_recv_rx2.sh   (last line "RECV RX2 TEST PASS" or "... FAIL (<n>)")
set -u
D=$(cd "$(dirname "$0")/.." && pwd)
. "$D/recv-mode.sh"
bad=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; bad=$((bad + 1)); }
t() { local name=$1; shift; if "$@" > /dev/null 2>&1; then ok "$name"; else no "$name"; fi; }
f() { local name=$1; shift; if "$@" > /dev/null 2>&1; then no "$name (expected a refusal)"; else ok "$name"; fi; }
# readback lines: the standard (every earlier run) and the variant
STD="recv_mode=adaptive ring_coherent=-1 ipoll=0 fault_poll=0 spin_us=50 watch_us=50 s_min_us=50 s_max_us=50 idle_spin_us=50 idle_sleep_us=20 srcversion=X ipoll_threads=4 ipoll_run_ns=1 recv_threads=1 recv_run_ns=2"
RX2="recv_mode=adaptive ring_coherent=-1 ipoll=0 fault_poll=1 spin_us=20 watch_us=50 s_min_us=200 s_max_us=200 idle_spin_us=50 idle_sleep_us=20 srcversion=X ipoll_threads=4 ipoll_run_ns=1 recv_threads=1 recv_run_ns=2"
unset RECV_WATCH_US RECV_S_MAX_US RECV_SPIN_US RECV_SMIN_US
# ---- defaults unchanged
[ "$(recv_wsm_desc)" = "watch_us=default s_max_us=default" ] && ok "desc unset" || no "desc unset: $(recv_wsm_desc)"
RECV_WATCH_US=50 RECV_S_MAX_US=50
[ "$(recv_wsm_desc)" = "watch_us=50 s_max_us=50" ] && ok "desc w50 (= the run-2 plan text)" || no "desc w50: $(recv_wsm_desc)"
t "wsm_check w50 adaptive" recv_wsm_check adaptive
t "rb std, old 8-arg call" recv_rb_check ds adaptive "$STD" - 0 0 50 50
t "rb std, new call with - -" recv_rb_check ds adaptive "$STD" - 0 0 50 50 - -
f "rb rx2 line vs standard wants" recv_rb_check ds adaptive "$RX2" - 0 0 50 50
# ---- variant keys
RECV_S_MAX_US=200 RECV_SPIN_US=20 RECV_SMIN_US=200
[ "$(recv_wsm_desc)" = "watch_us=50 s_max_us=200 spin_us=20 s_min_us=200" ] && ok "desc rx2" || no "desc rx2: $(recv_wsm_desc)"
t "wsm_check rx2 adaptive" recv_wsm_check adaptive
recv_wsm_check sleep > /dev/null; [ $? = 2 ] && ok "wsm_check rx2 with sleep = 2" || no "wsm_check rx2 with sleep != 2"
t "rb rx2" recv_rb_check ds adaptive "$RX2" - 0 1 50 200 20 200
f "rb std line vs rx2 wants" recv_rb_check ds adaptive "$STD" - 0 1 50 200 20 200
f "rb rx2 line, fault_poll want 0" recv_rb_check ds adaptive "$RX2" - 0 0 50 200 20 200
f "rb spin 50 line vs want 20" recv_rb_check ds adaptive "${RX2/spin_us=20/spin_us=50}" - 0 1 50 200 20 200
f "rb s_min 50 line vs want 200" recv_rb_check ds adaptive "${RX2/s_min_us=200/s_min_us=50}" - 0 1 50 200 20 200
RECV_S_MAX_US=100; f "wsm_check s_max 100 < s_min 200" recv_wsm_check adaptive
unset RECV_S_MAX_US; RECV_SMIN_US=200; t "wsm_check s_min 200, s_max default 200" recv_wsm_check adaptive
RECV_SMIN_US=300; f "wsm_check s_min 300 > default s_max 200" recv_wsm_check adaptive
RECV_S_MAX_US=200 RECV_SMIN_US=200 RECV_SPIN_US=x; f "wsm_check bad spin" recv_wsm_check adaptive
RECV_SPIN_US=0; t "wsm_check spin 0" recv_wsm_check adaptive
RECV_SPIN_US=20 RECV_SMIN_US=0; f "wsm_check s_min 0" recv_wsm_check adaptive
RECV_SMIN_US=200
# ---- recv_apply with a fake ssh: write order and the readback check
TD=$(mktemp -d /tmp/recv-rx2-test-XXXXXX)
cat > "$TD/ssh" << 'EOS'
#!/bin/bash
# fake ssh: log the remote command; "bash -s" = readback (the line in $TD/rb), else empty output
d=$(dirname "$0"); shift; echo "$*" >> "$d/cmds"
case "$*" in "bash -s") cat > /dev/null; cat "$d/rb";; *page_coherence/protocol*) echo destijl;; *instr/enabled*) echo 1;; esac
EOS
chmod +x "$TD/ssh"
SSH=$TD/ssh IPS=(10.0.0.1 10.0.0.2) E=$TD DSRX="fault_poll=1" DSFP=1 IPOLL=0 RECV_WATCH_US=50
stopf() { echo "STOP $*" >> "$TD/stops"; }
RECV_STOP=stopf
echo "$RX2" > "$TD/rb"
recv_apply ds rx2 adaptive
w=$(grep -m1 'sudo -n sh -c' "$TD/cmds")
[[ $w == *"echo adaptive > /sys/module/cxl_shm/parameters/recv_mode && echo 0 > /sys/module/cxl_shm/parameters/ipoll && echo 50 > /sys/module/cxl_shm/parameters/watch_us && echo 200 > /sys/module/cxl_shm/parameters/s_max_us && echo 20 > /sys/module/cxl_shm/parameters/spin_us && echo 200 > /sys/module/cxl_shm/parameters/s_min_us'"* ]] \
  && ok "apply rx2 write order (s_max, spin, s_min)" || no "apply rx2 write: $w"
[ ! -s "$TD/stops" ] && ok "apply rx2 readback PASS" || no "apply rx2 stopped: $(cat "$TD/stops")"
[ "$(wc -l < "$TD/recv-mode-rx2.txt")" = 2 ] && ok "recv-mode-rx2.txt one line per VM" || no "recv-mode-rx2.txt lines"
echo "$STD" > "$TD/rb"; : > "$TD/stops"
recv_apply ds rx2b adaptive
grep -q "spin_us=50 (want 20" "$TD/stops" && ok "apply rx2 with a standard readback stops" || no "apply rx2 std readback: $(cat "$TD/stops")"
# defaults: no spin / s_min write, standard readback passes
unset RECV_SPIN_US RECV_SMIN_US; RECV_S_MAX_US=50 DSRX="fault_poll=0" DSFP=0; : > "$TD/cmds"; : > "$TD/stops"
recv_apply ds std adaptive
w=$(grep -m1 'sudo -n sh -c' "$TD/cmds")
[[ $w == *"echo 50 > /sys/module/cxl_shm/parameters/s_max_us'"* && $w != *spin_us* && $w != *s_min_us* ]] && ok "apply std: no spin / s_min write" || no "apply std write: $w"
[ ! -s "$TD/stops" ] && ok "apply std readback PASS" || no "apply std stopped: $(cat "$TD/stops")"
rm -rf "$TD"
[ $bad = 0 ] && echo "RECV RX2 TEST PASS" || { echo "RECV RX2 TEST FAIL ($bad)"; exit 1; }
