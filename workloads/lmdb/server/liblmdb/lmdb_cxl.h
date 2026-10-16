/* LMDB over a shared CXL region (workloads/lmdb/DESIGN.md). Additions to liblmdb 0.9.70 (mdb.c, marked "CXL").
 *
 * An environment opened with mdb_env_open_cxl() has no data file and no lock file:
 *   - B+tree pages (pgno * 4096) live in SWcc. Either directly addressable (page_base != NULL: all-HWcc, Popcorn) or
 *     reachable only through page_read / page_write (Megalon: one object per page, every access in a section).
 *   - The lock-file state lives in the HWcc app range (pointers below), accessed only with <= 8 B atomics:
 *       wlock      writer lock, a polling ticket lock (two lines: [0] next ticket, [8] now serving)
 *       committed  last committed txnid (LMDB mti_txnid)
 *       meta[2]    the two meta slots (LMDB meta pages 0/1), seqlock-protected; slot txnid & 1
 *       readers    reader table, one line per slot (value = snapshot txnid + 1, 0 = free); slot index is given by the
 *                  caller per thread (mdb_cxl_thread_slot), so no cross-node slot allocation exists
 *   - Write transactions use LMDB's default (non-WRITEMAP) path: dirty pages are private copies; commit writes each
 *     dirty page whole with page_write (or memcpy to page_base), then the meta slot, then `committed` (release).
 * Nothing here is compiled out for any system; only page access differs (page_base vs callbacks).
 */
#ifndef LMDB_CXL_H
#define LMDB_CXL_H

#include <stddef.h>
#include <stdint.h>

#include "lmdb.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MDB_CXL_PSIZE 4096u
#define MDB_CXL_LINE 64u

/* One meta slot (two cache lines). Words written only by the writer-lock holder; seq is odd while being written. */
typedef struct MDB_cxl_meta {
	uint64_t seq;
	uint64_t txnid;
	uint64_t last_pg;
	uint64_t dbs[12]; /* MDB_db[CORE_DBS] (FREE_DBI, MAIN_DBI) as 8-byte words */
	uint64_t pad;
} MDB_cxl_meta;

typedef struct MDB_cxl_conf {
	uint64_t *wlock;     /* 2 lines */
	uint64_t *committed; /* 1 line */
	MDB_cxl_meta *meta;  /* 2 slots */
	uint64_t *readers;   /* nreaders lines (stride MDB_CXL_LINE / 8 words) */
	unsigned nreaders;
	size_t max_pages;    /* page number space (LMDB mapsize / 4096); pages 0 and 1 are never used */
	char *page_base;     /* != NULL: page p at page_base + p * 4096, read in place */
	void *ctx;
	/* page_base == NULL: copy page pgno into dst (the call contains one complete read section; may retry inside) */
	int (*page_read)(void *ctx, size_t pgno, void *dst);
	/* write page pgno whole from src (one write section; page_base != NULL and page_write == NULL: memcpy) */
	int (*page_write)(void *ctx, size_t pgno, const void *src);
} MDB_cxl_conf;

typedef struct MDB_cxl_stats {
	uint64_t page_writes;   /* pages written at commit (page copies by readers are counted by the backend) */
	uint64_t wlock_wait_ns; /* time waiting for the writer lock */
	uint64_t wlock_acquires;
	uint64_t reader_retries;  /* reader registration / meta seqlock retries */
	uint64_t oldest_scans;    /* mdb_find_oldest calls */
	uint64_t oldest_lag_max;  /* max (writer txnid - 1 - oldest) seen */
} MDB_cxl_stats;

/* Open env over the shared state. flags: 0 (MDB_NOLOCK|MDB_NOSYNC|MDB_NOTLS are implied). The conf is copied. */
int mdb_env_open_cxl(MDB_env *env, const MDB_cxl_conf *conf, unsigned int flags);
/* Reader slot of the calling thread for read-only txns (0 <= slot < nreaders; -1 = none). */
void mdb_cxl_thread_slot(int slot);
/* Meta helpers for prepare / image tools (no concurrency: called before any txn on any node). */
void mdb_cxl_init_empty(const MDB_cxl_conf *conf);
/* Copy out / in the latest committed meta (seqlock read; *_set publishes committed = txnid). */
int mdb_cxl_meta_get(const MDB_cxl_conf *conf, uint64_t *txnid, uint64_t *last_pg, uint64_t dbs[12]);
void mdb_cxl_meta_set(const MDB_cxl_conf *conf, uint64_t txnid, uint64_t last_pg, const uint64_t dbs[12]);
void mdb_cxl_get_stats(MDB_env *env, MDB_cxl_stats *s);

#ifdef __cplusplus
}
#endif
#endif
