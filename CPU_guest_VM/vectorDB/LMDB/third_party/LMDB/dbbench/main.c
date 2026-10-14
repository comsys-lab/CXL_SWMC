/* Copyright (c) 2017-2018 Howard Chu @ Symas Corp. */
#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <assert.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <linux/fs.h>
#include <errno.h>
#include <pthread.h>

#include "dbb.h"

#define handle_error_en(en, msg) \
               do { errno = en; perror(msg); exit(EXIT_FAILURE); } while (0)


// Comma-separated list of operations to run in the specified order
//   Actual benchmarks:
//
//   fillseq	   -- write N values in sequential key order in async mode
//   fillrandom	-- write N values in random key order in async mode
//   overwrite	 -- overwrite N values in random key order in async mode
//   overwriteopen -- overwrite random keys using open-loop arrivals
//   fillseqsync   -- write N/100 values in sequential key order in sync mode
//   fillseqbatch  -- batch write N values in sequential key order in async mode
//   fillrandsync  -- write N/100 values in random key order in sync mode
//   fillrandbatch  -- batch write N values in random key order in async mode
//   readseq	   -- read N times sequentially
//   readreverse   -- read N times in reverse order
//   readrandom	-- read N times in random order
//   readopen	-- read random keys using open-loop arrivals
static char* FLAGS_benchmarks =
	"fillrandsync,"
	"fillrandom,"
	"fillrandbatch,"
	"fillseqsync,"
	"fillseq,"
	"fillseqbatch,"
	"overwrite,"
	"overwritebatch,"
#if 0
	"overwritebatch,"
#endif
	"readrandom,"
	"readseq,"
	"readreverse,"
	;

// Number of key/values to place in database
int64_t FLAGS_num = 50000000;

// Number of read operations to do.  If negative, do FLAGS_num reads.
int64_t FLAGS_reads = -1;

// Number of concurrent threads to run.
int FLAGS_threads = 1;

// Maximum number of threads.
int FLAGS_max_threads = 0;

// Time in seconds for the random-ops tests to run.
int FLAGS_duration = 0;

// Per-thread rate limit on writes per second.
// Only for the readwhilewriting test.
int FLAGS_writes_per_second;

// Target arrival rate (ops/sec) for open-loop readopen/overwriteopen benchmark.
// Uses Poisson process (exponential inter-arrival times).
int64_t FLAGS_arrival_rate = 0;

// Comma-separated list of arrival rates for multi-RPS sweep in readopen/overwriteopen.
// When set, overrides --arrival_rate.  Example: --arrival_rates=1000,5000,10000
static const char *FLAGS_arrival_rates = NULL;

// Warmup duration in seconds for open-loop benchmarks (0 = no warmup).
// During warmup the benchmark runs at 10% of max(rates) and latency is not recorded.
int FLAGS_warmup_sec = 10;

// CPU to pin the open-loop generator thread to (-1 = no pinning).
int FLAGS_generator_cpu = -1;

// SCHED_FIFO priority for the open-loop generator thread (0 = no RT scheduling,
// 1-99 = real-time priority; requires CAP_SYS_NICE or root).
int FLAGS_generator_rt_prio = 0;

// Stats are reported every N seconds when this is
// greater than zero.
int FLAGS_stats_period = 0;

// Size of each value
int FLAGS_value_size = 1024;

// Size of each key
int FLAGS_key_size = 12;

// Number of key/values to place in database
int FLAGS_batch = 100;

// Arrange to generate values that shrink to this fraction of
// their original size after compression
float FLAGS_compression_ratio = 0.5;

// Compression disabled by default
int FLAGS_compression = 0;

// Print histogram of operation timings
int FLAGS_histogram = 0;

// If true, do not destroy the existing database.  If you set this
// flag and also specify a benchmark that wants a fresh database, that
// benchmark will fail.
int FLAGS_use_existing_db = 0;

// If true, running on a raw device
int FLAGS_rawdev = 0;

// Use the db with the following name.
const char* FLAGS_db = "/mnt/pmem0/lmdb";

static rndctx **seeds;
static Hstctx **hists;

extern DBB_backend *dbb_backend;

static char *CompressibleString(rndctx *ctx, float ratio, int len, char *buf)
{
	char *ptr, *end;
	int i, raw = (int)len * ratio;
	if (raw < 1) raw = 1;

	ptr = buf;
	end = buf + len;
	for (i=0; i<raw; i++)
		*ptr++ = (DBB_random(ctx) % 96) + ' ';

	i = 0;
	while (ptr < end) {
		*ptr++ = buf[i++];
		if (i >= raw)
			i = 0;
	}
	return end;
}

#define RAND_STRSIZE	10485600
static void GenerateString(DBB_local *dl)
{
	int i;
	char *ptr, *end;
	dl->dl_randstr = malloc(RAND_STRSIZE);
	dl->dl_randstrpos = 0;

	ptr = dl->dl_randstr;
	end = ptr + RAND_STRSIZE;
	while (ptr < end)
		ptr = CompressibleString(dl->dl_rndctx, FLAGS_compression_ratio, 100, ptr);
}

/* Helper for quickly generating random data */
void DBB_randstring(DBB_local *dl, DBB_val *val)
{
	if (dl->dl_randstrpos + val->dv_size > RAND_STRSIZE) {
		dl->dl_randstrpos = 0;
		assert(val->dv_size < RAND_STRSIZE);
	}
	val->dv_data = dl->dl_randstr + dl->dl_randstrpos;
	dl->dl_randstrpos += val->dv_size;
}

static int timecmp(struct timeval *a, struct timeval *b)
{
	int ret;
	ret = a->tv_sec - b->tv_sec;
	if (ret)
		return ret;
	return a->tv_usec - b->tv_usec;
}

static void timesub(struct timeval *end, struct timeval *beg)
{
	end->tv_sec -= beg->tv_sec;
	end->tv_usec -= beg->tv_usec;
	if (end->tv_usec < 0) {
		end->tv_usec += 1000000;
		end->tv_sec--;
	}
}

static void Merge(DBB_local *dst, DBB_local *src) {
	DBB_hstmerge(dst->dl_hstctx, src->dl_hstctx);
	dst->dl_done += src->dl_done;
	dst->dl_bytes += src->dl_bytes;
	dst->dl_seconds += src->dl_seconds;
	if (timecmp(&dst->dl_start, &src->dl_start) > 0)
		dst->dl_start = src->dl_start;
	if (timecmp(&dst->dl_finish, &src->dl_finish) < 0)
		dst->dl_finish = src->dl_finish;

	/* Just keep the messages from one thread */
	if (!dst->dl_message.dv_data && src->dl_message.dv_data)
		dst->dl_message = src->dl_message;
}

