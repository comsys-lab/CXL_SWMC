// Process / node counters for workload servers (key=value text, appended to a server's stats reply).
// Read at the start and end of a measurement window (loadgen --stats-op) and differenced offline
// (experiments/loadgen/stats_delta.py). Linux /proc and sysfs only; nothing here changes system behaviour.
//
// Emitted keys (all cumulative):
//   t_mono_ns, t_real_ns                     clocks at the snapshot
//   thr.<comm>.n / .cpu_ticks / .run_ns / .wait_ns
//                                            this process's threads grouped by name (name_thread()); run/wait from
//                                            /proc/self/task/<tid>/schedstat (CPU time, run-queue wait)
//   thr.<comm>.swmc.<key>                    per-thread coherence counters if the kernel provides
//                                            /proc/self/task/<tid>/swmc ("name value" lines; Popcorn build >= 8)
//   kthr.<comm>.n / .cpu_ticks / .run_ns / .wait_ns
//                                            kernel threads whose comm starts with a configured prefix (e.g. cxl_recv)
//   irq.<name>                               /proc/interrupts rows summed over CPUs (TLB shootdowns, call IPIs, ...)
//   cpu.<field>                              /proc/stat "cpu" line (node-wide, ticks)
//   proc.minflt / proc.majflt                this process's page faults
//   sys.<dir>.<file>                         every single-integer file in configured sysfs dirs (e.g. Popcorn counters;
//                                            <dir> = path below /sys/kernel/ with '.' for '/', e.g. swmc.page_coherence)
//   sys.<dir>.<file>.<name>                  files of "name value" lines in those dirs (e.g. Popcorn instr/ histograms)
//   sys.<dir>.<file>.<name>.b<i>             "<name>_log2 v0 v1 .." lines (all integers) in those files: one key per
//                                            log2 bucket i (e.g. cxl_shm recv_adaptive r_sleep_found_us_log2)
//   sys.swmc.destijl.<name>                  De Stijl v2 counters (/sys/kernel/swmc/destijl), only when that directory
//                                            exists (De Stijl kernels): the fixed list destijl_counters() (a missing
//                                            file = 0) plus any other single-integer rx_* / replica_* / wr_* / srv_* /
//                                            ack_ph_* / fetch_stale file there; pending_now,
//                                            lambda_per_s, p95_us, ss_residence_max_us, replica_pages are gauges
//                                            (stats_delta.py keeps the end value)
// cpu_ticks are USER_HZ ticks (utime + stime); run_ns / wait_ns are ns from schedstat. Key names never contain '='
// or spaces. *.max_ns style keys are maxima, not sums (stats_delta.py reports their end value).
#pragma once

#include <dirent.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

// De Stijl v2 counter dir; servers use the default. Host tests compile with -DCXL_PROC_DESTIJL_DIR=<fake dir> to run
// the same snapshot code against synthetic counter files (workspaces/destijl-v2/phase5d/t/ds_dump.cc).
#ifndef CXL_PROC_DESTIJL_DIR
#define CXL_PROC_DESTIJL_DIR "/sys/kernel/swmc/destijl"
#endif

