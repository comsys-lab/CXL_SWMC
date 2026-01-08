# CPU_host_machine

## How to enable CXL memory expander to devdax device
- `sudo vim /etc/default/grub`
- add `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash modprobe.blacklist=kmem" # to change CXL as devdax mode`
- `sudo update-grub` and reboot
- after reboot
  - `lsmod | grep kmem` to check kmem module is not started
  - `sudo grep 'soft reserved' /proc/iomem`
  - `daxctl list` and enable dax device with `sudo daxctl enable-device daxX.X`
- use dax_setting.c to check if devdax mode CXL

## VM Setting
- install prerequisite
  ```bash
  sudo apt update
  sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils ovmf ndctl daxctl virt-install
  ```
- libvirt setup
  ```bash
  sudo systemctl enable --now libvirtd
  sudo usermod -aG kvm,libvirt $USER # log out and 'grep $USER /etc/group' to check permission is changed 
  ```

- VM disk image
  ```bash
  # ubuntu cloud image download
  cd /var/lib/libvirt/images
  sudo wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
  # vm disk
  sudo cp jammy-server-cloudimg-amd64.img  cxl_vmx.qcow2
  sudo chown libvirt-qemu:libvirt-qemu cxl_vmx.qcow2
  ```

- VM installation
  ```bash
  sudo virt-install \
    --name cxl_vmx \
    --memory 16384 \
    --vcpus 4 \
    --os-variant ubuntu22.04 \
    --disk path=/var/lib/libvirt/images/cxl_vmx.qcow2,format=qcow2 \
    --import \
    --network network=default,model=virtio \
    --graphics none \
    --noautoconsole
  ```

- VM username setting
  ```bash
  sudo virsh destroy cxl_vmx

  sudo virt-customize -a /var/lib/libvirt/images/cxl_vmx.qcow2 \
    --root-password password:comsyslab \
    --run-command "useradd -m -s /bin/bash comsys" \
    --run-command "echo 'comsys:comsyslab' | chpasswd" \
    --run-command "usermod -aG sudo comsys" \
    --run-command "sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config" \
    --run-command "sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" \
    --run-command "cat > /etc/netplan/99-dhcp.yaml << 'EOF'
  network:
    version: 2
    ethernets:
      enp1s0:
        dhcp4: true
  EOF" \
    --run-command "systemctl enable ssh"
  ```

- VM network setting
  check mac address of VM and bind ip address to mac address in default network
  ```bash
  sudo virsh shutdown cxl_vmx
  sudo virsh dumpxml cxl_vmx | grep 'mac address'
  ```
  1. xml backup: `sudo virsh net-dumpxml default > default.xml`
  2. stop virtual network: `sudo virsh net-destroy default`
  3. edit xml file
  ```xml
  <network connections='2'>
    <ip address='192.168.122.1' netmask='255.255.255.0'>
      <dhcp>
        ...
        <host mac='52:54:00:fc:10:bd' ip='192.168.122.110'/>
      </dhcp>
    </ip>
  </network>
  ```
  4. undefine network: `sudo virsh net-undefine default`
  5. define new network with xml file: `sudo virsh net-define default.xml`
  6. network restart: `sudo virsh net-start default`
  7. set network to autostart: `sudo virsh net-autostart default`

- VM disk image resizing
  in Host machine, we need to increase disk image about ~200G
  ```bash
  sudo qemu-img resize /var/lib/libvirt/images/<qcow2 file used by VM> +<size to> 
  # ex) sudo qemu-img resize /var/lib/libvirt/images/cxl_vmx.qcow2 +200G
  ```
  inside VM
  ```bash
  # use lsblk and df -h to check if it is done right.
  sudo growpart /dev/vda 1
  sudo resize2fs /dev/vda1
  ```

- VM SSH setting
  This should be done in VM. use `virsh console cxl_vmx`
  ```bash
  sudo apt update
  sudo apt install -y openssh-server
  sudo ssh-keygen -A
  sudo systemctl enable --now ssh
  sudo systemctl restart ssh

  # check ssh status
  systemctl status ssh
  ss -tln | grep :22
  ```
  Edit SSH server config in `/etc/ssh/sshd_config`
  ```text
  PasswordAuthentication yes
  PermitRootLogin yes
  PubkeyAuthentication yes
  ```
  restart ssh with `sudo systemctl restart ssh`
  (!) if ssh is not working, change .conf file in `/etc/ssh/sshd_config.d` to .conf.disable to disable cloud-init configuration.


- VM remote-ssh config in VScode
  ``` text
  # Host Server
  Host <hostid>@<hostip:port>
      HostName <hostip>
      User <hostid>
      Port <port>

  # cxl_vmx
  Host cxl_vmx
      HostName 192.168.122.110
      User comsys
      ProxyJump <hostid>@<hostip:port>
  ```

