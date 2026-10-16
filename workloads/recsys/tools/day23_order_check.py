#!/usr/bin/env python3
"""Host-side check whether MLPerf day 23 (multi-hot npz) is in time order or shuffled (no timestamps in the data).

Proxy: id-set overlap (Jaccard) of the element-0 ids of 100k-sample windows, window at 0 vs windows at increasing
distance, for four 40M-row tables, plus CTR per window. A shuffled file gives the same overlap at every distance;
a time-ordered file gives overlap that falls with distance (temporal locality of ids). Shuffled control: the same
overlap between two random 100k-sample subsets of the whole day (what every distance would show if the file were
shuffled).
usage: day23_order_check.py <day23 dir>
"""
import os
import sys
import zipfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mlperf_npz_to_samples as m  # noqa: E402


def main():
    d = sys.argv[1]
    npz = f'{d}/day_23_sparse_multi_hot.npz'
    zf = zipfile.ZipFile(npz)
    w = 100000
    pos = [0, w, 2 * w, 10 * w, 100 * w, 44_000_000, 89_000_000, 133_000_000, 178_000_000]
    lab = np.load(f'{d}/day_23_labels.npy', mmap_mode='r')
    for k in (0, 9, 19, 21):
        a = m.npz_member(npz, zf, f'{k}.npy')
        sets = [set(np.asarray(a[p:p + w, 0]).tolist()) for p in pos]
        rng = np.random.default_rng(20261016 + k)
        r1, r2 = (set(np.asarray(a[np.sort(rng.choice(a.shape[0], w, replace=False)), 0]).tolist()) for _ in range(2))
        print(f'table {k}: jaccard(window@0, window@p):',
              ' '.join(f'{p}:{len(sets[0] & s) / len(sets[0] | s):.4f}' for p, s in zip(pos[1:], sets[1:])),
              f'| shuffled control (two random 100k subsets): {len(r1 & r2) / len(r1 | r2):.4f}')
    print('CTR per window:', ' '.join(f'{p}:{float(np.asarray(lab[p:p + w]).mean()):.4f}' for p in pos))


if __name__ == '__main__':
    main()
