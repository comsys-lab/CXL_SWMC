// umwait_ping: does a store from one node wake UMONITOR/UMWAIT on a shared cache line in another node?
// Experiment: reports/experiments/umwait-remote-wake.md. See README.md in this directory.
//
// Two 64 B lines in the HW-coherent app area of the shared device: line X (offset) carries the sequence number
// written by the initiator, line Y (offset + 4096, another page so the adjacent-line prefetcher does not pair
// them) carries the responder's echo. The responder waits for X to change (spin or UMONITOR/UMWAIT), then
// stores the same value to Y; the initiator spins on Y and measures the round trip on its own TSC.
// Plain write-back loads/stores only (no non-temporal stores, no flushes).
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <sched.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <cpuid.h>
#include <immintrin.h>
#include <x86intrin.h>

#define LINE_Y_DELTA 4096u
#define WIN (2u << 20)  // mapping window: 2 MiB, aligned (device-dax alignment is 4 KiB or 2 MiB)

// Control values in X / Y. Sequence numbers are 1..2^32-1; control values carry a tag in bits 56..63 and the
// run nonce in bits 0..31, so values from an earlier run with another nonce are never taken for this run's.
#define TAG_HELLO_R 0xA1ull
#define TAG_HELLO_I 0xA2ull
#define TAG_ACK 0xA3ull
#define TAG_STOP 0xA4ull  // sentinel: initiator is done
#define TAG_BYE 0xA5ull   // responder acknowledges the sentinel
#define TAG_ABORT 0xAEull // either side gave up
static uint64_t ctl(uint64_t tag, uint64_t nonce) { return (tag << 56) | (nonce & 0xffffffffull); }

struct args {
  const char *role, *mode, *dev, *region, *csv;
  int cpu, cpu2, c02, selftest;
  uint64_t offset, n, nonce, seed, deadline_cycles, tsc_khz;
  int have_offset;
  unsigned gap_min_us, gap_max_us;
  double start_timeout_s, ping_timeout_ms, idle_timeout_s;
};

static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "umwait_ping: ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
  exit(2);
}

static void usage(void) {
  fprintf(stderr,
          "usage: umwait_ping --role init|resp --mode spin|umwait [options]\n"
          "  --dev PATH            device or file to map (default /dev/dax0.0)\n"
          "  --region YAML         region config; default offset = msg_ring offset - 2 MiB, offset checked to lie\n"
          "                        in [hwcc_offset, msg_ring offset)\n"
          "  --offset BYTES        device offset of line X (64 B aligned); line Y = X + 4096\n"
          "  --cpu N               pin this process to CPU N (default: no pinning)\n"
          "  --n N                 pings (default 50000)\n"
          "  --gap-us-min/--gap-us-max  uniform random gap between pings on the initiator (default 1..200)\n"
          "  --deadline-cycles C   UMWAIT TSC deadline delta (default 10 x umwait_control/max_time)\n"
          "  --c02 0|1             UMWAIT state operand: 0 = C0.2, 1 = C0.1 (default 0)\n"
          "  --nonce N             run nonce, identical on both sides (default 1)\n"
          "  --seed N              gap RNG seed (default 1)\n"
          "  --csv PATH|-          per-ping CSV (init: seq,gap_us,rtt_cycles,rtt_ns; resp: per-wait); summary\n"
          "                        goes to stderr when --csv -, else to stdout\n"
          "  --tsc-khz K           TSC frequency (default: calibrated against CLOCK_MONOTONIC_RAW)\n"
          "  --start-timeout-s S   handshake timeout (default 60)\n"
          "  --ping-timeout-ms M   initiator: per-ping echo timeout (default 1000)\n"
          "  --idle-timeout-s S    responder: no change on X for this long -> abort (default 30)\n"
          "  --selftest --cpu A --cpu2 B   fork resp (CPU B) + init (CPU A) on an anonymous shared mapping\n");
  exit(2);
}

static uint64_t parse_u64(const char *s, const char *what) {
  char *e;
  errno = 0;
  unsigned long long v = strtoull(s, &e, 0);
  if (errno || *e || e == s) die("bad %s: %s", what, s);
  return v;
}

