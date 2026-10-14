#!/bin/bash
sed -i '/msize = FLAGS_num\*32L\*FLAGS_value_size\/10;/a\
\tstruct stat st;\
\tchar data_file[1024];\
\tsnprintf(data_file, sizeof(data_file), "%s/data.mdb", FLAGS_db);\
\tif (stat(data_file, &st) == 0 && st.st_size > msize) {\
\t\tmsize = st.st_size; /* Existing size + 1GB */\
\t}' ~/CXLSharedMemVM/LMDB/third_party/LMDB/dbbench/t_lmdb.c
