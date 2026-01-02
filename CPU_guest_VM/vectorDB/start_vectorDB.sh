#!/bin/bash

# this should be run on sudo su 

cd /home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB
sysctl -w vm.watermark_scale_factor=200
sh -c "echo 3 > /proc/sys/vm/drop_caches"
./run.sh

