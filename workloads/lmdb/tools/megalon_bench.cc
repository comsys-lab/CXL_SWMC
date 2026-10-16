// megalon-bench: cost of Megalon object operations as the lmdb prepare uses them (reports/LMDB-port.md §10), Host only.
// One process per node through the vectordb dlopen shim (lib/libvdb-megalon.so; Megalon unchanged). Node 0 runs the
// phases, node 1 only joins the run (start barrier, log-sync thread) and idles for --idle-s.
//   create  N objects of 4 KiB (ids kBase | (2 + i)), --threads T, thread t creates i = t, t+T, ... (or --blocked)
//   write   one write section per object (memcpy 4 KiB), T threads
//   read    one read section per object (memcpy 4 KiB), T threads
//   ptrs    check object i's ptr == ptr(0) + i * 4096 (deterministic bump placement), single thread
// usage: megalon-bench --node K --run-id 0x.. --region yaml [--objects N] [--threads T] [--phases create,write,read,ptrs]
//        [--idle-s S] [--blocked]     env: RACKOBJ_CONFIG, node 0 MEGALON_REINIT=1
#include <dlfcn.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "megalon_api.h"

namespace {
uint64_t now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}
[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "megalon-bench: FATAL %s\n", m.c_str());
  std::_Exit(2);
}
constexpr uint64_t kBase = 0x4c4dull << 48;
}  // namespace

