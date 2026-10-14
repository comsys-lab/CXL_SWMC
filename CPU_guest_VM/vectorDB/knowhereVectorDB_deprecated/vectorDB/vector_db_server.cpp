#include "vector_db_server.h"
#include <iostream>
#include <sstream>

VectorDBServer::VectorDBServer(const std::string& hnsw_path, const std::string& flat_path, int port)
    : running_(false), port_(port) {
    vector_db_ = std::make_unique<VectorDB>(hnsw_path, flat_path);
    server_ = std::make_unique<httplib::Server>();
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
    
    // HTTP 서버 라우트 설정
    setupRoutes();
    
    std::cout << "VectorDB 서버 초기화 완료" << std::endl;
    return true;
}

void VectorDBServer::setupRoutes() {
    // CORS 헤더 설정
    server_->set_pre_routing_handler([](const httplib::Request&, httplib::Response& res) {
        res.set_header("Access-Control-Allow-Origin", "*");
        res.set_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        res.set_header("Access-Control-Allow-Headers", "Content-Type, Authorization");
        return httplib::Server::HandlerResponse::Unhandled;
    });
    
    // OPTIONS 요청 처리 (CORS preflight)
    server_->Options(".*", [](const httplib::Request&, httplib::Response& res) {
        return;
    });
    
    // 벡터 삽입 API
    server_->Post("/api/vectors", [this](const httplib::Request& req, httplib::Response& res) {
        handleInsert(req, res);
    });
    
    // 벡터 검색 API
    server_->Post("/api/search", [this](const httplib::Request& req, httplib::Response& res) {
        handleSearch(req, res);
    });
    
    // 상태 조회 API
    server_->Get("/api/status", [this](const httplib::Request& req, httplib::Response& res) {
        handleStatus(req, res);
    });
    
    // 헬스체크 API
    server_->Get("/health", [](const httplib::Request&, httplib::Response& res) {
        json response = {
            {"status", "healthy"},
            {"timestamp", std::time(nullptr)}
        };
        res.set_content(response.dump(), "application/json");
    });
    
    std::cout << "HTTP 라우트 설정 완료" << std::endl;
}

void VectorDBServer::handleInsert(const httplib::Request& req, httplib::Response& res) {
    try {
        // JSON 파싱
        auto request_json = json::parse(req.body);
        
        // 벡터 데이터 추출
        if (!request_json.contains("vector") || !request_json["vector"].is_array()) {
            res.status = 400;
            res.set_content(createErrorResponse("Missing or invalid 'vector' field").dump(), "application/json");
            return;
        }
        
        std::vector<float> vector = request_json["vector"].get<std::vector<float>>();
        
        // 벡터 삽입
        uint64_t assigned_id;
        bool success = vector_db_->insertVector(vector, assigned_id);
        
        if (success) {
            json response = createSuccessResponse({
                {"id", assigned_id},
                {"message", "Vector inserted successfully"}
            });
            res.set_content(response.dump(), "application/json");
        } else {
            res.status = 503;
            json response = createErrorResponse("Failed to insert vector (possibly full)");
            res.set_content(response.dump(), "application/json");
        }
        
    } catch (const json::exception& e) {
        res.status = 400;
        res.set_content(createErrorResponse("Invalid JSON format").dump(), "application/json");
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(createErrorResponse("Internal server error").dump(), "application/json");
    }
}

void VectorDBServer::handleSearch(const httplib::Request& req, httplib::Response& res) {
    try {
        // JSON 파싱
        auto request_json = json::parse(req.body);
        
        // 쿼리 벡터 추출
        if (!request_json.contains("vector") || !request_json["vector"].is_array()) {
            res.status = 400;
            res.set_content(createErrorResponse("Missing or invalid 'vector' field").dump(), "application/json");
            return;
        }
        
        std::vector<float> query_vector = request_json["vector"].get<std::vector<float>>();
        
        // k 값 추출 (기본값: 10)
        int k = 10;
        if (request_json.contains("k") && request_json["k"].is_number_integer()) {
            k = request_json["k"].get<int>();
            if (k <= 0 || k > 1000) {
                res.status = 400;
                res.set_content(createErrorResponse("k must be between 1 and 1000").dump(), "application/json");
                return;
            }
        }
        
        // 검색 수행
        auto start_time = std::chrono::high_resolution_clock::now();
        auto search_results = vector_db_->searchVectors(query_vector, k);
        auto end_time = std::chrono::high_resolution_clock::now();
        
        auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end_time - start_time);
        
        // 결과 JSON 구성
        json results_array = json::array();
        for (const auto& result : search_results) {
            results_array.push_back({
                {"id", result.id},
                {"distance", result.distance}
            });
        }
        
        json response = createSuccessResponse({
            {"results", results_array},
            {"search_time_us", duration.count()},
            {"total_results", search_results.size()}
        });
        
        res.set_content(response.dump(), "application/json");
        
    } catch (const json::exception& e) {
        res.status = 400;
        res.set_content(createErrorResponse("Invalid JSON format").dump(), "application/json");
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(createErrorResponse("Internal server error").dump(), "application/json");
    }
}

void VectorDBServer::handleStatus(const httplib::Request& req, httplib::Response& res) {
    try {
        json response = createSuccessResponse({
            {"flat_index_count", vector_db_->getFlatIndexCount()},
            {"flat_index_full", vector_db_->isFlatIndexFull()},
            {"server_running", running_.load()},
            {"port", port_}
        });
        
        res.set_content(response.dump(), "application/json");
        
    } catch (const std::exception& e) {
        res.status = 500;
        res.set_content(createErrorResponse("Internal server error").dump(), "application/json");
    }
}

void VectorDBServer::start() {
    if (running_.load()) {
        std::cout << "서버가 이미 실행 중입니다." << std::endl;
        return;
    }
    
    running_.store(true);
    
    // 별도 스레드에서 서버 실행
    server_thread_ = std::thread(&VectorDBServer::runServer, this);
    
    std::cout << "VectorDB 서버 시작됨 - 포트: " << port_ << std::endl;
    std::cout << "API 엔드포인트:" << std::endl;
    std::cout << "  POST /api/vectors  - 벡터 삽입" << std::endl;
    std::cout << "  POST /api/search   - 벡터 검색" << std::endl;
    std::cout << "  GET  /api/status   - 상태 조회" << std::endl;
    std::cout << "  GET  /health       - 헬스체크" << std::endl;
}

void VectorDBServer::stop() {
    if (!running_.load()) {
        return;
    }
    
    std::cout << "VectorDB 서버 종료 중..." << std::endl;
    
    running_.store(false);
    
    if (server_) {
        server_->stop();
    }
    
    if (server_thread_.joinable()) {
        server_thread_.join();
    }
    
    std::cout << "VectorDB 서버 종료 완료" << std::endl;
}

void VectorDBServer::runServer() {
    std::cout << "HTTP 서버 시작 중 - 포트: " << port_ << std::endl;
    
    if (!server_->listen("0.0.0.0", port_)) {
        std::cerr << "서버 시작 실패 - 포트: " << port_ << std::endl;
        running_.store(false);
    }
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
