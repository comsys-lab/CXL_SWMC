// loadgen plugin "socialgraph" (workloads/socialgraph/DESIGN.md, experiments/loadgen/README.md, experiment doc
// reports/experiments/socialgraph-serving.md §2). Generators: sg_gen.h (keys, op mix, payload sizes).
//
// Streams (one open-loop arrival process each; the engine scales them together with --mix):
//   feed (SLO stream: getlinklist id1 limit 50 + multiget of the neighbour nodes), getnode, countlink, getlink,
//   write (ordered: one connection per target, so a VM's writer sees its writes in w_seq order).
// The read:write mix is BY REQUEST: --mix "$(sg-loadgen-mix <rw>)" gives each stream its share of all requests
// (writes = 1/(rw+1), scaling with the load as the vector DB updates). --opt rw=<rw> must name the same ratio; finish()
// compares the requests made with it (sg.txt mix_max_abs_pp, mix_ok: every op within 0.5 percentage points).
// Read target: uniform VM. Write target (write_route=owner, default): node slot % N (the VM owning the record, same
// rule as layout.h owned_by for slack slots / pool blocks), so every record has one writer; addnode: uniform VM.
// write_route=random: uniform VM for every write.
//
// Options: rw=R (required; 100 or 470 in the experiment), image=PATH (graph.img, read once at init: header checked,
//   node count / id base taken from it, build-time adjacency copied to a private ~1 GB table for the id2 choices
//   below; the file is unmapped before the run), gen=PATH (gen.json of the
//   image: nodes, id_base, limit, read_zipf and fisher_yates_perm_seed must match), nodes=N id_base=B (without image;
//   defaults image build 1: 3072626 / 1), seed=N (20261111), limit=50, read_perm_seed, write_perm_seed, read_zipf=0.8,
//   getnode_zipf=0.625, wlink_zipf=0.741, wnode_zipf=0.606, write_route=owner|random, coh_read_every=16 (log the
//   OpCoh block of 1 in K OK read responses; every write's), coh_max=8000000 (records kept).
// id2 (LinkBench ID2Chooser pExist: getlink 0.5, updatelink 0.9, deletelink 0.9, addlink 0.05): with probability
//   pExist a uniformly chosen slot of id1's build-time list (needs image=), else a uniform node id (a link that almost
//   surely does not exist). Without image= every id2 is uniform (counted as id2_no_image).
// Payloads: LinkBench LogNormal sizes capped at the slot data field (12 B link, 88 B node), bytes uniform in the
//   LinkBench datagen byte range. Link time = CLOCK_REALTIME ms. Node type 2048.
// Responses: frame status != 0 is an engine error; RespHead.status NotFound / Full are counted per op (not errors).
// Output (<out>/): sg.txt (counts, realized mix, statuses, feed rows/records, protocol errors), writes.bin (WriteLog per
//   write response: client-side commit log for the staleness join), op-coh.bin (CohLog per sampled response with an
//   OpCoh block). finish() fails on protocol errors (bad responses, w_seq mismatch).
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <stdexcept>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include "../../vectordb/proto.h"
#include "../proto.h"
#include "../server/layout.h"
#include "frame.h"
#include "sg_gen.h"
#include "workload.h"

