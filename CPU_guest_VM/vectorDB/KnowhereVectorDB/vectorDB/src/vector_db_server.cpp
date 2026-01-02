#include "vector_db_server.h"
#include <iostream>
#include <sstream>
#include <algorithm>

// thread_local 버퍼들 정의
thread_local std::vector<float> VectorDBServer::worker_batch_buffer_;
thread_local std::vector<std::vector<float>> VectorDBServer::worker_queries_buffer_;
thread_local std::vector<int> VectorDBServer::worker_k_values_buffer_;

VectorDBServer::VectorDBServer(const std::string& hnsw_path, const std::string& flat_path, int port)
    : running_(false), port_(port), acceptor_(ioc_) {
    vector_db_ = std::make_unique<VectorDB>(hnsw_path, flat_path);
}

VectorDBServer::~VectorDBServer() {
    stop();
}

bool VectorDBServer::initialize() {
    std::cout << "=== VectorDB 서버 초기화 ===" << std::endl;
    
    // VectorDB 초기화
    if (!vector_db_->initialize()) {
        std::cerr << "Failed to initialize VectorDB" << std::endl;
        return false;
    }
    
    auto hardware_threads = std::thread::hardware_concurrency();

    search_pool_ = std::make_unique<net::thread_pool>(hardware_threads);
    
    // Search worker들 시작
    startSearchWorkers(hardware_threads);

    std::cout << "Using " << hardware_threads << " threads for search workers" << std::endl;
    
    std::cout << "VectorDB 서버 초기화 완료" << std::endl;
    return true;
}

void VectorDBServer::start() {
    if (running_.load()) {
        std::cout << "서버가 이미 실행 중입니다." << std::endl;
        return;
    }
    
    running_.store(true);
    
    try {
        // TCP acceptor 설정
        auto const address = net::ip::make_address("0.0.0.0");
        tcp::endpoint endpoint{address, static_cast<unsigned short>(port_)};
        
        acceptor_.open(endpoint.protocol());
        acceptor_.set_option(net::socket_base::reuse_address(true));
        acceptor_.bind(endpoint);
        acceptor_.listen(net::socket_base::max_listen_connections);
        
        std::cout << "VectorDB 서버 시작됨 - 포트: " << port_ << std::endl;
        std::cout << "API 엔드포인트:" << std::endl;
        std::cout << "  POST /api/vectors      - 벡터 삽입" << std::endl;
        std::cout << "  POST /api/search       - 벡터 검색 (HNSW approximate)" << std::endl;
        std::cout << "  POST /api/exact-search - 벡터 검색 (Brute-force exact)" << std::endl;
        std::cout << "  GET  /api/status       - 상태 조회" << std::endl;
        std::cout << "  GET  /health           - 헬스체크" << std::endl;
        
        // auto const threads = std::max(1u, std::thread::hardware_concurrency());
        auto const threads = std::thread::hardware_concurrency();
        std::cout << "Starting " << threads << " IO threads" << std::endl;
        ioc_threads_.reserve(threads);
        
        // Accept 시작
        startAccepting();
        
        // IO context 실행
        for(auto i = threads - 1; i > 0; --i) {
            ioc_threads_.emplace_back([this] { ioc_.run(); });
        }
        ioc_.run();  // 메인 스레드에서도 실행
        
    } catch (std::exception const& e) {
        std::cerr << "서버 시작 실패: " << e.what() << std::endl;
        running_.store(false);
    }
}

void VectorDBServer::stop() {
    if (!running_.load()) {
        return;
    }
    
    std::cout << "VectorDB 서버 종료 중..." << std::endl;
    
    running_.store(false);
    
    // Acceptor 닫기
    if (acceptor_.is_open()) {
        acceptor_.close();
    }
    
    // IO context 정지
    ioc_.stop();
    
    // IO 스레드들 조인
    for (auto& t : ioc_threads_) {
        if (t.joinable()) {
            t.join();
        }
    }
    ioc_threads_.clear();
    
    // Search workers 정지
    stopSearchWorkers();
    
    // Search pool 정지
    if (search_pool_) {
        search_pool_->join();
        search_pool_.reset();
    }
    
    std::cout << "VectorDB 서버 종료 완료" << std::endl;
}

