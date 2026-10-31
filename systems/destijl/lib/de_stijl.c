/* De Stijl v2 user library: syscall wrapper (see de_stijl.h). */
#define _GNU_SOURCE
#include "de_stijl.h"

#include <sys/syscall.h>
#include <unistd.h>

int de_stijl_set_staleness(void *addr, size_t len, uint64_t staleness_us)
{
	/* syscall() returns -1 and sets errno on failure. */
	return (int)syscall(DE_STIJL_SYS_SET_STALENESS, (unsigned long)addr,
			    len, staleness_us);
}
