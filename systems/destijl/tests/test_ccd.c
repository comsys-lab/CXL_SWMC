/*
 * ds_ccd.h + ds_ring.h protocol test: N = 8 simulated nodes over one shared
 * buffer (HPD, BPD, per-node FETCH/INV/ACK rings). Each node has a fault
 * thread (random read/write faults, spec section 4, synchronous T = 0) and a
 * remote handler thread (section 7) consuming its rings: one pass = drain INV,
 * up to 64 FETCH, drain ACK. Local state (LCM I/S/M) per node per page; the
 * per-node per-page fh is a spinlock held only around decisions and commits
 * (see the locking contract in ds_ccd.h).
 *
 * Checked continuously: at most one node in M per page and no node in S
 * while another is M (checked at every LCM transition), no transaction or
 * ring produce times out, no INV without a BPD entry, every eviction victim
 * is S (M victims downgraded first: structural + LCM check at quiescence).
 * Checked after quiescence: every directory entry idle; local S/M nodes are
 * within BPD holders (or HPD sharers for pages without a BPD entry); an M
 * entry's holder is the only non-I node; unique tags per set.
 *
 * Usage: test_ccd [faults_per_node (default 10^6)] [seed]
 */
#include "test_common.h"
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

#define NNODES		8
#define NHUGE		64
#define MANAGED_PAGES	(NHUGE * 512)
#define WS_PAGES	4096	/* working set: every 8th page, 64 per huge page */
#define HOT_PAGES	16	/* contended subset (merges, ping-pong) */
#define BPD_SETS	16	/* 256 ways for 4096 pages: eviction-heavy */
#define RING_SLOTS	16
#define WRITE_PCT	25
#define HOT_PCT		10
#define BUDGET		200000000ull

enum { LCM_I = 0, LCM_S = 1, LCM_M = 2 };
enum { R_FETCH = 0, R_INV = 1, R_ACK = 2, NRINGS = 3 };

struct node_stats {
	unsigned long long rd_faults, wr_faults, hits, filtered, merged, fetches;
	unsigned long long invs_sent, created, evict, evict_m, evict_fetch;
	unsigned long long wait_write, inv_handled, fetch_handled, downgrades;
	unsigned long long completions;
};

struct node {
	unsigned int id;
	_Atomic unsigned char lcm[MANAGED_PAGES];
	_Atomic unsigned char fh[MANAGED_PAGES];
	struct ds_ring *ring[NRINGS];
	struct node_stats st;
	unsigned long long seed;
};

static struct ds_ccd g_ccd;
static struct node *g_nodes[NNODES];
static unsigned long long g_faults_per_node = 1000000ull;
static atomic_int g_faulters_running;
static atomic_ullong g_progress;
static atomic_int g_stop;

static void fail_exit(const char *what, unsigned int node, unsigned long long p)
{
	fprintf(stderr, "FAIL: %s (node %u page %llu)\n", what, node, p);
	exit(1);
}

static void fh_lock(struct node *n, ds_u64 p)
{
	unsigned int spins = 0;

	for (;;) {
		unsigned char z = 0;

		if (atomic_compare_exchange_weak(&n->fh[p], &z, 1))
			return;
		spins++;
		DS_SPIN_RELAX(spins);
	}
}

static void fh_unlock(struct node *n, ds_u64 p)
{
	atomic_store_explicit(&n->fh[p], 0, memory_order_release);
}

/* LCM transitions with the single-writer / no-S-while-M check. */
static void set_lcm(struct node *n, ds_u64 p, unsigned char s)
{
	unsigned int o;

	atomic_store(&n->lcm[p], s);
	if (s == LCM_I)
		return;
	for (o = 0; o < NNODES; o++) {
		unsigned char x;

		if (o == n->id)
			continue;
		x = atomic_load(&g_nodes[o]->lcm[p]);
		if (s == LCM_M && x != LCM_I)
			fail_exit("node entered M while another node is S or M", n->id, p);
		if (s == LCM_S && x == LCM_M)
			fail_exit("node entered S while another node is M", n->id, p);
	}
}

