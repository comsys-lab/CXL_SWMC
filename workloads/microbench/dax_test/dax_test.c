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
    const char *path = "/dev/dax0.0";
    size_t len = 512 * 1024 * 1024;  // 512MB

    printf("[INFO] Opening %s...\n", path);
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror("[ERROR] open failed");
        return 1;
    }
    printf("[OK] Opened %s\n", path);

    printf("[INFO] mmap() %zu bytes...\n", len);
    // mmap middle of the dax device, offset is about 32GB
    void *addr = mmap((void *)(32ULL * 1024 * 1024 * 1024), len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

    getchar();
    if (addr == MAP_FAILED) {
        perror("[ERROR] mmap failed");
        close(fd);
        return 1;
    }
    printf("[OK] mmap succeeded at address %p\n", addr);

    // change present bit to 0
    printf("[INFO] Invalidating pages...\n");
    size_t page_size = 4096;  // 페이지 크기
    for (size_t i = 0; i < len; i += page_size)
    {
        // invalidate the page by writing to it
        *(volatile char *)(addr + i) = 0;
    }
    printf("[OK] Pages invalidated\n");

    printf("[INFO] Writing to memory...\n");
    memset(addr, 0xAA, len);  // 메모리 초기화
    printf("[OK] Memory initialized with 0xAA\n");  

    printf("[INFO] reading every pages...\n");
    for (size_t i = 0; i < len; i += 4096) {
        // printf("Page %zu: %02x\n", i / 4096, ((unsigned char *)addr)[i]);
    }
    printf("[OK] Read completed\n");

    printf("[INFO] Cleaning up...\n");
    munmap(addr, len);
    close(fd);
    printf("[DONE] All operations completed successfully.\n");

    return 0;
}