void VectorDBServer::startSearchWorkers(int num_workers) {
    for (int i = 0; i < num_workers; ++i) {
        net::post(*search_pool_, [this] { searchWorkerLoop(); });
    }
    std::cout << "Started " << num_workers << " search worker threads" << std::endl;
}

void VectorDBServer::stopSearchWorkers() {
    // search_pool이 join()될 때 자동으로 모든 워커가 종료됨
    std::cout << "Stopping search workers..." << std::endl;
}

void VectorDBServer::searchWorkerLoop() {
    std::vector<SearchTask> current_batch;
    auto last_batch_time = std::chrono::high_resolution_clock::now();
    
    while (running_.load()) {
        SearchTask task;
        bool has_task = false;
        
        // 1. 가능한 많은 태스크를 배치에 수집
        while (current_batch.size() < MAX_BATCH_SIZE) {
            if (search_queue_.try_dequeue(task)) {
                current_batch.push_back(std::move(task));
                has_task = true;
            } else {
                break; // 더 이상 태스크가 없음
            }
        }
        
        auto now = std::chrono::high_resolution_clock::now();
        bool timeout_reached = (now - last_batch_time) >= BATCH_TIMEOUT;
        bool batch_full = current_batch.size() >= MAX_BATCH_SIZE;
        
        // 2. 배치 처리 조건 체크
        if (!current_batch.empty() && (batch_full || timeout_reached)) {
            processBatch(current_batch);
            current_batch.clear();
            last_batch_time = now;
        }
        
        // 3. 아무 작업이 없으면 짧게 대기
        if (!has_task && current_batch.empty()) {
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    }
    
    // 종료 시 남은 배치 처리
    if (!current_batch.empty()) {
        processBatch(current_batch);
    }
}

void VectorDBServer::processBatch(const std::vector<SearchTask>& batch) {
    if (batch.empty()) return;
    
    try {
        // 1. 배치 데이터 준비 (버퍼 재사용)
        worker_queries_buffer_.clear();
        worker_k_values_buffer_.clear();
        
        worker_queries_buffer_.reserve(batch.size());
        worker_k_values_buffer_.reserve(batch.size());
        
        for (const auto& task : batch) {
            worker_queries_buffer_.push_back(task.query_vector);
            worker_k_values_buffer_.push_back(task.k);
        }
        
        // 2. 배치 검색 수행
        auto start_time = std::chrono::high_resolution_clock::now();
        
        // 최대 k 값으로 배치 검색 (버퍼 재사용)
        int max_k = *std::max_element(worker_k_values_buffer_.begin(), worker_k_values_buffer_.end());
        auto batch_results = vector_db_->searchVectorsBatch(worker_queries_buffer_, max_k, worker_batch_buffer_);
        
        auto end_time = std::chrono::high_resolution_clock::now();
        auto total_time = std::chrono::duration_cast<std::chrono::microseconds>(end_time - start_time);
        
        // 3. 개별 결과를 각 콜백으로 전달
        for (size_t i = 0; i < batch.size(); ++i) {
            AsyncSearchResult result;
            
            // 요청된 k 값만큼만 결과 잘라서 전달
            int requested_k = worker_k_values_buffer_[i];
            if (i < batch_results.size()) {
                if (batch_results[i].size() > static_cast<size_t>(requested_k)) {
                    result.results.assign(batch_results[i].begin(), 
                                        batch_results[i].begin() + requested_k);
                } else {
                    result.results = batch_results[i];
                }
            }
            
            // 평균 시간 계산
            result.search_time = total_time / batch.size();
            
            // 콜백을 I/O 컨텍스트로 포스트
            net::post(ioc_, [callback = batch[i].callback, result = std::move(result)]() mutable {
                callback(std::move(result));
            });
        }
        
        total_processed_.fetch_add(batch.size());
        
        // 배치 처리 로그 (선택적)
        // std::cout << "Processed batch of " << batch.size() << " queries in " 
        //           << std::chrono::duration_cast<std::chrono::milliseconds>(total_time).count() 
        //           << " ms" << std::endl;
        
    } catch (const std::exception& e) {
        // 에러 시 모든 태스크에 에러 전달
        std::string error_msg = std::string("Batch search failed: ") + e.what();
        for (const auto& task : batch) {
            net::post(ioc_, [error_callback = task.error_callback, error_msg]() {
                error_callback(error_msg);
            });
        }
    }
}

void VectorDBServer::startAccepting() {
    acceptor_.async_accept(
        net::make_strand(ioc_),
        beast::bind_front_handler(&VectorDBServer::onAccept, this));
}

void VectorDBServer::onAccept(beast::error_code ec, tcp::socket socket) {
    if (ec) {
        if (ec != net::error::operation_aborted) {
            std::cerr << "Accept error: " << ec.message() << std::endl;
        }
        return;
    }
    
    // 새 세션 생성
    std::make_shared<HttpSession>(std::move(socket), this)->run();
    
    // 다음 연결 대기
    if (running_.load()) {
        startAccepting();
    }
}

// HTTP 응답 헬퍼 함수들
void VectorDBServer::handleRequest(
    http::request<http::string_body>&& req, 
    std::function<void(http::response<http::string_body>&&)> send_callback) {
    
    auto addCorsHeaders = [](auto& res) {
        res.set(http::field::access_control_allow_origin, "*");
        res.set(http::field::access_control_allow_methods, "GET, POST, PUT, DELETE, OPTIONS");
        res.set(http::field::access_control_allow_headers, "Content-Type, Authorization");
    };
    
    if (req.method() == http::verb::options) {
        http::response<http::string_body> res{http::status::ok, req.version()};
        addCorsHeaders(res);
        res.prepare_payload();
        return send_callback(std::move(res)); // 즉시 콜백 호출
    }
    
    std::string target = std::string(req.target());
    
    if (req.method() == http::verb::post && target == "/api/search") {
        // 이 함수는 이제 비동기적으로 동작하며, 완료되면 내부에서 send_callback을 호출합니다.
        return handleSearchRequest(req.body(), req, std::move(send_callback));
    }
    else if (req.method() == http::verb::post && target == "/api/exact-search") {
        // Exact search (brute-force) 엔드포인트
        return handleExactSearchRequest(req.body(), req, std::move(send_callback));
    }
    else if (req.method() == http::verb::get && target == "/api/status") {
        auto response = handleStatusRequest(req);
        addCorsHeaders(response);
        return send_callback(std::move(response)); // 즉시 콜백 호출
    }
    else if (req.method() == http::verb::get && target == "/health") {
        auto response = handleHealthRequest(req);
        addCorsHeaders(response);
        return send_callback(std::move(response)); // 즉시 콜백 호출
    }
    
    // 404 응답
    http::response<http::string_body> res{http::status::not_found, req.version()};
    res.set(http::field::content_type, "application/json");
    addCorsHeaders(res);
    res.body() = createErrorResponse("Endpoint not found").dump();
    res.prepare_payload();
    return send_callback(std::move(res)); // 즉시 콜백 호출
}

void VectorDBServer::handleSearchRequest(
    const std::string& body, 
    const http::request<http::string_body>& req, // 버전, keep_alive 등을 위해 req 참조 추가
    std::function<void(http::response<http::string_body>&&)> send_callback) {
    
    try {
        auto request_json = json::parse(body);
        
        // 쿼리 벡터 추출
        if (!request_json.contains("vector") || !request_json["vector"].is_array()) {
            http::response<http::string_body> res{http::status::bad_request, 11};
            res.set(http::field::content_type, "application/json");
            res.body() = createErrorResponse("Missing or invalid 'vector' field").dump();
            res.prepare_payload();
            return send_callback(std::move(res));
        }
        
        std::vector<float> query_vector = request_json["vector"].get<std::vector<float>>();
        
        // k 값 추출 (기본값: 10)
        int k = request_json.value("k", 10);
        if (request_json.contains("k") && request_json["k"].is_number_integer()) {
            k = request_json["k"].get<int>();
            if (k <= 0 || k > 1000) {
                http::response<http::string_body> res{http::status::bad_request, 11};
                res.set(http::field::content_type, "application/json");
                res.body() = createErrorResponse("k must be between 1 and 1000").dump();
                res.prepare_payload();
                return send_callback(std::move(res));
            }
        }

        // --- 여기가 비동기 처리의 핵심입니다 ---
        SearchTask task;
        task.request_id = std::to_string(std::chrono::high_resolution_clock::now().time_since_epoch().count());
        task.query_vector = std::move(query_vector);
        task.k = k;
        
        // [콜백 설정 1] 검색 성공 시
        task.callback = [this, version = req.version(), send_callback](AsyncSearchResult search_result) {
            // 이 코드는 워커 스레드에서 실행됩니다.
            json results_array = json::array();
            for (const auto& result : search_result.results) {
                results_array.push_back({{"id", result.id}, {"distance", result.distance}});
            }
            json data = {
                {"results", results_array},
                {"search_time_us", search_result.search_time.count()},
                {"total_results", search_result.results.size()},
            };
            
            http::response<http::string_body> res{http::status::ok, version};
            res.set(http::field::content_type, "application/json");
            res.body() = createSuccessResponse(data).dump();
            res.prepare_payload();
            
            // 중요: 네트워크 작업은 I/O 스레드에서 수행해야 합니다.
            // net::post를 사용해 I/O 컨텍스트로 작업을 다시 보냅니다.
            net::post(ioc_, [send_callback, res = std::move(res)]() mutable {
                send_callback(std::move(res));
            });
        };
        
        // [콜백 설정 2] 검색 실패 시
        task.error_callback = [this, version = req.version(), send_callback](const std::string& error_msg) {
            // 이 코드도 워커 스레드에서 실행됩니다.
            http::response<http::string_body> res{http::status::internal_server_error, version};
            res.set(http::field::content_type, "application/json");
            res.body() = createErrorResponse(error_msg).dump();
            res.prepare_payload();

            // 중요: 네트워크 작업은 I/O 스레드에서 수행해야 합니다.
            net::post(ioc_, [send_callback, res = std::move(res)]() mutable {
                send_callback(std::move(res));
            });
        };
        
        // 작업을 큐에 넣습니다. I/O 스레드는 여기서 블록되지 않고 즉시 다음 일을 처리하러 갑니다.
        search_queue_.enqueue(task);
        
    } catch (const std::exception& e) {
        // JSON 파싱 오류 등 즉시 에러를 반환할 수 있는 경우
        http::response<http::string_body> res{http::status::bad_request, req.version()};
        res.set(http::field::content_type, "application/json");
        res.body() = createErrorResponse(std::string("Invalid request: ") + e.what()).dump();
        res.prepare_payload();
        return send_callback(std::move(res));
    }
}

void VectorDBServer::handleExactSearchRequest(
    const std::string& body, 
    const http::request<http::string_body>& req,
    std::function<void(http::response<http::string_body>&&)> send_callback) {
    
    try {
        auto request_json = json::parse(body);
        
        // 쿼리 벡터 추출
        if (!request_json.contains("vector") || !request_json["vector"].is_array()) {
            http::response<http::string_body> res{http::status::bad_request, 11};
            res.set(http::field::content_type, "application/json");
            res.body() = createErrorResponse("Missing or invalid 'vector' field").dump();
            res.prepare_payload();
            return send_callback(std::move(res));
        }
        
        std::vector<float> query_vector = request_json["vector"].get<std::vector<float>>();
        
        // k 값 추출 (기본값: 10)
        int k = request_json.value("k", 10);
        if (request_json.contains("k") && request_json["k"].is_number_integer()) {
            k = request_json["k"].get<int>();
            if (k <= 0 || k > 1000) {
                http::response<http::string_body> res{http::status::bad_request, 11};
                res.set(http::field::content_type, "application/json");
                res.body() = createErrorResponse("k must be between 1 and 1000").dump();
                res.prepare_payload();
                return send_callback(std::move(res));
            }
        }

        // Exact search는 동기적으로 실행 (이미 충분히 무거운 작업이므로)
        // search_pool_에서 실행하여 I/O 스레드를 블록하지 않음
        net::post(*search_pool_, [this, 
                                   query_vector = std::move(query_vector), 
                                   k, 
                                   version = req.version(), 
                                   send_callback]() mutable {
            try {
                auto start_time = std::chrono::high_resolution_clock::now();
                
                // VectorDB의 exactSearchVectors 호출
                auto results = vector_db_->exactSearchVectors(query_vector, k);
                
                auto end_time = std::chrono::high_resolution_clock::now();
                auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end_time - start_time);
                
                // 결과를 JSON으로 변환
                json results_array = json::array();
                for (const auto& result : results) {
                    results_array.push_back({{"id", result.id}, {"distance", result.distance}});
                }
                
                json data = {
                    {"results", results_array},
                    {"search_time_us", duration.count()},
                    {"total_results", results.size()},
                    {"search_type", "exact_brute_force"}
                };
                
                http::response<http::string_body> res{http::status::ok, version};
                res.set(http::field::content_type, "application/json");
                res.body() = createSuccessResponse(data).dump();
                res.prepare_payload();
                
                // I/O 컨텍스트로 돌려보내서 응답 전송
                net::post(ioc_, [send_callback, res = std::move(res)]() mutable {
                    send_callback(std::move(res));
                });
                
            } catch (const std::exception& e) {
                http::response<http::string_body> res{http::status::internal_server_error, version};
                res.set(http::field::content_type, "application/json");
                res.body() = createErrorResponse(std::string("Exact search failed: ") + e.what()).dump();
                res.prepare_payload();
                
                net::post(ioc_, [send_callback, res = std::move(res)]() mutable {
                    send_callback(std::move(res));
                });
            }
        });
        
    } catch (const std::exception& e) {
        // JSON 파싱 오류 등 즉시 에러를 반환할 수 있는 경우
        http::response<http::string_body> res{http::status::bad_request, req.version()};
        res.set(http::field::content_type, "application/json");
        res.body() = createErrorResponse(std::string("Invalid request: ") + e.what()).dump();
        res.prepare_payload();
        return send_callback(std::move(res));
    }
}

