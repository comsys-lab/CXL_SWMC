// Host unit test (no shared memory): the Knowhere zero_copy deserialize patch (knowhere branch destijl-zero-copy)
// gives the same HNSW search results as a normal (copying) deserialize, and really reads the caller's bytes.
// Build: see tests/build_zero_copy_test.sh. Exit 0 = PASS.
#include <cstdio>
#include <cstring>
#include <memory>
#include <random>
#include <vector>

#include "knowhere/comp/index_param.h"
#include "knowhere/comp/knowhere_config.h"
#include "knowhere/dataset.h"
#include "knowhere/index/index_factory.h"
#include "knowhere/version.h"

static knowhere::DataSetPtr Gen(int rows, int dim, uint32_t seed, std::vector<float> *buf) {
    std::mt19937 rng(seed);
    std::normal_distribution<float> nd;
    buf->resize(size_t(rows) * dim);
    for (int r = 0; r < rows; r++) {
        double n = 0;
        for (int d = 0; d < dim; d++) n += double((*buf)[size_t(r) * dim + d] = nd(rng)) * (*buf)[size_t(r) * dim + d];
        for (int d = 0; d < dim; d++) (*buf)[size_t(r) * dim + d] /= float(std::sqrt(n));
    }
    return knowhere::GenDataSet(rows, dim, buf->data());
}

int main() {
    const int nb = 4000, nq = 100, dim = 128, k = 10;
    const auto ver = knowhere::Version::GetCurrentVersion().VersionNumber();
    std::vector<float> xb, xq;
    auto base = Gen(nb, dim, 1, &xb);
    auto query = Gen(nq, dim, 2, &xq);

    knowhere::Json conf;
    conf[knowhere::meta::METRIC_TYPE] = knowhere::metric::IP;
    conf[knowhere::meta::DIM] = dim;
    conf[knowhere::meta::TOPK] = k;
    conf[knowhere::indexparam::HNSW_M] = 16;
    conf[knowhere::indexparam::EFCONSTRUCTION] = 100;
    conf[knowhere::indexparam::EF] = 64;

    auto built = knowhere::IndexFactory::Instance().Create<knowhere::fp32>(knowhere::IndexEnum::INDEX_HNSW, ver).value();
    if (built.Build(base, conf) != knowhere::Status::success) { std::puts("FAIL build"); return 1; }
    knowhere::BinarySet bs;
    if (built.Serialize(bs) != knowhere::Status::success) { std::puts("FAIL serialize"); return 1; }
    auto bin = bs.GetByName(built.Type());
    std::printf("serialized %zu bytes\n", size_t(bin->size));

    // "shared" bytes owned by the caller (stand-in for an index object in CXL memory)
    std::unique_ptr<uint8_t[]> shared(new uint8_t[bin->size]);
    std::memcpy(shared.get(), bin->data.get(), bin->size);
    knowhere::BinarySet zbs;
    zbs.Append(built.Type(), std::shared_ptr<uint8_t[]>(shared.get(), [](uint8_t *) {}), bin->size);

    auto copy_idx = knowhere::IndexFactory::Instance().Create<knowhere::fp32>(knowhere::IndexEnum::INDEX_HNSW, ver).value();
    auto zc_idx = knowhere::IndexFactory::Instance().Create<knowhere::fp32>(knowhere::IndexEnum::INDEX_HNSW, ver).value();
    if (copy_idx.Deserialize(bs, conf) != knowhere::Status::success) { std::puts("FAIL deserialize copy"); return 1; }
    knowhere::Json zconf = conf;
    zconf["zero_copy"] = true;
    if (zc_idx.Deserialize(zbs, zconf) != knowhere::Status::success) { std::puts("FAIL deserialize zero_copy"); return 1; }

    auto r1 = copy_idx.Search(query, conf, nullptr).value();
    auto r2 = zc_idx.Search(query, conf, nullptr).value();
    if (std::memcmp(r1->GetIds(), r2->GetIds(), sizeof(int64_t) * nq * k) != 0) {
        std::puts("FAIL zero_copy results differ from copy");
        return 1;
    }
    // views over the caller's bytes: overwriting them must change zero_copy results but not the copy's
    std::memset(shared.get() + bin->size / 2, 0, bin->size - bin->size / 2);
    auto r3 = zc_idx.Search(query, conf, nullptr);
    auto r4 = copy_idx.Search(query, conf, nullptr).value();
    bool zc_changed = !r3.has_value() || std::memcmp(r1->GetIds(), r3.value()->GetIds(), sizeof(int64_t) * nq * k) != 0;
    bool copy_same = std::memcmp(r1->GetIds(), r4->GetIds(), sizeof(int64_t) * nq * k) == 0;
    if (!zc_changed || !copy_same) {
        std::printf("FAIL view check: zero_copy changed=%d copy unchanged=%d\n", zc_changed, copy_same);
        return 1;
    }
    std::puts("ZERO-COPY-TEST PASS");
    return 0;
}