void DBB_message(DBB_local *dl, char *msg) {
	int len = strlen(msg) + 1;	/* add a space */
	char *ptr;
	if (dl->dl_message.dv_size) {
		ptr = realloc(dl->dl_message.dv_data, dl->dl_message.dv_size + len);
		if (!ptr)
			return;
		dl->dl_message.dv_data = ptr;
		ptr += dl->dl_message.dv_size - 1;
	} else {
		ptr = malloc(len + 1);
		if (!ptr)
			return;
		dl->dl_message.dv_data = ptr;
		dl->dl_message.dv_size = 1;
	}
	*ptr++ = ' ';
	strcpy(ptr, msg);
	dl->dl_message.dv_size += len;
}

static void TimeStr(time_t seconds, char *buf) {
	struct tm tm;
	localtime_r(&seconds, &tm);
	sprintf(buf, "%04d/%02d/%02d-%02d:%02d:%02d",
		tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday,
		tm.tm_hour, tm.tm_min, tm.tm_sec);
}

void DBB_opdone(DBB_local *dl) {
	if (FLAGS_histogram) {
		struct timeval now;
		struct timeval last;
		gettimeofday(&now, NULL);
		last = dl->dl_last_op_finish;
		dl->dl_last_op_finish = now;
		timesub(&now, &last);
		DBB_hstadd(dl->dl_hstctx, &now);
		if (now.tv_sec > 0 || now.tv_usec > 20000) {
			fprintf(stderr, "long op: %d.%06d micros%30s\r", (int)now.tv_sec, (int)now.tv_usec, "");
			fflush(stderr);
		}
	}
	dl->dl_done++;
}

static void Report(DBB_local *dl, const char *name) {
	char rate[100];
	// Pretend at least one op was done in case we are running a benchmark
	// that does not call FinishedSingleOp().
	if (dl->dl_done < 1) dl->dl_done = 1;

	timesub(&dl->dl_finish, &dl->dl_start);
	double elapsed = dl->dl_finish.tv_sec + dl->dl_finish.tv_usec * 1e-6;
	if (dl->dl_bytes > 0) {
		// Rate is computed on actual elapsed time, not the sum of per-thread
		// elapsed times.
		snprintf(rate, sizeof(rate), "%6.1f MB/s",
			(dl->dl_bytes / 1048576.0) / elapsed);
	} else {
		rate[0] = '\0';
	}

	double throughput = (double)dl->dl_done/elapsed;

	fprintf(stdout, "%-13s : %11.3f micros/op %ld ops/sec;%s%s\n",
			name,
			elapsed * 1e6 / dl->dl_done,
			(long)throughput, rate, dl->dl_message.dv_data ? (char *)dl->dl_message.dv_data : "");
	if (FLAGS_histogram) {
		DBB_hstprint(dl->dl_hstctx);
	}
	fflush(stdout);
}

/* ================================================================
 * Open-loop benchmark infrastructure (readopen/overwriteopen)
 * ================================================================ */

/*
 * Lock-free SPSC ring buffer (one per worker).
 * Producer (generator) updates tail; consumer (worker) updates head.
 * capacity must be a power of two.
 */
#define OL_QUEUE_CAP (1 << 20)   /* 1M slots per worker queue */

typedef struct {
	uint64_t        key_idx;
	struct timespec enqueue_time;
	int             phase;   /* 0 = warmup (discard), 1..N = measurement phase */
} ol_req_t;

typedef struct {
	ol_req_t *buf;
	int       capacity;
	volatile int head;          /* consumer (worker) updates */
	volatile int tail;          /* producer (generator) updates */
	volatile int producer_done;
} ol_queue_t;

static void ol_queue_init(ol_queue_t *q) {
	q->buf           = malloc(OL_QUEUE_CAP * sizeof(ol_req_t));
	q->capacity      = OL_QUEUE_CAP;
	q->head          = 0;
	q->tail          = 0;
	q->producer_done = 0;
}

static void ol_queue_destroy(ol_queue_t *q) {
	free(q->buf);
}

/* Returns 1 if enqueued, 0 if full (request dropped).  Called by generator only. */
static int ol_queue_try_push(ol_queue_t *q, ol_req_t *req) {
	int t    = __atomic_load_n(&q->tail, __ATOMIC_RELAXED);
	int next = (t + 1) & (q->capacity - 1);
	if (next == __atomic_load_n(&q->head, __ATOMIC_ACQUIRE))
		return 0;  /* full */
	q->buf[t] = *req;
	__atomic_store_n(&q->tail, next, __ATOMIC_RELEASE);
	return 1;
}

/* Spin-wait until item available or producer done.
 * Returns 1 if dequeued, 0 if done.  Called by worker only. */
static int ol_queue_pop(ol_queue_t *q, ol_req_t *out) {
	while (1) {
		int h = __atomic_load_n(&q->head, __ATOMIC_RELAXED);
		int t = __atomic_load_n(&q->tail, __ATOMIC_ACQUIRE);
		if (h != t) {
			*out = q->buf[h];
			__atomic_store_n(&q->head, (h + 1) & (q->capacity - 1),
			                 __ATOMIC_RELEASE);
			return 1;
		}
		if (__atomic_load_n(&q->producer_done, __ATOMIC_ACQUIRE))
			return 0;
		__asm__ volatile("pause");
	}
}

static void ol_queue_producer_done(ol_queue_t *q) {
	__atomic_store_n(&q->producer_done, 1, __ATOMIC_RELEASE);
}

/* ---- timing helper ---- */
static inline void timespec_add_ns(struct timespec *ts, long ns) {
	ts->tv_nsec += ns;
	if (ts->tv_nsec >= 1000000000L) {
		ts->tv_sec++;
		ts->tv_nsec -= 1000000000L;
	}
}

static inline int timespec_lt(const struct timespec *a, const struct timespec *b) {
	return a->tv_sec < b->tv_sec ||
	       (a->tv_sec == b->tv_sec && a->tv_nsec < b->tv_nsec);
}

/* ---- generator thread context ---- */
typedef struct {
	ol_queue_t **queues;     /* array of n_queues per-worker queue pointers */
	int          n_queues;
	int64_t     *rates;      /* measurement arrival rates array [n_rates] */
	int          n_rates;
	int          warmup_sec;
	int          duration_sec;
	rndctx      *rndctx;
	int64_t      num_keys;
	/* output */
	int64_t      warmup_sent;
	int64_t      warmup_dropped;
	int64_t     *sent;       /* per-phase [n_rates] */
	int64_t     *dropped;    /* per-phase [n_rates] */
} ol_gen_ctx_t;

