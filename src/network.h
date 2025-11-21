#ifndef NETWORK_H
#define NETWORK_H

#include <string>
#include <iostream>
#include <vector>

// Configures eth0 with static IP (QEMU defaults)
void ConfigureNetwork();

struct HttpOptions {
    std::string method = "GET";
    std::vector<std::string> headers;
    std::string data;
    std::string user_agent = "GeminiOS/0.2";
    std::string proxy; // host:port or user:pass@host:port
    std::string auth; // user:pass
    bool verbose = false;
    bool include_headers = false;
    bool head_only = false;
    bool follow_location = false;
    bool insecure = true;
    int max_redirects = 5;
    int timeout = 30;
};

// Generic HTTP Request
bool HttpRequest(const std::string& url, std::ostream& out, const HttpOptions& opts);

// Resolve Hostname to IP
std::string ResolveDNS(const std::string& host);

// Downloads a file from an HTTPS URL to a local path
bool DownloadFile(std::string url, const std::string& dest_path);

#endif // NETWORK_H