http::response<http::string_body> VectorDBServer::handleStatusRequest(const http::request<http::string_body>& req) {
    json data = {
        {"flat_index_count", vector_db_->getFlatIndexCount()},
        {"flat_index_full", vector_db_->isFlatIndexFull()},
        {"server_running", running_.load()},
        {"port", port_},
        {"queue_size", search_queue_.size_approx()},
        {"total_processed", total_processed_.load()}
    };
    
    http::response<http::string_body> res{http::status::ok, req.version()};
    res.set(http::field::content_type, "application/json");
    res.body() = createSuccessResponse(data).dump();
    res.prepare_payload();
    return res;
}

http::response<http::string_body> VectorDBServer::handleHealthRequest(const http::request<http::string_body>& req) {
    json response = {
        {"status", "healthy"},
        {"timestamp", std::time(nullptr)}
    };
    
    http::response<http::string_body> res{http::status::ok, req.version()};
    res.set(http::field::content_type, "application/json");
    res.body() = response.dump();
    res.prepare_payload();
    return res;
}

json VectorDBServer::createErrorResponse(const std::string& message) {
    return {
        {"success", false},
        {"error", message},
        {"timestamp", std::time(nullptr)}
    };
}

json VectorDBServer::createSuccessResponse(const json& data) {
    json response = {
        {"success", true},
        {"timestamp", std::time(nullptr)}
    };
    
    if (!data.is_null() && !data.empty()) {
        response["data"] = data;
    }
    
    return response;
}

