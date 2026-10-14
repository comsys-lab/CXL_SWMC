#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <emmintrin.h>  // _mm_clflush
#include <xmmintrin.h>  // _mm_sfence

// 수동 cache flush 함수
void persist(void *addr, size_t len) {
    char *p = (char *)addr;
    size_t line_size = 64; // 일반적인 x86 cache line
    for (size_t i = 0; i < len; i += line_size) {
        _mm_clflush(p + i);
    }
    _mm_sfence();  // flush ordering 보장
}

int main() {
    const char *path = "/dev/dax1.0";
    size_t len = 2 * 1024 * 1024;  // 2MiB align

    printf("[INFO] Opening %s...\n", path);
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror("[ERROR] open failed");
        return 1;
    }
    printf("[OK] Opened %s\n", path);

    printf("[INFO] mmap() %zu bytes...\n", len);
    void *addr = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) {
        perror("[ERROR] mmap failed");
        close(fd);
        return 1;
    }
    printf("[OK] mmap succeeded at address %p\n", addr);

    printf("[INFO] Writing message to DAX memory...\n");
    const char *msg = "Hello from DAX mmap with flush!\n";
    memcpy(addr, msg, strlen(msg));
    printf("[OK] Message written: \"%s\"\n", msg);

    printf("[INFO] Flushing changes with clflush + sfence...\n");
    persist(addr, strlen(msg));
    printf("[OK] Flush successful\n");

    printf("[INFO] Cleaning up...\n");
    munmap(addr, len);
    close(fd);
    printf("[DONE] All operations completed successfully.\n");

    return 0;
}
