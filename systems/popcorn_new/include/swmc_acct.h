/* Per-thread Popcorn coherence accounting readable by the thread itself at operation boundaries (MOT1 v6 Fig 2;
 * reports/MOT1-v6-redesign-draft.md §3, §6.1). CONTRACT fixed 2026-10-16 by the coordinator: workloads code against
 * this header; the kernel side (Popcorn build 9) implements it. rseq-style: the thread registers one area; the
 * kernel adds to it in process context (end of a coherence fault; pending IPI time on return to user mode), so a
 * plain load by the owning thread sees every completed fault/IPI. Durations in ns (kernel TSC clock), counts in
 * events. Only faults that performed an MSI transition are counted; [0] I->S, [1] S->M, [2] write-protect upgrade.
 * A kernel without support (or cxl_shm not enabled) leaves the area all zero; swmc_acct_register returns -1. */
#pragma once
#include <stdint.h>

#define SWMC_ACCT_VERSION 1

struct swmc_acct {
  uint32_t version;      /* SWMC_ACCT_VERSION once registered */
  uint32_t flags;        /* reserved, 0 */
  uint64_t fault_ns[3];  /* full fault duration: exception entry to the end of the fault handler */
  uint64_t fault_cnt[3];
  uint64_t ipi_ns;       /* TLB-shootdown call-function IPI handling (irq entry..exit) on this thread's CPU */
  uint64_t ipi_cnt;
  uint64_t reserved[7];
} __attribute__((aligned(64)));

/* Register the calling thread's area (one per thread, lives until the thread exits). 0 = ok, -1 = unsupported.
 * Implementation (kernel interface, e.g. a write of the address to /proc/thread-self/swmc_acct) is provided below
 * by the build-9 owner; until then this stub returns -1 so workloads build and run with zeros. */
static inline int swmc_acct_register(struct swmc_acct *a) { (void)a; return -1; }

/* Total coherence management time of the thread so far (ns): Fig 2 C_o = delta of this across an operation. */
static inline uint64_t swmc_acct_coh_ns(const volatile struct swmc_acct *a) {
  return a->fault_ns[0] + a->fault_ns[1] + a->fault_ns[2] + a->ipi_ns;
}