// HttpSession 구현
HttpSession::HttpSession(tcp::socket&& socket, VectorDBServer* server)
    : stream_(std::move(socket)), server_(server) {
}

void HttpSession::run() {
    net::dispatch(stream_.get_executor(),
                  beast::bind_front_handler(&HttpSession::doRead,
                                            shared_from_this()));
}

void HttpSession::doRead() {
    req_ = {};
    
    stream_.expires_after(std::chrono::seconds(30));
    
    http::async_read(stream_, buffer_, req_,
                     beast::bind_front_handler(&HttpSession::onRead,
                                               shared_from_this()));
}

void HttpSession::onRead(beast::error_code ec, std::size_t bytes_transferred) {
    boost::ignore_unused(bytes_transferred);
    
    if (ec == http::error::end_of_stream) {
        return doClose();
    }
    
    if (ec) {
        std::cerr << "Read error: " << ec.message() << std::endl;
        return;
    }
    
    // [수정] handleRequest 호출 방식 변경
    // handleRequest는 이제 즉시 반환되며, 작업이 완료되면 아래 람다 콜백이 호출됩니다.
    server_->handleRequest(std::move(req_), 
        // [self = shared_from_this()] 를 통해 비동기 작업 중 HttpSession 객체가 살아있도록 보장
        [self = shared_from_this()](http::response<http::string_body>&& res) {
            self->sendResponse(std::move(res));
        });
}