/*
 * Run one phase of the Poisson generator for dur_sec seconds at the given
 * rate.  Every request is tagged with 'phase' so workers can route it to
 * the correct histogram (phase 0 = warmup → discard).
 */
static void run_gen_phase(ol_gen_ctx_t *g, int phase, int64_t rate, int dur_sec,
                          int64_t *out_sent, int64_t *out_dropped)
{
	double mean_ns = 1e9 / (double)rate;
	int    n       = g->n_queues;
	int    q_idx   = 0;
	*out_sent    = 0;
	*out_dropped = 0;

	struct timespec now, next;
	clock_gettime(CLOCK_MONOTONIC, &now);
	next = now;

	struct timespec deadline = now;
	deadline.tv_sec += dur_sec;

	while (1) {
		/* next inter-arrival time: -mean * ln(U), U ~ Uniform(0,1) */
		double u = ((double)(DBB_random(g->rndctx) % 1000000) + 0.5) / 1000000.0;
		long interval_ns = (long)(-mean_ns * log(u));
		if (interval_ns < 1) interval_ns = 1;
		timespec_add_ns(&next, interval_ns);

		/* busy-wait until next arrival */
		do {
			clock_gettime(CLOCK_MONOTONIC, &now);
		} while (timespec_lt(&now, &next));

		/* Prevent catch-up burst: if we overran the scheduled arrival by more
		 * than one mean interval (e.g. due to OS preemption), reset 'next' to
		 * now so we don't fire a burst of back-to-back requests trying to
		 * compensate.  The skipped arrivals are simply not sent (they raise the
		 * effective drop rate, which is the correct open-loop signal). */
		{
			long overrun_ns = (now.tv_sec  - next.tv_sec)  * 1000000000L
			                + (now.tv_nsec - next.tv_nsec);
			if (overrun_ns > (long)mean_ns)
				next = now;
		}

		/* stop if duration elapsed */
		if (!timespec_lt(&now, &deadline))
			break;

		ol_req_t req;
		req.key_idx      = DBB_random(g->rndctx) % g->num_keys;
		req.enqueue_time = now;
		req.phase        = phase;

		/* round-robin across per-worker queues */
		if (ol_queue_try_push(g->queues[q_idx], &req))
			(*out_sent)++;
		else
			(*out_dropped)++;
		q_idx = (q_idx + 1) % n;
	}
}

static int64_t ol_compute_warmup_rate(const int64_t *rates, int n_rates)
{
	int64_t max_rate = 0;
	for (int i = 0; i < n_rates; i++)
		if (rates[i] > max_rate) max_rate = rates[i];
	return max_rate > 0 ? (max_rate + 9) / 10 : 0;
}

static void *OLGeneratorThread(void *arg) {
	ol_gen_ctx_t *g = arg;

	int64_t warmup_rate = ol_compute_warmup_rate(g->rates, g->n_rates);

	/* Phase 0: warmup — latency not recorded by workers */
	if (g->warmup_sec > 0 && warmup_rate > 0) {
		fprintf(stdout, "[warmup] %ds @ %" PRId64 " rps ...\n",
		        g->warmup_sec, warmup_rate);
		fflush(stdout);
		run_gen_phase(g, 0, warmup_rate, g->warmup_sec,
		              &g->warmup_sent, &g->warmup_dropped);
	}

	/* Phases 1..n_rates: measurement at each target rate */
	for (int r = 0; r < g->n_rates; r++)
		run_gen_phase(g, r + 1, g->rates[r], g->duration_sec,
		              &g->sent[r], &g->dropped[r]);

	/* signal each worker that no more items will arrive */
	for (int i = 0; i < g->n_queues; i++)
		ol_queue_producer_done(g->queues[i]);
	return NULL;
}

/* ---- worker thread context ---- */
typedef struct {
	ol_queue_t *queue;
	Hstctx    **phase_hists;   /* [n_phases]: one histogram per measurement phase */
	int         n_phases;      /* == n_rates */
	void       *worker_state;  /* backend per-worker state */
	int         write_mode;
	int64_t    *processed;     /* [n_phases]: per-phase processed count */
} ol_worker_ctx_t;

static void *OLWorkerThread(void *arg) {
	ol_worker_ctx_t *w = arg;
	ol_req_t req;

	while (ol_queue_pop(w->queue, &req)) {
		if (w->write_mode)
			dbb_backend->db_write_one_key(w->worker_state, req.key_idx);
		else
			dbb_backend->db_read_one_key(w->worker_state, req.key_idx);

		/* phase 0 = warmup: execute but do not record latency */
		if (req.phase == 0)
			continue;

		struct timespec done;
		clock_gettime(CLOCK_MONOTONIC, &done);

		long latency_ns = (done.tv_sec  - req.enqueue_time.tv_sec)  * 1000000000L
		                + (done.tv_nsec - req.enqueue_time.tv_nsec);
		if (latency_ns < 0) latency_ns = 0;

		/* convert to struct timeval (microseconds) for existing histogram */
		long latency_us = latency_ns / 1000;
		struct timeval tv;
		tv.tv_sec  = latency_us / 1000000;
		tv.tv_usec = latency_us % 1000000;

		int pidx = req.phase - 1;   /* 0-based phase index */
		DBB_hstadd(w->phase_hists[pidx], &tv);
		w->processed[pidx]++;
	}
	return NULL;
}

