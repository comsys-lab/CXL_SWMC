// recsys-rate: update sample rate for an operating point given as a fraction of all rows published per interval T
// (MOT1 v6, Ekko OSDI'22 rates; DESIGN.md §5). Replays the update trace in time order from --start exactly as the
// updater does (rows of the first hot[k] multi-hot ids per table, id mod rows; latest-wins dedup per interval) and
// counts the samples needed until the distinct rows of one interval reach round(F x total rows); repeats for
// --windows consecutive intervals. rate = mean samples per interval / T. Server parameters must match the run
// (--row-div, --row-cap, --multi-hot-div; only row_div/row_cap change rows).
// usage: recsys-rate --samples FILE --frac F --t-ms T [--start N (0)] [--windows W (10)] [--row-div N] [--row-cap R]
//                    [--multi-hot-div N]
// Prints key=value lines; rate_samples_per_s is the value for loadgen --fixed update=<rate>.
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_set>
#include <vector>

#include "../samples.h"
#include "../server/layout.h"

using namespace rsys;

int main(int argc, char **argv) {
  std::string path;
  double frac = 0, t_ms = 0;
  uint64_t start = 0, windows = 10;
  Params p;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto v = [&] { return i + 1 < argc ? std::string(argv[++i]) : std::string("0"); };
    if (a == "--samples") path = v();
    else if (a == "--frac") frac = std::stod(v());
    else if (a == "--t-ms") t_ms = std::stod(v());
    else if (a == "--start") start = std::stoull(v());
    else if (a == "--windows") windows = std::stoull(v());
    else if (a == "--row-div") p.row_div = std::stoull(v());
    else if (a == "--row-cap") p.row_cap = std::stoull(v());
    else if (a == "--multi-hot-div") p.multi_hot_div = std::stoul(v());
    else { std::fprintf(stderr, "unknown %s\n", a.c_str()); return 2; }
  }
  if (path.empty() || !(frac > 0 && frac <= 1) || !(t_ms > 0) || windows == 0) {
    std::fprintf(stderr, "usage: recsys-rate --samples FILE --frac F --t-ms T [--start N] [--windows W] [--row-div N] "
                         "[--row-cap R] [--multi-hot-div N]\n");
    return 2;
  }
  p.derive();
  int fd = open(path.c_str(), O_RDONLY);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) != 0) return std::perror(path.c_str()), 1;
  void *m = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_SHARED, fd, 0);
  if (m == MAP_FAILED) return std::perror("mmap"), 1;
  SamplesHeader h;
  std::memcpy(&h, m, sizeof(h));
  if (h.magic != kSamplesMagic || h.version != kSamplesVersion || h.record_bytes != sizeof(Sample) ||
      uint64_t(st.st_size) != sizeof(h) + h.count * sizeof(Sample)) {
    std::fprintf(stderr, "%s: not a v%u samples file\n", path.c_str(), kSamplesVersion);
    return 1;
  }
  const Sample *S = reinterpret_cast<const Sample *>(static_cast<const uint8_t *>(m) + sizeof(h));
  const uint64_t target = uint64_t(frac * double(p.total_rows) + 0.5);
  if (target == 0) return std::fprintf(stderr, "target rows per interval is 0\n"), 1;
  std::unordered_set<uint64_t> seen;
  seen.reserve(target * 2);
  std::vector<uint64_t> per;
  uint64_t pos = start, touched = 0;
  for (uint64_t w = 0; w < windows; w++) {
    seen.clear();
    uint64_t n = 0;
    while (seen.size() < target) {
      if (pos >= start + h.count * 1000) return std::fprintf(stderr, "target unreachable\n"), 1;
      const Sample &s = S[pos % h.count];
      for (uint32_t k = 0; k < kSparse; k++)
        for (uint32_t j = 0; j < p.hot[k]; j++) seen.insert(Params::key(k, p.row_of(k, s, j))), touched++;
      pos++, n++;
    }
    per.push_back(n);
  }
  double mean = 0;
  for (uint64_t x : per) mean += double(x);
  mean /= double(per.size());
  double sd = 0;
  for (uint64_t x : per) sd += (double(x) - mean) * (double(x) - mean);
  sd = per.size() > 1 ? std::sqrt(sd / double(per.size() - 1)) : 0;
  std::printf("samples=%s\nsource=%.96s\ntrace_samples=%lu\nstart=%lu\nfrac=%.9g\nt_ms=%.3f\ntotal_rows=%lu\n"
              "rows_per_round_target=%lu\nlookups_per_sample=%u\nwindows=%lu\nsamples_per_window_mean=%.1f\n"
              "samples_per_window_sd=%.1f\nsamples_per_window_min=%lu\nsamples_per_window_max=%lu\n"
              "distinct_per_touched=%.4f\nrate_samples_per_s=%.4f\n",
              path.c_str(), h.source, (unsigned long)h.count, (unsigned long)start, frac, t_ms,
              (unsigned long)p.total_rows, (unsigned long)target, p.lookups_per_sample, (unsigned long)windows, mean, sd,
              (unsigned long)*std::min_element(per.begin(), per.end()), (unsigned long)*std::max_element(per.begin(), per.end()),
              double(target) * double(windows) / double(touched), mean / (t_ms / 1000.0));
  return 0;
}
