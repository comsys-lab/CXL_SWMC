#!/bin/bash

##########################
###    Mode Choice    ####
##########################
MEM_CONFIG="96GB_De_Stijl"
MODE="tuning"  # "tuning" or "experiment"

##########################
###   공통 Parameter   ###
##########################
LANGCHAIN_IP="163.152.48.206"
LANGCHAIN_PORT=9000
DATASET="kroshan/BioASQ"
SLO=1
READ_WRITE_RATIO="2_1"   # 예: 9_1 = 90% read, 10% write
DOCUMENT_FILE="./Dataset/pubmed/pubmed_corpus.jsonl"  # main_writeadded.py의 --document-dir 인자로 전달되는 파일 경로

##########################
### Tuning용 Parameter ###
##########################
MAX_NUM_CLIENTS=1000
TUNING_DURATION=80
TUNING_ACCURACY=25 # client 개수 100 개까지의 정확도로 tuning 수행

##############################
### Experiment용 Parameter ###
##############################
NUM_CLIENTS_LIST=(10)
EXPERIMENT_DURATION=330  # 5 minutes + 30 seconds warmup

#######################
### Result 저장 위치 ###
#######################
RESULT_BASE=./results/$(date +%y%m%d)/${MEM_CONFIG}
TUNING_BASE=$RESULT_BASE/tuning_writeadded
EXPERIMENT_BASE=$RESULT_BASE/experiment_writeadded

#################
### functions ###
#################

# RESULT_DIR은 이 .sh를 실행할때마다 새로 설정됨.
function create_result_dir() {
    if [ ! -d "$RESULT_BASE" ]; then
        mkdir -p "$RESULT_BASE"
    fi

    last_clients="${NUM_CLIENTS_LIST[${#NUM_CLIENTS_LIST[@]}-1]}"

    if [ "$MODE" == "tuning" ]; then
        tuning_subdir=$TUNING_BASE/max_clients_${MAX_NUM_CLIENTS}_rw_${READ_WRITE_RATIO}
        if [ ! -d "$tuning_subdir" ]; then
            mkdir -p "$tuning_subdir"
        fi
        # SUBDIR내에 몇개의 attempt가 있는지 확인해서, 현재 attempt 생성
        attempt_num=$(ls -l "$tuning_subdir" | grep '^d' | wc -l)
        RESULT_DIR=$tuning_subdir/attempt_$((attempt_num + 1))
        mkdir -p "$RESULT_DIR"
    else
        experiment_subdir=$EXPERIMENT_BASE/clients_${NUM_CLIENTS_LIST[0]}_to_${last_clients}_rw_${READ_WRITE_RATIO}
        if [ ! -d "$experiment_subdir" ]; then
            mkdir -p "$experiment_subdir"
        fi
        # SUBDIR내에 몇개의 attempt가 있는지 확인해서, 현재 attempt 생성
        attempt_num=$(ls -l "$experiment_subdir" | grep '^d' | wc -l)
        RESULT_DIR=$experiment_subdir/attempt_$((attempt_num + 1))
        mkdir -p "$RESULT_DIR"
    fi
}


function run_tuning() {
    echo "=== Tuning(writeadded) 모드 실행 ==="
    echo "최대 Client 수: $MAX_NUM_CLIENTS"
    echo "Tuning Duration: $TUNING_DURATION 초"
    echo "Tuning Accuracy: ±$TUNING_ACCURACY clients"
    echo "SLO: $SLO 초"
    echo "Read/Write 비율: $READ_WRITE_RATIO"
    echo "Document 파일: $DOCUMENT_FILE"
    echo "==============================="

    stop=0
    curr_clients=${MAX_NUM_CLIENTS}
    delta=$((curr_clients / 2))

    while [ $stop -eq 0 ];
    do
        echo "현재 Client 수: $curr_clients"
        numactl --cpunodebind=1 --membind=1 \
        python3 main_writeadded.py --num-clients "$curr_clients" \
                                   --duration "$TUNING_DURATION" \
                                   --host "$LANGCHAIN_IP" \
                                   --port "$LANGCHAIN_PORT" \
                                   --slo "$SLO" \
                                   --dataset "$DATASET" \
                                   --read-write "$READ_WRITE_RATIO" \
                                   --document-dir "$DOCUMENT_FILE" > "$RESULT_DIR/reqgen_writeadded_${curr_clients}_clients.log" 2>&1

        ## Binary search
        if grep -q "부하 테스트가 조기 종료되었습니다!" "$RESULT_DIR/reqgen_writeadded_${curr_clients}_clients.log"; then
            echo "조기 종료 감지, client 수 감소"
            curr_clients=$((curr_clients - delta))
            delta=$((delta / 2))
        else
            rps=$(grep "전체 Requests Per Second (RPS):" "$RESULT_DIR/reqgen_writeadded_${curr_clients}_clients.log" | tail -1 | awk '{print $6}')
            p99ttft=$(grep "99%ile Tail:" "$RESULT_DIR/reqgen_writeadded_${curr_clients}_clients.log" | grep "초" | awk '{print $4}')
            echo "Client 수: $curr_clients, RPS: $rps, p99 TTFT: $p99ttft 초"

            if (( $(echo "$p99ttft > $SLO" | bc -l) )); then
                echo "p99 TTFT가 SLO 초과, client 수 감소"
                curr_clients=$((curr_clients - delta))
                delta=$((delta / 2))
                continue
            else
                if (( $(echo "$delta <= $TUNING_ACCURACY" | bc -l) )); then
                    echo "목표 정확도 달성, tuning 종료"
                    stop=1
                else
                    echo "목표 정확도 미달성, client 수 증가"
                    curr_clients=$((curr_clients + delta))
                    delta=$((delta / 2))
                fi
            fi
        fi
    done
    echo "=== Tuning(writeadded) 모드 종료 ==="
}

function run_experiment() {
    echo "=== Experiment(writeadded) 모드 실행 ==="
    echo "Client 수 리스트: ${NUM_CLIENTS_LIST[@]}"
    echo "Experiment Duration: $EXPERIMENT_DURATION 초"
    echo "SLO: $SLO 초"
    echo "Read/Write 비율: $READ_WRITE_RATIO"
    echo "Document 파일: $DOCUMENT_FILE"
    echo "==================================="

    for clients in "${NUM_CLIENTS_LIST[@]}"; do
        curr_clients=$clients
        echo "현재 Client 수: $curr_clients"
        numactl --cpunodebind=1 --membind=1 \
        python3 main_writeadded.py --num-clients "$curr_clients" \
                                   --duration "$EXPERIMENT_DURATION" \
                                   --host "$LANGCHAIN_IP" \
                                   --port "$LANGCHAIN_PORT" \
                                   --slo "$SLO" \
                                   --dataset "$DATASET" \
                                   --read-write "$READ_WRITE_RATIO" \
                                   --document-dir "$DOCUMENT_FILE" > "$RESULT_DIR/reqgen_writeadded_${curr_clients}_clients.log" 2>&1
        echo "Client 수 $curr_clients 에 대한 실험 완료, 결과는 $RESULT_DIR 에 저장됨"
    done
    echo "=== Experiment(writeadded) 모드 종료 ==="
}

if [ "$MODE" == "tuning" ]; then
    create_result_dir
    run_tuning
    exit 0
fi

if [ "$MODE" == "experiment" ]; then
    create_result_dir
    run_experiment
    exit 0
fi