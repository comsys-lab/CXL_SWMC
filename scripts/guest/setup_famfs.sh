#!/bin/bash

# Make filesystem and directories
sudo /home/comsys/famfs/debug/mkfs.famfs -k -f /dev/dax0.0
sudo /home/comsys/famfs/debug/mkfs.famfs --loglen 256m /dev/dax0.0
sudo /home/comsys/famfs/debug/famfs mount --fuse /dev/dax0.0 /mnt/famfs 

sudo /home/comsys/famfs/debug/famfs mkdir /mnt/famfs/vectorDB
sudo /home/comsys/famfs/debug/famfs mkdir /mnt/famfs/vectorDB/indexbin

# Copy index files to famfs mounted directory
for i in $(seq 0 3)
do
	sudo /home/comsys/famfs/debug/famfs cp -v /home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/indexbin/hnsw_index_6500k_${i}.bin /mnt/famfs/vectorDB/indexbin
	sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"
done

sudo /home/comsys/famfs/debug/famfs cp -v /home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/flat_index_1M.bin /mnt/famfs/vectorDB/flat_index_1M.bin
sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"