static void send(unsigned int dst, unsigned int ring, unsigned int type, unsigned int src,
		 ds_u64 p)
{
	struct ds_msg m;

	memset(&m, 0, sizeof(m));
	m.type = (ds_u8)type;
	m.src = (ds_u8)src;
	m.page_index = p;
	if (ds_ring_produce(g_nodes[dst]->ring[ring], &m, BUDGET))
		fail_exit("ring produce timed out", src, p);
}

/* Eviction callback: FETCH the owner of an M victim. */
static int evict_fetch_cb(void *arg, ds_u64 victim, unsigned int owner)
{
	struct node *n = arg;

	n->st.evict_fetch++;
	send(owner, R_FETCH, DS_MSG_FETCH, n->id, victim);
	return 0;
}

static void read_fault(struct node *n, ds_u64 p)
{
	struct ds_ccd_txn t;
	int first = 1, rc;

	memset(&t, 0, sizeof(t));
	for (;;) {
		fh_lock(n, p);
		if (atomic_load(&n->lcm[p]) != LCM_I) {
			fh_unlock(n, p);
			if (first)
				n->st.hits++;
			return;
		}
		if (first)
			n->st.rd_faults++;
		rc = ds_ccd_read_fault(&g_ccd, p, n->id, &t);
		if (rc < 0)
			fail_exit("read fault: CCD names me M owner", n->id, p);
		if (rc == DS_RD_MAP_FILTERED) {
			set_lcm(n, p, LCM_S);
			fh_unlock(n, p);
			if (first)
				n->st.filtered++;
			else
				n->st.completions++;
			return;
		}
		fh_unlock(n, p);
		switch (rc) {
		case DS_RD_SEND_FETCH:
			n->st.fetches++;
			send(t.owner, R_FETCH, DS_MSG_FETCH, n->id, p);
			break;
		case DS_RD_MAP_MERGED_WAIT:
			n->st.merged++;
			break;
		case DS_RD_WAIT_WRITE:
			n->st.wait_write++;
			break;
		default:
			fail_exit("unknown read action", n->id, p);
		}
		if (ds_ccd_wait(&g_ccd, &t, n->id, BUDGET))
			fail_exit("read transaction timed out", n->id, p);
		first = 0;
	}
}

static void write_fault(struct node *n, ds_u64 p)
{
	static __thread struct ds_ccd_txn t;	/* carries eviction counters */
	unsigned int d;
	ds_u64 c0, e0, m0;

	if (atomic_load(&n->lcm[p]) == LCM_M) {
		n->st.hits++;
		return;
	}
	n->st.wr_faults++;
	c0 = t.created;
	e0 = t.evicted;
	m0 = t.evicted_m;
	if (ds_ccd_write_acquire(&g_ccd, p, n->id, &t, evict_fetch_cb, n, BUDGET))
		fail_exit("write acquire timed out", n->id, p);
	n->st.created += t.created - c0;
	n->st.evict += t.evicted - e0;
	n->st.evict_m += t.evicted_m - m0;
	for (d = 0; d < NNODES; d++) {
		if (t.inv_mask & (1u << d)) {
			n->st.invs_sent++;
			send(d, R_INV, DS_MSG_INV, n->id, p);
		}
	}
	if (ds_ccd_wait_inv(&g_ccd, &t, n->id, BUDGET))
		fail_exit("INV wait timed out", n->id, p);
	fh_lock(n, p);
	if (ds_ccd_write_complete(&g_ccd, &t, n->id))
		fail_exit("write complete: entry not locked by me", n->id, p);
	set_lcm(n, p, LCM_M);
	fh_unlock(n, p);
}

static ds_u64 pick_page(struct node *n)
{
	unsigned long long r = xorshift64(&n->seed);
	unsigned int k;

	if ((r % 100) < HOT_PCT)
		k = (unsigned int)((r >> 8) % HOT_PAGES) * (WS_PAGES / HOT_PAGES);
	else
		k = (unsigned int)((r >> 8) % WS_PAGES);
	return (ds_u64)k * (MANAGED_PAGES / WS_PAGES);
}

static void *fault_thread(void *arg)
{
	struct node *n = arg;

	while (n->st.rd_faults + n->st.wr_faults < g_faults_per_node) {
		ds_u64 p = pick_page(n);
		unsigned long long r = xorshift64(&n->seed);

		if ((r % 100) < WRITE_PCT)
			write_fault(n, p);
		else
			read_fault(n, p);
		atomic_fetch_add_explicit(&g_progress, 1, memory_order_relaxed);
	}
	atomic_fetch_sub(&g_faulters_running, 1);
	return NULL;
}

