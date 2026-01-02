#!/bin/bash

HOST_SIZE=$1

if [ -z "$HOST_SIZE" ]; then
    echo "Usage: $0 <host_size>"
    echo "Example: $0 24GB_2MiB"
    exit 1
fi

echo "Reconfiguring VMs for host size: $HOST_SIZE"

sudo virsh destroy cxl_vm0
sudo virsh undefine cxl_vm0
sudo virsh destroy cxl_vm1
sudo virsh undefine cxl_vm1

sudo virsh define ./cxl_vm0_${HOST_SIZE}.xml
sudo virsh define ./cxl_vm1_${HOST_SIZE}.xml

sudo virsh start cxl_vm0
sudo virsh start cxl_vm1