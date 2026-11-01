# User-space tests for the De Stijl v2 headers include/swmc/ds_ring.h and ds_ccd.h.
#   make test            build and run both tests (ring: 10^7 messages; ccd: 8 nodes x 10^6 faults)
#   make headers         compile each header alone with -std=gnu11 -Wall -Werror
#   make DS_INC=<dir>    use another kernel include dir (must contain swmc/ds_ring.h)
# Binaries go to $(BUILD) (default ./build, git-ignored).

HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
# Kernel tree: the CXL_SWMC submodule kernels/destijl, or the destijl-v2 worktree layout
# (workspaces/destijl-v2/{CXL_SWMC,kernel/famfs-linux}).
DS_INC_CANDIDATES := $(HERE)/../../../kernels/destijl/famfs-linux/include \
		     $(HERE)/../../../../kernel/famfs-linux/include
DS_INC ?= $(abspath $(firstword $(foreach d,$(DS_INC_CANDIDATES),$(if $(wildcard $(d)/swmc/ds_ring.h),$(d)))))
BUILD ?= $(HERE)/build

CC ?= gcc
CFLAGS ?= -std=gnu11 -O2 -g -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=undefined
LDLIBS = -lpthread
RUN ?= nice -n 19
RING_MSGS ?= 10000000
CCD_FAULTS ?= 1000000

HDRS = $(DS_INC)/swmc/ds_ring.h $(DS_INC)/swmc/ds_ccd.h
BINS = $(BUILD)/test_ring $(BUILD)/test_ccd

.PHONY: all test headers check-inc clean-build

all: check-inc headers $(BINS)

check-inc:
	@test -f "$(DS_INC)/swmc/ds_ring.h" || { echo "DS_INC not found; set DS_INC=<kernel>/include"; exit 1; }

$(BUILD):
	mkdir -p $@

$(BUILD)/%: $(HERE)/%.c $(HERE)/test_common.h $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) -I$(DS_INC) -o $@ $< $(LDLIBS)

headers: check-inc | $(BUILD)
	for h in ds_ring.h ds_ccd.h; do \
		printf '#include <swmc/%s>\nint ds_header_only_tu;\n' $$h > $(BUILD)/hdr_$$h.c; \
		$(CC) -std=gnu11 -Wall -Wextra -Werror -c -I$(DS_INC) -o $(BUILD)/hdr_$$h.o $(BUILD)/hdr_$$h.c || exit 1; \
	done
	@echo "headers: ds_ring.h ds_ccd.h compile standalone with -std=gnu11 -Wall -Wextra -Werror: OK"

test: all
	$(RUN) $(BUILD)/test_ring $(RING_MSGS)
	$(RUN) $(BUILD)/test_ccd $(CCD_FAULTS)
	@echo "ALL TESTS PASSED"

# Removes only this directory's build output.
clean-build:
	rm -rf $(BUILD)
