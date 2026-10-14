#!/bin/bash

MODE="${MODE:-MTRR}" # Popcorn or MTRR or DeStijl or Popcorn4KB
NODE_ID="${NODE_ID:-0}" # Node ID for CXL Shared Memory

# turn on inter-kernel messaging layer if DeStijl or Popcorn4KB mode
if [ "$MODE" == "DeStijl" ] || [ "$MODE" == "Popcorn4KB" ]; then
    cd /home/comsys/CXLSHMSWcoherence/msg_layer_module/ && make
    sudo insmod cxl_shm.ko dax_name=dax0.0 node_id=${NODE_ID}
fi

# Check filesystem and directories
sudo /home/comsys/famfs/debug/famfs fsck -v /dev/dax0.0 # Filesystem 생성 확인
sudo /home/comsys/famfs/debug/famfs mount --fuse /dev/dax0.0 /mnt/famfs

sudo /home/comsys/famfs/debug/famfs logplay -v /mnt/famfs
sudo ls /mnt/famfs/vectorDB -ahl
sudo ls /mnt/famfs/vectorDB/indexbin -ahl

# Read index files from famfs mounted directory
if [ "$MODE" == "DeStijl" ] || [ "$MODE" == "Popcorn4KB" ]; then
    cd /home/comsys/CXLSHMSWcoherence/unittest/page_replication
    sudo ./read_once /mnt/famfs/vectorDB/indexbin/hnsw_index_6500k_0.bin 4096
    sudo ./read_once /mnt/famfs/vectorDB/indexbin/hnsw_index_6500k_1.bin 4096
    sudo ./read_once /mnt/famfs/vectorDB/indexbin/hnsw_index_6500k_2.bin 4096
    sudo ./read_once /mnt/famfs/vectorDB/indexbin/hnsw_index_6500k_3.bin 4096
    sudo ./read_once /mnt/famfs/vectorDB/indexbin/ivf_index_6500k_0.bin 4096
    sudo ./read_once /mnt/famfs/vectorDB/indexbin/ivf_index_6500k_1.bin 4096
    sudo ./read_once /mnt/famfs/vectorDB/indexbin/ivf_index_6500k_2.bin 4096
    sudo ./read_once /mnt/famfs/vectorDB/indexbin/ivf_index_6500k_3.bin 4096
    sudo ./read_once /mnt/famfs/vectorDB/flat_index_1M.bin 4096
    sudo ./read_once /mnt/famfs/lmdb_7M_4KB/data.mdb 4096
fi

sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"

if [ "$MODE" == "DeStijl" ] || [ "$MODE" == "Popcorn4KB" ]; then
    # enable DeStijl page coherence
    sudo /home/comsys/CXLSHMSWcoherence/userspace_tool/page_coherence enable
fi