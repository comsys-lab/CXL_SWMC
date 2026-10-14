# Builds the guest-side binary. Plain C++17, no dependencies beyond libstdc++.
CXX ?= g++
CXXFLAGS ?= -O2 -g -Wall -Wextra -std=c++17
BIN := faultlat

$(BIN): faultlat.cc ../../systems/common/cxl_region.h
	$(CXX) $(CXXFLAGS) -o $@ faultlat.cc

clean:
	rm -f $(BIN)

.PHONY: clean
