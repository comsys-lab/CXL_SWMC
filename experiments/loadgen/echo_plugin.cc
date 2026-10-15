// "echo" workload: harness self-test against test/echo_server.cc (known capacity = workers / service time).
// Streams: "req" (unordered) and "bg" (ordered, e.g. a fixed-rate background stream).
#include <atomic>
#include <cstring>

#include "workload.h"

namespace {
class Echo : public loadgen::Workload {
 public:
  bool init(const loadgen::Options &, uint32_t n, std::string *) override {
    targets_ = n;
    return true;
  }
  std::vector<loadgen::StreamSpec> streams() const override { return {{"req", false}, {"bg", true}}; }
  bool make(uint32_t stream, loadgen::Request *r, std::vector<uint8_t> *p) override {
    r->target = uint32_t(n_ % targets_);
    r->op = uint16_t(1 + stream);
    r->seq = n_++;
    p->resize(8);
    std::memcpy(p->data(), &r->seq, 8);
    return true;
  }
  void on_response(const loadgen::Request &r, bool, uint16_t status, const uint8_t *p, uint32_t len) override {
    uint64_t v = 0;
    if (len == 8) std::memcpy(&v, p, 8);
    if (status == 0 && v != r.seq) bad_.fetch_add(1);
  }
  bool finish(const std::string &, std::string *err) override {
    if (bad_.load()) *err = "echo mismatches " + std::to_string(bad_.load());
    return bad_.load() == 0;
  }

 private:
  uint32_t targets_ = 1;
  uint64_t n_ = 0;
  std::atomic<uint64_t> bad_{0};
};
LOADGEN_REGISTER("echo", Echo);
}  // namespace