namespace {

struct __attribute__((packed)) WriteLog {
  uint64_t recv_ns;    // CLOCK_REALTIME when the plugin got the response
  uint64_t id, version, commit_ns;  // WriteResp (0 if the response had no WriteResp body)
  uint32_t w_seq;      // sent w_seq (per target, from 1)
  uint32_t id2;        // link writes: id2 sent; node writes: 0
  uint16_t op, status; // sg op; RespHead.status (0xffff: frame error)
  uint8_t target, measured;
  uint16_t pad;
};
static_assert(sizeof(WriteLog) == 48, "WriteLog layout");

struct __attribute__((packed)) CohLog {
  uint64_t seq, recv_ns;  // recv_ns = CLOCK_MONOTONIC (joins loadgen raw-step done times)
  uint8_t measured, target;
  uint16_t status, op, pad;
  vdb::OpCoh c;
};

uint64_t clk(clockid_t id) {
  timespec ts;
  clock_gettime(id, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

// Minimal "key": value lookup in gen.json (numbers only).
bool json_num(const std::string &txt, const std::string &key, std::string *out) {
  const std::string k = "\"" + key + "\":";
  size_t p = txt.find(k);
  if (p == std::string::npos) return false;
  p += k.size();
  while (p < txt.size() && txt[p] == ' ') p++;
  size_t e = p;
  while (e < txt.size() && (std::isdigit(uint8_t(txt[e])) || txt[e] == '.' || txt[e] == '-' || txt[e] == 'e')) e++;
  if (e == p) return false;
  *out = txt.substr(p, e - p);
  return true;
}

class SocialGraph : public loadgen::Workload {
 public:
  bool init(const loadgen::Options &o, uint32_t targets, std::string *err) override {
    auto get = [&](const char *k, const std::string &d) {
      auto it = o.find(k);
      return it == o.end() ? d : it->second;
    };
    static const char *known[] = {"rw", "image", "gen", "nodes", "id_base", "seed", "limit", "read_perm_seed",
                                  "write_perm_seed", "read_zipf", "getnode_zipf", "wlink_zipf", "wnode_zipf",
                                  "write_route", "coh_read_every", "coh_max"};
    for (auto &kv : o)
      if (std::find_if(std::begin(known), std::end(known), [&](const char *k) { return kv.first == k; }) ==
          std::end(known))
        return *err = "unknown option " + kv.first, false;
    targets_ = targets;
    if (get("rw", "").empty()) return *err = "need --opt rw=<read:write by request, e.g. 100>", false;
    rw_ = std::stod(get("rw", ""));
    if (!(rw_ > 0)) return *err = "rw must be > 0", false;
    mix_ = sgl::Mix(rw_);
    wsampler_ = sgl::WriteOpSampler(mix_);
    seed_ = std::stoull(get("seed", "20261111"));
    rng_.seed(seed_);
    limit_ = uint16_t(std::stoul(get("limit", "50")));
    route_ = get("write_route", "owner");
    if (route_ != "owner" && route_ != "random") return *err = "write_route owner|random", false;
    coh_read_every_ = std::max<uint64_t>(1, std::stoull(get("coh_read_every", "16")));
    coh_max_ = std::stoull(get("coh_max", "8000000"));
    sgl::KeyParams kp;
    kp.read_perm_seed = std::stoull(get("read_perm_seed", std::to_string(sgl::kReadPermSeed)));
    kp.write_perm_seed = std::stoull(get("write_perm_seed", std::to_string(sgl::kWritePermSeed)));
    kp.read_zipf = std::stod(get("read_zipf", "0.8"));
    kp.getnode_zipf = std::stod(get("getnode_zipf", "0.625"));
    kp.wlink_zipf = std::stod(get("wlink_zipf", "0.741"));
    kp.wnode_zipf = std::stod(get("wnode_zipf", "0.606"));
    if (kp.read_perm_seed == kp.write_perm_seed) return *err = "read and write permutation seeds must differ", false;
    image_ = get("image", "");
    if (!image_.empty()) {
      if (!map_image(err)) return false;
      kp.n = hdr_.n_orig, id_base_ = hdr_.id_base;
      if (!get("nodes", "").empty() && std::stoull(get("nodes", "")) != kp.n) return *err = "nodes != image n_orig", false;
      if (!get("id_base", "").empty() && std::stoull(get("id_base", "")) != id_base_)
        return *err = "id_base != image id_base", false;
    } else {
      kp.n = std::stoull(get("nodes", "3072626"));
      id_base_ = std::stoull(get("id_base", "1"));
    }
    if (kp.n < 2 || kp.n > 0xffffffffull) return *err = "nodes out of range", false;
    gen_ = get("gen", "");
    if (!gen_.empty() && !check_gen(kp, err)) return false;
    keys_.build(kp);
    n_ = kp.n;
    next_wseq_.assign(targets, 0);
    return true;
  }

  std::vector<loadgen::StreamSpec> streams() const override {
    return {{"feed", false}, {"getnode", false}, {"countlink", false}, {"getlink", false}, {"write", true}};
  }

  bool make(uint32_t stream, loadgen::Request *r, std::vector<uint8_t> *p) override {
    if (stream >= sgl::kStreams) return false;
    made_[stream]++;
    if (stream != sgl::kWrite) r->target = targets_ == 1 ? 0 : uint32_t((unsigned __int128)rng_() * targets_ >> 64);
    switch (stream) {
      case sgl::kFeed: {
        const uint32_t slot = keys_.link_read(rng_);
        sg::FeedReq q{id_of(slot), sg::kAssocFriend, limit_, 0};
        put(p, &q, sizeof(q));
        r->op = sg::kOpFeed, r->seq = slot;
        return true;
      }
      case sgl::kGetNode: {
        const uint32_t slot = keys_.node_read(rng_);
        sg::NodeKeyReq q{id_of(slot)};
        put(p, &q, sizeof(q));
        r->op = sg::kOpGetNode, r->seq = slot;
        return true;
      }
      case sgl::kCountLink: {
        const uint32_t slot = keys_.link_read(rng_);
        sg::LinkListReq q{id_of(slot), sg::kAssocFriend, {0, 0, 0}};
        put(p, &q, sizeof(q));
        r->op = sg::kOpCountLink, r->seq = slot;
        return true;
      }
      case sgl::kGetLink: {
        const uint32_t slot = keys_.link_read(rng_);
        const uint32_t k = sgl::multiget_size(rng_);
        sg::GetLinkReq q{id_of(slot), sg::kAssocFriend, uint16_t(k), 0};
        p->resize(sizeof(q) + size_t(k) * 4);
        std::memcpy(p->data(), &q, sizeof(q));
        uint32_t *ids = reinterpret_cast<uint32_t *>(p->data() + sizeof(q));
        for (uint32_t i = 0; i < k; i++) {
          uint32_t id2 = 0;
          for (int tries = 0; tries < 100; tries++) {  // distinct id2s (LinkBench chooseMultipleForOp, <= 100 retries)
            id2 = pick_id2(slot, socialgraph::linkbench::kPGetExist);
            if (std::find(ids, ids + i, id2) == ids + i) break;
          }
          std::memcpy(ids + i, &id2, 4);
        }
        r->op = sg::kOpGetLink, r->seq = slot;
        return true;
      }
      default:
        return make_write(r, p);
    }
  }

  void on_response(const loadgen::Request &r, bool measured, uint16_t fstatus, const uint8_t *p,
                   uint32_t len) override {
    const uint32_t oi = op_index(r.op);
    if (fstatus != frame::kStatusOk) {
      frame_err_[oi].fetch_add(1);
      if (is_write(r.op)) log_write(r, measured, 0xffff, nullptr);
      return;
    }
    sg::RespHead h{};
    if (len < sizeof(h)) return bad(oi, "short");
    std::memcpy(&h, p, sizeof(h));
    if (h.op != r.op) return bad(oi, "op");
    if (h.status > kStatusBusy) return bad(oi, "status");
    status_[oi][h.status].fetch_add(1);
    if (h.status == sg::kStatusBad) bad_status_.fetch_add(1);
    const uint8_t *b = p + sizeof(h);
    const uint32_t bl = len - uint32_t(sizeof(h));
    if (is_write(r.op)) {
      const sg::WriteResp *wr = nullptr;
      sg::WriteResp w{};
      if (bl >= sizeof(w)) {
        std::memcpy(&w, b, sizeof(w));
        wr = &w;
        if (w.w_seq != uint32_t(r.seq)) wseq_mismatch_.fetch_add(1);
      } else if (h.status == sg::kStatusOk) {
        return bad(oi, "write body");
      }
      log_write(r, measured, h.status, wr);
      if (h.status == sg::kStatusOk) maybe_coh(r, measured, h, b, bl, sizeof(w), true);
      return;
    }
    if (h.status != sg::kStatusOk) return;
    size_t body = 0;
    switch (r.op) {
      case sg::kOpFeed: {
        sg::FeedResp f;
        if (bl < sizeof(f)) return bad(oi, "feed body");
        std::memcpy(&f, b, sizeof(f));
        body = sizeof(f) + size_t(f.n) * sizeof(sg::FeedRow);
        if (f.n > limit_ || bl < body) return bad(oi, "feed rows");
        feed_rows_.fetch_add(f.n);
        feed_missing_.fetch_add(f.missing);
        feed_records_.fetch_add(h.records);
        feed_ok_.fetch_add(1);
        break;
      }
      case sg::kOpGetNode: {
        sg::NodeResp nr;
        if (bl < sizeof(nr)) return bad(oi, "node body");
        std::memcpy(&nr, b, sizeof(nr));
        body = sizeof(nr) + nr.data_len;
        if (nr.data_len > sg::kNodeDataCap || bl < body || nr.id != id_of(uint32_t(r.seq))) return bad(oi, "node");
        break;
      }
      case sg::kOpCountLink:
        body = sizeof(sg::CountResp);
        if (bl < body) return bad(oi, "count body");
        break;
      case sg::kOpGetLink: {
        sg::GetLinkResp gr;
        if (bl < sizeof(gr)) return bad(oi, "getlink body");
        std::memcpy(&gr, b, sizeof(gr));
        body = sizeof(gr) + size_t(gr.n) * sizeof(sg::LinkRow);
        if (gr.n > 127 || bl < body) return bad(oi, "getlink rows");
        getlink_rows_.fetch_add(gr.n);
        break;
      }
      default:
        return bad(oi, "op");
    }
    maybe_coh(r, measured, h, b, bl, body, false);
  }

  bool finish(const std::string &dir, std::string *err) override {
    {
      std::lock_guard<std::mutex> g(mu_);
      if (!dump(dir + "/writes.bin", wlog_.data(), wlog_.size() * sizeof(WriteLog)) ||
          !dump(dir + "/op-coh.bin", clog_.data(), clog_.size() * sizeof(CohLog)))
        return *err = "cannot write writes.bin / op-coh.bin", false;
    }
    FILE *t = std::fopen((dir + "/sg.txt").c_str(), "w");
    if (!t) return *err = "cannot write sg.txt", false;
    uint64_t total = 0;
    for (uint32_t s = 0; s < sgl::kStreams; s++) total += made_[s];
    std::fprintf(t, "rw=%g\nrequests_made=%lu\n", rw_, (unsigned long)total);
    // realized mix (percent of all requests made) vs target; writes split by op
    double maxpp = 0;
    auto mixline = [&](const char *name, uint64_t c, double target) {
      const double pct = total ? 100.0 * double(c) / double(total) : 0;
      maxpp = std::max(maxpp, std::fabs(pct - 100.0 * target));
      std::fprintf(t, "made.%s=%lu pct=%.4f target_pct=%.4f\n", name, (unsigned long)c, pct, 100.0 * target);
    };
    for (uint32_t s = 0; s < sgl::kWrite; s++) mixline(sgl::stream_name(s), made_[s], mix_.stream[s]);
    mixline("write", made_[sgl::kWrite], mix_.stream[sgl::kWrite]);
    for (uint32_t w = 0; w < sgl::kWriteOps; w++)
      mixline(sgl::write_name(w), wmade_[w], mix_.stream[sgl::kWrite] * mix_.write_op[w]);
    std::fprintf(t, "mix_max_abs_pp=%.4f\nmix_ok=%d\n", maxpp, total >= 100000 ? int(maxpp <= 0.5) : -1);
    for (uint32_t i = 0; i < kOps; i++)
      std::fprintf(t, "resp.%s ok=%lu notfound=%lu full=%lu bad_status=%lu busy=%lu frame_err=%lu bad=%lu\n",
                   kOpNames[i], (unsigned long)status_[i][0].load(), (unsigned long)status_[i][1].load(),
                   (unsigned long)status_[i][2].load(), (unsigned long)status_[i][3].load(),
                   (unsigned long)status_[i][kStatusBusy].load(), (unsigned long)frame_err_[i].load(),
                   (unsigned long)bad_[i].load());
    const uint64_t fo = feed_ok_.load();
    std::fprintf(t, "feed_ok=%lu feed_rows_mean=%.4f feed_records_mean=%.4f feed_missing=%lu getlink_rows=%lu\n",
                 (unsigned long)fo, fo ? double(feed_rows_.load()) / double(fo) : 0.0,
                 fo ? double(feed_records_.load()) / double(fo) : 0.0, (unsigned long)feed_missing_.load(),
                 (unsigned long)getlink_rows_.load());
    std::fprintf(t, "id2_from_image=%lu id2_uniform=%lu id2_no_image=%lu image_links=%zu image_load_ms=%.0f\n",
                 (unsigned long)id2_img_, (unsigned long)id2_uni_, (unsigned long)id2_noimg_, csr_id2_.size(), csr_ms_);
    std::fprintf(t, "wseq_mismatch=%lu bad_responses=%lu first_bad=%s\n", (unsigned long)wseq_mismatch_.load(),
                 (unsigned long)bad_total(), first_bad_.c_str());
    std::fprintf(t, "write_records=%zu write_record_bytes=%zu coh_records=%zu coh_record_bytes=%zu coh_dropped=%lu\n",
                 wlog_.size(), sizeof(WriteLog), clog_.size(), sizeof(CohLog), (unsigned long)coh_dropped_.load());
    for (uint32_t i = 0; i < targets_; i++) std::fprintf(t, "target%u.w_seq_last=%u\n", i, next_wseq_[i]);
    std::fclose(t);
    if (bad_total() || wseq_mismatch_.load())
      return *err = "socialgraph protocol errors: bad=" + std::to_string(bad_total()) +
                    " wseq_mismatch=" + std::to_string(wseq_mismatch_.load()) + " (" + first_bad_ + ")", false;
    return true;
  }

  std::string describe() const override {
    const auto &k = keys_.params();
    std::ostringstream s;
    s << "socialgraph rw=" << rw_ << " mix=" << mix_.loadgen_mix() << " nodes=" << k.n << " id_base=" << id_base_
      << " image=" << (image_.empty() ? "-" : image_) << " gen=" << (gen_.empty() ? "-" : gen_) << " limit=" << limit_
      << " seed=" << seed_ << " read_perm_seed=" << k.read_perm_seed << " write_perm_seed=" << k.write_perm_seed
      << " read_zipf=" << k.read_zipf << " getnode_zipf=" << k.getnode_zipf << " wlink_zipf=" << k.wlink_zipf
      << " wnode_zipf=" << k.wnode_zipf << " write_route=" << route_ << " coh_read_every=" << coh_read_every_
      << " coh_max=" << coh_max_ << " perm=fisher-yates-splitmix64 zipf=exact-pmf-alias";
    return s.str();
  }

 private:
  static constexpr uint32_t kOps = 10;
  // RespHead.status 4 = Busy (record read gave up after the retry bound), added to proto.h by part 3 (server);
  // counted per op, not a protocol error. Defined here so this plugin builds against proto.h at 29a23ccd7 too.
  static constexpr uint16_t kStatusBusy = 4;
  static constexpr const char *kOpNames[kOps] = {"feed",       "getnode",    "countlink", "getlink",    "addlink",
                                                 "updatelink", "deletelink", "addnode",   "updatenode", "deletenode"};
  static uint32_t op_index(uint16_t op) {
    switch (op) {
      case sg::kOpFeed: return 0;
      case sg::kOpGetNode: return 1;
      case sg::kOpCountLink: return 2;
      case sg::kOpGetLink: return 3;
      case sg::kOpAddLink: return 4;
      case sg::kOpUpdateLink: return 5;
      case sg::kOpDeleteLink: return 6;
      case sg::kOpAddNode: return 7;
      case sg::kOpUpdateNode: return 8;
      default: return 9;
    }
  }
  static bool is_write(uint16_t op) { return op >= sg::kOpAddLink && op <= sg::kOpDeleteNode; }
  uint64_t id_of(uint32_t slot) const { return id_base_ + slot; }
  static void put(std::vector<uint8_t> *p, const void *q, size_t n) {
    p->resize(n);
    std::memcpy(p->data(), q, n);
  }

  bool make_write(loadgen::Request *r, std::vector<uint8_t> *p) {
    namespace lb = socialgraph::linkbench;
    const uint32_t w = wsampler_.draw(rng_);
    wmade_[w]++;
    uint32_t slot = 0, id2 = 0;
    bool keyed = true;
    switch (w) {
      case sgl::kAddLink: slot = keys_.link_write(rng_); id2 = pick_id2(slot, lb::kPAddExist); break;
      case sgl::kUpdateLink: slot = keys_.link_write(rng_); id2 = pick_id2(slot, lb::kPUpdateExist); break;
      case sgl::kDeleteLink: slot = keys_.link_write(rng_); id2 = pick_id2(slot, lb::kPDeleteExist); break;
      case sgl::kUpdateNode: slot = keys_.node_update(rng_); break;
      case sgl::kDeleteNode: slot = keys_.node_delete(rng_); break;
      default: keyed = false; break;  // addnode
    }
    if (keyed && route_ == "owner") r->target = slot % targets_;
    else r->target = targets_ == 1 ? 0 : uint32_t((unsigned __int128)rng_() * targets_ >> 64);
    const uint32_t wseq = ++next_wseq_[r->target];
    if (w <= sgl::kDeleteLink) {
      static const uint16_t ops[] = {sg::kOpAddLink, sg::kOpUpdateLink, sg::kOpDeleteLink};
      const uint32_t dl = w == sgl::kDeleteLink ? 0 : sgl::payload_size(rng_, lb::kLinkDataSize, sg::kEdgeDataCap);
      sg::LinkWriteReq q{id_of(slot), id2, sg::kAssocFriend, uint16_t(dl), clk(CLOCK_REALTIME) / 1000000ull, wseq, 0};
      p->resize(sizeof(q) + dl);
      std::memcpy(p->data(), &q, sizeof(q));
      fill_bytes(p->data() + sizeof(q), dl, lb::kLinkDatagenStartByte, lb::kLinkDatagenEndByte);
      r->op = ops[w];
    } else {
      static const uint16_t ops[] = {sg::kOpAddNode, sg::kOpUpdateNode, sg::kOpDeleteNode};
      const uint32_t dl = w == sgl::kDeleteNode ? 0 : sgl::payload_size(rng_, lb::kNodeDataSize, sg::kNodeDataCap);
      sg::NodeWriteReq q{keyed ? id_of(slot) : 0, uint32_t(lb::kDefaultNodeType), uint16_t(dl), 0, wseq, 0};
      p->resize(sizeof(q) + dl);
      std::memcpy(p->data(), &q, sizeof(q));
      fill_bytes(p->data() + sizeof(q), dl, lb::kNodeDatagenStartByte, lb::kNodeDatagenEndByte);
      r->op = ops[w - sgl::kAddNode];
    }
    r->seq = (uint64_t(id2) << 32) | wseq;
    return true;
  }

  void fill_bytes(uint8_t *d, uint32_t n, int lo, int hi) {
    for (uint32_t i = 0; i < n; i++) d[i] = uint8_t(lo + int(rng_() % uint64_t(hi - lo)));
  }

  // id2 for (id1 slot, pExist): an existing build-time link of slot with probability pexist (image needed), else a
  // uniform node id.
  uint32_t pick_id2(uint32_t slot, double pexist) {
    if (sgl::u01(rng_) < pexist) {
      if (csr_off_.empty()) {
        id2_noimg_++;
      } else {
        const uint64_t a = csr_off_[slot], n = csr_off_[slot + 1] - a;
        if (n) return id2_img_++, csr_id2_[a + uint64_t((unsigned __int128)rng_() * n >> 64)];
      }
    }
    id2_uni_++;
    return uint32_t(id_of(keys_.uniform(rng_)));
  }

  // Map the image read-only, check its header and copy the build-time adjacency (every occupied slot of every list,
  // newest first) into a private CSR (~1 GB for Orkut), then unmap: make() never touches the file (no page-cache
  // misses on the scheduling thread, which would show up as send lag).
  bool map_image(std::string *err) {
    const uint64_t t0 = clk(CLOCK_MONOTONIC);
    int fd = ::open(image_.c_str(), O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) return *err = "cannot open image " + image_, false;
    if (pread(fd, &hdr_, sizeof(hdr_), 0) != ssize_t(sizeof(hdr_))) return ::close(fd), *err = "short image header", false;
    const std::string bad = sg::check_header(hdr_, uint64_t(st.st_size));
    if (!bad.empty()) return ::close(fd), *err = "image header: " + bad, false;
    void *m = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_SHARED, fd, 0);
    ::close(fd);
    if (m == MAP_FAILED) return *err = "cannot map " + image_, false;
    madvise(m, size_t(st.st_size), MADV_SEQUENTIAL);
    sg::View v(m);
    const uint64_t n = hdr_.n_orig;
    csr_off_.assign(n + 1, 0);
    csr_id2_.reserve(hdr_.n_links);
    for (uint64_t s = 0; s < n; s++) {
      csr_off_[s] = csr_id2_.size();
      sg::walk_links(v, s, [&](const sg::EdgeSlot &e) { return csr_id2_.push_back(e.id2), true; });
    }
    csr_off_[n] = csr_id2_.size();
    munmap(m, size_t(st.st_size));
    if (csr_id2_.size() != hdr_.n_links)
      return *err = "image adjacency: " + std::to_string(csr_id2_.size()) + " slots != n_links " +
                    std::to_string(hdr_.n_links), false;
    csr_ms_ = double(clk(CLOCK_MONOTONIC) - t0) / 1e6;
    std::fprintf(stderr, "socialgraph: image adjacency %lu links of %lu nodes loaded in %.0f ms\n",
                 (unsigned long)csr_id2_.size(), (unsigned long)n, csr_ms_);
    return true;
  }

  bool check_gen(const sgl::KeyParams &kp, std::string *err) {
    std::ifstream in(gen_);
    if (!in) return *err = "cannot read " + gen_, false;
    std::stringstream ss;
    ss << in.rdbuf();
    const std::string txt = ss.str();
    std::string v;
    auto need = [&](const char *key) {
      if (!json_num(txt, key, &v)) throw std::runtime_error(std::string("gen.json: no ") + key);
      return v;
    };
    try {
      if (std::stoull(need("nodes")) != kp.n) return *err = "gen.json nodes != " + std::to_string(kp.n), false;
      if (std::stoull(need("id_base")) != id_base_) return *err = "gen.json id_base differs", false;
      if (std::stoull(need("limit")) != limit_) return *err = "gen.json limit differs", false;
      if (std::fabs(std::stod(need("read_zipf")) - kp.read_zipf) > 5e-4) return *err = "gen.json read_zipf differs", false;
      if (std::stoull(need("fisher_yates_perm_seed")) != kp.read_perm_seed)
        return *err = "gen.json fisher_yates_perm_seed != read_perm_seed", false;
    } catch (const std::exception &e) {
      return *err = e.what(), false;
    }
    return true;
  }

  void bad(uint32_t oi, const char *why) {
    if (bad_[oi].fetch_add(1) == 0) {
      std::lock_guard<std::mutex> g(mu_);
      if (first_bad_.empty()) first_bad_ = std::string(kOpNames[oi]) + ":" + why;
    }
  }
  uint64_t bad_total() const {
    uint64_t s = 0;
    for (const auto &b : bad_) s += b.load();
    return s;
  }

  void log_write(const loadgen::Request &r, bool measured, uint16_t status, const sg::WriteResp *w) {
    WriteLog l{};
    l.recv_ns = clk(CLOCK_REALTIME);
    if (w) l.id = w->id, l.version = w->version, l.commit_ns = w->commit_ns;
    l.w_seq = uint32_t(r.seq), l.id2 = uint32_t(r.seq >> 32), l.op = r.op, l.status = status;
    l.target = uint8_t(r.target), l.measured = measured;
    std::lock_guard<std::mutex> g(mu_);
    wlog_.push_back(l);
  }

  void maybe_coh(const loadgen::Request &r, bool measured, const sg::RespHead &h, const uint8_t *b, uint32_t bl,
                 size_t body, bool write) {
    if (!(h.flags & sg::kRespCoh)) return no_coh_.fetch_add(1), void();
    if (bl < body + sizeof(vdb::OpCoh)) return bad(op_index(r.op), "coh block");
    if (!write && coh_read_n_.fetch_add(1) % coh_read_every_) return;
    CohLog c{};
    c.seq = r.seq, c.recv_ns = clk(CLOCK_MONOTONIC), c.measured = measured, c.target = uint8_t(r.target);
    c.status = h.status, c.op = r.op;
    std::memcpy(&c.c, b + body, sizeof(c.c));
    std::lock_guard<std::mutex> g(mu_);
    if (clog_.size() >= coh_max_) return coh_dropped_.fetch_add(1), void();
    clog_.push_back(c);
  }

  static bool dump(const std::string &path, const void *d, size_t n) {
    FILE *f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const bool ok = std::fwrite(d, 1, n, f) == n;
    return std::fclose(f) == 0 && ok;
  }

  uint32_t targets_ = 1;
  double rw_ = 0;
  sgl::Mix mix_;
  sgl::WriteOpSampler wsampler_{sgl::Mix()};
  sgl::KeyGen keys_;
  uint64_t n_ = 0, id_base_ = 1, seed_ = 0, coh_read_every_ = 16, coh_max_ = 0;
  uint16_t limit_ = 50;
  std::string route_, image_, gen_;
  std::mt19937_64 rng_;
  sg::ImageHeader hdr_{};
  std::vector<uint64_t> csr_off_;  // build-time adjacency (image=): slot -> [off[s], off[s+1]) in csr_id2_
  std::vector<uint32_t> csr_id2_;
  double csr_ms_ = 0;
  // make() thread only
  uint64_t made_[sgl::kStreams] = {}, wmade_[sgl::kWriteOps] = {}, id2_img_ = 0, id2_uni_ = 0, id2_noimg_ = 0;
  std::vector<uint32_t> next_wseq_;
  // receiver threads
  std::atomic<uint64_t> status_[kOps][kStatusBusy + 1] = {}, frame_err_[kOps] = {}, bad_[kOps] = {};
  std::atomic<uint64_t> feed_rows_{0}, feed_missing_{0}, feed_records_{0}, feed_ok_{0}, getlink_rows_{0};
  std::atomic<uint64_t> wseq_mismatch_{0}, bad_status_{0}, no_coh_{0}, coh_read_n_{0}, coh_dropped_{0};
  std::mutex mu_;
  std::string first_bad_;
  std::vector<WriteLog> wlog_;
  std::vector<CohLog> clog_;
};
LOADGEN_REGISTER("socialgraph", SocialGraph);

}  // namespace
