// FileSystem plugin over the shared region (DESIGN.md §2, §4 "public-API parts"): paths /cxl/n<v>/<name> are files
// of node v (directory + extent lists in HWcc, data in v's SWcc file extents); every other path goes to the
// default (local) file system. Only node v creates, appends, renames or deletes files of /cxl/n<v>; every node reads
// them. A deleted file's extents and slot are freed only after the reader epochs pass (shared.h).
#pragma once

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "rocksdb/file_system.h"
#include "shared.h"

namespace rdbw {

using ROCKSDB_NAMESPACE::FileLock;
using ROCKSDB_NAMESPACE::FileOptions;
using ROCKSDB_NAMESPACE::FileSystem;
using ROCKSDB_NAMESPACE::FileSystemWrapper;
using ROCKSDB_NAMESPACE::FSDirectory;
using ROCKSDB_NAMESPACE::FSRandomAccessFile;
using ROCKSDB_NAMESPACE::FSSequentialFile;
using ROCKSDB_NAMESPACE::FSWritableFile;
using ROCKSDB_NAMESPACE::IODebugContext;
using ROCKSDB_NAMESPACE::IOOptions;
using ROCKSDB_NAMESPACE::IOStatus;
using ROCKSDB_NAMESPACE::Slice;

inline const std::string kCxlRoot = "/cxl/n";

// ---- slot access (any node; seqlock on name/state) ----
inline void pack_name(const std::string &s, uint64_t w[kNameWords]) {
  char b[kNameWords * 8] = {};
  std::memcpy(b, s.data(), std::min<size_t>(s.size(), sizeof(b) - 1));
  std::memcpy(w, b, sizeof(b));
}
struct SlotView {
  bool live = false;     // state 1
  bool retired = false;  // state 2: deleted, name kept until the slot is reclaimed (remote openers, shared.h)
  uint64_t serial = 0;
  std::string name;
  uint64_t size = 0;
};
inline SlotView read_slot(const FileHead *fh) {
  for (;;) {
    const uint64_t s1 = cxl::hwcc::load_acquire(&fh->seq);
    if (s1 & 1) {
      __builtin_ia32_pause();
      continue;
    }
    SlotView v;
    const uint64_t st = cxl::hwcc::load_relaxed(&fh->state);
    v.live = st == 1;
    v.retired = st == 2;
    uint64_t w[kNameWords];
    for (uint32_t i = 0; i < kNameWords; i++) w[i] = cxl::hwcc::load_relaxed(&fh->name[i]);
    v.serial = cxl::hwcc::load_relaxed(&fh->serial);
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    if (cxl::hwcc::load_relaxed(&fh->seq) != s1) continue;
    char b[kNameWords * 8 + 1] = {};
    std::memcpy(b, w, kNameWords * 8);
    v.name = b;
    v.size = cxl::hwcc::load_acquire(&fh->size);
    return v;
  }
}

class CxlFs;

// A file of node `node`, slot `slot` (reader view). Reads clamp to the published size.
class CxlFileReader {
 public:
  CxlFileReader(Shared *sh, uint32_t node, uint32_t slot) : sh_(sh), node_(node), slot_(slot) {}
  uint64_t size() const { return cxl::hwcc::load_acquire(&sh_->hwcc()->head(node_, slot_)->size); }
  size_t read(uint64_t off, size_t n, char *out) const {
    const uint64_t sz = size();
    if (off >= sz) return 0;
    n = size_t(std::min<uint64_t>(n, sz - off));
    const uint32_t *ex = sh_->hwcc()->exts(node_, slot_);
    size_t done = 0;
    while (done < n) {
      const uint64_t o = off + done;
      const uint32_t k = uint32_t(o / kUnit);
      const uint32_t j = __atomic_load_n(&ex[k], __ATOMIC_RELAXED);
      const size_t in = size_t(o % kUnit), take = std::min<size_t>(n - done, kUnit - in);
      sh_->backend()->file_read(node_, j, in, out + done, take);
      done += take;
    }
    return n;
  }

