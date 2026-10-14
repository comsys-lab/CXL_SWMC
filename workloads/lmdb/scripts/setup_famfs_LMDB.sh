#!/bin/bash

# Make filesystem and directories
sudo /home/comsys/famfs/debug/mkfs.famfs -k -f /dev/dax0.0
sudo /home/comsys/famfs/debug/mkfs.famfs --loglen 256m /dev/dax0.0
sudo /home/comsys/famfs/debug/famfs mount --fuse /dev/dax0.0 /mnt/famfs 

sudo /home/comsys/famfs/debug/famfs mkdir /mnt/famfs/lmdb_7M_4KB

sudo /home/comsys/famfs/debug/famfs cp -v /home/comsys/CXLSharedMemVM/LMDB/Dataset/lmdb_7M_4KB/data.mdb /mnt/famfs/lmdb_7M_4KB/data.mdb
sudo /home/comsys/famfs/debug/famfs cp -v /home/comsys/CXLSharedMemVM/LMDB/Dataset/lmdb_7M_4KB/lock.mdb /mnt/famfs/lmdb_7M_4KB/lock.mdb
sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"

