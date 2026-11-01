/* Smoke test for libdestijl. Runs only inside a De Stijl v2 VM (it maps the
 * CXL device of $CXL_REGION_CONFIG); refuses to run unless
 * DE_STIJL_TEST_IN_VM=1 so that it never touches a Host device by accident.
 * Usage: CXL_REGION_CONFIG=<yaml> DE_STIJL_TEST_IN_VM=1 ./de_stijl_test */
#include "de_stijl.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
	const char *vm = getenv("DE_STIJL_TEST_IN_VM");
	volatile unsigned char *a, *b;

	if (!vm || strcmp(vm, "1") != 0) {
		fprintf(stderr, "de_stijl_test: set DE_STIJL_TEST_IN_VM=1 (guest only)\n");
		return 2;
	}
	/* 1: alloc with T = 0 (synchronous), then 3 MiB with T = 100 us. */
	a = de_stijl_alloc(4096, 0);
	if (!a) {
		perror("de_stijl_alloc(4096, 0)");
		return 1;
	}
	b = de_stijl_alloc(3u << 20, 100);
	if (!b) {
		perror("de_stijl_alloc(3 MiB, 100)");
		return 1;
	}
	if ((unsigned char *)b - (unsigned char *)a != (long)DE_STIJL_ALLOC_ALIGN) {
		fprintf(stderr, "unexpected cursor step %p -> %p\n", (void *)a, (void *)b);
		return 1;
	}
	/* 2: re-set T on the middle of b (splits the VMA in the kernel). */
	if (de_stijl_set_staleness((unsigned char *)b + (1u << 20), 1u << 20, 1000)) {
		perror("de_stijl_set_staleness(middle of b, 1000)");
		return 1;
	}
	/* 3: unaligned address must fail with EINVAL. */
	if (de_stijl_set_staleness((unsigned char *)b + 1, 4096, 1) != -1 || errno != EINVAL) {
		fprintf(stderr, "unaligned set_staleness did not fail with EINVAL\n");
		return 1;
	}
	/* 4: the memory is usable. */
	a[0] = 1;
	b[0] = a[0] + 1;
	printf("de_stijl_test: ok a=%p b=%p b[0]=%u\n", (void *)a, (void *)b, b[0]);
	return 0;
}