static void parse_args(int argc, char **argv, struct args *a) {
  memset(a, 0, sizeof(*a));
  a->dev = "/dev/dax0.0";
  a->cpu = a->cpu2 = -1;
  a->n = 50000;
  a->nonce = 1;
  a->seed = 1;
  a->gap_min_us = 1;
  a->gap_max_us = 200;
  a->start_timeout_s = 60;
  a->ping_timeout_ms = 1000;
  a->idle_timeout_s = 30;
  for (int i = 1; i < argc; i++) {
    const char *k = argv[i];
#define VAL() (i + 1 < argc ? argv[++i] : (die("%s needs a value", k), ""))
    if (!strcmp(k, "--role")) a->role = VAL();
    else if (!strcmp(k, "--mode")) a->mode = VAL();
    else if (!strcmp(k, "--dev")) a->dev = VAL();
    else if (!strcmp(k, "--region")) a->region = VAL();
    else if (!strcmp(k, "--offset")) a->offset = parse_u64(VAL(), k), a->have_offset = 1;
    else if (!strcmp(k, "--cpu")) a->cpu = (int)parse_u64(VAL(), k);
    else if (!strcmp(k, "--cpu2")) a->cpu2 = (int)parse_u64(VAL(), k);
    else if (!strcmp(k, "--n")) a->n = parse_u64(VAL(), k);
    else if (!strcmp(k, "--gap-us-min")) a->gap_min_us = (unsigned)parse_u64(VAL(), k);
    else if (!strcmp(k, "--gap-us-max")) a->gap_max_us = (unsigned)parse_u64(VAL(), k);
    else if (!strcmp(k, "--deadline-cycles")) a->deadline_cycles = parse_u64(VAL(), k);
    else if (!strcmp(k, "--c02")) a->c02 = (int)parse_u64(VAL(), k);
    else if (!strcmp(k, "--nonce")) a->nonce = parse_u64(VAL(), k);
    else if (!strcmp(k, "--seed")) a->seed = parse_u64(VAL(), k);
    else if (!strcmp(k, "--csv")) a->csv = VAL();
    else if (!strcmp(k, "--tsc-khz")) a->tsc_khz = parse_u64(VAL(), k);
    else if (!strcmp(k, "--start-timeout-s")) a->start_timeout_s = atof(VAL());
    else if (!strcmp(k, "--ping-timeout-ms")) a->ping_timeout_ms = atof(VAL());
    else if (!strcmp(k, "--idle-timeout-s")) a->idle_timeout_s = atof(VAL());
    else if (!strcmp(k, "--selftest")) a->selftest = 1;
    else usage();
#undef VAL
  }
  if (!a->mode || (strcmp(a->mode, "spin") && strcmp(a->mode, "umwait"))) usage();
  if (!a->selftest && (!a->role || (strcmp(a->role, "init") && strcmp(a->role, "resp")))) usage();
  if (a->c02 != 0 && a->c02 != 1) die("--c02 must be 0 (C0.2) or 1 (C0.1)");
  if (a->gap_max_us < a->gap_min_us) die("--gap-us-max < --gap-us-min");
  if (a->n == 0 || a->n >= 0xffffffffull) die("--n out of range");
}

// ---- region config (only the keys we need: hwcc_offset, hwcc_size, msg_ring) ----
static void region_default(struct args *a) {
  if (!a->region) {
    if (!a->have_offset && !a->selftest) die("give --offset or --region");
    return;
  }
  FILE *f = fopen(a->region, "r");
  if (!f) die("open %s: %s", a->region, strerror(errno));
  uint64_t hoff = 0, hsize = 0, roff = 0, rsize = 0;
  int got_h = 0, got_hs = 0, got_r = 0;
  char line[1024];
  while (fgets(line, sizeof line, f)) {
    char *c = strchr(line, '#');
    if (c) *c = 0;
    unsigned long long x, y;
    if (sscanf(line, " hwcc_offset: %llu", &x) == 1) hoff = x, got_h = 1;
    else if (sscanf(line, " hwcc_size: %llu", &x) == 1) hsize = x, got_hs = 1;
    else if (sscanf(line, " msg_ring: [ %llu , %llu ]", &x, &y) == 2) roff = x, rsize = y, got_r = 1;
  }
  fclose(f);
  if (!got_h || !got_hs || !got_r) die("%s: need hwcc_offset, hwcc_size, msg_ring", a->region);
  if (roff < hoff + WIN || roff + rsize > hoff + hsize) die("%s: msg_ring not inside hwcc", a->region);
  if (!a->have_offset) a->offset = roff - WIN;
  if (a->offset < hoff || a->offset + LINE_Y_DELTA + 64 > roff)
    die("offset %" PRIu64 " (+%u for line Y) not in HWcc app area [%" PRIu64 ", %" PRIu64 ")", a->offset,
        LINE_Y_DELTA, hoff, roff);
  fprintf(stderr, "region %s: hwcc=[%" PRIu64 ",+%" PRIu64 ") msg_ring=[%" PRIu64 ",+%" PRIu64 ") offset=%" PRIu64 "\n",
          a->region, hoff, hsize, roff, rsize, a->offset);
}

