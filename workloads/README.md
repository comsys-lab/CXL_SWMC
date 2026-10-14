# workloads/

Workloads run unchanged on every system; system differences belong in
systems/<system>/adapters. Datasets, model weights and results are never committed.

| Workload | Contents |
| --- | --- |
| rag | gpu/ (LangChain, TEI, vLLM, benchmark, Dataset scripts), vectordb/ (Knowhere vector DB, CPU/guest), reqgen/ (Host request generator) |
| lmdb | LMDB db_bench scripts (guest) |
| microbench | dax_test (guest), dax_setting (Host) |
| recommendation, pagerank | planned |

Note: imported scripts still use absolute guest paths (/home/comsys/CXLSharedMemVM/...).
