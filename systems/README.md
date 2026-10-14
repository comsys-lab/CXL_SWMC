# systems/

One directory per coherence system. `system.yaml` names what the system runs
on (kernel submodule + config + LOCALVERSION, or a user-level library) and the
guest setup it needs. System-specific setup and per-workload adapters live here,
so workloads stay unchanged across systems.

    systems/<system>/system.yaml
    systems/<system>/setup/        guest/host preparation specific to the system
    systems/<system>/adapters/<workload>/   API/initialization differences
