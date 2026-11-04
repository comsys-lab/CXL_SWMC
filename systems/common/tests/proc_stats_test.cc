// Host helper for experiments/loadgen/test/stats_rca_export_test.py (no shared memory, no real /sys): prints
// cxl::proc::text() for a stub counter tree, so the test can check the keys the RocksDB N=4 write-wait RCA needs
// (sys.swmc.destijl.wr_* / srv_*, sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b<i>) end to end.
// Build (from systems/common/tests): c++ -std=c++17 -O2 -pthread -I.. -DCXL_PROC_DESTIJL_DIR='"stub/destijl"'
//   proc_stats_test.cc -o proc_stats_test
// usage: proc_stats_test <stub cxl_shm dir>   (run with cwd = the dir holding stub/; prints key=value lines)
#include <cstdio>

#include "proc_stats.h"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <stub cxl_shm dir>\n", argv[0]);
    return 2;
  }
  cxl::proc::Opts o;
  o.kthread_prefixes = {"cxl_recv"};
  o.sysfs_dirs = {argv[1]};
  std::fputs(cxl::proc::text(o).c_str(), stdout);
  return 0;
}
