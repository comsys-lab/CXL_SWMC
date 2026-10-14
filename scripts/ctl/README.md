# scripts/ctl — Host entry point (not implemented yet)

One controller on the CPU Host drives every machine in config/inventory.yaml
over SSH, using the role scripts in scripts/{host,guest,gpu} and the system
definitions in systems/. Phases are separate commands:

| Phase | When | Examples |
| --- | --- | --- |
| provision | once per machine | packages, toolchains, FamFS userspace, dataset download |
| prepare | before each experiment | build/deploy kernel variant, boot, devdax/FamFS/cxl_shm/DAMON setup, start vLLM/TEI |
| run | benchmark only | run workload with fixed parameters |
| collect | after run | fetch raw outputs, write run manifest |

Approval-gated actions (VM lifecycle, sudo, shared CXL memory) keep their
approval requirements; the controller never bypasses them.
