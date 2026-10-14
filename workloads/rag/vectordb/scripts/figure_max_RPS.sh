#!/bin/bash

HOST_SIZE="24GB"
MODE="Popcorn" # Popcorn or MTRR or DeStijl

# enable DeStijl page replication
if [ "$MODE" == "DeStijl" ]; then
    if [ "$HOST_SIZE" == "96GB" ]; then
        sudo damo start --kdamond ./damo_yamls/replicate_all_${HOST_SIZE}.yaml
    else
        sudo damo start --kdamond ./damo_yamls/replicate_test_${HOST_SIZE}.yaml
    fi
fi

# this should be run on sudo su 

cd /home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB
sysctl -w vm.watermark_scale_factor=200
sh -c "echo 3 > /proc/sys/vm/drop_caches"
./run.sh