 private:
  Shared *sh_;
  uint32_t node_, slot_;
};

class CxlRandomAccessFile final : public FSRandomAccessFile {
 public:
  explicit CxlRandomAccessFile(CxlFileReader r) : r_(r) {}
  IOStatus Read(uint64_t offset, size_t n, const IOOptions &, Slice *result, char *scratch,
                IODebugContext *) const override {
    *result = Slice(scratch, r_.read(offset, n, scratch));
    return IOStatus::OK();
  }

 private:
  CxlFileReader r_;
};

class CxlSequentialFile final : public FSSequentialFile {
 public:
  explicit CxlSequentialFile(CxlFileReader r) : r_(r) {}
  IOStatus Read(size_t n, const IOOptions &, Slice *result, char *scratch, IODebugContext *) override {
    const size_t got = r_.read(pos_, n, scratch);
    pos_ += got;
    *result = Slice(scratch, got);
    return IOStatus::OK();
  }
  IOStatus Skip(uint64_t n) override {
    pos_ = std::min(pos_ + n, r_.size());
    return IOStatus::OK();
  }

 private:
  CxlFileReader r_;
  uint64_t pos_ = 0;
};

// Owner-side append-only writer: extents are allocated as the file grows; size is published (release) after the
// data and the extent indexes it covers.
class CxlWritableFile final : public FSWritableFile {
 public:
  CxlWritableFile(Shared *sh, uint32_t slot, uint64_t size) : sh_(sh), slot_(slot), size_(size) {}
  IOStatus Append(const Slice &data, const IOOptions &, IODebugContext *) override {
    const char *p = data.data();
    size_t n = data.size();
    uint32_t *ex = sh_->hwcc()->exts(sh_->me(), slot_);
    while (n) {
      const uint32_t k = uint32_t(size_ / kUnit);
      if (k >= sh_->params().max_ext) return IOStatus::NoSpace("file larger than max_ext extents");
      const size_t in = size_t(size_ % kUnit);
      if (in == 0) {
        uint32_t j;
        if (!sh_->get_extent(&j)) return IOStatus::NoSpace("CXL file extent pool exhausted");
        __atomic_store_n(&ex[k], j, __ATOMIC_RELAXED);
      }
      const uint32_t j = __atomic_load_n(&ex[k], __ATOMIC_RELAXED);
      const size_t take = std::min<size_t>(n, kUnit - in);
      sh_->backend()->file_write(sh_->me(), j, in, p, take);
      p += take;
      n -= take;
      size_ += take;
    }
    cxl::hwcc::store_release(&sh_->hwcc()->head(sh_->me(), slot_)->size, size_);
    return IOStatus::OK();
  }
  IOStatus Close(const IOOptions &, IODebugContext *) override { return IOStatus::OK(); }
  IOStatus Flush(const IOOptions &, IODebugContext *) override { return IOStatus::OK(); }
  IOStatus Sync(const IOOptions &, IODebugContext *) override { return IOStatus::OK(); }
  IOStatus Fsync(const IOOptions &, IODebugContext *) override { return IOStatus::OK(); }
  uint64_t GetFileSize(const IOOptions &, IODebugContext *) override { return size_; }
  bool IsSyncThreadSafe() const override { return true; }

 private:
  Shared *sh_;
  uint32_t slot_;
  uint64_t size_;
};

class CxlDirectory final : public FSDirectory {
 public:
  IOStatus Fsync(const IOOptions &, IODebugContext *) override { return IOStatus::OK(); }
  IOStatus Close(const IOOptions &, IODebugContext *) override { return IOStatus::OK(); }
};

class CxlLock final : public FileLock {};

class CxlFs final : public FileSystemWrapper {
 public:
  CxlFs(std::shared_ptr<FileSystem> base, Shared *sh) : FileSystemWrapper(std::move(base)), sh_(sh) {}
  static const char *kClassName() { return "CxlFs"; }
  const char *Name() const override { return kClassName(); }

