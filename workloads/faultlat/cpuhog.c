// cpuhog: user-space CPU hogs that report the CPU they got (iterations/s).
//
// One thread per CPU 0..T-1 (pinned), each spinning on a counter, until
// SIGTERM/SIGINT or --seconds expire.  The iteration rate is the CPU left to a
// workload on that node: with one hog per vCPU, anything else that runs
// (coherence receive thread, consumer kworkers, timer interrupts) takes CPU
// time from the hogs.  Used by the P-popcorn recv13 comparison (scenario S2,
// "answering node saturated").  No shared memory, no root.
//
//   cpuhog --threads T [--seconds S] [--cpu-base B] --out F.json   (threads on CPUs B..B+T-1, B default 0)
//
// Output JSON: threads, elapsed_s, per-thread iterations, total and mean
// iterations per second.  Build: cc -O2 -pthread -o cpuhog cpuhog.c
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_THREADS 1024

static volatile sig_atomic_t stop_flag;
static long cpu_base;
static uint64_t iters[MAX_THREADS];

static void on_signal(int sig) { (void)sig; stop_flag = 1; }

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void *hog(void *arg)
{
	long id = (long)arg;
	cpu_set_t set;
	volatile uint64_t n = 0;

	CPU_ZERO(&set);
	CPU_SET((int)(cpu_base + id), &set);
	if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set)) {
		fprintf(stderr, "cpuhog: cannot pin thread %ld\n", id);
		exit(1);
	}
	while (!stop_flag) {
		for (int i = 0; i < 4096; i++)
			n++;
	}
	__atomic_store_n(&iters[id], n, __ATOMIC_RELAXED);
	return NULL;
}

int main(int argc, char **argv)
{
	long threads = 0;
	double seconds = 0, t0, t1;
	const char *out = NULL;
	pthread_t th[MAX_THREADS];
	struct sigaction sa;
	uint64_t total = 0;
	FILE *f;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--threads") && i + 1 < argc)
			threads = strtol(argv[++i], NULL, 10);
		else if (!strcmp(argv[i], "--seconds") && i + 1 < argc)
			seconds = strtod(argv[++i], NULL);
		else if (!strcmp(argv[i], "--cpu-base") && i + 1 < argc)
			cpu_base = strtol(argv[++i], NULL, 10);
		else if (!strcmp(argv[i], "--out") && i + 1 < argc)
			out = argv[++i];
		else {
			fprintf(stderr, "usage: cpuhog --threads T [--seconds S] [--cpu-base B] --out F.json\n");
			return 2;
		}
	}
	if (threads < 1 || threads > MAX_THREADS || cpu_base < 0 ||
	    cpu_base + threads > sysconf(_SC_NPROCESSORS_CONF) || !out || seconds < 0) {
		fprintf(stderr, "cpuhog: --threads 1..online CPUs and --out are required\n");
		return 2;
	}
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	t0 = now_s();
	for (long i = 0; i < threads; i++)
		if (pthread_create(&th[i], NULL, hog, (void *)i)) {
			fprintf(stderr, "cpuhog: pthread_create failed\n");
			return 1;
		}
	while (!stop_flag && (seconds == 0 || now_s() - t0 < seconds))
		usleep(10000);
	stop_flag = 1;
	for (long i = 0; i < threads; i++)
		pthread_join(th[i], NULL);
	t1 = now_s();
	f = fopen(out, "w");
	if (!f) {
		fprintf(stderr, "cpuhog: cannot write %s: %s\n", out, strerror(errno));
		return 1;
	}
	fprintf(f, "{\"tool\": \"cpuhog-1\", \"threads\": %ld, \"cpu_base\": %ld, \"elapsed_s\": %.6f, \"iterations\": [",
		threads, cpu_base, t1 - t0);
	for (long i = 0; i < threads; i++) {
		fprintf(f, "%s%llu", i ? ", " : "", (unsigned long long)iters[i]);
		total += iters[i];
	}
	fprintf(f, "], \"total_iterations\": %llu, \"iter_per_s\": %.1f, \"iter_per_s_per_thread\": %.1f}\n",
		(unsigned long long)total, total / (t1 - t0), total / (t1 - t0) / threads);
	fclose(f);
	return 0;
}