/* ---- RunOpenLoopBenchmark ---- */
static void RunOpenLoopBenchmark(const char *name) {
	int write_mode = !strcmp(name, "overwriteopen");

	if (!dbb_backend->db_open_worker ||
	    !(write_mode ? dbb_backend->db_write_one_key : dbb_backend->db_read_one_key) ||
	    !dbb_backend->db_close_worker) {
		fprintf(stderr, "%s: backend '%s' does not support this open-loop interface\n",
		        name, dbb_backend->db_name);
		return;
	}
	if (FLAGS_duration <= 0) {
		fprintf(stderr, "%s: --duration must be > 0\n", name);
		return;
	}

	/* ---- parse target rates ---- */
	int64_t *rates;
	int      n_rates;

	if (FLAGS_arrival_rates && FLAGS_arrival_rates[0]) {
		/* count comma-separated tokens */
		n_rates = 1;
		for (const char *p = FLAGS_arrival_rates; *p; p++)
			if (*p == ',') n_rates++;
		rates = malloc(n_rates * sizeof(int64_t));
		char *buf = strdup(FLAGS_arrival_rates);
		char *tok = strtok(buf, ",");
		for (int i = 0; i < n_rates && tok; i++, tok = strtok(NULL, ","))
			rates[i] = (int64_t)atoll(tok);
		free(buf);
	} else if (FLAGS_arrival_rate > 0) {
		n_rates  = 1;
		rates    = malloc(sizeof(int64_t));
		rates[0] = FLAGS_arrival_rate;
	} else {
		fprintf(stderr,
		        "%s: --arrival_rates=<r1,r2,...> or --arrival_rate=<r> must be set\n",
		        name);
		return;
	}

	for (int i = 0; i < n_rates; i++) {
		if (rates[i] <= 0) {
			fprintf(stderr, "%s: all rates must be > 0\n", name);
			free(rates);
			return;
		}
	}

	int n_workers = FLAGS_threads;

	/* ---- per-phase histograms: phase_hists[phase_idx][worker_id] ---- */
	Hstctx ***phase_hists = malloc(n_rates * sizeof(Hstctx **));
	for (int p = 0; p < n_rates; p++) {
		phase_hists[p] = malloc(n_workers * sizeof(Hstctx *));
		for (int w = 0; w < n_workers; w++) {
			phase_hists[p][w] = DBB_hstctx();
			DBB_hstinit(phase_hists[p][w]);
		}
	}

	/* ---- per-worker, per-phase processed counts ---- */
	int64_t **processed = malloc(n_workers * sizeof(int64_t *));
	for (int w = 0; w < n_workers; w++)
		processed[w] = calloc(n_rates, sizeof(int64_t));

	/* ---- one lock-free SPSC queue per worker ---- */
	ol_queue_t  *queues = malloc(n_workers * sizeof(ol_queue_t));
	ol_queue_t **qptrs  = malloc(n_workers * sizeof(ol_queue_t *));
	for (int i = 0; i < n_workers; i++) {
		ol_queue_init(&queues[i]);
		qptrs[i] = &queues[i];
	}

	/* ---- init worker contexts ---- */
	ol_worker_ctx_t *workers = malloc(n_workers * sizeof(ol_worker_ctx_t));
	pthread_t        *wtids  = malloc(n_workers * sizeof(pthread_t));
	for (int i = 0; i < n_workers; i++) {
		workers[i].queue        = &queues[i];
		workers[i].n_phases     = n_rates;
		workers[i].phase_hists  = malloc(n_rates * sizeof(Hstctx *));
		for (int p = 0; p < n_rates; p++)
			workers[i].phase_hists[p] = phase_hists[p][i];
		workers[i].worker_state = dbb_backend->db_open_worker(i);
		workers[i].write_mode    = write_mode;
		workers[i].processed    = processed[i];
		pthread_create(&wtids[i], NULL, OLWorkerThread, &workers[i]);
	}

	/* ---- init generator context ---- */
	ol_gen_ctx_t gen;
	gen.queues          = qptrs;
	gen.n_queues        = n_workers;
	gen.rates           = rates;
	gen.n_rates         = n_rates;
	gen.warmup_sec      = FLAGS_warmup_sec;
	gen.duration_sec    = FLAGS_duration;
	gen.rndctx          = seeds[n_workers];   /* extra seed slot */
	gen.num_keys        = FLAGS_num;
	gen.warmup_sent     = 0;
	gen.warmup_dropped  = 0;
	gen.sent            = calloc(n_rates, sizeof(int64_t));
	gen.dropped         = calloc(n_rates, sizeof(int64_t));

	pthread_t gtid;
	pthread_create(&gtid, NULL, OLGeneratorThread, &gen);

	/* ---- optional: pin generator to a dedicated CPU ---- */
	if (FLAGS_generator_cpu >= 0) {
		cpu_set_t cpuset;
		CPU_ZERO(&cpuset);
		CPU_SET(FLAGS_generator_cpu, &cpuset);
		int rc = pthread_setaffinity_np(gtid, sizeof(cpuset), &cpuset);
		if (rc != 0)
			fprintf(stderr,
			        "%s: warning: could not pin generator to CPU %d: %s\n",
			        name, FLAGS_generator_cpu, strerror(rc));
		else
			fprintf(stdout,
			        "%s: generator pinned to CPU %d\n",
			        name, FLAGS_generator_cpu);
	}

	/* ---- optional: elevate generator to SCHED_FIFO (requires CAP_SYS_NICE) ---- */
	if (FLAGS_generator_rt_prio > 0) {
		struct sched_param sp = { .sched_priority = FLAGS_generator_rt_prio };
		int rc = pthread_setschedparam(gtid, SCHED_FIFO, &sp);
		if (rc != 0)
			fprintf(stderr,
			        "%s: warning: could not set SCHED_FIFO prio %d: %s\n",
			        name, FLAGS_generator_rt_prio, strerror(rc));
		else
			fprintf(stdout,
			        "%s: generator set to SCHED_FIFO priority %d\n",
			        name, FLAGS_generator_rt_prio);
	}

	pthread_join(gtid, NULL);

	/* wait for all workers to drain their queues */
	for (int i = 0; i < n_workers; i++)
		pthread_join(wtids[i], NULL);

	/* close worker state */
	for (int i = 0; i < n_workers; i++)
		dbb_backend->db_close_worker(workers[i].worker_state);

	/* ---- print warmup summary ---- */
	if (FLAGS_warmup_sec > 0) {
		int64_t wrate = ol_compute_warmup_rate(rates, n_rates);
		fprintf(stdout,
		        "[warmup] %ds @ %" PRId64 " rps  "
		        "sent=%" PRId64 "  dropped=%" PRId64 " — skipped\n",
		        FLAGS_warmup_sec, wrate,
		        gen.warmup_sent, gen.warmup_dropped);
	}

	/* ---- print per-phase results ---- */
	for (int p = 0; p < n_rates; p++) {
		/* merge worker histograms into [p][0] */
		for (int w = 1; w < n_workers; w++)
			DBB_hstmerge(phase_hists[p][0], phase_hists[p][w]);

		int64_t total_processed = 0;
		for (int w = 0; w < n_workers; w++)
			total_processed += processed[w][p];

		double avg_us = total_processed > 0
		              ? ((double)FLAGS_duration * 1e6 / total_processed)
		              : 0.0;
		double throughput = FLAGS_duration > 0
		                  ? (double)total_processed / FLAGS_duration
		                  : 0.0;

		fprintf(stdout, "\n[phase %d] arrival_rate=%" PRId64
		        "  workers=%d\n", p + 1, rates[p], n_workers);
		fprintf(stdout,
		        "  %-13s : %11.3f micros/op  %.0f ops/sec\n",
		        name, avg_us, throughput);
		fprintf(stdout,
		        "  sent=%" PRId64 "  dropped=%" PRId64 " (%.2f%%)"
		        "  processed=%" PRId64 "\n",
		        gen.sent[p], gen.dropped[p],
		        (gen.sent[p] + gen.dropped[p]) > 0
		            ? 100.0 * gen.dropped[p] / (gen.sent[p] + gen.dropped[p])
		            : 0.0,
		        total_processed);

		DBB_hstsum(phase_hists[p][0]);
		fprintf(stdout,
		        "  p50=%.1f us  p99=%.1f us  p99.9=%.1f us  p99.99=%.1f us\n",
		        DBB_hstpct(phase_hists[p][0], 50.0),
		        DBB_hstpct(phase_hists[p][0], 99.0),
		        DBB_hstpct(phase_hists[p][0], 99.9),
		        DBB_hstpct(phase_hists[p][0], 99.99));

		if (FLAGS_histogram)
			DBB_hstprint(phase_hists[p][0]);
	}
	fflush(stdout);

	/* ---- cleanup ---- */
	for (int i = 0; i < n_workers; i++) {
		free(workers[i].phase_hists);
		free(processed[i]);
	}
	free(processed);

	for (int p = 0; p < n_rates; p++)
		free(phase_hists[p]);
	free(phase_hists);

	for (int i = 0; i < n_workers; i++)
		ol_queue_destroy(&queues[i]);
	free(queues);
	free(qptrs);
	free(workers);
	free(wtids);
	free(gen.sent);
	free(gen.dropped);
	free(rates);
}