  static std::string dir_of(uint32_t node) { return kCxlRoot + std::to_string(node); }
  std::string stats_text() const {
    std::lock_guard<std::mutex> g(mu_);
    return "fs.created=" + std::to_string(created_) + "\nfs.deleted=" + std::to_string(deleted_) +
           "\nfs.manifests=" + std::to_string(manifests_) + "\nfs.live=" + std::to_string(names_.size()) + "\n";
  }

  // ---- files ----
  IOStatus NewSequentialFile(const std::string &f, const FileOptions &o, std::unique_ptr<FSSequentialFile> *r,
                             IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->NewSequentialFile(f, o, r, d);
    uint32_t slot;
    if (!find(p, &slot)) return IOStatus::PathNotFound(f);
    r->reset(new CxlSequentialFile(CxlFileReader(sh_, p.node, slot)));
    return IOStatus::OK();
  }
  IOStatus NewRandomAccessFile(const std::string &f, const FileOptions &o, std::unique_ptr<FSRandomAccessFile> *r,
                               IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->NewRandomAccessFile(f, o, r, d);
    uint32_t slot;
    if (!find(p, &slot)) return IOStatus::PathNotFound(f);
    r->reset(new CxlRandomAccessFile(CxlFileReader(sh_, p.node, slot)));
    return IOStatus::OK();
  }
  IOStatus NewWritableFile(const std::string &f, const FileOptions &o, std::unique_ptr<FSWritableFile> *r,
                           IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->NewWritableFile(f, o, r, d);
    if (p.node != sh_->me() || p.name.empty()) return IOStatus::NotSupported("CXL file of another node: " + f);
    std::lock_guard<std::mutex> g(mu_);
    auto it = names_.find(p.name);
    if (it != names_.end()) delete_locked(p.name);  // truncate = delete + create
    uint32_t slot;
    IOStatus s = create_locked(p.name, &slot);
    if (!s.ok()) return s;
    r->reset(new CxlWritableFile(sh_, slot, 0));
    return IOStatus::OK();
  }
  IOStatus ReopenWritableFile(const std::string &f, const FileOptions &o, std::unique_ptr<FSWritableFile> *r,
                              IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->ReopenWritableFile(f, o, r, d);
    if (p.node != sh_->me()) return IOStatus::NotSupported("CXL file of another node: " + f);
    std::lock_guard<std::mutex> g(mu_);
    auto it = names_.find(p.name);
    uint32_t slot;
    if (it == names_.end()) {
      IOStatus s = create_locked(p.name, &slot);
      if (!s.ok()) return s;
    } else {
      slot = it->second;
    }
    r->reset(new CxlWritableFile(sh_, slot, cxl::hwcc::load_relaxed(&sh_->hwcc()->head(sh_->me(), slot)->size)));
    return IOStatus::OK();
  }
  IOStatus ReuseWritableFile(const std::string &f, const std::string &old, const FileOptions &o,
                             std::unique_ptr<FSWritableFile> *r, IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->ReuseWritableFile(f, old, o, r, d);
    return NewWritableFile(f, o, r, d);
  }
  IOStatus NewDirectory(const std::string &n, const IOOptions &io, std::unique_ptr<FSDirectory> *r,
                        IODebugContext *d) override {
    Path p;
    if (!parse(n, &p)) return target()->NewDirectory(n, io, r, d);
    r->reset(new CxlDirectory());
    return IOStatus::OK();
  }
  IOStatus FileExists(const std::string &f, const IOOptions &io, IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->FileExists(f, io, d);
    if (p.name.empty()) return IOStatus::OK();
    uint32_t slot;
    return find(p, &slot) ? IOStatus::OK() : IOStatus::NotFound(f);
  }
  IOStatus GetChildren(const std::string &dir, const IOOptions &io, std::vector<std::string> *r,
                       IODebugContext *d) override {
    Path p;
    if (!parse(dir, &p)) return target()->GetChildren(dir, io, r, d);
    if (!p.name.empty()) return IOStatus::NotFound(dir);
    r->clear();
    for (uint32_t s = 0; s < sh_->params().max_files; s++) {
      SlotView v = read_slot(sh_->hwcc()->head(p.node, s));
      if (v.live) r->push_back(v.name);
    }
    return IOStatus::OK();
  }
  IOStatus DeleteFile(const std::string &f, const IOOptions &io, IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->DeleteFile(f, io, d);
    if (p.node != sh_->me()) return IOStatus::NotSupported("delete of another node's CXL file: " + f);
    std::lock_guard<std::mutex> g(mu_);
    if (!names_.count(p.name)) return IOStatus::PathNotFound(f);
    delete_locked(p.name);
    return IOStatus::OK();
  }
  IOStatus GetFileSize(const std::string &f, const IOOptions &io, uint64_t *s, IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->GetFileSize(f, io, s, d);
    uint32_t slot;
    if (!find(p, &slot)) return IOStatus::PathNotFound(f);
    *s = cxl::hwcc::load_acquire(&sh_->hwcc()->head(p.node, slot)->size);
    return IOStatus::OK();
  }
  IOStatus GetFileModificationTime(const std::string &f, const IOOptions &io, uint64_t *t,
                                   IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->GetFileModificationTime(f, io, t, d);
    *t = 0;
    return IOStatus::OK();
  }
  IOStatus RenameFile(const std::string &s, const std::string &t, const IOOptions &io, IODebugContext *d) override {
    Path ps, pt;
    const bool a = parse(s, &ps), b = parse(t, &pt);
    if (!a && !b) return target()->RenameFile(s, t, io, d);
    if (!a || !b || ps.node != sh_->me() || pt.node != sh_->me()) return IOStatus::NotSupported("rename " + s);
    std::lock_guard<std::mutex> g(mu_);
    auto it = names_.find(ps.name);
    if (it == names_.end()) return IOStatus::PathNotFound(s);
    const uint32_t slot = it->second;
    if (names_.count(pt.name)) delete_locked(pt.name);
    names_.erase(ps.name);
    set_slot_locked(slot, pt.name, 1);
    names_[pt.name] = slot;
    return IOStatus::OK();
  }
  IOStatus LinkFile(const std::string &s, const std::string &t, const IOOptions &io, IODebugContext *d) override {
    Path ps, pt;
    const bool a = parse(s, &ps), b = parse(t, &pt);
    if (!a && !b) return target()->LinkFile(s, t, io, d);
    if (!a || !b || ps.node != sh_->me() || pt.node != sh_->me()) return IOStatus::NotSupported("link " + s);
    std::lock_guard<std::mutex> g(mu_);
    auto it = names_.find(ps.name);
    if (it == names_.end()) return IOStatus::PathNotFound(s);
    if (names_.count(pt.name)) return IOStatus::IOError("link target exists: " + t);
    uint32_t slot;
    IOStatus st = create_locked(pt.name, &slot, false);
    if (!st.ok()) return st;
    const uint32_t from = it->second;
    const uint64_t size = cxl::hwcc::load_relaxed(&sh_->hwcc()->head(sh_->me(), from)->size);
    const uint32_t *fe = sh_->hwcc()->exts(sh_->me(), from);
    uint32_t *te = sh_->hwcc()->exts(sh_->me(), slot);
    for (uint64_t k = 0; k * kUnit < size; k++) {
      const uint32_t j = __atomic_load_n(&fe[k], __ATOMIC_RELAXED);
      sh_->ref_extent(j);
      __atomic_store_n(&te[k], j, __ATOMIC_RELAXED);
    }
    cxl::hwcc::store_release(&sh_->hwcc()->head(sh_->me(), slot)->size, size);
    set_slot_locked(slot, pt.name, 1);
    return IOStatus::OK();
  }
  IOStatus SyncFile(const std::string &f, const FileOptions &fo, const IOOptions &io, bool use_fsync,
                    IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->SyncFile(f, fo, io, use_fsync, d);
    return IOStatus::OK();  // appends are visible once Append returns (size published)
  }
  IOStatus NumFileLinks(const std::string &f, const IOOptions &io, uint64_t *c, IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->NumFileLinks(f, io, c, d);
    return IOStatus::NotSupported("NumFileLinks on CXL files");
  }
  IOStatus AreFilesSame(const std::string &a, const std::string &b, const IOOptions &io, bool *r,
                        IODebugContext *d) override {
    Path pa, pb;
    if (!parse(a, &pa) && !parse(b, &pb)) return target()->AreFilesSame(a, b, io, r, d);
    *r = a == b;
    return IOStatus::OK();
  }
  IOStatus CreateDir(const std::string &n, const IOOptions &io, IODebugContext *d) override {
    Path p;
    if (!parse(n, &p)) return target()->CreateDir(n, io, d);
    return IOStatus::OK();
  }
  IOStatus CreateDirIfMissing(const std::string &n, const IOOptions &io, IODebugContext *d) override {
    Path p;
    if (!parse(n, &p) && n != "/cxl") return target()->CreateDirIfMissing(n, io, d);
    return IOStatus::OK();
  }
  IOStatus DeleteDir(const std::string &n, const IOOptions &io, IODebugContext *d) override {
    Path p;
    if (!parse(n, &p)) return target()->DeleteDir(n, io, d);
    return IOStatus::OK();
  }
  IOStatus IsDirectory(const std::string &n, const IOOptions &io, bool *is_dir, IODebugContext *d) override {
    Path p;
    if (!parse(n, &p)) return target()->IsDirectory(n, io, is_dir, d);
    *is_dir = p.name.empty();
    return IOStatus::OK();
  }
  IOStatus GetAbsolutePath(const std::string &n, const IOOptions &io, std::string *out, IODebugContext *d) override {
    Path p;
    if (!parse(n, &p)) return target()->GetAbsolutePath(n, io, out, d);
    *out = n;
    return IOStatus::OK();
  }
  IOStatus LockFile(const std::string &f, const IOOptions &io, FileLock **l, IODebugContext *d) override {
    Path p;
    if (!parse(f, &p)) return target()->LockFile(f, io, l, d);
    if (p.node != sh_->me()) return IOStatus::NotSupported("lock of another node's DB");
    auto *c = new CxlLock();
    std::lock_guard<std::mutex> g(mu_);
    locks_.push_back(c);
    *l = c;
    return IOStatus::OK();
  }
  IOStatus UnlockFile(FileLock *l, const IOOptions &io, IODebugContext *d) override {
    {
      std::lock_guard<std::mutex> g(mu_);
      auto it = std::find(locks_.begin(), locks_.end(), l);
      if (it != locks_.end()) {
        locks_.erase(it);
        delete l;
        return IOStatus::OK();
      }
    }
    return target()->UnlockFile(l, io, d);
  }
  IOStatus GetFreeSpace(const std::string &n, const IOOptions &io, uint64_t *free, IODebugContext *d) override {
    Path p;
    if (!parse(n, &p)) return target()->GetFreeSpace(n, io, free, d);
    *free = sh_->free_extents() * kUnit;
    return IOStatus::OK();
  }

