#include "vector_db_server.h"
#include <iostream>
#include <csignal>
#include <memory>

std::unique_ptr<VectorDBServer> g_server;

void signalHandler(int signal) {
    std::cout << "\n시그널 수신: " << signal << std::endl;
    if (g_server) {
        g_server->stop();
    }
    exit(0);
}

int main(int argc, char* argv[]) {
    // 시그널 핸들러 등록
    std::signal(SIGINT, signalHandler);
    std::signal(SIGTERM, signalHandler);
    
    std::cout << "=== VectorDB 서버 시작 ===" << std::endl;
    
    // 기본 파라미터
    std::string hnsw_dir = "../knowhere_cpp";
    std::string flat_path = "flat_index.bin";
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
    
    std::cout << "설정:" << std::endl;
    std::cout << "  HNSW 인덱스 디렉토리: " << hnsw_dir << std::endl;
    std::cout << "  Flat 인덱스: " << flat_path << std::endl;
    std::cout << "  포트: " << port << std::endl;
    
    try {
        // 서버 생성 및 초기화
        g_server = std::make_unique<VectorDBServer>(hnsw_dir, flat_path, port);
        
        if (!g_server->initialize()) {
            std::cerr << "서버 초기화 실패" << std::endl;
            return 1;
        }
        
        // 서버 시작
        g_server->start();
        
        std::cout << "\n서버가 실행 중입니다. Ctrl+C로 종료하세요." << std::endl;
        
        // 메인 스레드는 대기
        while (true) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
        
    } catch (const std::exception& e) {
        std::cerr << "오류: " << e.what() << std::endl;
        return 1;
    }
    
    return 0;
}
