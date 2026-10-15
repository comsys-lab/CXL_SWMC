# Builds the guest-side binary. Plain C++17, no dependencies beyond libstdc++ (+ pthreads).
CXX ?= g++
CXXFLAGS ?= -O2 -g -Wall -Wextra -std=c++17
BIN := faultlat
TEST_BIN ?= contend_test

$(BIN): faultlat.cc contend.h ../../systems/common/cxl_region.h ../../systems/common/hwcc_app.h
	$(CXX) $(CXXFLAGS) -pthread -o $@ faultlat.cc

# Host-only unit tests of the contend data invariant (no device access).
$(TEST_BIN): contend_test.cc contend.h
	$(CXX) $(CXXFLAGS) -o $@ contend_test.cc

test: $(TEST_BIN)
	./$(TEST_BIN)

clean:
	rm -f $(BIN) $(TEST_BIN)

.PHONY: clean test
