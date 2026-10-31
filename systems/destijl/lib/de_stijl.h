/* De Stijl v2 user library (libdestijl.a): per-region staleness bound T.
 * Spec: reports/design/DS2-protocol-spec.md §6 and §9.
 *
 * Link with a C++ linker (or add -lstdc++): de_stijl_alloc() reads the region
 * config through systems/common/cxl_region.h. */
#ifndef DE_STIJL_H
#define DE_STIJL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* x86_64 syscall number of de_stijl_set_staleness (kernel tree destijl-v2). */
#define DE_STIJL_SYS_SET_STALENESS 472

/* Granularity of de_stijl_alloc() (the region's align, at least 2 MiB). */
#define DE_STIJL_ALLOC_ALIGN (2ull << 20)

/* Set the staleness bound T (microseconds; 0 = synchronous) of
 * [addr, addr + len), which must be covered by coherence-managed device-DAX
 * mappings. addr page aligned; len rounded up to whole pages by the kernel.
 * Returns 0, or -1 with errno: EINVAL (unaligned, not a managed mapping),
 * ENOMEM (hole in the range), ENOSYS (kernel without De Stijl v2). */
int de_stijl_set_staleness(void *addr, size_t len, uint64_t staleness_us);

/* Reserve the next `size` bytes (rounded up to DE_STIJL_ALLOC_ALIGN) of the
 * SWcc range of the whole-device mapping at the region's map_va and set its
 * staleness bound. The region comes from $CXL_REGION_CONFIG
 * (config/cxl_region.yaml format). If the caller has not mapped the device
 * at map_va, the first call maps the whole device there (MAP_SHARED,
 * MAP_FIXED_NOREPLACE). Thread safe. Offsets are a bump cursor starting at
 * swcc_offset and never reused, so the same call sequence returns the same
 * addresses on every node; nothing is coordinated across nodes.
 * Returns NULL with errno: EINVAL (size 0, bad region config), ENOMEM (SWcc
 * exhausted), EEXIST (map_va occupied by another mapping), or the errno of
 * open/mmap/de_stijl_set_staleness. A reservation whose set_staleness fails
 * is not returned to the cursor. */
void *de_stijl_alloc(size_t size, uint64_t staleness_us);

#ifdef __cplusplus
}
#endif

#endif /* DE_STIJL_H */