static void handle_inv(struct node *n, const struct ds_msg *m)
{
	ds_u64 p = m->page_index;

	fh_lock(n, p);
	/* M: revoke PTEs then flush; S: unmap. Both end in I. */
	set_lcm(n, p, LCM_I);
	if (!ds_ccd_inv_self_remove(&g_ccd, p, n->id))
		fail_exit("INV for a page without a BPD entry", n->id, p);
	fh_unlock(n, p);
	n->st.inv_handled++;
}

static void handle_fetch(struct node *n, const struct ds_msg *m)
{
	ds_u64 p = m->page_index;

	fh_lock(n, p);
	if (atomic_load(&n->lcm[p]) == LCM_M) {
		/* write-protect PTEs, flush, LCM = S */
		set_lcm(n, p, LCM_S);
		n->st.downgrades++;
	}
	ds_ccd_read_complete(&g_ccd, p, n->id);
	fh_unlock(n, p);
	n->st.fetch_handled++;
}

static void *handler_thread(void *arg)
{
	struct node *n = arg;
	struct ds_msg m;
	unsigned int idle = 0, k;
	int work;

	for (;;) {
		work = 0;
		while (ds_ring_consume(n->ring[R_INV], &m)) {
			handle_inv(n, &m);
			work = 1;
		}
		for (k = 0; k < 64 && ds_ring_consume(n->ring[R_FETCH], &m); k++) {
			handle_fetch(n, &m);
			work = 1;
		}
		while (ds_ring_consume(n->ring[R_ACK], &m))
			work = 1;	/* async only (phase 3); none in this test */
		if (work) {
			idle = 0;
			continue;
		}
		if (atomic_load(&g_stop))
			return NULL;
		if (++idle > 16)
			sched_yield();
	}
}

static void *watchdog(void *arg)
{
	unsigned long long last = 0, cur;
	int stalled = 0;

	(void)arg;
	while (atomic_load(&g_faulters_running) > 0) {
		sleep(1);
		cur = atomic_load(&g_progress);
		stalled = (cur == last) ? stalled + 1 : 0;
		last = cur;
		if (stalled >= 30) {
			fprintf(stderr, "FAIL: no fault completed for 30 s (deadlock)\n");
			exit(1);
		}
	}
	return NULL;
}

static void check_quiescent(void)
{
	unsigned long long bpd_pages = 0, m_pages = 0, s_pages = 0;
	ds_u32 idx, tags[DS_CCD_WAYS];
	ds_u64 p;
	int w, x;

	for (idx = 0; idx < g_ccd.bpd_sets; idx++) {
		ds_u32 *set = ds_ccd_set(&g_ccd, idx);

		for (w = 0; w < DS_CCD_WAYS; w++) {
			ds_u32 v = set[w];

			tags[w] = ds_bpd_tag(v);
			if (!tags[w])
				continue;
			CHECK(!(v & (DS_BPD_BUSY | DS_BPD_PEND_W)) && !ds_bpd_waiters(v),
			      "set %u way %d not idle: %#x", idx, w, v);
			p = ds_ccd_way_page(&g_ccd, idx, tags[w]);
			CHECK(ds_ccd_set_index(&g_ccd, p) == idx && ds_ccd_tag(&g_ccd, p) == tags[w],
			      "way page inverse");
			CHECK(ds_hpd_exc(*ds_ccd_hpd_ptr(&g_ccd, p)), "BPD entry without HPD exc");
			if (ds_bpd_is_m(v))
				CHECK(__builtin_popcount(ds_bpd_holders(v)) == 1, "M entry holders %#x",
				      ds_bpd_holders(v));
			for (x = 0; x < w; x++)
				CHECK(tags[x] != tags[w], "duplicate tag in set %u", idx);
		}
	}
	for (p = 0; p < MANAGED_PAGES; p++) {
		struct ds_ccd_ref r;
		ds_u32 allowed, nonI = 0, inM = 0;
		unsigned int o;

		CHECK(!ds_hpd_busy(*ds_ccd_hpd_ptr(&g_ccd, p)), "HPD lock left");
		for (o = 0; o < NNODES; o++) {
			unsigned char s = atomic_load(&g_nodes[o]->lcm[p]);

			CHECK(atomic_load(&g_nodes[o]->fh[p]) == 0, "fh left locked");
			if (s != LCM_I)
				nonI |= 1u << o;
			if (s == LCM_M)
				inM |= 1u << o;
		}
		ds_ccd_lookup(&g_ccd, p, &r);
		if (r.kind == DS_CCD_BPD) {
			bpd_pages++;
			allowed = ds_bpd_holders(r.snap);
			if (ds_bpd_is_m(r.snap)) {
				CHECK(inM == allowed && nonI == allowed,
				      "page %llu: M entry holder %#x but LCM M %#x non-I %#x",
				      (unsigned long long)p, allowed, inM, nonI);
				m_pages++;
			} else {
				CHECK(!inM, "page %llu: S entry but a node is M (%#x)",
				      (unsigned long long)p, inM);
			}
		} else {
			allowed = ds_hpd_sharers(r.snap);
			CHECK(!inM, "page %llu: M without BPD entry (evicted without downgrade?)",
			      (unsigned long long)p);
		}
		CHECK((nonI & ~allowed) == 0,
		      "page %llu: holders/sharers %#x do not cover non-I nodes %#x",
		      (unsigned long long)p, allowed, nonI);
		if (nonI && !inM)
			s_pages++;
	}
	printf("quiescence: %llu BPD entries (%llu M), %llu pages S somewhere: OK\n", bpd_pages,
	       m_pages, s_pages);
}