- VM configuration with xml
  1. `sudo virsh dumpxml cxl_vmx > /path/to/VM/setting/cxl_vmx_96GB_2MB.xml` to dump xml files
  2. edit xml files following 
    ```xml
      ...
      <maxMemory slots='2' unit='KiB'>201326592</maxMemory> 
      <memory unit='KiB'>201326592</memory>
      <currentMemory unit='KiB'>201326592</currentMemory> <!-- 192 GB (100%) -->
      <vcpu placement='static'>16</vcpu>
      <cputune>
        <vcpupin vcpu='0' cpuset='1'/>
        <vcpupin vcpu='1' cpuset='3'/>
        <vcpupin vcpu='2' cpuset='5'/>
        <vcpupin vcpu='3' cpuset='7'/>
        <vcpupin vcpu='4' cpuset='9'/>
        <vcpupin vcpu='5' cpuset='11'/>
        <vcpupin vcpu='6' cpuset='13'/>
        <vcpupin vcpu='7' cpuset='15'/>
        <vcpupin vcpu='8' cpuset='33'/>
        <vcpupin vcpu='9' cpuset='35'/>
        <vcpupin vcpu='10' cpuset='37'/>
        <vcpupin vcpu='11' cpuset='39'/>
        <vcpupin vcpu='12' cpuset='41'/>
        <vcpupin vcpu='13' cpuset='43'/>
        <vcpupin vcpu='14' cpuset='45'/>
        <vcpupin vcpu='15' cpuset='47'/>
      </cputune>
      <numatune>
        <memory mode='strict' nodeset='0'/>
      </numatune>
      ...
        <cpu mode='host-passthrough' check='none' migratable='on'>
        <numa>
          <cell id='0' cpus='0-15' memory='100663296' unit='KiB'/> <!-- 96 GB (100%) -->
        </numa>
      </cpu>
      ...
      <devices>
      ...
        <memory model='nvdimm' access='shared'>
          <source>
            <path>/dev/dax0.0</path>
            <alignsize unit='KiB'>2048</alignsize>
            <pmem/>
          </source>
          <target>
            <size unit='KiB'>100663296</size>
            <node>0</node>
            <label>
              <size unit='KiB'>16384</size>
            </label>
          </target>
          <address type='dimm' slot='1'/>
        </memory>  
      </devices>
    ```
  3. `sudo virsh undefine cxl_vmx`
  4. `sudo virsh define cxl_vmx_96G_2MB.xml`

- (TODO) VM iptable configuration
  ```bash
  comsys@cloudcxl2:~$ sudo iptables -t nat -L --line-number -n
  Chain PREROUTING (policy ACCEPT)
  num  target     prot opt source               destination         
  1    DOCKER     all  --  0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
  2    DNAT       tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:8080 to:192.168.122.100:8080
  3    DNAT       tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:8081 to:192.168.122.101:8080

  Chain INPUT (policy ACCEPT)
  num  target     prot opt source               destination         

  Chain OUTPUT (policy ACCEPT)
  num  target     prot opt source               destination         
  1    DOCKER     all  --  0.0.0.0/0           !127.0.0.0/8          ADDRTYPE match dst-type LOCAL

  Chain POSTROUTING (policy ACCEPT)
  num  target     prot opt source               destination         
  1    MASQUERADE  all  --  172.17.0.0/16        0.0.0.0/0           
  2    LIBVIRT_PRT  all  --  0.0.0.0/0            0.0.0.0/0           
  3    MASQUERADE  all  --  172.19.0.0/16        0.0.0.0/0           
  4    MASQUERADE  all  --  172.18.0.0/16        0.0.0.0/0           

  Chain DOCKER (2 references)
  num  target     prot opt source               destination         
  1    RETURN     all  --  0.0.0.0/0            0.0.0.0/0           

  Chain LIBVIRT_PRT (1 references)
  num  target     prot opt source               destination         
  1    RETURN     all  --  192.168.122.0/24     224.0.0.0/24        
  2    RETURN     all  --  192.168.122.0/24     255.255.255.255     
  3    MASQUERADE  tcp  --  192.168.122.0/24    !192.168.122.0/24     masq ports: 1024-65535
  4    MASQUERADE  udp  --  192.168.122.0/24    !192.168.122.0/24     masq ports: 1024-65535
  5    MASQUERADE  all  --  192.168.122.0/24    !192.168.122.0/24    
  6    RETURN     all  --  192.168.122.0/24     224.0.0.0/24        
  7    RETURN     all  --  192.168.122.0/24     255.255.255.255     
  8    MASQUERADE  tcp  --  192.168.122.0/24    !192.168.122.0/24     masq ports: 1024-65535
  9    MASQUERADE  udp  --  192.168.122.0/24    !192.168.122.0/24     masq ports: 1024-65535
  10   MASQUERADE  all  --  192.168.122.0/24    !192.168.122.0/24
  ```
  ```bash
  comsys@cloudcxl2:~$ sudo iptables -L FORWARD -n -v --line-numbers
  Chain FORWARD (policy DROP 0 packets, 0 bytes)
  num   pkts bytes target     prot opt in     out     source               destination         
  1        0     0 ACCEPT     tcp  --  *      *       0.0.0.0/0            192.168.122.100      tcp dpt:8080
  2        0     0 ACCEPT     tcp  --  *      *       0.0.0.0/0            192.168.122.101      tcp dpt:8080
  3    2139K 2631M DOCKER-USER  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
  4    2139K 2631M DOCKER-ISOLATION-STAGE-1  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
  5        0     0 ACCEPT     all  --  *      docker0  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
  6        0     0 DOCKER     all  --  *      docker0  0.0.0.0/0            0.0.0.0/0           
  7        0     0 ACCEPT     all  --  docker0 !docker0  0.0.0.0/0            0.0.0.0/0           
  8        0     0 ACCEPT     all  --  docker0 docker0  0.0.0.0/0            0.0.0.0/0           
  9    2139K 2631M LIBVIRT_FWX  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
  10   2139K 2631M LIBVIRT_FWI  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
  11   1105K 1628M LIBVIRT_FWO  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
  12       0     0 ACCEPT     all  --  *      br-ebf3efdace98  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
  13       0     0 DOCKER     all  --  *      br-ebf3efdace98  0.0.0.0/0            0.0.0.0/0           
  14       0     0 ACCEPT     all  --  br-ebf3efdace98 !br-ebf3efdace98  0.0.0.0/0            0.0.0.0/0           
  15       0     0 ACCEPT     all  --  br-ebf3efdace98 br-ebf3efdace98  0.0.0.0/0            0.0.0.0/0           
  16       0     0 ACCEPT     all  --  *      br-a91b28eefef2  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
  17       0     0 DOCKER     all  --  *      br-a91b28eefef2  0.0.0.0/0            0.0.0.0/0           
  18       0     0 ACCEPT     all  --  br-a91b28eefef2 !br-a91b28eefef2  0.0.0.0/0            0.0.0.0/0           
  19       0     0 ACCEPT     all  --  br-a91b28eefef2 br-a91b28eefef2  0.0.0.0/0            0.0.0.0/0   
  ```

