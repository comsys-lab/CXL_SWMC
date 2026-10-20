# umwait_ping

Question (reports/experiments/umwait-remote-wake.md): when node A arms UMONITOR/UMWAIT on a cache line of the shared
device and node B stores to that line, does A wake because of the store, and how fast compared with spin polling?

## Protocol
- Line X = device offset `--offset` (default from `--region`: msg_ring offset - 2 MiB, inside the HWcc app area of
  config/cxl_region-ring2m.yaml), line Y = X + 4096 (another page). One 2 MiB-aligned window is mapped from
  `--dev` (default /dev/dax0.0). Plain write-back loads/stores only.
- Handshake: responder stores HELLO_R to Y, initiator answers HELLO_I on X, responder ACK on Y; control values carry
  `--nonce` (same on both sides), so values left by an earlier run are not taken for this one's.
- Ping i: initiator busy-waits a uniform random gap (`--gap-us-min..max`, default 1..200 us), reads TSC, stores i to
  X, spins on Y == i, reads TSC. Responder waits for X to change (`--mode spin`: load + pause loop; `--mode umwait`:
  UMONITOR X, re-check, UMWAIT(`--c02`, now + `--deadline-cycles`) until X changes), then stores the value to Y.
- End: initiator stores STOP to X, responder answers BYE on Y. Timeouts: handshake `--start-timeout-s` (60),
  per-ping echo `--ping-timeout-ms` (1000), responder idle `--idle-timeout-s` (30); a side that gives up stores ABORT.

## Wake classification (responder, umwait mode)
Intel SDM: UMWAIT sets CF = 1 only when the OS time limit (IA32_UMWAIT_CONTROL, guest
/sys/devices/system/cpu/umwait_control/max_time) ended the wait; expiry of the instruction's own TSC deadline returns
CF = 0. So each return is classified with the TSC read after it:
`trigger` (CF=0, before deadline, X changed), `spurious` (CF=0, before deadline, X unchanged), `deadline` (CF=0, past
the deadline), `oslimit` (CF=1). Each ping ends as `precheck` (X changed before UMWAIT was entered), `trigger`,
`deadline` or `oslimit` (the store was only noticed after a timer-ended wait). Default deadline = 10 x max_time, so
the OS limit ends long waits; gaps longer than max_time therefore show several `oslimit` returns per wait, which is
expected; what matters is how the wait *ends*.

## Output
- Initiator `--csv`: `seq,gap_us,rtt_cycles,rtt_ns` per ping; summary line `summary role=init ... rtt_ns_p50/p99/max`.
- Responder `--csv`: `seq,end,loops,wait_cycles` per wait; summary `summary role=resp ... end_* ret_* loops_p50/p99/max
  wait_us_p50/p99/max`. With `--csv -` the CSV goes to stdout and the summary to stderr.
- TSC frequency: calibrated against CLOCK_MONOTONIC_RAW (3 x 100 ms) unless `--tsc-khz`; RTT uses the initiator's TSC
  only.

## Build and test
    nice -n 19 numactl --cpunodebind=1 --membind=1 ./build.sh <builds/umwait-ping/N>   # static, -mwaitpkg, manifest.txt
    <out>/umwait_ping --selftest --mode umwait --cpu 20 --cpu2 22 --n 20000 --csv /tmp/x.csv   # Host, fork + anon map

## Two-VM run (main session, inside the experiment approval)
    run-umwait.sh <recovery/umwait-remote-wake-vN>    # DRY=1 for prechecks only; see header for env knobs
