#include "vector_db_server.h"
#include <iostream>
#include <csignal>
#include <memory>
#include <atomic>
#include <thread>
#include <chrono>

std::unique_ptr<VectorDBServer> g_server;
std::atomic<bool> g_stop_requested{false};

void signalHandler(int signal) {
    (void)signal;
    // Signal handlers must stay minimal and async-signal-safe.
    g_stop_requested.store(true);
}

int main(int argc, char* argv[]) {
    // 시그널 핸들러 등록
    std::signal(SIGINT, signalHandler);
    std::signal(SIGTERM, signalHandler);
    
    std::cout << "=== VectorDB 서버 시작 ===" << std::endl;
    
    // 기본 파라미터
    std::string hnsw_dir = "../knowhere_cpp";
    std::string flat_path = "flat_index.bin";
    std::string index_type = "hnsw";
    int port = 8080;
    
    // 명령행 인수 처리
    if (argc >= 2) {
        hnsw_dir = argv[1];
    }
    if (argc >= 3) {
        flat_path = argv[2];
    }
    if (argc >= 4) {
        port = std::atoi(argv[3]);
    }
    if (argc >= 5) {
        index_type = argv[4];
    }

    if (index_type != "hnsw" && index_type != "ivf") {
        std::cerr << "지원하지 않는 index_type: " << index_type
                  << " (허용값: hnsw, ivf)" << std::endl;
        return 1;
    }
    
    std::cout << "설정:" << std::endl;
    std::cout << "  HNSW 인덱스 디렉토리: " << hnsw_dir << std::endl;
    std::cout << "  Flat 인덱스: " << flat_path << std::endl;
    std::cout << "  포트: " << port << std::endl;
    std::cout << "  ANN 인덱스 타입: " << index_type << std::endl;
    
    try {
        // 서버 생성 및 초기화
        g_server = std::make_unique<VectorDBServer>(hnsw_dir, flat_path, port, index_type);
        
        if (!g_server->initialize()) {
            std::cerr << "서버 초기화 실패" << std::endl;
            return 1;
        }
        
        std::cout << "\n서버가 실행 중입니다. Ctrl+C로 종료하세요." << std::endl;

        // 서버는 별도 스레드에서 실행하고, 메인 스레드가 종료 신호를 감시한다.
        std::thread server_thread([] {
            g_server->start();
        });

        while (!g_stop_requested.load()) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }

        std::cout << "\n종료 시그널 수신. 서버를 종료합니다..." << std::endl;
        g_server->stop();

        if (server_thread.joinable()) {
            server_thread.join();
        }
        
    } catch (const std::exception& e) {
        std::cerr << "오류: " << e.what() << std::endl;
        return 1;
    }
    
    return 0;
}
