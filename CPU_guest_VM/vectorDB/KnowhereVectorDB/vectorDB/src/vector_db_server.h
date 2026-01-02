#pragma once

#include "vector_db.h"
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/version.hpp>
#include <boost/asio/dispatch.hpp>
#include <boost/asio/strand.hpp>
#include <boost/asio/thread_pool.hpp>
#include <boost/config.hpp>
#include <concurrentqueue.h>
#include <nlohmann/json.hpp>
#include <memory>
#include <string>
#include <thread>
#include <atomic>
#include <chrono>

namespace beast = boost::beast;
namespace http = beast::http;
namespace net = boost::asio;
using tcp = boost::asio::ip::tcp;
using json = nlohmann::json;

class VectorDBServer {
private:
    // 배치 처리 상수
    static constexpr size_t MAX_BATCH_SIZE = 32;
    static constexpr std::chrono::milliseconds BATCH_TIMEOUT{10}; // 10ms
    
    // Worker별 재사용 버퍼들 (thread_local)
    static thread_local std::vector<float> worker_batch_buffer_;
    static thread_local std::vector<std::vector<float>> worker_queries_buffer_;
    static thread_local std::vector<int> worker_k_values_buffer_;
    
    // 기존 멤버들
    std::unique_ptr<VectorDB> vector_db_;
    std::atomic<bool> running_;
    int port_;

    // Beast/Asio 관련
    net::io_context ioc_;
    std::unique_ptr<net::thread_pool> search_pool_;
    tcp::acceptor acceptor_;
    std::vector<std::thread> ioc_threads_;

    // 비동기 처리를 위한 구조체
    struct AsyncSearchResult {
        std::vector<SearchResult> results;
        std::chrono::microseconds search_time;
    };

    struct SearchTask {
        std::string request_id;
        std::vector<float> query_vector;
        int k;
        std::function<void(AsyncSearchResult)> callback;
        std::function<void(std::string)> error_callback;
    };
    
    // Lock-free queue
    moodycamel::ConcurrentQueue<SearchTask> search_queue_;
    
    // 통계
    std::atomic<size_t> queue_size_{0};
    std::atomic<size_t> total_processed_{0};

public:
    VectorDBServer(const std::string& hnsw_path, const std::string& flat_path, int port = 8080);
    ~VectorDBServer();
    
    bool initialize();
    void start();
    void stop();
    
    void handleRequest(
        http::request<http::string_body>&& req, 
        std::function<void(http::response<http::string_body>&&)> send_callback);
    
private:
    void startSearchWorkers(int num_workers = 64);
    void stopSearchWorkers();
    void searchWorkerLoop();
    void processBatch(const std::vector<SearchTask>& batch);
    
    void startAccepting();
    void onAccept(beast::error_code ec, tcp::socket socket);
    
    // 유틸리티 함수들
    json createErrorResponse(const std::string& message);
    json createSuccessResponse(const json& data = json::object());
    
    // API 핸들러들도 콜백을 받도록 시그니처를 변경합니다.
    void handleSearchRequest(
        const std::string& body, 
        const http::request<http::string_body>& req,
        std::function<void(http::response<http::string_body>&&)> send_callback);
    
    void handleExactSearchRequest(
        const std::string& body, 
        const http::request<http::string_body>& req,
        std::function<void(http::response<http::string_body>&&)> send_callback);
        
    // 이 핸들러들은 간단하므로 동기적으로 응답을 생성하고 바로 콜백을 호출합니다.
    http::response<http::string_body> handleStatusRequest(const http::request<http::string_body>& req);
    http::response<http::string_body> handleHealthRequest(const http::request<http::string_body>& req);
};

// HTTP 세션 클래스
class HttpSession : public std::enable_shared_from_this<HttpSession> {
private:
    beast::tcp_stream stream_;
    beast::flat_buffer buffer_;
    http::request<http::string_body> req_;
    http::response<http::string_body> res_;  // 응답 객체를 멤버로 유지
    VectorDBServer* server_;

public:
    HttpSession(tcp::socket&& socket, VectorDBServer* server);
    void run();

private:
    void doRead();
    void onRead(beast::error_code ec, std::size_t bytes_transferred);

    void sendResponse(http::response<http::string_body>&& response);

    void onWrite(bool close, beast::error_code ec, std::size_t bytes_transferred);
    void doClose();
};