// ---- timing ----
static inline uint64_t tsc(void) {
  _mm_lfence();
  uint64_t t = __rdtsc();
  _mm_lfence();
  return t;
}

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint64_t calibrate_tsc_khz(void) {
  double best = 0;
  for (int r = 0; r < 3; r++) {
    double s0 = now_s();
    uint64_t t0 = tsc();
    while (now_s() - s0 < 0.1) {
    }
    double s1 = now_s();
    uint64_t t1 = tsc();
    double khz = (double)(t1 - t0) / (s1 - s0) / 1000.0;
    if (r == 0 || khz < best) best = khz;  // min: least disturbed by a preemption between the two reads
  }
  return (uint64_t)(best + 0.5);
}

static int have_waitpkg(void) {
  unsigned a, b, c, d;
  if (!__get_cpuid_count(7, 0, &a, &b, &c, &d)) return 0;
  return (c >> 5) & 1;
}

static long read_sysfs_long(const char *p) {
  FILE *f = fopen(p, "r");
  long v = -1;
  if (f) {
    if (fscanf(f, "%ld", &v) != 1) v = -1;
    fclose(f);
  }
  return v;
}

// ---- stats ----
static int cmp_u64(const void *x, const void *y) {
  uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y;
  return a < b ? -1 : a > b;
}
static void pct(uint64_t *v, uint64_t n, uint64_t *p50, uint64_t *p99, uint64_t *mx) {
  if (!n) {
    *p50 = *p99 = *mx = 0;
    return;
  }
  qsort(v, n, sizeof *v, cmp_u64);
  *p50 = v[(n - 1) * 50 / 100];
  *p99 = v[(n - 1) * 99 / 100];
  *mx = v[n - 1];
}

static inline uint64_t ld(volatile uint64_t *p) { return *p; }
static inline void st(volatile uint64_t *p, uint64_t v) { *p = v; }

// Wait until *p == want or timeout (seconds); spin with pause. Returns 1 on success.
static int wait_eq(volatile uint64_t *p, uint64_t want, double timeout_s) {
  double t0 = now_s();
  for (uint64_t i = 0;; i++) {
    if (ld(p) == want) return 1;
    _mm_pause();
    if ((i & 4095) == 0 && now_s() - t0 > timeout_s) return 0;
  }
}

static FILE *open_csv(const char *path, FILE **sum) {
  *sum = stdout;
  if (!path) return NULL;
  if (!strcmp(path, "-")) {
    *sum = stderr;
    return stdout;
  }
  FILE *f = fopen(path, "w");
  if (!f) die("open %s: %s", path, strerror(errno));
  return f;
}