## devdax device (emulated CXL shared memory) setup in VM
- prerequisite  
  first, `sudo cat /proc/iomem | grep Persistent` must show output like `1880000000-307effffff : Persistent Memory`  
  second,
  ```bash
  sudo apt update
  sudo apt install linux-modules-extra-$(uname -r)
  sudo apt install -y libcxl1 libdaxctl1 libiniparser1 libndctl6 ndctl
  sudo apt install daxctl
  ```
  and `sudo reboot now`
- modeprobe
  ```bash
  sudo modprobe nd_pmem
  sudo modprobe dax_pmem
  # check module
  lsmod | grep -E 'nd_pmem|dax_pmem'
  ```
- ndctl
  ```bash
  sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=devdax --map=mem --size=103062437888
  # check device
  sudo ndctl list
  ```
- Change devdax device alignment from 2MB to 4KB  
  To change alignment of emulated CXL shared memory device, we should change
  - Host machine's kernel
    ```Diff
    --- a/drivers/dax/hmem/hmem.c
    +++ b/drivers/dax/hmem/hmem.c
    @@ -29,5 +29,5 @@
      mir = dev->platform_data;
      dax_region = alloc_dax_region(dev, pdev->id, &mri->range,
    -				      mri->target_node, PMD_SIZE, flags);
    +				      mri->target_node, PAGE_SIZE, flags);
      if (!dax_region)
        return -ENOMEM;
    ```
  - xml file
    ```Diff
    --- a/VM_setting/cxl_vmx_96GB_2MB.xml
    +++ b/VM_setting/cxl_vmx_96GB.xml
    @@ -216,5 +216,5 @@
        <source>
          <path>/dev/dax0.0</path>
    -     <alignsize unit='KiB'>2048</alignsize>
    +     <alignsize unit='KiB'>4</alignsize>
          <pmem/>
        </source>
    ```
  - VM's kernel
    ```Diff
    --- a/fs/fuse/famfs.c
    +++ b/fs/fuse/famfs.c
    @@ -1110,4 +1110,4 @@ 
    	  file_accessed(file);
	      vma->vm_ops = &famfs_file_vm_ops;
    -     vm_flags_set(vma, VM_HUGEPAGE);
    +     vm_flags_set(vma, VM_NOHUGEPAGE);
	      return 0;
    ``` 
  - device configuration with ndctl in VM
    ```bash
    sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=devdax --map=mem --size=103062437888 --align=4096
    # check with daxctl list
    ```
    to return back to 2MB alignment:
    `sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=devdax --map=mem --size=103062437888 --align=2097152`

## Change devdax device to uncachable region via intel MTRRs  
MTRR is configurable only with 2's power alignment, so make sure to offline host memory in uncachable region first.  
you need to check `/proc/iomem` output first to find the range of devdax device. (Soft Reserved)  
`sudo vim /etc/default/grub` and add `memmap=2G!320G` to `GRUB_CMDLINE_LINUX_DEFAULT` to make 320GB~322GB is offlined.  
and change MTRR settings in host machine
```bash
# check MTRR status
sudo cat /proc/mtrr

# set uncachable region for devdax device from 0x5080000000 to 0x687fffffff (322GB ~ 418GB)
echo "base=0x5000000000 size=0x1000000000 type=uncachable" | sudo tee /proc/mtrr
echo "base=0x6000000000 size=0x1000000000 type=uncachable" | sudo tee /proc/mtrr
```