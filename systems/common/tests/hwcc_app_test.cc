// Host unit test (no shared memory): app range carving in cxl_region.h and the hwcc_app.h init/join protocol
// over a private buffer. Build: c++ -std=c++17 -O2 -pthread -I.. hwcc_app_test.cc -o hwcc_app_test. Exit 0 = PASS.
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

#include "hwcc_app.h"

#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)

int main(int argc, char **argv) {
  const char *cfg = argc > 1 ? argv[1] : "../../../config/cxl_region.yaml";
  const uint64_t dev = 103060340736ull;
  cxl::region r;
  std::string err;

  unsetenv("CXL_APP_HWCC_BYTES");
  CHECK(cxl::region_load(cfg, &r, &err, dev));
  CHECK(r.app.size == 0 && r.hwcc_alloc.end() == r.msg_ring.offset);
  const uint64_t alloc0 = r.hwcc_alloc.size;

  cxl::hwcc::layout L;
  uint64_t off_p = L.add("P", 8);
  uint64_t off_bmp = L.add("applied", (16u << 20) / 8);
  uint64_t off_seg = L.add("seg_count", 2 * 64);
  CHECK(off_p == sizeof(cxl::hwcc::header) && off_bmp % 64 == 0 && off_seg >= off_bmp + (2u << 20));

  setenv("CXL_APP_HWCC_BYTES", std::to_string(L.bytes() - 100).c_str(), 1);  // rounded up to 4 KiB
  CHECK(cxl::region_load(cfg, &r, &err, dev));
  CHECK(r.app.size == L.bytes() && r.app.end() == r.msg_ring.offset);
  CHECK(r.hwcc_alloc.offset == r.hwcc.offset && r.hwcc_alloc.end() == r.app.offset);
  CHECK(r.hwcc_alloc.size == alloc0 - L.bytes());

  setenv("CXL_APP_HWCC_BYTES", std::to_string(alloc0).c_str(), 1);  // leaves nothing for the system
  CHECK(!cxl::region_load(cfg, &r, &err, dev));
  setenv("CXL_APP_HWCC_BYTES", "12x", 1);
  CHECK(!cxl::region_load(cfg, &r, &err, dev));

  // init/join over a private buffer standing in for the mapping (app placed at offset 0 of the buffer)
  cxl::region fake;
  fake.app = cxl::range{0, L.bytes()};
  std::vector<uint64_t> mem(L.bytes() / 8, ~0ull);  // garbage from a "previous run"
  auto *map = reinterpret_cast<uint8_t *>(mem.data());
  bool ok1 = false;
  std::string err1;
  std::thread n1([&] { ok1 = cxl::hwcc::app_init(fake, map, L, 0x77, 2, 1, 5000, &err1); });
  std::this_thread::sleep_for(std::chrono::milliseconds(50));  // node 1 is already waiting
  CHECK(cxl::hwcc::app_init(fake, map, L, 0x77, 2, 0, 5000, &err));
  n1.join();
  CHECK(ok1);
  CHECK(cxl::hwcc::app_wait_all_joined(fake, map, 0x77, 1000));
  CHECK(*reinterpret_cast<uint64_t *>(map + off_bmp) == 0);  // fields zeroed by node 0

  cxl::hwcc::layout L2 = L;
  L2.add("extra", 8);
  CHECK(!cxl::hwcc::app_init(fake, map, L2, 0x77, 2, 1, 100, &err));  // different layout refused
  CHECK(!cxl::hwcc::app_init(fake, map, L, 0x78, 2, 1, 100, &err));   // other run_id: times out
  std::printf("HWCC-APP-TEST PASS (layout %llu B, hash %016llx)\n", (unsigned long long)L.bytes(),
              (unsigned long long)L.hash());
  return 0;
}
