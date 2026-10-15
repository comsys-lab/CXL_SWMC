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
      std::istringstream in(v);  // "name value" lines; anything else is skipped
      std::string line;
      while (std::getline(in, line)) {
        std::istringstream ls(line);
        std::string name, val, extra;
        if (ls >> name >> val && !(ls >> extra) && val.find_first_not_of("0123456789") == std::string::npos &&
            name.find('=') == std::string::npos)
          kv["sys." + tag + "." + f + "." + name] = std::strtoull(val.c_str(), nullptr, 10);
      }
    }
  }
  std::ostringstream out;
  for (auto &p : kv) out << p.first << "=" << p.second << "\n";
  return out.str();
}

}  // namespace cxl::proc
