# CPU_guest_VM

## How to build kernel
- `cp ~/famfs/kconfig/famfs-config-6.14 ~/CXLSHMSWcoherence/famfs-linux/.config`
- `make oldconfig`
- `make -j $(nproc)`
- `sudo make modules_install headers_install install INSTALL_HDR_PATH=/usr`
- `grep menuentry /boot/grub/grub.cfg`
- `sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux <kernel name>"`
- `sudo reboot now`

## How to change dax device alignment
- `sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=devdax --map=mem --size=103062437888 --align=4096`: to 4KB
- `sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=devdax --map=mem --size=103062437888 --align=2097152`: to 2MB