/* ================================================================ */

int DBB_done(DBB_local *dl) {
	/* If rate limiting, check every 100ms */
	if (dl->dl_wps_by_10) {
		struct timeval now;
		++dl->dl_writes;
		if (dl->dl_writes >= dl->dl_wps_by_10) {
			struct timeval tv;
			int delta;
			gettimeofday(&now, NULL);
			tv = now;
			timesub(&tv, &dl->dl_lastwrite);
			tv.tv_usec += tv.tv_sec * 1000000;
			dl->dl_writes = 0;
			dl->dl_lastwrite = now;
			if (tv.tv_usec < 100000) {
				usleep(100000 - tv.tv_usec);
				gettimeofday(&dl->dl_lastwrite, NULL);
			}
		}
	}
	if (dl->dl_max_seconds) {
		if (!(dl->dl_done % 1000)) {
		// Recheck every appx 1000 ops (exact iff increment is factor of 1000)
			time_t now = time(NULL);
			return (now - dl->dl_start.tv_sec >= dl->dl_max_seconds);
		} else {
			return 0;
		}
	} else {
		return dl->dl_done >= dl->dl_max_ops;
	}
}

static void PrintWarnings() {
#if defined(__GNUC__) && !defined(__OPTIMIZE__)
	fprintf(stdout,
			"WARNING: Optimization is disabled: benchmarks unnecessarily slow\n"
			);
#endif
#ifndef NDEBUG
	fprintf(stdout,
			"WARNING: Assertions are enabled; benchmarks unnecessarily slow\n");
#endif
}

static void PrintEnvironment() {
	fprintf(stdout, "%s: version %s\n", dbb_backend->db_longname, dbb_backend->db_verstr());

#if defined(__linux)
	time_t now = time(NULL);
	fprintf(stdout, "Date:	   %s", ctime(&now));  // ctime() adds newline

	FILE* cpuinfo = fopen("/proc/cpuinfo", "r");
	if (cpuinfo != NULL) {
		char line[1000];
		int num_cpus = 0;
		char cpu_type[1000];
		char cache_size[1000];
		cpu_type[0] = '\0';
		cache_size[0] = '\0';
		while (fgets(line, sizeof(line), cpuinfo) != NULL) {
			char *val, *ptr;
			char *sep = strchr(line, ':');
			if (sep == NULL) {
				continue;
			}
			*sep++ = '\0';
			ptr = strchr(line, '\t');
			if (ptr)
				*ptr = '\0';
			val = sep+1;
			if (!strcmp(line,"model name")) {
				strcpy(cpu_type, val);
			} else if (!strcmp(line, "processor")) {
				++num_cpus;
			} else if (!strcmp(line, "cache size")) {
				strcpy(cache_size, val);
			}
		}
		fclose(cpuinfo);
		if (!cpu_type[0]) {
			char family[250], manuf[250], version[250], freq[200], *ptr;
			int cachei = 0;
			cpuinfo = popen("dmidecode -t processor", "r");
			if (cpuinfo) {
				while(fgets(line, sizeof(line), cpuinfo)) {
					char *sep = strchr(line, ':');
					if (!sep) continue;
					*sep = '\0';
					sep += 2;
					ptr = strrchr(sep, '\n');
					if (ptr) *ptr = '\0';
					ptr = line+1;
					if (!strcmp(ptr, "Manufacturer")) {
						strcpy(manuf, sep);
					} else if (!strcmp(ptr, "Family")) {
						strcpy(family, sep);
					} else if (!strcmp(ptr, "Version")) {
						strcpy(version, sep);
					} else if (!strcmp(ptr, "Max Speed")) {
						strcpy(freq, sep);
					}
				}
				pclose(cpuinfo);
				snprintf(cpu_type, sizeof(cpu_type), "%s %s %s %s\n", manuf, family, version, freq);
				cpuinfo = popen("dmidecode -t cache", "r");
				while(fgets(line, sizeof(line), cpuinfo)) {
					char *sep = strchr(line, ':');
					if (!sep) continue;
					*sep = '\0';
					sep += 2;
					ptr = line+1;
					if (!strcmp(ptr, "Installed Size")) {
						int i = atoi(sep);
						if (i > cachei)
							strcpy(cache_size, sep);
					}
				}
				pclose(cpuinfo);
			}
		}
		fprintf(stdout, "CPU:		%d * %s", num_cpus, cpu_type);
		fprintf(stdout, "CPUCache:   %s", cache_size);
	}
#endif
}