// ---- initiator ----
static int run_init(const struct args *a, volatile uint64_t *X, volatile uint64_t *Y, uint64_t khz) {
  FILE *sum, *csv = open_csv(a->csv, &sum);
  uint64_t *rtt = malloc(a->n * sizeof *rtt);
  if (!rtt) die("malloc");
  const uint64_t nonce = a->nonce;
  // handshake: wait for the responder's hello, announce ourselves, wait for its ack
  if (!wait_eq(Y, ctl(TAG_HELLO_R, nonce), a->start_timeout_s)) {
    fprintf(stderr, "init: no responder hello within %.0f s (Y=%#" PRIx64 ")\n", a->start_timeout_s, ld(Y));
    st(X, ctl(TAG_ABORT, nonce));
    return 3;
  }
  st(X, ctl(TAG_HELLO_I, nonce));
  if (!wait_eq(Y, ctl(TAG_ACK, nonce), a->start_timeout_s)) {
    fprintf(stderr, "init: no responder ack (Y=%#" PRIx64 ")\n", ld(Y));
    st(X, ctl(TAG_ABORT, nonce));
    return 3;
  }
  if (csv) fprintf(csv, "seq,gap_us,rtt_cycles,rtt_ns\n");
  uint64_t rng = a->seed * 0x9E3779B97F4A7C15ull + 1;
  const uint64_t to_cyc = (uint64_t)(a->ping_timeout_ms * khz);
  const unsigned span = a->gap_max_us - a->gap_min_us + 1;
  int rc = 0;
  uint64_t done = 0;
  for (uint64_t seq = 1; seq <= a->n; seq++) {
    rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
    unsigned gap = a->gap_min_us + (unsigned)(rng % span);
    uint64_t until = tsc() + (uint64_t)gap * khz / 1000;
    while (tsc() < until) _mm_pause();  // busy gap: keeps the initiator's timing independent of its own wakeups
    uint64_t t0 = tsc();
    st(X, seq);
    uint64_t t1;
    for (uint64_t i = 0;; i++) {
      if (ld(Y) == seq) {
        t1 = tsc();
        break;
      }
      _mm_pause();
      if ((i & 1023) == 0 && tsc() - t0 > to_cyc) {
        fprintf(stderr, "init: ping %" PRIu64 " timed out after %.0f ms (Y=%#" PRIx64 ")\n", seq, a->ping_timeout_ms,
                ld(Y));
        st(X, ctl(TAG_ABORT, nonce));
        rc = 4;
        goto out;
      }
    }
    uint64_t c = t1 - t0;
    rtt[done++] = c;
    if (csv) fprintf(csv, "%" PRIu64 ",%u,%" PRIu64 ",%.1f\n", seq, gap, c, c * 1e6 / khz);
  }
  st(X, ctl(TAG_STOP, nonce));
  if (!wait_eq(Y, ctl(TAG_BYE, nonce), 10)) {
    fprintf(stderr, "init: no responder bye (Y=%#" PRIx64 ")\n", ld(Y));
    rc = 5;
  }
out:
  if (csv && csv != stdout) fclose(csv);
  else if (csv) fflush(csv);
  uint64_t p50, p99, mx;
  pct(rtt, done, &p50, &p99, &mx);
  fprintf(sum,
          "summary role=init mode=%s pings=%" PRIu64 " of %" PRIu64 " tsc_khz=%" PRIu64 " rtt_ns_p50=%.1f rtt_ns_p99=%.1f"
          " rtt_ns_max=%.1f rc=%d\n",
          a->mode, done, a->n, khz, p50 * 1e6 / khz, p99 * 1e6 / khz, mx * 1e6 / khz, rc);
  free(rtt);
  return rc;
}

// ---- responder ----
// Classes of one UMWAIT return (Intel SDM: CF = 1 only when the OS time limit, IA32_UMWAIT_CONTROL[31:2] =
// umwait_control/max_time, ended the wait; the instruction's own TSC deadline ends it with CF = 0, so that case is
// told apart by reading the TSC after the return):
//   trigger   CF=0, before the deadline, X changed      (the monitor fired because of the store)
//   spurious  CF=0, before the deadline, X unchanged    (interrupt, other monitor event)
//   deadline  CF=0, TSC past the deadline
//   oslimit   CF=1
// Each ping (wait) ends in one of: precheck (X had already changed before UMWAIT was entered), trigger, deadline or
// oslimit (the change was found only after a timer-ended wait: a missed or late trigger).
enum { R_TRIGGER, R_SPURIOUS, R_DEADLINE, R_OSLIMIT, R_N };
enum { E_PRECHECK, E_TRIGGER, E_DEADLINE, E_OSLIMIT, E_N };
static const char *rname[R_N] = {"trigger", "spurious", "deadline", "oslimit"};
static const char *ename[E_N] = {"precheck", "trigger", "deadline", "oslimit"};

