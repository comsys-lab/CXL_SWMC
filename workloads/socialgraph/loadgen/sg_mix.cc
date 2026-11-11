// sg-loadgen-mix <rw>: print the loadgen --mix value for read:write = rw:1 by request (sg_gen.h Mix), so the
// harness and the plugin's --opt rw= use one definition. usage: loadgen ... --mix "$(sg-loadgen-mix 100)" --opt rw=100
// With -v also prints the write-op split (fractions of all requests).
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "sg_gen.h"

int main(int argc, char **argv) {
  const bool verbose = argc == 3 && !std::strcmp(argv[2], "-v");
  if (argc < 2 || std::atof(argv[1]) <= 0 || (argc == 3 && !verbose))
    return std::fprintf(stderr, "usage: sg-loadgen-mix <rw> [-v]\n"), 2;
  sgl::Mix m(std::atof(argv[1]));
  std::printf("%s\n", m.loadgen_mix().c_str());
  if (verbose)
    for (uint32_t w = 0; w < sgl::kWriteOps; w++)
      std::printf("# %s %.6f %% of requests (%.4f %% of writes)\n", sgl::write_name(w),
                  100.0 * m.stream[sgl::kWrite] * m.write_op[w], 100.0 * m.write_op[w]);
  return 0;
}
