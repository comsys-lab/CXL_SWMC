#!/bin/bash

NODE_ID=0 # Node ID for CXL Shared Memory

cd /home/comsys/CXLSHMSWcoherence/msg_layer_module/ && make
sudo insmod cxl_shm.ko dax_name=dax0.0 node_id=${NODE_ID}
