// Test server for the loadgen harness: echoes each request payload after `service_us` of busy work on one of
// `workers` threads (capacity = workers * 1e6 / service_us req/s). usage: echo_server <port> <workers> <service_us>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <time.h>

#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "../frame.h"

struct Job {
  int fd;
  std::mutex *wmu;
  frame::header h;
  std::vector<uint8_t> p;
};
static std::mutex qmu;
static std::condition_variable qcv;
static std::deque<Job> q;

static uint64_t now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

int main(int argc, char **argv) {
  if (argc != 4) return std::fprintf(stderr, "usage: echo_server <port> <workers> <service_us>\n"), 2;
  int port = std::atoi(argv[1]), workers = std::atoi(argv[2]);
  uint64_t svc = std::strtoull(argv[3], nullptr, 10) * 1000;
  for (int i = 0; i < workers; i++)
    std::thread([svc] {
      for (;;) {
        std::unique_lock<std::mutex> l(qmu);
        qcv.wait(l, [] { return !q.empty(); });
        Job j = std::move(q.front());
        q.pop_front();
        l.unlock();
        for (uint64_t t = now_ns() + svc; now_ns() < t;) {
        }
        frame::header h;
        frame::fill(&h, frame::kStatusOk, j.h.req_id, uint32_t(j.p.size()));
        std::lock_guard<std::mutex> g(*j.wmu);
        frame::write_full(j.fd, &h, sizeof(h));
        frame::write_full(j.fd, j.p.data(), j.p.size());
      }
    }).detach();
  int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(uint16_t(port));
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(ls, (sockaddr *)&a, sizeof(a)) || listen(ls, 64)) return std::perror("bind"), 1;
  for (;;) {
    int fd = accept(ls, nullptr, nullptr);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    std::thread([fd] {
      auto *wmu = new std::mutex;
      frame::header h;
      while (frame::read_full(fd, &h, sizeof(h))) {
        Job j{fd, wmu, h, std::vector<uint8_t>(frame::payload_len(h))};
        if (!j.p.empty() && !frame::read_full(fd, j.p.data(), j.p.size())) break;
        {
          std::lock_guard<std::mutex> g(qmu);
          q.push_back(std::move(j));
        }
        qcv.notify_one();
      }
    }).detach();
  }
}
