// Host unit test of server/qcoh.h: the /proc/thread-self/swmc reader on fixture files in the kernel's format
// (kernels/popcorn_new include/swmc/swmc_task_stats.h, fs/proc/base.c proc_tid_swmc: "name value" lines), re-read by
// pread at offset 0 after the file changed; format errors; clock calibration.
// build/run: tests/build_qcoh_test.sh <out dir>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "qcoh.h"

static int fails = 0;
#define CHECK(c)                                                    \
  do {                                                              \
    if (!(c)) {                                                     \
      std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); \
      fails++;                                                      \
    }                                                               \
  } while (0)

static const char *kOrder[] = {"read_faults", "read_fault_ns", "read_msg_faults", "read_transactions", "read_msg_wait_ns",
                               "read_local_wait_ns", "write_faults", "write_fault_ns", "write_msg_faults",
                               "write_transactions", "write_msg_wait_ns", "write_local_wait_ns", "wp_faults",
                               "wp_fault_ns", "nack_retries", "fault_errors"};

static void write_fixture(const std::string &p, unsigned long long base) {
  FILE *f = std::fopen(p.c_str(), "w");
  for (int i = 0; i < 16; i++) std::fprintf(f, "%s %llu\n", kOrder[i], base * 100 + i);
  std::fclose(f);
}

int main() {
  const char *tmp = getenv("TMPDIR");
  const std::string p = std::string(tmp ? tmp : "/tmp") + "/qcoh_test_swmc." + std::to_string(getpid());
  write_fixture(p, 1);
  vdb::SwmcReader r;
  std::string err;
  CHECK(r.open(p.c_str(), &err));
  vdb::SwmcVals v;
  CHECK(r.read(&v));
  // base 1: value of line i = 100 + i
  CHECK(v.faults == (100 + 0) + (100 + 6));
  CHECK(v.fault_ns == (100 + 1) + (100 + 7));
  CHECK(v.transactions == (100 + 3) + (100 + 9));
  CHECK(v.msg_wait_ns == (100 + 4) + (100 + 10));
  CHECK(v.local_wait_ns == (100 + 5) + (100 + 11));
  write_fixture(p, 1000000000ull);  // larger numbers, same fd, pread at 0 sees the new contents
  CHECK(r.read(&v));
  CHECK(v.fault_ns == 2 * 100000000000ull + 1 + 7);
  // a line count change is a read failure (format changed)
  FILE *f = std::fopen(p.c_str(), "a");
  std::fprintf(f, "extra 1\n");
  std::fclose(f);
  CHECK(!r.read(&v));
  // missing counter -> open fails
  f = std::fopen(p.c_str(), "w");
  std::fprintf(f, "read_faults 1\nread_fault_ns 2\n");
  std::fclose(f);
  vdb::SwmcReader r2;
  CHECK(!r2.open(p.c_str(), &err));
  std::remove(p.c_str());
  vdb::SwmcReader r3;
  CHECK(!r3.open("/proc/thread-self/no-such-file", &err));
  // Megalon estimate rule (also experiments/vectordb/qcoh.py mg_estimate)
  uint64_t chk, re;
  vdb::mg_estimate(1000, 5000, 400, 10, 3, 2, 3000, 20, 64, &chk, &re);
  CHECK(chk == (1400 - 400) * 64 && re == 3 * ((3000 - 40) / 2));
  vdb::mg_estimate(1000, 5000, 400, 10, 3, 0, 0, 20, 64, &chk, &re);  // no timed failure: mean sampled section
  CHECK(re == 3 * ((6400 - 600) / 10));
  vdb::mg_estimate(100, 0, 100, 10, 0, 0, 0, 20, 64, &chk, &re);  // overhead larger than the sums: clamp at 0
  CHECK(chk == 0 && re == 0);
  const uint32_t c = vdb::calibrate_clock_ns(20000);
  std::printf("clock_ns=%u\n", c);
  CHECK(c > 0 && c < 2000);
  {  // SwmcKeyReader (opcoh.h file source): build-9+ keys found among other lines; a missing key refuses open
    const std::string p = std::string(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp") + "/swmc-keys.txt";
    auto put = [&](unsigned long long b, bool with_f) {
      FILE *f = std::fopen(p.c_str(), "w");
      for (int i = 0; i < 16; i++) std::fprintf(f, "%s %llu\n", kOrder[i], b + i);
      if (with_f) {
        const char *nf[] = {"is_faults", "is_fault_ns", "sm_faults", "sm_fault_ns", "wpu_faults", "wpu_fault_ns",
                            "nontrans_faults", "nontrans_fault_ns"};
        for (int i = 0; i < 8; i++) std::fprintf(f, "%s %llu\n", nf[i], b * 10 + i);
      }
      std::fclose(f);
    };
    const std::vector<std::string> F = {"is_faults", "is_fault_ns", "sm_faults", "sm_fault_ns", "wpu_faults",
                                        "wpu_fault_ns", "nontrans_faults", "nontrans_fault_ns"};
    std::string err;
    put(5, true);
    vdb::SwmcKeyReader r;
    CHECK(r.open(p.c_str(), F, &err));
    uint64_t x[8] = {};
    CHECK(r.read(x) && x[0] == 50 && x[1] == 51 && x[7] == 57);
    put(7, true);  // same layout, new values: re-read at offset 0
    CHECK(r.read(x) && x[3] == 73);
    put(9, false);  // build 8 file: no build-9 keys
    vdb::SwmcKeyReader r8;
    CHECK(!r8.open(p.c_str(), F, &err));
    CHECK(r8.open(p.c_str(), {"read_faults", "read_fault_ns", "write_faults", "write_fault_ns"}, &err));
    CHECK(r8.read(x) && x[0] == 9 && x[1] == 10 && x[2] == 15 && x[3] == 16);
  }
  std::printf("%s (%d failures)\n", fails ? "QCOH_TEST FAIL" : "QCOH_TEST PASS", fails);
  return fails ? 1 : 0;
}