namespace cxl::proc {

inline void name_thread(const char *name) { pthread_setname_np(pthread_self(), name); }  // <= 15 chars

struct Opts {
  std::vector<std::string> kthread_prefixes;  // e.g. {"cxl_recv"}
  std::vector<std::string> irq_rows{"TLB", "CAL", "RES", "LOC"};
  std::vector<std::string> sysfs_dirs;  // e.g. {"/sys/kernel/swmc/page_coherence"}
};

inline std::string slurp(const std::string &path, size_t max = 1 << 20) {
  std::ifstream f(path);
  if (!f) return "";
  std::string s;
  s.resize(max);
  f.read(&s[0], std::streamsize(max));
  s.resize(size_t(f.gcount()));
  return s;
}

inline std::string trim(std::string s) {
  while (!s.empty() && (s.back() == '\n' || s.back() == ' ')) s.pop_back();
  return s;
}

// utime + stime (fields 14, 15) of a /proc/.../stat line; comm may contain spaces, so parse after the last ')'
inline uint64_t stat_ticks(const std::string &stat) {
  const size_t rp = stat.rfind(')');
  if (rp == std::string::npos) return 0;
  std::istringstream in(stat.substr(rp + 2));
  std::string f;
  uint64_t ut = 0, st = 0;
  for (int i = 3; i <= 15 && (in >> f); i++) {
    if (i == 14) ut = std::strtoull(f.c_str(), nullptr, 10);
    if (i == 15) st = std::strtoull(f.c_str(), nullptr, 10);
  }
  return ut + st;
}

inline std::vector<std::string> dir_entries(const std::string &d) {
  std::vector<std::string> v;
  if (DIR *dp = opendir(d.c_str())) {
    while (dirent *e = readdir(dp))
      if (e->d_name[0] != '.') v.push_back(e->d_name);
    closedir(dp);
  }
  return v;
}

// De Stijl v2 counters exported in every snapshot of a De Stijl kernel (DS2-protocol-spec.md §4-§8): every counter of
// kernel/swmc/destijl.c DS_DS_COUNTERS (kernel commit 2424ff336; tx_timeout / protocol_error are the error counters
// opcoh_check.py destijl requires to stay 0), the gauges pending_now, lambda_per_s, p95_us, ss_residence_max_us, and
// the spec's replica_* names (a kernel without them reads 0; further replica_* / rx_* files come from the dir scan)
inline const std::vector<std::string> &destijl_counters() {
  static const std::vector<std::string> v{
      "ccd_filtered",   "ccd_merged",      "ccd_write_wait",      "fetch_sent",         "inv_sent",
      "ack_sent",       "rx_fetch",        "rx_inv",              "rx_ack",             "read_complete",
      "bpd_insert",     "bpd_evict",       "bpd_evict_m",         "evict_self_fetch",   "tx_timeout",
      "protocol_error", "async_issued",    "async_installed",     "async_completed",    "async_dropped",
      "async_early_ack", "async_raced",    "async_fallback_mean", "async_fallback_p95", "async_fallback_write",
      "async_fallback_nomem", "async_probe", "async_superseded_write", "async_superseded_inv", "ack_deferred",
      "ack_retried",    "ack_overflow",    "pending_now",         "lambda_per_s",       "p95_us",
      "ss_residence_max_us", "replica_pages", "replica_create",  "replica_evict",      "replica_writeback",
      "replica_refresh"};
  return v;
}

inline uint64_t clock_ns(clockid_t c) {
  timespec ts;
  clock_gettime(c, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

inline std::string text(const Opts &o) {
  std::map<std::string, uint64_t> kv;
  kv["t_mono_ns"] = clock_ns(CLOCK_MONOTONIC);
  kv["t_real_ns"] = clock_ns(CLOCK_REALTIME);
  // this process's threads by name
  for (const std::string &tid : dir_entries("/proc/self/task")) {
    const std::string b = "/proc/self/task/" + tid + "/";
    const std::string comm = trim(slurp(b + "comm", 64));
    if (comm.empty()) continue;
    std::string key = "thr." + comm;
    for (char &c : key)
      if (c == ' ' || c == '=') c = '_';
    kv[key + ".n"] += 1;
    kv[key + ".cpu_ticks"] += stat_ticks(slurp(b + "stat", 4096));
    std::istringstream ss(slurp(b + "schedstat", 256));
    uint64_t run = 0, wait = 0;
    ss >> run >> wait;
    kv[key + ".run_ns"] += run;
    kv[key + ".wait_ns"] += wait;
    std::istringstream sw(slurp(b + "swmc", 1 << 16));
    std::string name;
    uint64_t v;
    while (sw >> name >> v) kv[key + ".swmc." + name] += v;
  }
  // kernel threads by comm prefix
  if (!o.kthread_prefixes.empty())
    for (const std::string &pid : dir_entries("/proc")) {
      if (pid.find_first_not_of("0123456789") != std::string::npos) continue;
      const std::string comm = trim(slurp("/proc/" + pid + "/comm", 64));
      for (const std::string &pre : o.kthread_prefixes)
        if (comm.compare(0, pre.size(), pre) == 0) {
          kv["kthr." + comm + ".n"] += 1;
          kv["kthr." + comm + ".cpu_ticks"] += stat_ticks(slurp("/proc/" + pid + "/stat", 4096));
          std::istringstream ss(slurp("/proc/" + pid + "/schedstat", 256));
          uint64_t run = 0, wait = 0;
          ss >> run >> wait;
          kv["kthr." + comm + ".run_ns"] += run;
          kv["kthr." + comm + ".wait_ns"] += wait;
        }
    }
  // interrupts rows summed over CPUs
  {
    std::istringstream in(slurp("/proc/interrupts"));
    std::string line;
    while (std::getline(in, line)) {
      std::istringstream ls(line);
      std::string row;
      ls >> row;
      if (row.empty() || row.back() != ':') continue;
      row.pop_back();
      for (const std::string &want : o.irq_rows)
        if (row == want) {
          uint64_t sum = 0;
          std::string tok;
          while (ls >> tok && tok.find_first_not_of("0123456789") == std::string::npos) sum += std::strtoull(tok.c_str(), nullptr, 10);
          kv["irq." + row] = sum;
        }
    }
  }
  // node-wide CPU
  {
    std::istringstream in(slurp("/proc/stat", 1 << 16));
    std::string cpu;
    in >> cpu;
    static const char *names[] = {"user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"};
    uint64_t v;
    for (const char *n : names)
      if (cpu == "cpu" && (in >> v)) kv[std::string("cpu.") + n] = v;
  }
  // own page faults (fields 10 and 12)
  {
    const std::string st = slurp("/proc/self/stat", 4096);
    const size_t rp = st.rfind(')');
    if (rp != std::string::npos) {
      std::istringstream in(st.substr(rp + 2));
      std::string f;
      for (int i = 3; i <= 12 && (in >> f); i++) {
        if (i == 10) kv["proc.minflt"] = std::strtoull(f.c_str(), nullptr, 10);
        if (i == 12) kv["proc.majflt"] = std::strtoull(f.c_str(), nullptr, 10);
      }
    }
  }
  // sysfs counters
  for (const std::string &d : o.sysfs_dirs) {
    std::string base = d;
    while (!base.empty() && base.back() == '/') base.pop_back();
    // tag: path below /sys/kernel/ with '/' -> '.' (e.g. swmc.page_coherence, cxl_shm.instr), else the last component
    std::string tag = base.compare(0, 12, "/sys/kernel/") == 0 ? base.substr(12) : base.substr(base.rfind('/') + 1);
    for (char &c : tag)
      if (c == '/') c = '.';
    for (const std::string &f : dir_entries(base)) {
      const std::string v = trim(slurp(base + "/" + f, 1 << 16));
      if (v.empty()) continue;
      if (v.find_first_not_of("0123456789") == std::string::npos) {
        kv["sys." + tag + "." + f] = std::strtoull(v.c_str(), nullptr, 10);
        continue;
      }
      std::istringstream in(v);  // "name value" lines and "<name>_log2 v0 v1 .." histogram lines; anything else skipped
      std::string line;
      while (std::getline(in, line)) {
        std::istringstream ls(line);
        std::string name, tok;
        std::vector<std::string> vals;
        if (!(ls >> name) || name.find('=') != std::string::npos) continue;
        while (ls >> tok) vals.push_back(tok);
        bool ints = !vals.empty();
        for (const std::string &x : vals)
          if (x.find_first_not_of("0123456789") != std::string::npos) ints = false;
        if (!ints) continue;
        const std::string key = "sys." + tag + "." + f + "." + name;
        if (vals.size() == 1) {
          kv[key] = std::strtoull(vals[0].c_str(), nullptr, 10);
        } else if (name.size() > 5 && name.compare(name.size() - 5, 5, "_log2") == 0) {
          // log2 histogram (e.g. cxl_shm recv_adaptive r_sleep_found_us_log2): one key per bucket, <key>.b<i>
          for (size_t i = 0; i < vals.size(); i++) kv[key + ".b" + std::to_string(i)] = std::strtoull(vals[i].c_str(), nullptr, 10);
        }
      }
    }
  }
  // De Stijl v2 counters (only on a De Stijl kernel: the directory exists); a listed file that is missing reads 0
  {
    const std::string ds = CXL_PROC_DESTIJL_DIR;
    if (DIR *dp = opendir(ds.c_str())) {
      closedir(dp);
      auto num = [](const std::string &v) {  // integer prefix ("12", "12 us"); anything else 0
        return std::strtoull(v.c_str(), nullptr, 10);
      };
      for (const std::string &f : destijl_counters()) kv["sys.swmc.destijl." + f] = num(trim(slurp(ds + "/" + f, 256)));
      // single-integer files with these prefixes (rx_*, replica_*, and since 2026-11-05 the writer / server phase
      // counters wr_* / srv_* / ack_ph_* and fetch_stale: the RocksDB N=4 write-wait RCA needed them per step). Only
      // prefixed names are opened: inspect / page_digest / histogram files are not read on every snapshot.
      static const char *const pfx[] = {"rx_", "replica_", "wr_", "srv_", "ack_ph_", "fetch_stale"};
      for (const std::string &f : dir_entries(ds)) {
        bool want = false;
        for (const char *p : pfx) want = want || f.compare(0, std::strlen(p), p) == 0;
        if (!want) continue;
        const std::string v = trim(slurp(ds + "/" + f, 256));
        if (!v.empty() && v.find_first_not_of("0123456789") == std::string::npos) kv["sys.swmc.destijl." + f] = num(v);
      }
    }
  }
  std::ostringstream out;
  for (auto &p : kv) out << p.first << "=" << p.second << "\n";
  return out.str();
}

}  // namespace cxl::proc
