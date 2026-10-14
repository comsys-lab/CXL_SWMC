#!/bin/bash

# Compile the program
echo "Compiling dax_mmap_test..."
gcc -O0 -Wall -Wextra -std=gnu99 -o dax_mmap_test dax_mmap_test.c -lpthread

if [ $? -eq 0 ]; then
    echo "Compilation successful!"
    echo ""
    echo "Usage examples:"
    echo "  # Write mode: Fill 1GB with value 5"
    echo "  sudo ./dax_mmap_test /dev/dax0.0 1G write 5 0"
    echo ""
    echo "  # Read mode: Verify 1GB with 1 million random accesses for value 5"
    echo "  sudo ./dax_mmap_test /dev/dax0.0 1G read 5 1000000"
    echo ""
    echo "  # Write 256M with value 7"
    echo "  sudo ./dax_mmap_test /dev/dax0.0 256M write 7 0"
    echo ""
    echo "  # Read 256M with 500k iterations for value 7"
    echo "  sudo ./dax_mmap_test /dev/dax0.0 256M read 7 500000"
else
    echo "Compilation failed!"
    exit 1
fi