static void PrintHeader() {
	PrintEnvironment();
	fprintf(stdout, "Keys:	   %d bytes each\n", FLAGS_key_size);
	fprintf(stdout, "Values:	 %d bytes each (%d bytes after compression)\n",
			FLAGS_value_size,
			(int)(FLAGS_value_size * FLAGS_compression_ratio + 0.5));
	fprintf(stdout, "Entries:	%ld\n", FLAGS_num);
	fprintf(stdout, "RawSize:	%.1f MB (estimated)\n",
			(((int64_t)(FLAGS_key_size + FLAGS_value_size) * FLAGS_num)
			 / 1048576.0));
	fprintf(stdout, "FileSize:   %.1f MB (estimated)\n",
			(((FLAGS_key_size + FLAGS_value_size * FLAGS_compression_ratio) * FLAGS_num)
			 / 1048576.0));
	PrintWarnings();
	fprintf(stdout, "------------------------------------------------\n");
	fflush(stdout);
}

static void *RunThread(void *v) {
	DBB_local *dl = v;

	pthread_mutex_lock(&dl->dl_global->dg_mu);
	dl->dl_global->dg_initialized++;
	if (dl->dl_global->dg_initialized >= dl->dl_global->dg_threads)
		pthread_cond_broadcast(&dl->dl_global->dg_cv);

	while(!dl->dl_global->dg_start)
		pthread_cond_wait(&dl->dl_global->dg_cv, &dl->dl_global->dg_mu);
	pthread_mutex_unlock(&dl->dl_global->dg_mu);

	dl->dl_done = 0;
	dl->dl_last_report_done = 0;
	dl->dl_bytes = 0;
	dl->dl_seconds = 0;
	dl->dl_max_ops = dl->dl_op == DO_READ ? dl->dl_global->dg_reads : dl->dl_global->dg_num;
	dl->dl_max_seconds = dl->dl_order == DO_RANDOM ? FLAGS_duration : 0;
	dl->dl_message.dv_size = 0;
	dl->dl_message.dv_data = NULL;
	gettimeofday(&dl->dl_start, NULL);
	dl->dl_finish = dl->dl_start;
	dl->dl_last_op_finish = dl->dl_start;
	dl->dl_last_report_finish = dl->dl_start;
	if (dl->dl_wps_by_10)
		dl->dl_lastwrite = dl->dl_start;
	if (dl->dl_op == DO_READ)
		dbb_backend->db_read(dl);
	else
		dbb_backend->db_write(dl);

	gettimeofday(&dl->dl_finish, NULL);
	dl->dl_seconds = dl->dl_finish.tv_sec - dl->dl_start.tv_sec;

    printf("Time taken in run = %d seconds\n", dl->dl_seconds);

	pthread_mutex_lock(&dl->dl_global->dg_mu);
	dl->dl_global->dg_done++;
	if (dl->dl_global->dg_done >= dl->dl_global->dg_threads)
		pthread_cond_broadcast(&dl->dl_global->dg_cv);
	pthread_mutex_unlock(&dl->dl_global->dg_mu);
	return NULL;
}

static void *StatsThread(void *v) {
	DBB_local *args = v;
	DBB_global *dg = args->dl_global;
	int i;
	int banner = 0;

	pthread_mutex_lock(&dg->dg_mu);
	while(!dg->dg_start)
		pthread_cond_wait(&dg->dg_cv, &dg->dg_mu);
	pthread_mutex_unlock(&dg->dg_mu);
	while(1) {
		struct timeval now, end1, end2;
		sleep(FLAGS_stats_period);
		if (dg->dg_done >= dg->dg_threads)
			break;
		if (!banner) {
			banner = 1;
			fprintf(stderr,
			"     Timestamp     	Thread	Cur Ops	Tot Ops	Cur Rate	Avg Rate	Cur Sec 	Tot Sec\n");
		}
		gettimeofday(&now, NULL);
		char buf[20];
		TimeStr(now.tv_sec, buf);
		for (i=0; i<dg->dg_threads; i++) {
			DBB_local *dl = &args[i];
			int64_t done = dl->dl_done;
			end1 = now; end2 = now;
			timesub(&end1, &dl->dl_last_report_finish);
			timesub(&end2, &dl->dl_start);
			fprintf(stderr,
			"%s\t%d\t%zd\t%zd\t%.1f\t%.1f\t%d.%06d\t%d.%06d\n",
			buf, dl->dl_id,
			done - dl->dl_last_report_done, done,
			(float)(done - dl->dl_last_report_done) / end1.tv_sec,
			(float)done / end2.tv_sec,
			(int)end1.tv_sec, (int)end1.tv_usec, (int)end2.tv_sec, (int)end2.tv_usec);
			dl->dl_last_report_done = dl->dl_done;
			dl->dl_last_report_finish = now;
		}
		fflush(stderr);
	}
}

static void RunBenchmark(int n, const char *name, DBB_global *dg) {
	DBB_local *args;
	int i;
	pthread_t stats_thread;

	dg->dg_threads = n;
	dg->dg_initialized = 0;
	dg->dg_done = 0;
	dg->dg_start = 0;

	args = malloc(n * sizeof(DBB_local));
	for (i = 0; i < n; i++) {
		args[i].dl_global = dg;
		args[i].dl_rndctx = seeds[i];
		args[i].dl_hstctx = hists[i];
		args[i].dl_order = dg->dg_order;
		args[i].dl_id = i;
		args[i].dl_randstrpos = 0;
		args[i].dl_writes_per_sec = 0;
		args[i].dl_wps_by_10 = 0;
		args[i].dl_writes = 0;
		args[i].dl_lastwrite.tv_sec = 0;
		args[i].dl_lastwrite.tv_usec = 0;
		if (dg->dg_op == DO_READWRITE) {
			if (i)
				args[i].dl_op = DO_READ;
			else {
				args[i].dl_op = DO_WRITE;
				args[i].dl_writes_per_sec = FLAGS_writes_per_second;
				args[i].dl_wps_by_10 = FLAGS_writes_per_second / 10;
			}
		} else {
			args[i].dl_op = dg->dg_op;
			if (args[i].dl_op == DO_WRITE) {
				args[i].dl_writes_per_sec = FLAGS_writes_per_second;
				args[i].dl_wps_by_10 = FLAGS_writes_per_second / 10;
			}
		}
		if (args[i].dl_op == DO_WRITE)
			GenerateString(&args[i]);
		pthread_create(&args[i].dl_tid, NULL, RunThread, &args[i]);
	}
	if (FLAGS_stats_period)
		pthread_create(&stats_thread, NULL, StatsThread, args);

	pthread_mutex_lock(&dg->dg_mu);
	while (dg->dg_initialized < n) {
		pthread_cond_wait(&dg->dg_cv, &dg->dg_mu);
	}

	dg->dg_start = 1;
	pthread_cond_broadcast(&dg->dg_cv);
	while (dg->dg_done < n) {
		pthread_cond_wait(&dg->dg_cv, &dg->dg_mu);
	}
	pthread_mutex_unlock(&dg->dg_mu);

	if (dg->dg_op == DO_READWRITE) {
		Report(&args[0], "writer");
		for (i = 2; i < n; i++) {
			Merge(&args[1], &args[i]);
		}
		Report(&args[1], name);
	} else {
		for (i = 1; i < n; i++) {
			Merge(&args[0], &args[i]);
		}
		Report(&args[0], name);
	}

	if (FLAGS_stats_period)
		pthread_join(stats_thread, NULL);
	for (i = 0; i < n; i++) {
		DBB_srandom(seeds[i], DBB_random(seeds[i]));
		pthread_join(args[i].dl_tid, NULL);
	}
	free(args);
}

