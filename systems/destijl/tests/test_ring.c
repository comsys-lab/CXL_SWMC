/*
 * ds_ring.h test: 7 producers x 1 consumer over one MPSC ring.
 * Checks: no loss, no duplication, per-producer FIFO, payload integrity,
 * blocking while full (deterministic), timeout return, ds_ring_count.
 * Usage: test_ring [total_messages (default 10^7)] [nslots (default 256)]
 */
#include "test_common.h"
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

#define NPROD 7

static struct ds_ring *g_ring;
static unsigned long long g_per_prod;
static atomic_ullong g_full_seen;

static void fill_msg(struct ds_msg *m, unsigned int src, unsigned long long seq)
{
	unsigned int i;

	memset(m, 0, sizeof(*m));
	m->type = DS_MSG_FETCH + (seq % 3);
	m->src = (ds_u8)src;
	m->flags = (ds_u8)(seq & 1);
	m->page_index = seq;
	m->ts = seq * 2654435761ull + src;
	for (i = 0; i < sizeof(m->body); i++)
		m->body[i] = (ds_u8)(seq + i + src);
}

static void check_msg(const struct ds_msg *m)
{
	struct ds_msg ref;

	fill_msg(&ref, m->src, m->page_index);
	CHECK(memcmp(&ref, m, sizeof(ref)) == 0, "payload mismatch src %u seq %llu",
	      m->src, (unsigned long long)m->page_index);
}

static void *producer(void *arg)
{
	unsigned int id = (unsigned int)(unsigned long)arg;
	unsigned long long i;
	struct ds_msg m;

	for (i = 0; i < g_per_prod; i++) {
		fill_msg(&m, id, i);
		CHECK(ds_ring_produce(g_ring, &m, DS_SPIN_FOREVER) == 0, "produce");
	}
	return NULL;
}

struct blk_arg {
	struct ds_ring *r;
	atomic_int done;
};

static void *blocked_producer(void *arg)
{
	struct blk_arg *a = arg;
	struct ds_msg m;

	fill_msg(&m, 1, 1000);
	CHECK(ds_ring_produce(a->r, &m, DS_SPIN_FOREVER) == 0, "blocked produce");
	atomic_store(&a->done, 1);
	return NULL;
}

static void test_deterministic(void)
{
	const unsigned int n = 8;
	struct ds_ring *r = ds_ring_init(xalloc64(ds_ring_bytes(n)), n);
	struct blk_arg a = { .r = r };
	struct ds_msg m;
	pthread_t th;
	unsigned int i;

	CHECK(r != NULL, "init");
	CHECK(ds_ring_init(r, 6) == NULL, "non power of two accepted");
	CHECK(ds_ring_init((char *)r + 8, 8) == NULL, "misaligned accepted");
	CHECK(ds_ring_consume(r, &m) == 0, "empty ring returned a message");
	CHECK(ds_ring_count(r) == 0, "count empty");
	for (i = 0; i < n; i++) {
		fill_msg(&m, 1, i);
		CHECK(ds_ring_produce(r, &m, 0) == 0, "produce into free slot %u", i);
	}
	CHECK(ds_ring_count(r) == n, "count full %llu", (unsigned long long)ds_ring_count(r));

	/* Blocking when full: the 9th producer must wait for a consume. */
	atomic_init(&a.done, 0);
	CHECK(pthread_create(&th, NULL, blocked_producer, &a) == 0, "pthread_create");
	usleep(100000);
	CHECK(atomic_load(&a.done) == 0, "producer did not block on a full ring");
	CHECK(ds_ring_consume(r, &m) == 1, "consume");
	CHECK(m.page_index == 0, "FIFO");
	check_msg(&m);
	pthread_join(th, NULL);
	CHECK(atomic_load(&a.done) == 1, "producer not released");
	for (i = 1; i < n; i++) {
		CHECK(ds_ring_consume(r, &m) == 1, "consume %u", i);
		CHECK(m.page_index == i, "FIFO %u", i);
		check_msg(&m);
	}
	CHECK(ds_ring_consume(r, &m) == 1 && m.page_index == 1000, "blocked msg");
	CHECK(ds_ring_consume(r, &m) == 0, "ring not empty");
	free(r);

	/* Timeout on a full ring returns -ETIMEDOUT (ring is then poisoned). */
	r = ds_ring_init(xalloc64(ds_ring_bytes(2)), 2);
	fill_msg(&m, 2, 0);
	CHECK(ds_ring_produce(r, &m, 0) == 0 && ds_ring_produce(r, &m, 0) == 0, "fill 2");
	CHECK(ds_ring_produce(r, &m, 1000) == -DS_ETIMEDOUT, "timeout expected");
	free(r);
	printf("ring deterministic: init checks, FIFO, blocking when full, timeout: OK\n");
}

int main(int argc, char **argv)
{
	unsigned long long total = argc > 1 ? strtoull(argv[1], NULL, 0) : 10000000ull;
	unsigned long long nslots = argc > 2 ? strtoull(argv[2], NULL, 0) : 256;
	unsigned long long next[NPROD] = { 0 }, got = 0, empty = 0;
	pthread_t th[NPROD];
	struct ds_msg m;
	double t0, t1;
	unsigned int i;

	test_deterministic();

	g_per_prod = (total + NPROD - 1) / NPROD;
	total = g_per_prod * NPROD;
	g_ring = ds_ring_init(xalloc64(ds_ring_bytes(nslots)), nslots);
	CHECK(g_ring != NULL, "init nslots %llu", nslots);
	atomic_init(&g_full_seen, 0);

	t0 = now_s();
	for (i = 0; i < NPROD; i++)
		CHECK(pthread_create(&th[i], NULL, producer, (void *)(unsigned long)i) == 0,
		      "pthread_create");
	while (got < total) {
		if (!ds_ring_consume(g_ring, &m)) {
			empty++;
			if ((empty & 63) == 0)
				sched_yield();
			continue;
		}
		CHECK(m.src < NPROD, "bad src %u", m.src);
		CHECK(m.page_index == next[m.src],
		      "producer %u: got seq %llu expected %llu (loss, dup or reorder)",
		      m.src, (unsigned long long)m.page_index, next[m.src]);
		check_msg(&m);
		next[m.src]++;
		got++;
		if ((got & 1023) == 0 && ds_ring_count(g_ring) == nslots)
			atomic_fetch_add(&g_full_seen, 1);
	}
	for (i = 0; i < NPROD; i++)
		pthread_join(th[i], NULL);
	t1 = now_s();
	CHECK(ds_ring_consume(g_ring, &m) == 0, "extra message after all consumed");
	CHECK(ds_ring_count(g_ring) == 0, "count after drain");
	for (i = 0; i < NPROD; i++)
		CHECK(next[i] == g_per_prod, "producer %u delivered %llu of %llu", i, next[i],
		      g_per_prod);
	printf("ring stress: %u producers x 1 consumer, %llu messages, nslots %llu, "
	       "%.2f s (%.1f M msg/s), full-ring samples %llu, empty polls %llu: OK\n",
	       NPROD, total, nslots, t1 - t0, total / (t1 - t0) / 1e6,
	       (unsigned long long)atomic_load(&g_full_seen), empty);
	free(g_ring);
	return 0;
}