static void unit_checks(void)
{
	ds_u32 e;
	ds_u64 p;

	e = ds_bpd_pack(0x1abc, 1, 0x81, 0x42, 1, 1);
	CHECK(ds_bpd_tag(e) == 0x1abc && ds_bpd_is_m(e) && ds_bpd_holders(e) == 0x81 &&
	      ds_bpd_waiters(e) == 0x42 && ds_bpd_busy(e) && ds_bpd_pend_w(e), "bpd pack");
	CHECK(e == (0x1abcu | 1u << 13 | 0x81u << 14 | 0x42u << 22 | 1u << 30 | 1u << 31),
	      "bpd bit positions %#x", e);
	e = ds_hpd_pack(0xa5, 0x3c, 0x9, 1, 1, 1, 0xfe);
	CHECK(e == (0xa5u | 0x3cu << 8 | 0x9u << 16 | 1u << 20 | 1u << 21 | 1u << 22 | 0xfeu << 24),
	      "hpd bit positions %#x", e);
	CHECK(ds_hpd_sharers(e) == 0xa5 && ds_hpd_waiters(e) == 0x3c && ds_hpd_owner(e) == 9 &&
	      ds_hpd_busy(e) && ds_hpd_pend_w(e) && ds_hpd_exc(e) && ds_hpd_cnt(e) == 0xfe,
	      "hpd unpack");
	e = ds_hpd_unlock_created(ds_hpd_unlock_created(e | DS_HPD_BUSY));
	CHECK(ds_hpd_cnt(e) == 0xff && !ds_hpd_busy(e) && ds_hpd_exc(e), "cnt saturates");
	for (p = 0; p < MANAGED_PAGES; p++)
		CHECK(ds_ccd_way_page(&g_ccd, ds_ccd_set_index(&g_ccd, p), ds_ccd_tag(&g_ccd, p)) == p,
		      "index/tag inverse at %llu", (unsigned long long)p);
	{
		struct ds_ccd c2;
		static ds_u32 h[8], b[16 * 16] __attribute__((aligned(64)));

		CHECK(ds_ccd_init(&c2, h, b, 16, 0x1fffull * 16) == 0, "tag limit ok");
		CHECK(ds_ccd_init(&c2, h, b, 16, 0x1fffull * 16 + 1) == -DS_EINVAL, "tag limit");
		CHECK(ds_ccd_init(&c2, h, b, 12, 1024) == -DS_EINVAL, "pow2 sets");
	}
	printf("ccd unit: entry packing, index/tag inverse, init limits: OK\n");
}

