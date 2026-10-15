// Per-query coherence attribution (DESIGN.md §14; user decision 2026-10-16: every search response carries its own
// coherence time, search-serving threads only, the writer is reported separately by the window counters).
// Model: a search is a set of sections run by search threads: the start (E1 wait + delete-log replay) and one task
// per segment. Between two sections a search thread touches no shared memory (queues, merge, reply are process-
// local), so the change of a thread's own counters since its previous section end belongs to the section that just
// ended. Each search thread therefore reads its counters once at the end of each section and adds the delta to the
// query (no read at the section start). Sources:
//   page MSI  /proc/thread-self/swmc (Popcorn build >= 8: kernels/popcorn_new include/swmc/swmc_task_stats.h), the
//             handler time of this thread's managed faults; written only by the thread itself (no locks), so a
//             delta around a section is exact. Read on every system whose kernel provides the file (all three
//             systems run on build 8: identical overhead; all-HWcc and Megalon read zeros, cxl_shm unloaded).
//   Megalon   this thread's wrapper timers (megalon_backend.h MegTimers, 1-in-kSample sampled read sections).
// This file: the swmc reader (pread at offset 0 of a per-thread fd; parse "name value" lines) and the clock
// calibration used to subtract the timer-read overhead from Megalon's timed intervals.
#pragma once

#include <fcntl.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace vdb {

inline uint64_t qc_now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

// Timer-read overhead: median of back-to-back CLOCK_MONOTONIC reads. A timed interval [t_a, t_b] taken with two
// reads contains about one read's cost besides the measured code; Megalon's sampled intervals subtract it.
inline uint32_t calibrate_clock_ns(int n = 200000) {
  std::vector<uint32_t> d(static_cast<size_t>(n));
  for (int i = 0; i < n; i++) {
    const uint64_t a = qc_now_ns(), b = qc_now_ns();
    d[size_t(i)] = uint32_t(b - a);
  }
  std::nth_element(d.begin(), d.begin() + n / 2, d.end());
  return d[size_t(n / 2)];
}

// Megalon read-section coherence time (ns) from sampled sums (1 in `sample` sections timed), timer overhead c ns per
// timed interval: checks = max(0, start + end - 2 c sampled) x sample; re-executed work = retries x mean failed
// attempt (timed failed attempts: (failed_ns - c failed_timed) / failed_timed; none timed: the mean sampled section
// (start + body + end - 3 c sampled) / sampled). Same rule in experiments/vectordb/qcoh.py mg_estimate.
inline void mg_estimate(uint64_t start, uint64_t body, uint64_t end, uint64_t sampled, uint64_t retries,
                        uint64_t failed_timed, uint64_t failed_ns, uint64_t c, uint64_t sample, uint64_t *check,
                        uint64_t *reexec) {
  const uint64_t chk = start + end;
  *check = (chk > 2 * c * sampled ? chk - 2 * c * sampled : 0) * sample;
  *reexec = 0;
  if (retries && failed_timed) {
    const uint64_t cf = c * failed_timed;
    *reexec = retries * ((failed_ns > cf ? failed_ns - cf : 0) / failed_timed);
  } else if (retries && sampled) {
    const uint64_t sec = chk + body, cs = 3 * c * sampled;
    *reexec = retries * ((sec > cs ? sec - cs : 0) / sampled);
  }
}

struct SwmcVals {  // sums of the read_* and write_* counters (wp faults are a subset of write faults)
  uint64_t fault_ns = 0, msg_wait_ns = 0, local_wait_ns = 0, faults = 0, transactions = 0;
};

class SwmcReader {
 public:
  ~SwmcReader() {
    if (fd_ >= 0) ::close(fd_);
  }
  // Opens the calling thread's file (path names the calling thread, e.g. /proc/thread-self/swmc) and learns the
  // line index of every needed counter. false: no such file (kernel without Popcorn instrumentation) or a format
  // without one of the counters.
  bool open(const char *path, std::string *err) {
    fd_ = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd_ < 0) return *err = std::string("cannot open ") + path, false;
    char buf[kBuf];
    const ssize_t n = pread(fd_, buf, sizeof(buf) - 1, 0);
    if (n <= 0) return *err = std::string("cannot read ") + path, false;
    buf[n] = 0;
    for (int &x : idx_) x = -1;
    int line = 0;
    for (char *p = buf; *p && line < kMaxLines; line++) {
      char *sp = std::strchr(p, ' '), *nl = std::strchr(p, '\n');
      if (!sp || !nl || sp > nl) return *err = std::string(path) + ": line " + std::to_string(line) + " is not 'name value'", false;
      const std::string name(p, size_t(sp - p));
      for (int f = 0; f < kNF; f++)
        if (name == kNames[f]) idx_[f] = line;
      p = nl + 1;
    }
    lines_ = line;
    for (int f = 0; f < kNF; f++)
      if (idx_[f] < 0) return *err = std::string(path) + ": no counter " + kNames[f], false;
    for (int f = 0; f < kNF; f++) want_[idx_[f]] = f + 1;
    return true;
  }
  // One pread + parse. false on a short read or a changed line count (the caller counts the error and keeps the
  // previous values).
  bool read(SwmcVals *v) const {
    char buf[kBuf];
    const ssize_t n = pread(fd_, buf, sizeof(buf) - 1, 0);
    if (n <= 0) return false;
    buf[n] = 0;
    uint64_t x[kNF] = {};
    int line = 0;
    for (char *p = buf; *p && line < kMaxLines; line++) {
      char *sp = std::strchr(p, ' ');
      if (!sp) return false;
      char *end;
      const uint64_t val = std::strtoull(sp + 1, &end, 10);
      if (want_[line]) x[want_[line] - 1] = val;
      if (*end != '\n') return false;
      p = end + 1;
    }
    if (line != lines_) return false;
    v->fault_ns = x[kReadFaultNs] + x[kWriteFaultNs];
    v->msg_wait_ns = x[kReadMsgWait] + x[kWriteMsgWait];
    v->local_wait_ns = x[kReadLocalWait] + x[kWriteLocalWait];
    v->faults = x[kReadFaults] + x[kWriteFaults];
    v->transactions = x[kReadTx] + x[kWriteTx];
    return true;
  }
  bool ok() const { return fd_ >= 0; }

 private:
  enum { kReadFaults, kReadFaultNs, kReadTx, kReadMsgWait, kReadLocalWait, kWriteFaults, kWriteFaultNs, kWriteTx,
         kWriteMsgWait, kWriteLocalWait, kNF };
  static constexpr const char *kNames[kNF] = {"read_faults", "read_fault_ns", "read_transactions", "read_msg_wait_ns",
                                              "read_local_wait_ns", "write_faults", "write_fault_ns",
                                              "write_transactions", "write_msg_wait_ns", "write_local_wait_ns"};
  static constexpr int kBuf = 2048, kMaxLines = 64;
  int fd_ = -1, lines_ = 0;
  int idx_[kNF];
  uint8_t want_[kMaxLines] = {};  // line -> field + 1 (0: not needed)
};

}  // namespace vdb
