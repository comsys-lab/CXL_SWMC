# CPU_host_macihne

## How to enable CXL memory expander to devdax device
- `sudo vim /etc/default/grub`
- add `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash modprobe.blacklist=kmem" # to change CXL as devdax mode`
- `sudo update-grub` and reboot
- after reboot
  - `lsmod | grep kmem` to check kmem module is not started
  - `sudo grep 'soft reserved' /proc/iomem`
  - `daxctl list` and enable dax device with `sudo daxctl enable-device daxX.X`
- use dax_setting.c to check if devdax mode CXL

## How to change alignment of CXL memory
-