// Megalon coherence-instrumentation overhead probe (MOT1 v6; reports/M2-megalon-port-changes.md §13).
// Uses only the object API common to builds >= 68 (no GetObjectThreadCoh), so one binary runs on build 70 (no
// instrumentation) and on 71+ with MEGALON_COH_TIMERS=0/1; the library is chosen with LD_LIBRARY_PATH.
//
//   coh-overhead <sections> <reps>
// Node 0: one thread, one 64 B object, no contention; per rep: <sections> read sections, then <sections> write
// sections (whole line), each timed with steady_clock around the loop. Node 1 only waits in the end barrier.
// Output (stdout, one line per rep): COH-OV label=<COH_OV_LABEL> rep=<r> read_ns=<x> write_ns=<y>
#include <rackobj.h>

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <sections> <reps>\n", argv[0]);
        return 1;
    }
    const uint64_t n = std::strtoull(argv[1], nullptr, 10);
    const int reps = std::atoi(argv[2]);
    const char *label = std::getenv("COH_OV_LABEL") ? std::getenv("COH_OV_LABEL") : "unlabelled";
    const size_t node = rackobj::GetConfigSize_t("node_id");
    rackobj::Register(0);
    int rc = 0;
    if (node == 0) {
        const uint64_t id = 0x0c0e0f000000ull;
        int c = rackobj::ObjectCreate(id, 64);
        if (c != 0 && c != -EEXIST) {
            std::fprintf(stderr, "ObjectCreate: %d\n", c);
            rc = 2;
        }
        rackobj::ObjectHandle h;
        for (int r = 0; rc == 0 && r < reps; r++) {
            uint64_t sink = 0;
            auto t0 = std::chrono::steady_clock::now();
            for (uint64_t i = 0; i < n; i++) {
                do {
                    if (rackobj::ObjectReadStart(id, &h) != 0) {
                        rc = 3;
                        break;
                    }
                    sink += h.ptr[0];
                } while (!rackobj::ObjectReadEnd(&h));
            }
            auto t1 = std::chrono::steady_clock::now();
            for (uint64_t i = 0; i < n; i++) {
                if (rackobj::ObjectWriteStart(id, &h) != 0) {
                    rc = 4;
                    break;
                }
                for (size_t k = 0; k < 8; k++) reinterpret_cast<uint64_t *>(h.ptr)[k] = i;
                rackobj::ObjectWriteEnd(&h);
            }
            auto t2 = std::chrono::steady_clock::now();
            auto ns = [&](auto a, auto b) {
                return std::chrono::duration<double, std::nano>(b - a).count() / static_cast<double>(n);
            };
            std::printf("COH-OV label=%s rep=%d read_ns=%.2f write_ns=%.2f sink=%lu\n", label, r, ns(t0, t1),
                        ns(t1, t2), static_cast<unsigned long>(sink & 1));
            std::fflush(stdout);
        }
    }
    rackobj::NodeBarrier(1);
    rackobj::UnRegister();
    return rc;
}
