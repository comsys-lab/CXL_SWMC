#!/bin/bash

HOST_SIZE="${HOST_SIZE:-96GB}"
MODE="${MODE:-test}" # all, test

# enable DeStijl page replication
if [ "$MODE" == "all" ]; then
    sudo damo start --kdamond ./damo_yamls/replicate_all_${HOST_SIZE}.yaml
else
    sudo damo start --kdamond ./damo_yamls/replicate_test_${HOST_SIZE}.yaml
fi