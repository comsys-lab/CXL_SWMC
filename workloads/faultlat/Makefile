# Builds the guest-side binary. Plain C++17, no dependencies beyond libstdc++ (+ pthreads).
CXX ?= g++
CXXFLAGS ?= -O2 -g -Wall -Wextra -std=c++17
BIN := faultlat
TEST_BIN ?= contend_test

DS_LIB := ../../systems/destijl/lib

# de_stijl.c (libdestijl's syscall wrapper, plain C) is compiled with the binary: --staleness-us calls
# de_stijl_set_staleness (syscall 472; ENOSYS on kernels without De Stijl v2, only when the option is used).
$(BIN): faultlat.cc contend.h ../../systems/common/cxl_region.h ../../systems/common/hwcc_app.h $(DS_LIB)/de_stijl.c $(DS_LIB)/de_stijl.h
	$(CC) -O2 -g -Wall -Wextra -std=gnu11 -c -o $@.de_stijl.o $(DS_LIB)/de_stijl.c
	$(CXX) $(CXXFLAGS) -pthread -o $@ faultlat.cc $@.de_stijl.o
	rm -f $@.de_stijl.o

# Host-only unit tests of the contend data invariant (no device access).
$(TEST_BIN): contend_test.cc contend.h
	$(CXX) $(CXXFLAGS) -o $@ contend_test.cc

test: $(TEST_BIN)
	$(abspath $(TEST_BIN))

clean:
	rm -f $(BIN) $(TEST_BIN)

.PHONY: clean test