 private:
  struct Path {
    uint32_t node = 0;
    std::string name;  // empty = the node directory
  };
  bool parse(const std::string &f, Path *p) const {
    if (f.compare(0, kCxlRoot.size(), kCxlRoot) != 0) return false;
    size_t i = kCxlRoot.size(), j = i;
    while (j < f.size() && f[j] >= '0' && f[j] <= '9') j++;
    if (j == i) return false;
    p->node = uint32_t(std::stoul(f.substr(i, j - i)));
    if (p->node >= sh_->params().nr_nodes) return false;
    while (j < f.size() && f[j] == '/') j++;
    p->name = f.substr(j);
    if (p->name.compare(0, 2, "./") == 0) p->name = p->name.substr(2);
    return p->name.find('/') == std::string::npos && p->name.size() < kNameWords * 8;
  }
  bool find(const Path &p, uint32_t *slot) {
    if (p.node == sh_->me()) {
      std::lock_guard<std::mutex> g(mu_);
      auto it = names_.find(p.name);
      if (it == names_.end()) return false;
      *slot = it->second;
      return true;
    }
    // A remote secondary may open a file its version refers to after the owner deleted it (the data stays until the
    // reader epochs pass): a live file first, else a retired one of that name.
    int64_t retired = -1;
    uint64_t newest = 0;
    for (uint32_t s = 0; s < sh_->params().max_files; s++) {
      SlotView v = read_slot(sh_->hwcc()->head(p.node, s));
      if (v.name != p.name) continue;
      if (v.live) {
        *slot = s;
        return true;
      }
      if (v.retired && (retired < 0 || v.serial > newest)) retired = s, newest = v.serial;
    }
    if (retired >= 0) *slot = uint32_t(retired);
    return retired >= 0;
  }
  void set_slot_locked(uint32_t slot, const std::string &name, uint64_t state) {
    FileHead *fh = sh_->hwcc()->head(sh_->me(), slot);
    const uint64_t s = cxl::hwcc::load_relaxed(&fh->seq);
    cxl::hwcc::store_relaxed(&fh->seq, s + 1);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    uint64_t w[kNameWords];
    pack_name(name, w);
    for (uint32_t i = 0; i < kNameWords; i++) cxl::hwcc::store_relaxed(&fh->name[i], w[i]);
    cxl::hwcc::store_relaxed(&fh->state, state);
    cxl::hwcc::store_release(&fh->seq, s + 2);
  }
  IOStatus create_locked(const std::string &name, uint32_t *slot, bool publish = true) {
    if (!sh_->get_slot(slot)) return IOStatus::NoSpace("CXL directory full");
    cxl::hwcc::store_release(&sh_->hwcc()->head(sh_->me(), *slot)->size, uint64_t(0));
    cxl::hwcc::store_relaxed(&sh_->hwcc()->head(sh_->me(), *slot)->serial, ++serial_);
    if (publish) set_slot_locked(*slot, name, 1);
    names_[name] = *slot;
    created_++;
    if (name.compare(0, 9, "MANIFEST-") == 0) manifests_++;
    return IOStatus::OK();
  }
  void delete_locked(const std::string &name) {
    const uint32_t slot = names_.at(name);
    names_.erase(name);
    const uint64_t size = cxl::hwcc::load_relaxed(&sh_->hwcc()->head(sh_->me(), slot)->size);
    const uint32_t *ex = sh_->hwcc()->exts(sh_->me(), slot);
    std::vector<uint32_t> exts;
    for (uint64_t k = 0; k * kUnit < size; k++) exts.push_back(__atomic_load_n(&ex[k], __ATOMIC_RELAXED));
    set_slot_locked(slot, name, 2);  // retired: name kept for remote openers until the slot is reclaimed
    sh_->retire_file(slot, exts);
    deleted_++;
  }

  Shared *sh_;
  mutable std::mutex mu_;
  std::unordered_map<std::string, uint32_t> names_;  // this node's files
  std::vector<FileLock *> locks_;                    // CXL locks handed out (no RTTI in librocksdb)
  uint64_t serial_ = 0, created_ = 0, deleted_ = 0, manifests_ = 0;
};

}  // namespace rdbw
