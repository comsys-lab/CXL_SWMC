# CXL_SWMC

<img width="1447" height="880" alt="image" src="https://github.com/user-attachments/assets/8e3260f1-492c-4b36-913d-f65196cf6b24" />


- 위 그림에서 회색 박스는 RAG 서버의 component를 뜻하며, 검은 화살표로 연결된 component 끼리는 network로 통신함.
- 실험 환경 setup은 GPU server, CPU server-socket0, CPU server-socket1 세 가지로 나누어서 설명함.

## CPU Server

### HW/SW Requirements

- HW
    - **CPU**: 2× Intel Xeon 6426Y (Sapphire Rapids)
      - 16 cores @ 2.5 GHz
      - 37.5 MiB LLC per CPU, HT Enabled
    - **Memory**: Total 320 GB DDR5 + 96 GB CXL
      - **Socket 0**: 4× 32 GB DDR5-4800 (256 GB)
      - **Socket 1**: 4× 16 GB DDR5-4000 (64 GB)
      - **CXL Expander**: 96 GB (PCIe 5.0 ×8, Socket 0)
- SW
    - ubuntu 22.04 LTS
    - Qemu
    - kvm
    - python 3.11

### Socket 0 Overview

<img width="1187" height="900" alt="image" src="https://github.com/user-attachments/assets/530f0e75-a2ad-4b7a-940c-87ba6a12edcb" />


- CPU Server socket 0는 2 개의 VM을 구동하고, 각 VM이 CXL memory expander를 CXL shared memory로 인식할 수 있도록 emulation함.
- 각 VM에서는 vectorDB가 실행되며, CXL shared memory 내에 external knowledge를 저장하고 있음.

### Socket 1 Overview

- Request generator, Orchestrator는 python 기반 환경에서 동작함.
- 따라서, CPU Server가 아니라, GPU 서버는 물론 다른 서버에서도 동작 가능함.
- 실험 스크립트는 Request generator 쪽에서 실행함. 
        

### 역할

- Host Machine
    - Kernel: CXL을 devdax device로 인식하게 하고, devdax device의 alignment를 2 MB로 할지, 4 KB로 할 지 결정해줌.
        - MTRR 기반으로 CXL memory를 uncacheable memory로 지정함.
    - QEMU-KVM: VM을 구동하고, 각 VM에게 알맞은 HW resource를 할당해줌.
- Guest VM
    - kernel: CXL shared memory에 대한 page fault를 handling함.
        - Popcorn-2MB
        - Popcorn-4KB
        - MTRR
        - De Stijl
    - VectorDB: CXL shared memory에 존재하는 external knowledge를 file-backed mmap으로 사용해서 ANNS 수행

## GPU Server

### HW/SW Requirements

- HW
    - **CPU**: 2× Intel Xeon 4410Y (Sapphire Rapids)
      - 12 cores per CPU @ 2.5 GHz (Total 24C/48T)
      - 30 MiB LLC per CPU, Hyper-Threading Enabled
    - **Memory**: Total 256 GB DDR5-4800 MT/s
      - **Socket 0**: 128 GB (2× 64 GB)
      - **Socket 1**: 128 GB (2× 64 GB)
    - **GPU**: 2× NVIDIA GeForce RTX 4090
- SW
    - ubuntu 22.04 LTS
    - python 3.11
