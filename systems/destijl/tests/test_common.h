/* Shared helpers for the ds_ring / ds_ccd user-space tests. */
#ifndef DS_TEST_COMMON_H
#define DS_TEST_COMMON_H

#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/*
 * Tests run more spinning threads than CPUs; yield every 64 failed polls so
 * that the thread being waited for gets to run.
 */
#define DS_SPIN_RELAX(iter)                                   \
	do {                                                  \
		if (((iter) & 63) == 0)                       \
			sched_yield();                        \
		else                                          \
			ds_cpu_relax();                       \
	} while (0)

#include <swmc/ds_ring.h>
#include <swmc/ds_ccd.h>

#define CHECK(cond, ...)                                                    \
	do {                                                                \
		if (!(cond)) {                                              \
			fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__,       \
				__LINE__, #cond);                           \
			fprintf(stderr, __VA_ARGS__);                       \
			fprintf(stderr, "\n");                              \
			exit(1);                                            \
		}                                                           \
	} while (0)

static inline double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static inline void *xalloc64(size_t bytes)
{
	size_t sz = (bytes + 63) & ~(size_t)63;
	void *p = aligned_alloc(64, sz);

	CHECK(p != NULL, "aligned_alloc(%zu)", sz);
	return p;
}

static inline unsigned long long xorshift64(unsigned long long *s)
{
	unsigned long long x = *s;

	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	*s = x;
	return x;
}

#endif
