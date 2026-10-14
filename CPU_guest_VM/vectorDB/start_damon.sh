#!/bin/bash

HOST_SIZE="24GB"
MODE="test" # all, test

# enable DeStijl page replication
if [ "$MODE" == "test" ]; then
    sudo damo start --kdamond ./damo_yamls/replicate_all_${HOST_SIZE}.yaml
else
    sudo damo start --kdamond ./damo_yamls/replicate_test_${HOST_SIZE}.yaml
fi