// [신규] 응답을 받아 비동기 쓰기를 시작하는 함수
void HttpSession::sendResponse(http::response<http::string_body>&& res) {
    res_ = std::move(res);

    // 응답을 보내기 전에 keep_alive 상태를 설정합니다.
    res_.keep_alive(req_.keep_alive());

    // std::cout << "Sending response, size: " << res_.body().size() << " bytes" << std::endl;
    
    http::async_write(
        stream_,
        res_,
        beast::bind_front_handler(
            &HttpSession::onWrite,
            shared_from_this(),
            res_.need_eof() // keep_alive가 아니면 연결을 닫도록 설정
        )
    );
}

void HttpSession::onWrite(bool close, beast::error_code ec, std::size_t bytes_transferred) {
    boost::ignore_unused(bytes_transferred);
    
    if (ec) {
        std::cerr << "Write error: " << ec.message() << std::endl;
        return;
    }
    
    // std::cout << "Response sent successfully, " << bytes_transferred << " bytes transferred" << std::endl;
    
    if (close) {
        std::cout << "Closing connection" << std::endl;
        return doClose();
    }
    
    // 다음 요청을 위해 응답 객체 초기화
    res_ = {};
    
    // std::cout << "Keep-alive connection, reading next request" << std::endl;
    doRead();
}

void HttpSession::doClose() {
    std::cout << "Closing HTTP session" << std::endl;
    beast::error_code ec;
    
    // 소켓 shutdown 시도
    stream_.socket().shutdown(tcp::socket::shutdown_send, ec);
    
    if (ec) {
        std::cerr << "Socket shutdown error: " << ec.message() << std::endl;
    }
    
    // 소켓 닫기
    stream_.socket().close(ec);
    
    if (ec) {
        std::cerr << "Socket close error: " << ec.message() << std::endl;
    }
}
