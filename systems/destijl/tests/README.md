# De Stijl v2 user-space tests (phase 1)

Tests for the header-only modules `include/swmc/ds_ring.h` (MPSC IKMB ring, spec section 2) and
`include/swmc/ds_ccd.h` (HPD/BPD directory and transactions, spec sections 3-5) of the kernel tree
(`kernels/destijl`, branch `destijl-v2`). Spec: `reports/design/DS2-protocol-spec.md` in destijl-control.

```
make test                 # headers standalone check + test_ring + test_ccd (about 10 s)
make headers              # each header alone: gcc -std=gnu11 -Wall -Wextra -Werror
make DS_INC=<kernel>/include test
```

`DS_INC` defaults to `../../../kernels/destijl/famfs-linux/include`, or to the destijl-v2 worktree layout
(`workspaces/destijl-v2/kernel/famfs-linux/include`). Binaries go to `build/` (git-ignored). Flags:
`-O2 -Wall -Wextra -Werror -fsanitize=undefined`.

## test_ring [messages=10^7] [nslots=256]
- Deterministic: init argument checks, FIFO, a producer blocks on a full ring until one consume,
  `-ETIMEDOUT` after the spin budget.
- Stress: 7 producers x 1 consumer; every message checked for payload integrity and per-producer
  sequence (no loss, no duplication, per-producer FIFO); ring empty and every producer complete at the end.

## test_ccd [faults_per_node=10^6] [seed]
8 simulated nodes over one shared HPD/BPD (64 huge pages = 32768 pages, `bpd_sets` = 16 so eviction runs
constantly) and per-node FETCH/INV/ACK rings (16 slots). Each node: a fault thread (25 % writes, 10 % of
accesses to 16 hot pages, working set 4096 pages spread over the 64 huge pages) following spec section 4
(synchronous, T = 0), and a remote handler thread following section 7 (drain INV, up to 64 FETCH, drain ACK).
Local state I/S/M per node per page; the per-page fh is a spinlock held only around decisions and commits
(locking contract in ds_ccd.h).

Checked continuously: no node enters M unless all others are I, no node enters S while another is M,
no ring produce or CCD poll times out (budget plus a 30 s no-progress watchdog), no INV without a BPD entry.
After quiescence: every BPD way and HPD lock idle, unique tags per set, every BPD entry has HPD exc, local
S/M nodes covered by BPD holders (or HPD sharers when the page has no BPD entry), an M entry's holder is the
only non-I node and no page is M without a BPD entry (M victims are downgraded before eviction), INV and
FETCH sent == handled. Coverage check: evictions, M-victim downgrades, merges and fetches all occur.

Asynchronous reads (SS, FETCH_ACK, spec section 6) are phase 3 and not exercised here.
