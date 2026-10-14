#pragma once

#include "vector_db.h"
#include <httplib.h>

using json = nlohmann::json;

class VectorDBServer {
private:
    std::unique_ptr<VectorDB> vector_db_;
    std::unique_ptr<httplib::Server> server_;
    std::atomic<bool> running_;
    std::thread server_thread_;
    int port_;

public:
    VectorDBServer(const std::string& hnsw_path, const std::string& flat_path, int port = 8080);
    ~VectorDBServer();
    
    bool initialize();
    void start();
    void stop();
    
private:
    void setupRoutes();
    void handleInsert(const httplib::Request& req, httplib::Response& res);
    void handleSearch(const httplib::Request& req, httplib::Response& res);
    void handleStatus(const httplib::Request& req, httplib::Response& res);
    void runServer();
    
    // 유틸리티 함수
    json createErrorResponse(const std::string& message);
    json createSuccessResponse(const json& data = json::object());
};
