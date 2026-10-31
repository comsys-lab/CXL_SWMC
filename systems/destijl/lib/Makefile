# libdestijl.a (de_stijl_set_staleness, de_stijl_alloc) and its smoke test.
# The test maps the CXL device: build anywhere, run only inside a VM.
CC ?= cc
CXX ?= c++
CFLAGS ?= -O2 -g
CXXFLAGS ?= -O2 -g
WARN := -Wall -Wextra -Werror
CPPFLAGS += -I. -I../../common

all: libdestijl.a de_stijl_test

de_stijl.o: de_stijl.c de_stijl.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -std=gnu11 -c -o $@ $<

de_stijl_alloc.o: de_stijl_alloc.cc de_stijl.h ../../common/cxl_region.h
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(WARN) -std=c++17 -c -o $@ $<

libdestijl.a: de_stijl.o de_stijl_alloc.o
	$(AR) rcs $@ $^

de_stijl_test.o: de_stijl_test.c de_stijl.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -std=gnu11 -c -o $@ $<

# C++ link: de_stijl_alloc.o needs libstdc++.
de_stijl_test: de_stijl_test.o libdestijl.a
	$(CXX) -o $@ $< -L. -ldestijl -pthread

clean:
	rm -f *.o libdestijl.a de_stijl_test

.PHONY: all clean
