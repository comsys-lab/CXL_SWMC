// Load generator plugin interface (experiments/loadgen/README.md).
// The engine owns time: open-loop arrivals per stream, connections, latency/throughput statistics, warmup, rate
// sweeps and the max-throughput-under-SLO search. A workload plugin only says what each request is.
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace loadgen {

using Options = std::map<std::string, std::string>;  // --opt key=value (workload-specific)

struct StreamSpec {
  std::string name;      // e.g. "write", "search"
  bool ordered = false;  // true: all requests of this stream to one target go over one connection, in schedule
                         // order (the server sees them in the order they were made)
};

struct Request {
  uint32_t stream = 0;
  uint32_t target = 0;  // index into --target list
  uint16_t op = 0;      // frame op code
  uint64_t seq = 0;     // plugin's own id for this request (e.g. op index), handed back in on_response
  uint64_t sched_ns = 0;  // input to make(): the request's scheduled time (CLOCK_MONOTONIC ns); 0 in on_response
};

class Workload {
 public:
  virtual ~Workload() = default;
  // Parse options; num_targets servers will be used. Return false and set *err to refuse.
  virtual bool init(const Options &opts, uint32_t num_targets, std::string *err) = 0;
  virtual std::vector<StreamSpec> streams() const = 0;
  // Make the next request of `stream` at its send time. Called from one thread, in global schedule order across
  // all streams, so "everything made before this call" = "everything scheduled before this request".
  // Fill *r (target, op, seq) and *payload (cleared by the caller). Return false when the stream is exhausted
  // (the run stops at the end of the current step).
  virtual bool make(uint32_t stream, Request *r, std::vector<uint8_t> *payload) = 0;
  // Requests per arrival of `stream` (default 1 = every plugin before 2026-11-13). With B > 1 the engine calls make()
  // B times back to back for one scheduled arrival (same sched_ns, sent in that order); every copy is its own request
  // (latency from the shared scheduled time, counted in sent / done / achieved). The stream's rate stays arrivals/s.
  virtual uint32_t burst(uint32_t stream) const {
    (void)stream;
    return 1;
  }
  // Response for a request made earlier; called from receiver threads (one per connection, concurrently).
  // measured: the request was scheduled inside a measurement window.
  virtual void on_response(const Request &r, bool measured, uint16_t status, const uint8_t *payload,
                           uint32_t len) {
    (void)r, (void)measured, (void)status, (void)payload, (void)len;
  }
  // End of run: write workload-specific outputs (e.g. vectordb search results for offline recall) into out_dir.
  virtual bool finish(const std::string &out_dir, std::string *err) {
    (void)out_dir, (void)err;
    return true;
  }
  // One line of workload parameters for the run manifest.
  virtual std::string describe() const { return ""; }
};

// Static registry: each plugin .cc registers itself; the binary is built with the plugins it needs.
using Factory = std::function<std::unique_ptr<Workload>()>;
std::map<std::string, Factory> &registry();
struct Registrar {
  Registrar(const char *name, Factory f) { registry()[name] = std::move(f); }
};
#define LOADGEN_REGISTER(name, cls) \
  static ::loadgen::Registrar loadgen_registrar_##cls(name, [] { return std::make_unique<cls>(); })

}  // namespace loadgen
