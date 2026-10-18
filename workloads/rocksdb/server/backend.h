// Access to SWcc data per system (DESIGN.md §7). File extents are written and read only through write()/read();
// memtable skiplist memory is accessed by RocksDB itself (plain: direct loads/stores).
//  plain (all-HWcc, Popcorn): ordinary loads and stores of the shared mapping.
//  megalon: (TODO, task 5) one section per 1 MiB object touched.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace rdbw {

class Backend {
 public:
  virtual ~Backend() = default;
  virtual const char *name() const = 0;
  virtual const char *layout_tag() const = 0;
  // copy into / out of SWcc file extents; [dst, dst + n) / [src, src + n) never crosses a 1 MiB unit
  virtual void write(uint8_t *dst, const void *src, size_t n) = 0;
  virtual void read(void *dst, const uint8_t *src, size_t n) = 0;
};

class PlainBackend final : public Backend {
 public:
  const char *name() const override { return "plain"; }
  const char *layout_tag() const override { return ""; }
  void write(uint8_t *dst, const void *src, size_t n) override { std::memcpy(dst, src, n); }
  void read(void *dst, const uint8_t *src, size_t n) override { std::memcpy(dst, src, n); }
};

}  // namespace rdbw