static int run_resp(const struct args *a, volatile uint64_t *X, volatile uint64_t *Y, uint64_t khz) {
  FILE *sum, *csv = open_csv(a->csv, &sum);
  const int umw = !strcmp(a->mode, "umwait");
  const uint64_t nonce = a->nonce;
  uint64_t *loops = malloc(a->n * sizeof *loops);
  uint64_t *waitc = malloc(a->n * sizeof *waitc);
  if (!loops || !waitc) die("malloc");
  uint64_t ret[R_N] = {0}, end[E_N] = {0};
  const unsigned state = (unsigned)a->c02;  // UMWAIT operand bit 0: 0 = C0.2, 1 = C0.1
  const uint64_t idle_cyc = (uint64_t)(a->idle_timeout_s * 1e3 * khz);

  st(Y, ctl(TAG_HELLO_R, nonce));
  if (!wait_eq(X, ctl(TAG_HELLO_I, nonce), a->start_timeout_s)) {
    fprintf(stderr, "resp: no initiator hello within %.0f s (X=%#" PRIx64 ")\n", a->start_timeout_s, ld(X));
    st(Y, ctl(TAG_ABORT, nonce));
    return 3;
  }
  uint64_t last = ctl(TAG_HELLO_I, nonce);
  st(Y, ctl(TAG_ACK, nonce));
  if (csv) fprintf(csv, "seq,end,loops,wait_cycles\n");
  uint64_t waits = 0;
  int rc = 0;
  for (;;) {
    uint64_t t0 = tsc(), v, nloop = 0;
    int e = E_PRECHECK;
    if (!umw) {
      while ((v = ld(X)) == last) {
        _mm_pause();
        if ((++nloop & 4095) == 0 && tsc() - t0 > idle_cyc) goto idle;
      }
    } else {
      for (;;) {
        if ((v = ld(X)) != last) break;
        _umonitor((void *)X);
        if ((v = ld(X)) != last) break;  // re-check after arming: a store between load and umonitor is not missed
        uint64_t dl = tsc() + a->deadline_cycles;
        unsigned char cf = _umwait(state, dl);
        uint64_t t = tsc();
        v = ld(X);
        nloop++;
        int r = cf ? R_OSLIMIT : (t >= dl ? R_DEADLINE : (v != last ? R_TRIGGER : R_SPURIOUS));
        ret[r]++;
        if (v != last) {
          e = r == R_DEADLINE ? E_DEADLINE : r == R_OSLIMIT ? E_OSLIMIT : E_TRIGGER;
          break;
        }
        if (t - t0 > idle_cyc) goto idle;
      }
    }
    uint64_t t1 = tsc();
    if (v == ctl(TAG_STOP, nonce)) {
      st(Y, ctl(TAG_BYE, nonce));
      break;
    }
    if (v >> 56) {
      fprintf(stderr, "resp: initiator aborted or foreign value X=%#" PRIx64 "\n", v);
      rc = 4;
      break;
    }
    st(Y, v);  // echo
    last = v;
    if (waits < a->n) {
      loops[waits] = nloop;
      waitc[waits] = t1 - t0;
    }
    waits++;
    end[e]++;
    if (csv) fprintf(csv, "%" PRIu64 ",%s,%" PRIu64 ",%" PRIu64 "\n", v, umw ? ename[e] : "spin", nloop, t1 - t0);
    continue;
  idle:
    fprintf(stderr, "resp: X unchanged for %.0f s, giving up (X=%#" PRIx64 ")\n", a->idle_timeout_s, ld(X));
    st(Y, ctl(TAG_ABORT, nonce));
    rc = 3;
    break;
  }
  if (csv && csv != stdout) fclose(csv);
  else if (csv) fflush(csv);
  uint64_t m = waits < a->n ? waits : a->n, l50, l99, lmx, w50, w99, wmx;
  pct(loops, m, &l50, &l99, &lmx);
  pct(waitc, m, &w50, &w99, &wmx);
  fprintf(sum, "summary role=resp mode=%s state=%s deadline_cycles=%" PRIu64 " waits=%" PRIu64, a->mode,
          umw ? (a->c02 ? "C0.1" : "C0.2") : "-", umw ? a->deadline_cycles : 0, waits);
  if (umw) {
    for (int i = 0; i < E_N; i++) fprintf(sum, " end_%s=%" PRIu64, ename[i], end[i]);
    for (int i = 0; i < R_N; i++) fprintf(sum, " ret_%s=%" PRIu64, rname[i], ret[i]);
  }
  fprintf(sum,
          " loops_p50=%" PRIu64 " loops_p99=%" PRIu64 " loops_max=%" PRIu64 " wait_us_p50=%.1f wait_us_p99=%.1f"
          " wait_us_max=%.1f rc=%d\n",
          l50, l99, lmx, w50 * 1e3 / khz, w99 * 1e3 / khz, wmx * 1e3 / khz, rc);
  free(loops);
  free(waitc);
  return rc;
}

