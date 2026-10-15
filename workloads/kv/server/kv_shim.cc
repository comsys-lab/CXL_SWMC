// libkv-megalon.so: thin adapter from kv_api.h to Megalon's KV interface (rackobj.h). No logic here.
#include <rackobj.h>

#include "kv_api.h"

#ifndef KV_SHIM_INFO
#define KV_SHIM_INFO "unknown"
#endif
#ifndef KV_SHIM_FLAVOR
#define KV_SHIM_FLAVOR "unknown"
#endif

namespace {
size_t node_id() { return rackobj::GetConfigSize_t("node_id"); }
size_t key_space() { return rackobj::GetConfigSize_t("key_space"); }
void reg(int tid) { rackobj::Register(tid); }
void unreg() { rackobj::UnRegister(); }
ssize_t put(const uint8_t *buf, uint64_t count, uint64_t key) { return rackobj::Put(buf, count, static_cast<off_t>(key)); }
ssize_t get(uint8_t *buf, uint64_t count, uint64_t key) { return rackobj::Get(buf, count, static_cast<off_t>(key)); }

const kvshim::Api kApi{kvshim::kApiVersion, KV_SHIM_INFO, KV_SHIM_FLAVOR, node_id, key_space, reg, unreg, put, get};
}  // namespace

extern "C" __attribute__((visibility("default"))) const kvshim::Api *kv_megalon_api() { return &kApi; }