int main(int argc, char **argv)
{
	unsigned long long seed = argc > 2 ? strtoull(argv[2], NULL, 0) : 0x5eed1234ull;
	pthread_t ft[NNODES], ht[NNODES], wd;
	struct node_stats tot;
	ds_u32 *hpd, *bpd;
	unsigned int i, r;
	double t0, t1;

	if (argc > 1)
		g_faults_per_node = strtoull(argv[1], NULL, 0);
	hpd = xalloc64(ds_ccd_hpd_bytes(MANAGED_PAGES));
	bpd = xalloc64(ds_ccd_bpd_bytes(BPD_SETS));
	CHECK(ds_ccd_init(&g_ccd, hpd, bpd, BPD_SETS, MANAGED_PAGES) == 0, "ccd init");
	ds_ccd_format(&g_ccd);
	unit_checks();

	for (i = 0; i < NNODES; i++) {
		struct node *n = calloc(1, sizeof(*n));

		CHECK(n != NULL, "calloc node");
		n->id = i;
		n->seed = seed ^ (0x9e3779b97f4a7c15ull * (i + 1));
		for (r = 0; r < NRINGS; r++) {
			n->ring[r] = ds_ring_init(xalloc64(ds_ring_bytes(RING_SLOTS)), RING_SLOTS);
			CHECK(n->ring[r] != NULL, "ring init");
		}
		g_nodes[i] = n;
	}
	atomic_init(&g_faulters_running, NNODES);
	atomic_init(&g_progress, 0);
	atomic_init(&g_stop, 0);

	t0 = now_s();
	for (i = 0; i < NNODES; i++)
		CHECK(pthread_create(&ht[i], NULL, handler_thread, g_nodes[i]) == 0, "handler");
	for (i = 0; i < NNODES; i++)
		CHECK(pthread_create(&ft[i], NULL, fault_thread, g_nodes[i]) == 0, "faulter");
	CHECK(pthread_create(&wd, NULL, watchdog, NULL) == 0, "watchdog");
	for (i = 0; i < NNODES; i++)
		pthread_join(ft[i], NULL);
	pthread_join(wd, NULL);
	/* All transactions completed, so no message is in flight; stop handlers. */
	atomic_store(&g_stop, 1);
	for (i = 0; i < NNODES; i++)
		pthread_join(ht[i], NULL);
	t1 = now_s();
	for (i = 0; i < NNODES; i++)
		for (r = 0; r < NRINGS; r++)
			CHECK(ds_ring_count(g_nodes[i]->ring[r]) == 0, "ring %u of node %u not empty",
			      r, i);

	memset(&tot, 0, sizeof(tot));
	for (i = 0; i < NNODES; i++) {
		unsigned long long *a = (unsigned long long *)&tot;
		unsigned long long *b = (unsigned long long *)&g_nodes[i]->st;

		for (r = 0; r < sizeof(tot) / sizeof(*a); r++)
			a[r] += b[r];
	}
	CHECK(tot.invs_sent == tot.inv_handled, "INV sent %llu handled %llu", tot.invs_sent,
	      tot.inv_handled);
	CHECK(tot.fetches + tot.evict_fetch == tot.fetch_handled, "FETCH sent %llu handled %llu",
	      tot.fetches + tot.evict_fetch, tot.fetch_handled);
	check_quiescent();
	printf("ccd protocol: %d nodes, %llu faults/node, %.2f s\n", NNODES, g_faults_per_node,
	       t1 - t0);
	printf("  read faults %llu, write faults %llu, hits %llu\n", tot.rd_faults, tot.wr_faults,
	       tot.hits);
	printf("  filtered %llu, merged %llu, fetches %llu, completions-after-wait %llu, "
	       "wait-write %llu\n", tot.filtered, tot.merged, tot.fetches, tot.completions,
	       tot.wait_write);
	printf("  invs %llu, bpd created %llu, evictions %llu, evictions of M (downgraded) %llu, "
	       "downgrades %llu\n", tot.invs_sent, tot.created, tot.evict, tot.evict_m,
	       tot.downgrades);
	CHECK(tot.evict > 0 && tot.evict_m > 0 && tot.merged > 0 && tot.fetches > 0,
	      "coverage: evictions, M evictions, merges and fetches must all occur");
	printf("ccd protocol: OK\n");
	return 0;
}
