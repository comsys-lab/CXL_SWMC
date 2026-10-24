# experiments/

Experiment specs: systems x workloads x parameters. Each run writes an
immutable result directory (outside Git: experiments/results/) with a manifest:
system (kernel submodule commit, release, .config hash, library commit),
workload version and parameters, inventory/VM config hash, timestamps, raw
outputs, parsed metrics. Comparisons read manifests only. Framework: later (P4).

chains/: the measurement run chains (eval2, knee sweep, lock split) and the VM topology tooling they call; see
chains/README.md.