static void pin(int cpu) {
  if (cpu < 0) return;
  cpu_set_t s;
  CPU_ZERO(&s);
  CPU_SET(cpu, &s);
  if (sched_setaffinity(0, sizeof s, &s)) die("sched_setaffinity(%d): %s", cpu, strerror(errno));
}

static int run_role(struct args *a, const char *role, int cpu, volatile char *line_x) {
  pin(cpu);
  uint64_t khz = a->tsc_khz ? a->tsc_khz : calibrate_tsc_khz();
  volatile uint64_t *X = (volatile uint64_t *)line_x, *Y = (volatile uint64_t *)(line_x + LINE_Y_DELTA);
  fprintf(stderr, "%s: cpu=%d mode=%s n=%" PRIu64 " nonce=%" PRIu64 " tsc_khz=%" PRIu64 " deadline_cycles=%" PRIu64
                  " c02=%d\n",
          role, cpu, a->mode, a->n, a->nonce, khz, a->deadline_cycles, a->c02);
  return !strcmp(role, "init") ? run_init(a, X, Y, khz) : run_resp(a, X, Y, khz);
}

int main(int argc, char **argv) {
  struct args a;
  parse_args(argc, argv, &a);
  if (!strcmp(a.mode, "umwait")) {
    if (!have_waitpkg()) die("CPU has no WAITPKG (CPUID.7.0:ECX[5]); umwait mode unavailable");
    if (!a.deadline_cycles) {
      long mt = read_sysfs_long("/sys/devices/system/cpu/umwait_control/max_time");
      a.deadline_cycles = 10ull * (uint64_t)(mt > 0 ? mt : 100000);
    }
  }
  region_default(&a);
  if (a.offset % 64) die("--offset must be 64 B aligned");
  setvbuf(stdout, NULL, _IOFBF, 1 << 20);

  if (a.selftest) {
    void *p = mmap(NULL, WIN, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) die("mmap anon: %s", strerror(errno));
    volatile char *x = (volatile char *)p + (a.offset % (WIN - LINE_Y_DELTA - 64) & ~63ull);
    const char *csv = a.csv;
    fflush(NULL);
    pid_t pid = fork();
    if (pid < 0) die("fork: %s", strerror(errno));
    if (pid == 0) {
      char path[4096];
      if (csv && strcmp(csv, "-")) snprintf(path, sizeof path, "%s.resp.csv", csv), a.csv = path;
      else a.csv = NULL;
      exit(run_role(&a, "resp", a.cpu2, x));
    }
    int rc = run_role(&a, "init", a.cpu, x), st = 0;
    fflush(NULL);
    waitpid(pid, &st, 0);
    int crc = WIFEXITED(st) ? WEXITSTATUS(st) : 128;
    fprintf(stderr, "selftest: init rc=%d resp rc=%d\n", rc, crc);
    return rc ? rc : crc;
  }

  int fd = open(a.dev, O_RDWR);
  if (fd < 0) die("open %s: %s", a.dev, strerror(errno));
  uint64_t base = a.offset & ~(uint64_t)(WIN - 1);
  if (a.offset + LINE_Y_DELTA + 64 > base + WIN) die("line Y crosses the 2 MiB window; pick another --offset");
  void *p = mmap(NULL, WIN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)base);
  if (p == MAP_FAILED) die("mmap %s offset %#" PRIx64 ": %s", a.dev, base, strerror(errno));
  fprintf(stderr, "mapped %s [%#" PRIx64 ", +%#x) line_x=%#" PRIx64 " line_y=%#" PRIx64 "\n", a.dev, base, WIN,
          a.offset, a.offset + LINE_Y_DELTA);
  int rc = run_role(&a, a.role, a.cpu, (volatile char *)p + (a.offset - base));
  fflush(NULL);
  munmap(p, WIN);
  close(fd);
  return rc;
}
