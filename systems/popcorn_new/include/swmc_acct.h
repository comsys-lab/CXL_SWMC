/* Per-thread Popcorn coherence accounting readable by the thread itself at operation boundaries (MOT1 v6 Fig 2;
 * reports/MOT1-v6-redesign-draft.md §3, §6.1). CONTRACT fixed 2026-10-16 by the coordinator: workloads code against
 * this header; the kernel side (Popcorn build 9) implements it. rseq-style: the thread registers one area; the
 * kernel adds to it in process context (end of a coherence fault; pending IPI time on return to user mode), so a
 * plain load by the owning thread sees every completed fault/IPI. Durations in ns (kernel TSC clock), counts in
 * events. fault_*[]: only faults that performed an MSI transition; [0] read fault I->S, [1] not-present write fault
 * I->M or S->M, [2] write-protect upgrade S->M. Coherence faults without a transition (request rounds NACKed up to
 * the retry limit, or a wait behind a local holder that then hit) are a separate component in reserved[0..1]
 * (build 10, see below), NOT part of swmc_acct_coh_ns(). ipi_*: coherence-initiated TLB-shootdown IPIs handled on
 * this thread's CPU outside its counted faults (an IPI that arrives inside a counted fault is already part of that
 * fault's duration and is not added again; the kernel shows it as ipi_coh_infault_* in /proc/thread-self/swmc).
 * A kernel without support leaves the area all zero (swmc_acct_register returns -1); without cxl_shm loaded the
 * registration succeeds but nothing is counted. */
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

#define SWMC_ACCT_VERSION 1

struct swmc_acct {
  uint32_t version;      /* SWMC_ACCT_VERSION once registered */
  uint32_t flags;        /* reserved, 0 */
  uint64_t fault_ns[3];  /* full fault duration: exception entry to the end of the fault handler */
  uint64_t fault_cnt[3];
  uint64_t ipi_ns;       /* coherence TLB-shootdown IPI handling (vector body) on this thread's CPU, outside faults */
  uint64_t ipi_cnt;
  uint64_t reserved[7];  /* [0] nontrans_ns, [1] nontrans_cnt (build 10; full fault duration of coherence faults
                            without a transition; 0 on build 9); [2..6] reserved, 0 */
} __attribute__((aligned(64)));

/* Register the calling thread's area (one per thread; it must stay valid until the thread exits or calls
 * swmc_acct_unregister()). 0 = ok, -1 = unsupported.
 * Kernel interface (Popcorn build 9): the thread writes the area's address to /proc/thread-self/swmc_acct (only
 * the thread itself may; "0" unregisters). The kernel zeroes the area, sets version, and from then on copies the
 * values (counted from 0 at registration) into it on every return to user mode after a counted fault/IPI. The
 * area must stay mapped and writable until the thread exits or unregisters; registration ends at execve and is
 * not inherited by new threads/processes. Any failure (older kernel: no such file; misaligned area) -> -1. */
static inline int swmc_acct_register(struct swmc_acct *a) {
  char buf[32];
  int fd, n, ok;
  if (!a || ((uintptr_t)a & 63)) return -1;
  fd = open("/proc/thread-self/swmc_acct", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  n = snprintf(buf, sizeof(buf), "0x%llx\n", (unsigned long long)(uintptr_t)a);
  ok = n > 0 && write(fd, buf, (size_t)n) == (ssize_t)n;
  close(fd);
  return ok && a->version == SWMC_ACCT_VERSION ? 0 : -1;
}

#define SWMC_ACCT_NONTRANS_NS 0   /* index into reserved[] */
#define SWMC_ACCT_NONTRANS_CNT 1

static inline uint64_t swmc_acct_nontrans_ns(const volatile struct swmc_acct *a) {
  return a->reserved[SWMC_ACCT_NONTRANS_NS];
}
static inline uint64_t swmc_acct_nontrans_cnt(const volatile struct swmc_acct *a) {
  return a->reserved[SWMC_ACCT_NONTRANS_CNT];
}

/* Unregister the calling thread's area (before it goes out of scope or is freed). 0 = ok, -1 = failed. */
static inline int swmc_acct_unregister(void) {
  int fd = open("/proc/thread-self/swmc_acct", O_WRONLY | O_CLOEXEC), ok;
  if (fd < 0) return -1;
  ok = write(fd, "0\n", 2) == 2;
  close(fd);
  return ok ? 0 : -1;
}

/* Total coherence management time of the thread so far (ns): Fig 2 C_o = delta of this across an operation.
 * Transition faults + coherence IPIs outside them; the no-transition faults (reserved[0]) are reported separately. */
static inline uint64_t swmc_acct_coh_ns(const volatile struct swmc_acct *a) {
  return a->fault_ns[0] + a->fault_ns[1] + a->fault_ns[2] + a->ipi_ns;
}
