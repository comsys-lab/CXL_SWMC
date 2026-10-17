// dlopen the v3 shim, one write + one read section, check thread_coh / thread_anchor (2 processes = 2 nodes, file
// region). Kept from builds/megalon/76/checks/shim/shimtest.cc (build 76 checks); build 77 adds the probe and
// timed-event count checks (verifier MED-2). Build: g++ -std=c++17 -O2 -I<this dir> shimtest.cc -o shimtest -ldl
#include <dlfcn.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include "megalon_objapi.h"
int main(int argc, char **argv) {
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
  auto fn = (megalon_object_api_fn)dlsym(h, "megalon_object_api");
  const mshim::Api *a = fn();
  size_t node = a->node_id();
  printf("node %zu version %u info '%s' thread_coh %p\n", node, a->version, a->info, (void *)a->thread_coh);
  if (a->version != 3 || !a->thread_coh || !a->thread_anchor) return 2;
  a->reg(1);
  uint64_t id = 0x5157000 + node;
  if (a->create(id, 4096 + 64) != 0) return 3;
  mshim::Obj o;
  if (a->write_start(id, &o) != 0) return 4;
  memset(o.ptr, 7, o.size); a->write_end(&o);
  do { if (a->read_start(id, &o) != 0) return 5; } while (!a->read_end(&o));
  mshim::CohSnap s; a->thread_coh(&s);
  const bool hw = strstr(a->info, "/hwcc/") != nullptr;  // hwcc flavor: objects RW at create, no flush
  const bool det = getenv("MEGALON_COH_DETAIL") && strcmp(getenv("MEGALON_COH_DETAIL"), "1") == 0;  // build 76: switch_rw count only with DETAIL
  printf("node %zu: rs %lu ws %lu sample %lu sampled %lu check_ns %lu wstart %lu switch_rw %lu/%lu wflush %lu/%lu ns/%lu B tsc_khz %lu\n",
         node, s.read_sections, s.write_sections, s.check_sample, s.check_sampled, s.check_ns_sampled, s.wstart_ns,
         s.switch_rw_cnt, s.switch_rw_ns, s.wflush_cnt, s.wflush_ns, s.wflush_bytes, s.reserved[0]);
  bool ok = s.read_sections == 1 && s.write_sections == 1 && s.check_sampled == 1 && s.check_ns_sampled > 0 &&
            (hw ? s.wflush_bytes == 0 : s.wflush_bytes == 4096 + 64) && s.switch_rw_cnt == (det && !hw ? 1u : 0u) && (s.reserved[1] & 2) && s.wflush_cnt == 1 && s.wstart_ns >= s.switch_rw_ns;
  mshim::AnchorSnap an; a->thread_anchor(&an);
  printf("node %zu anchor: rs %lu ws %lu sampled %lu read lookup %lu nr %lu rseq %lu | write lookup %lu nr %lu wseq %lu wseq_end %lu\n",
         node, an.read_sections, an.write_sections, an.check_sampled, an.read_lookup_ns_sampled, an.read_nr_ns_sampled,
         an.rseq_ns_sampled, an.write_lookup_ns, an.write_nr_ns, an.wseq_ns, an.wseq_end_ns);
  ok = ok && an.read_sections == s.read_sections && an.check_sampled == s.check_sampled && an.read_lookup_ns_sampled == s.reserved[7] &&
       an.read_nr_ns_sampled > 0 && an.write_lookup_ns > 0 && an.wseq_ns > 0 && an.wseq_end_ns > 0 && an.reserved[0] == 1;  // build 76: write_sampled
  // build 77: probe calibration (reserved[1] ns, [2] ps; 1-200 ns with timers on) and timed-event counts
  // (reserved[3] (A), [4] (B)+(C), [5] (D)): every read section here is timed (check_sampled == read_sections), so
  // each timed-event count equals the exact event count
  const bool timers = (s.reserved[1] & 1) != 0;
  const bool all_timed = s.check_sampled == s.read_sections;
  auto tev = [&](uint64_t tc, uint64_t c) { return !timers ? tc == 0 : all_timed ? tc == c : tc <= c; };
  printf("node %zu probe %lu ns %lu ps | timed (A) %lu/%lu (B)+(C) %lu/%lu (D) %lu/%lu\n", node, an.reserved[1],
         an.reserved[2], an.reserved[3], s.stale_cnt, an.reserved[4], s.concur_cnt + s.meta_cnt, an.reserved[5],
         s.spin_cnt);
  const uint64_t pns = an.reserved[2] / 1000;  // ns and ps come from the same cycles: equal up to rounding
  const bool probe_ok = timers ? (an.reserved[2] >= 1000 && an.reserved[2] <= 200000 && an.reserved[1] + 1 >= pns &&
                                  an.reserved[1] <= pns + 1)
                               : (an.reserved[1] == 0 && an.reserved[2] == 0);
  ok = ok && probe_ok &&
       tev(an.reserved[3], s.stale_cnt) && tev(an.reserved[4], s.concur_cnt + s.meta_cnt) && tev(an.reserved[5], s.spin_cnt);
  printf("SHIM-TEST %s node %zu\n", ok ? "PASS" : "FAIL", node);
  fflush(stdout);
  _exit(ok ? 0 : 6);
}
