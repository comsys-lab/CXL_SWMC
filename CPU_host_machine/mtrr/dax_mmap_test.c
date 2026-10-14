#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>
#include <errno.h>

// Function to parse size string (e.g., "1G", "256MB")
size_t parse_size(const char *size_str) {
    char *endptr;
    double size = strtod(size_str, &endptr);
    
    if (strcasecmp(endptr, "G") == 0 || strcasecmp(endptr, "GB") == 0) {
        return (size_t)(size * 1024 * 1024 * 1024);
    } else if (strcasecmp(endptr, "M") == 0 || strcasecmp(endptr, "MB") == 0) {
        return (size_t)(size * 1024 * 1024);
    } else if (strcasecmp(endptr, "K") == 0 || strcasecmp(endptr, "KB") == 0) {
        return (size_t)(size * 1024);
    } else if (strcasecmp(endptr, "B") == 0 || *endptr == '\0') {
        return (size_t)size;
    } else {
        fprintf(stderr, "Invalid size format: %s\n", size_str);
        exit(1);
    }
}

// Get timestamp in nanoseconds
static inline uint64_t get_nsecs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

// Simple LCG random number generator for deterministic random access
static uint64_t rand_seed = 12345;

static inline uint64_t simple_rand(void) {
    rand_seed = (rand_seed * 1103515245ULL + 12345ULL) & 0x7fffffffULL;
    return rand_seed;
}

int main(int argc, char *argv[]) {
    if (argc != 6) {
        fprintf(stderr, "Usage: %s <dax_device_path> <size> <mode> <integer> <iteration>\n", argv[0]);
        fprintf(stderr, "  size: e.g., 1G, 256M, 512M\n");
        fprintf(stderr, "  mode: read or write\n");
        fprintf(stderr, "  integer: 1-9\n");
        fprintf(stderr, "  iteration: number of iterations\n");
        return 1;
    }
    
    const char *dax_path = argv[1];
    size_t map_size = parse_size(argv[2]);
    const char *mode = argv[3];
    int value = atoi(argv[4]);
    long iterations = atol(argv[5]);
    
    // Validate inputs
    if (value < 1 || value > 9) {
        fprintf(stderr, "Integer value must be between 1 and 9\n");
        return 1;
    }
    
    if (strcmp(mode, "read") != 0 && strcmp(mode, "write") != 0) {
        fprintf(stderr, "Mode must be 'read' or 'write'\n");
        return 1;
    }
    
    printf("Configuration:\n");
    printf("  DAX device: %s\n", dax_path);
    printf("  Size: %zu bytes (%.2f M)\n", map_size, map_size / (1024.0 * 1024.0));
    printf("  Mode: %s\n", mode);
    printf("  Value: %d\n", value);
    printf("  Iterations: %ld\n", iterations);
    printf("\n");
    
    // Open DAX device
    int fd = open(dax_path, O_RDWR);
    if (fd < 0) {
        perror("Failed to open DAX device");
        return 1;
    }
    
    // Memory map the device
    void *mapped_addr = mmap(NULL, map_size, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd, 0);
    if (mapped_addr == MAP_FAILED) {
        perror("Failed to mmap DAX device");
        close(fd);
        return 1;
    }
    
    printf("Successfully mapped %zu bytes at address %p\n\n", map_size, mapped_addr);
    
    uint64_t start_time, end_time;
    
    if (strcmp(mode, "write") == 0) {
        // WRITE MODE: Fill the entire mapped region with the value
        printf("=== WRITE MODE ===\n");
        
        uint8_t *bytes = (uint8_t *)mapped_addr;
        size_t num_bytes = map_size;
        
        start_time = get_nsecs();
        
        // Fill memory with the value
        for (size_t i = 0; i < num_bytes; i++) {
            bytes[i] = (uint8_t)value;
        }
        
        // Ensure writes are completed
        __sync_synchronize();
        
        end_time = get_nsecs();
        
        double elapsed_sec = (end_time - start_time) / 1e9;
        double bandwidth_mbps = (map_size / (1024.0 * 1024.0)) / elapsed_sec;
        
        printf("Write completed successfully\n");
        printf("Elapsed time: %.6f seconds\n", elapsed_sec);
        printf("Bandwidth: %.2f M/s\n", bandwidth_mbps);
        
    } else {
        // READ MODE: Random access and verify
        printf("=== READ MODE ===\n");
        
        uint8_t *bytes = (uint8_t *)mapped_addr;
        size_t num_bytes = map_size;
        uint64_t mismatches = 0;
        uint64_t total_accesses = 0;
        
        rand_seed = 12345; // Reset seed for reproducibility
        
        start_time = get_nsecs();
        
        for (long i = 0; i < iterations; i++) {
            // Generate random offset
            uint64_t offset = simple_rand() % num_bytes;
            
            // Read and verify
            uint8_t read_value = bytes[offset];
            total_accesses++;
            
            if (read_value != (uint8_t)value) {
                mismatches++;
            }
        }
        
        end_time = get_nsecs();
        
        double elapsed_sec = (end_time - start_time) / 1e9;
        double accesses_per_sec = iterations / elapsed_sec;
        
        printf("Read verification completed\n");
        printf("Total accesses: %ld\n", iterations);
        printf("Mismatches: %lu\n", mismatches);
        printf("Accuracy: %.2f%%\n", 100.0 * (iterations - mismatches) / iterations);
        printf("Elapsed time: %.6f seconds\n", elapsed_sec);
        printf("Accesses per second: %.2f M/s\n", accesses_per_sec / 1e6);
    }
    
    // Cleanup
    munmap(mapped_addr, map_size);
    close(fd);
    
    printf("\nTest completed successfully\n");
    
    return 0;
}
