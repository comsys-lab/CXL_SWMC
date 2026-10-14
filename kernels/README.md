# kernels/

Each directory is a submodule with its own branch and working tree, so the
kernels can be edited and built independently and at the same time.

| Directory | Repository | Branch | Base |
| --- | --- | --- | --- |
| destijl | github.com/youkioh/CXLSHMSWcoherence | DE_STIJL_DAMON | 122d22dc (tag rel/destijl-p3a) |
| popcorn_new | github.com/youkioh/CXLSHMSWcoherence | popcorn_new | branched from 122d22dc |
| linux-6.14 | github.com/torvalds/linux (shallow) | vanilla-6.14 (local) | tag v6.14, commit 38fec10eb60d |

Kernel source is `famfs-linux/` in destijl and popcorn_new (plus
`msg_layer_module/`, `unittest/`, `userspace_tool/`), and the repo root in linux-6.14.

popcorn_new = De Stijl without selective replication and asynchronous
transaction handling; keeps PTE/MMU-fault transition detection, struct page
coherence metadata and inter-kernel messaging transactions. Shared fixes move
between destijl and popcorn_new only by explicit `cherry-pick -x` or merge.

Rules
- Build out of tree only: `make -C kernels/<k>/<src> O=<builds>/<k>/<n>`;
  build outputs never go inside this repository.
- LOCALVERSION per kernel: `-ds-destijl-<n>`, `-ds-popcorn-new-<n>`,
  `-vanilla-<n>`; tag each built/deployed commit `rel/<kernel>-<n>`.
- Clone: `git clone --recurse-submodules --shallow-submodules <CXL_SWMC>`
  (linux-6.14 is marked shallow). Push kernel commits before the CXL_SWMC
  commit that references them.