static void killdb() {
#define VM_ALIGN	0x200000
	if (FLAGS_rawdev) {
		int fd;
		char *ptr;
		fd = open(FLAGS_db, O_RDWR);
		ptr = mmap(NULL, VM_ALIGN, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
		memset(ptr, 0, 16384);
		msync(ptr, 16384, MS_SYNC);
		munmap(ptr, VM_ALIGN);
		close(fd);
	} else {
		char cmd[200];
		sprintf(cmd, "rm -rf %s", FLAGS_db);
		if (system(cmd)) exit(1);
	}
}

static int db_open;

static void Benchmark() {
	PrintHeader();

	char *benchmarks = (char *)FLAGS_benchmarks;
	DBB_global dg;

	pthread_mutex_init(&dg.dg_mu, NULL);
	pthread_cond_init(&dg.dg_cv, NULL);

	if (!FLAGS_use_existing_db) {
		dbb_backend->db_close();
		killdb();
		db_open = 0;
	}
	while (benchmarks != NULL) {
		char *sep = strchr(benchmarks, ',');
		char *name, namebuf[64];
		int fresh_db = 0;
		int num_threads = FLAGS_threads;
		if (sep == NULL) {
			name = benchmarks;
			benchmarks = NULL;
		} else {
			int len = sep-benchmarks;
			strncpy(namebuf, benchmarks, len);
			benchmarks = sep+1;
			name = namebuf;
			namebuf[len] = '\0';
		}

        benchmarks = NULL;

		dg.dg_num = FLAGS_num;
		dg.dg_reads = (FLAGS_reads < 0) ? FLAGS_num : FLAGS_reads;
		dg.dg_batchsize = 1;
		dg.dg_dbflags = 0;

		if (!strcmp(name, "fillseq")) {
			dg.dg_op = DO_WRITE;
			dg.dg_order = DO_FORWARD;
			fresh_db = 1;
		} else if (!strcmp(name, "fillseqbatch")) {
			dg.dg_op = DO_WRITE;
			dg.dg_order = DO_FORWARD;
			fresh_db = 1;
			dg.dg_batchsize = FLAGS_batch;
		} else if (!strcmp(name, "fillrandom")) {
			dg.dg_op = DO_WRITE;
			dg.dg_order = DO_RANDOM;
			fresh_db = 1;
		} else if (!strcmp(name, "fillrandbatch")) {
			dg.dg_op = DO_WRITE;
			dg.dg_order = DO_RANDOM;
			fresh_db = 1;
			dg.dg_batchsize = FLAGS_batch;
		} else if (!strcmp(name, "overwrite")) {
			dg.dg_op = DO_WRITE;
			dg.dg_order = DO_RANDOM;
		} else if (!strcmp(name, "overwritebatch")) {
			dg.dg_op = DO_WRITE;
			dg.dg_order = DO_RANDOM;
			dg.dg_batchsize = FLAGS_batch;
		} else if (!strcmp(name, "fillrandsync")) {
			dg.dg_op = DO_WRITE;
			dg.dg_order = DO_RANDOM;
			fresh_db = 1;
			dg.dg_num /= 1000;
			if (dg.dg_num<10) dg.dg_num=10;
			dg.dg_dbflags = DBB_SYNC;
		} else if (!strcmp(name, "fillseqsync")) {
			dg.dg_op = DO_WRITE;
			dg.dg_order = DO_FORWARD;
			fresh_db = 1;
			dg.dg_num /= 1000;
			if (dg.dg_num<10) dg.dg_num=10;
			dg.dg_dbflags = DBB_SYNC;
		} else if (!strcmp(name, "readseq")) {
			dg.dg_op = DO_READ;
			dg.dg_order = DO_FORWARD;
		} else if (!strcmp(name, "readreverse")) {
			dg.dg_op = DO_READ;
			dg.dg_order = DO_REVERSE;
		} else if (!strcmp(name, "readrandom")) {
			dg.dg_op = DO_READ;
			dg.dg_order = DO_RANDOM;
		} else if (!strcmp(name, "readwhilewriting")) {
			dg.dg_op = DO_READWRITE;
			dg.dg_order = DO_RANDOM;
			num_threads++;
		} else if (!strcmp(name, "readopen") || !strcmp(name, "overwriteopen")) {
			/* open-loop benchmark: handled separately */
			if (!db_open) {
				dbb_backend->db_open(dg.dg_dbflags);
				db_open = 1;
			}
			RunOpenLoopBenchmark(name);
			continue;
		} else {
			if (*name) {	// No error message for empty name
				fprintf(stderr, "unknown benchmark '%s'\n", name);
			}
			continue;
		}

		if (fresh_db) {
			if (FLAGS_use_existing_db) {
				fprintf(stdout, "%-12s : skipped (--use_existing_db is true)\n", name);
				continue;
			}
			if (db_open) {
				dbb_backend->db_close();
				killdb();
				db_open = 0;
			}
		}
		if (!db_open) {
			dbb_backend->db_open(dg.dg_dbflags);
			db_open = 1;
		}

        struct  rusage *usage;

        usage = (struct rusage *) malloc (sizeof(struct rusage));

        printf("PAGE FAULTS BEFORE WORKLOAD: \n");
        getrusage(RUSAGE_SELF, usage);
        printf("soft page faults (ru_minflt) : %ld\n", usage->ru_minflt);
        printf("hard page faults (ru_majflt) : %ld\n", usage->ru_majflt);
        printf("--------- \n");

		RunBenchmark(num_threads, name, &dg);

        printf("PAGE FAULTS AFTER WORKLOAD: \n");
        getrusage(RUSAGE_SELF, usage);
        printf("soft page faults (ru_minflt) : %ld\n", usage->ru_minflt);
        printf("hard page faults (ru_majflt) : %ld\n", usage->ru_majflt);
        printf("--------- \n");

		if (dg.dg_op == DO_WRITE || dg.dg_op == DO_READWRITE) {
			char cmd[200];
			sprintf(cmd, "du %s", FLAGS_db);
			if (system(cmd)) exit(1);
		}
	}
	pthread_cond_destroy(&dg.dg_cv);
	pthread_mutex_destroy(&dg.dg_mu);
}

static int benchflag(char *arg) {
	FLAGS_benchmarks = arg;
	return 1;
}

static arg_desc main_args[] = {
	{ "benchmarks", arg_magic, benchflag },
	{ "compression", arg_onoff, &FLAGS_compression },
	{ "compression_ratio", arg_float, &FLAGS_compression_ratio },
	{ "histogram", arg_onoff, &FLAGS_histogram },
	{ "use_existing_db", arg_onoff, &FLAGS_use_existing_db },
	{ "num", arg_long, &FLAGS_num },
	{ "batch", arg_int, &FLAGS_batch },
	{ "reads", arg_long, &FLAGS_reads },
	{ "threads", arg_int, &FLAGS_threads },
	{ "max_threads", arg_int, &FLAGS_max_threads },
	{ "duration", arg_int, &FLAGS_duration },
	{ "stats_period", arg_int, &FLAGS_stats_period },
	{ "writes_per_second", arg_int, &FLAGS_writes_per_second },
	{ "arrival_rate", arg_long, &FLAGS_arrival_rate },
	{ "arrival_rates", arg_string, &FLAGS_arrival_rates },
	{ "warmup_sec", arg_int, &FLAGS_warmup_sec },
	{ "generator_cpu", arg_int, &FLAGS_generator_cpu },
	{ "generator_rt_prio", arg_int, &FLAGS_generator_rt_prio },
	{ "value_size", arg_int, &FLAGS_value_size },
	{ "key_size", arg_int, &FLAGS_key_size },
	{ "db", arg_string, &FLAGS_db },
	{ NULL }
};

static char dirbuf[1024];

int main2(int argc, char *argv[]) {
	int i, aret;
	arg_setup(main_args, dbb_backend->db_args);

    /*
    int ioctl_fd = 0;
    int ioctl_ret = 0;
    char ioctl_file_name[256];
    int hugepages_flag_value = 0x40000000;
    int hint_numa_node_flag = 0x40000000;
	int cpu_start, cpu_end, cpu_idx;
	cpu_set_t cpuset;
	pthread_t thread;
    int s;

	thread = pthread_self();

    sprintf(ioctl_file_name, "/mnt/pmem0/ioctl_file_%d", getpid());

    ioctl_fd = open(ioctl_file_name, O_RDWR | O_CREAT, 0666);
    if (ioctl_fd < 0) {
        printf("%s: file open failed. Error = %s\n", __func__, strerror(errno));
        exit(-1);
    }

    ioctl_ret = ioctl(ioctl_fd, FS_IOC_SETFLAGS, &hugepages_flag_value);
    if (ioctl_ret != 0) {
        printf("%s: ioctl failed. Error = %s\n", __func__, strerror(errno));
    } else {
        printf("%s: ioctl passed. Will get huge pages for this application\n", __func__);
    }

	ioctl_ret = ioctl(ioctl_fd, _IOWR('f', 19, unsigned long), &hint_numa_node_flag);
	if (ioctl_ret < 0) {
		printf("%s: ioctl failed. Err = %s\n", __func__, strerror(errno));
	} else {
		printf("%s: ioctl passed. Will use NUMA node %d for this application\n", __func__, ioctl_ret);
	}
	close(ioctl_fd);

	if (ioctl_ret >= 0) {
		CPU_ZERO(&cpuset);
		if (ioctl_ret == 0) {
			cpu_start = 1;
			cpu_end = 24;
		} else if (ioctl_ret == 1) {
			cpu_start = 25;
			cpu_end = 48;
		}

		for (cpu_idx = cpu_start; cpu_idx < cpu_end; cpu_idx++) {
			CPU_SET(cpu_idx, &cpuset);
		}

		s = pthread_setaffinity_np(thread, sizeof(cpu_set_t), &cpuset);
		if (s != 0)
			handle_error_en(s, "pthread_setaffinity_np");

		s = pthread_getaffinity_np(thread, sizeof(cpu_set_t), &cpuset);
		if (s != 0)
			handle_error_en(s, "pthread_getaffinity_np");

		printf("Set returned by pthread_getaffinity_np() contained:\n");
		for (cpu_idx = cpu_start; cpu_idx < CPU_SETSIZE; cpu_idx++)
			if (CPU_ISSET(cpu_idx, &cpuset))
				printf("    CPU %d\n", cpu_idx);
	}


    close(ioctl_fd);
    */

	while ((aret = arg_process(argc, argv)) >= 0) {

	/* Choose a location for the test database if none given with --db=<path> */
	if (FLAGS_db == NULL) {
		char *dir = getenv("TEST_TMPDIR");
		if (!dir) {
			dir = dirbuf;
			sprintf(dirbuf, "/tmp/dbbench-%d", geteuid());
		}
		mkdir(dir, 0775);
		strcat(dirbuf, "/");
		strcat(dirbuf, dbb_backend->db_name);
		FLAGS_db = dir;
	}

	{
		struct stat st;
		int rc;
		rc = stat(FLAGS_db, &st);
		if (rc == 0 && (S_ISBLK(st.st_mode) || S_ISCHR(st.st_mode)))
			FLAGS_rawdev = 1;
	}

	if (!FLAGS_max_threads)
		FLAGS_max_threads = FLAGS_threads;

	if (!seeds)
		/* Set up an extra randctx */
		seeds = calloc(FLAGS_max_threads+1, sizeof(rndctx *));
	for (i=0; i<FLAGS_max_threads+1; i++)
		if (!seeds[i]) seeds[i] = DBB_randctx();
	DBB_srandom(seeds[0], 0);
	for (i=1; i<FLAGS_threads+1; i++)
		DBB_randjump(seeds[i-1], seeds[i]);

	if (!hists)
		hists = calloc(FLAGS_max_threads+1, sizeof(Hstctx *));
	for (i=0; i<FLAGS_max_threads+1; i++)
		if (!hists[i]) hists[i] = DBB_hstctx();
	for (i=0; i<FLAGS_threads+1; i++)
		DBB_hstinit(hists[i]);

	Benchmark();
    break;
	}
	if (db_open)
		dbb_backend->db_close();
	return 0;
}

int main() __attribute__((weak, alias ("main2")));