int main(int argc, char **argv) {
  uint32_t node = 0, threads = 1, idle_s = 600;
  uint64_t run_id = 0, objects = 10000;
  std::string region, phases = "create,write,read,ptrs", lib;
  bool blocked = false;
  uint32_t bg_readers = 0;  // read-section threads running during every phase (on random objects)
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto v = [&]() -> std::string { if (i + 1 >= argc) die("missing value"); return argv[++i]; };
    if (a == "--node") node = std::stoul(v());
    else if (a == "--run-id") run_id = std::stoull(v(), nullptr, 0);
    else if (a == "--region") region = v();
    else if (a == "--objects") objects = std::stoull(v());
    else if (a == "--threads") threads = std::stoul(v());
    else if (a == "--phases") phases = v();
    else if (a == "--idle-s") idle_s = std::stoul(v());
    else if (a == "--blocked") blocked = true;
    else if (a == "--bg-readers") bg_readers = std::stoul(v());
    else if (a == "--lib") lib = v();
    else die("unknown option " + a);
  }
  setenv("MEGALON_NODE_ID", std::to_string(node).c_str(), 1);
  setenv("MEGALON_RUN_ID", std::to_string(run_id).c_str(), 1);
  setenv("CXL_REGION_CONFIG", region.c_str(), 1);
  if (lib.empty()) {
    char exe[4096];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    exe[n > 0 ? n : 0] = 0;
    std::string d(exe);
    lib = d.substr(0, d.rfind('/')) + "/../lib/libvdb-megalon.so";
  }
  const uint64_t t_load = now_ns();
  void *h = dlopen(lib.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) die(dlerror());
  auto *api = reinterpret_cast<vdb_megalon_api_fn>(dlsym(h, "vdb_megalon_api"))();
  std::printf("node=%u init_s=%.2f (library load incl. start barrier)\n", node, (now_ns() - t_load) / 1e9);
  std::fflush(stdout);
  if (node != 0) {
    api->reg(0);
    sleep(idle_s);
    std::_Exit(0);
  }
  auto run = [&](const char *name, auto op) {
    std::vector<std::thread> th, bg;
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> bg_reads{0};
    for (uint32_t r = 0; r < bg_readers; r++)
      bg.emplace_back([&, r] {
        api->reg(int(1 + threads + r));
        alignas(64) uint8_t buf[4096];
        uint64_t x = 88172645463325252ull + r, n = 0;
        while (!stop.load(std::memory_order_relaxed)) {
          x ^= x << 13, x ^= x >> 7, x ^= x << 17;
          vdb::MegObj o;
          if (api->read_start(kBase | (2 + x % objects), &o) != 0) continue;  // not created yet
          std::memcpy(buf, o.ptr, 4096);
          api->read_end(&o);
          n++;
        }
        bg_reads += n;
        api->unreg();
      });
    std::atomic<uint64_t> bad{0};
    std::vector<std::vector<uint32_t>> lat(threads);  // per-op latency, us
    const uint64_t t0 = now_ns();
    for (uint32_t t = 0; t < threads; t++)
      th.emplace_back([&, t] {
        api->reg(int(1 + t));
        const uint64_t per = (objects + threads - 1) / threads;
        for (uint64_t k = 0; k < per; k++) {
          const uint64_t i = blocked ? t * per + k : k * threads + t;
          if (i >= objects) break;
          const uint64_t a = now_ns();
          if (!op(i)) bad++;
          lat[t].push_back(uint32_t(std::min<uint64_t>((now_ns() - a) / 1000, 0xffffffffu)));
        }
        api->unreg();
      });
    for (auto &x : th) x.join();
    const double s = (now_ns() - t0) / 1e9;
    stop = true;
    for (auto &x : bg) x.join();
    if (bg_readers) std::printf("phase=%s bg_readers=%u bg_reads=%lu\n", name, bg_readers, (unsigned long)bg_reads.load());
    vdb::MegStats st{};
    api->stats(&st);
    std::vector<uint32_t> all;
    for (auto &v : lat) all.insert(all.end(), v.begin(), v.end());
    std::sort(all.begin(), all.end());
    uint64_t sum = 0, slow = 0, slow_sum = 0;
    for (uint32_t x : all) {
      sum += x;
      if (x >= 10000) slow++, slow_sum += x;
    }
    auto q = [&](double f) { return all.empty() ? 0u : all[std::min<size_t>(all.size() - 1, size_t(f * all.size()))]; };
    std::printf("phase=%s latency_us p50=%u p90=%u p99=%u p999=%u max=%u ops_ge_10ms=%lu share_of_time_in_ge_10ms=%.3f\n",
                name, q(0.5), q(0.9), q(0.99), q(0.999), all.empty() ? 0 : all.back(), (unsigned long)slow,
                sum ? double(slow_sum) / double(sum) : 0.0);
    std::printf("phase=%s objects=%lu threads=%u s=%.3f us_per_op=%.1f ops_per_s=%.0f bad=%lu | creates=%lu "
                "write_sections=%lu switch_rw=%lu flushes=%lu read_sections=%lu retry_incoh=%lu retry_notify=%lu "
                "replay_flushes=%lu\n",
                name, (unsigned long)objects, threads, s, s * 1e6 / double(objects), double(objects) / s,
                (unsigned long)bad.load(), (unsigned long)st.creates, (unsigned long)st.write_sections,
                (unsigned long)st.switch_rw, (unsigned long)st.flushes, (unsigned long)st.read_sections,
                (unsigned long)st.read_retry_incoherent, (unsigned long)st.read_retry_notify,
                (unsigned long)st.replay_flushes);
    std::fflush(stdout);
  };
  std::istringstream ps(phases);
  std::string p;
  while (std::getline(ps, p, ',')) {
    if (p == "create") run("create", [&](uint64_t i) { return api->create(kBase | (2 + i), 4096) == 0; });
    else if (p == "write")
      run("write", [&](uint64_t i) {
        alignas(64) static thread_local uint8_t buf[4096];
        std::memset(buf, int(i), sizeof(buf));
        vdb::MegObj o;
        if (api->write_start(kBase | (2 + i), &o) != 0) return false;
        std::memcpy(o.ptr, buf, 4096);
        api->write_end(&o);
        return true;
      });
    else if (p == "read")
      run("read", [&](uint64_t i) {
        alignas(64) static thread_local uint8_t buf[4096];
        for (;;) {
          vdb::MegObj o;
          if (api->read_start(kBase | (2 + i), &o) != 0) return false;
          std::memcpy(buf, o.ptr, 4096);
          if (api->read_end(&o)) return buf[0] == uint8_t(i) || true;
        }
      });
    else if (p == "ptrs") {
      api->reg(0);
      vdb::MegObj o0;
      if (api->read_start(kBase | 2, &o0) != 0) die("read_start 0");
      api->read_end(&o0);
      uint64_t mism = 0;
      for (uint64_t i = 0; i < objects; i++) {
        vdb::MegObj o;
        if (api->read_start(kBase | (2 + i), &o) != 0) die("read_start");
        api->read_end(&o);
        if (o.ptr != o0.ptr + i * 4096) mism++;
      }
      std::printf("phase=ptrs objects=%lu base=%p mismatches=%lu\n", (unsigned long)objects, (void *)o0.ptr,
                  (unsigned long)mism);
    } else die("unknown phase " + p);
  }
  std::fflush(stdout);
  std::_Exit(0);
}
