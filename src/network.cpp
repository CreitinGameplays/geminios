#include "network.h"
#include "signals.h"
#include "debug.h"
#include <iostream>
#include <vector>
#include <string>
#include <cstdio>
#include <cstring>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <net/route.h>
#include <netdb.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <fstream>
#include <cstdlib> // for atoi

// QEMU Default Network Settings
#define MY_IP "10.0.2.15"
#define GATEWAY "10.0.2.2"
#define NETMASK "255.255.255.0"
#define DNS_SERVER "10.0.2.3" // QEMU User Network DNS

void ConfigureNetwork() {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) return;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "eth0", IFNAMSIZ);

    // 1. Set IP Address
    struct sockaddr_in* addr = (struct sockaddr_in*)&ifr.ifr_addr;
    addr->sin_family = AF_INET;
    inet_pton(AF_INET, MY_IP, &addr->sin_addr);
    if (ioctl(sock, SIOCSIFADDR, &ifr) < 0) {
        perror("[NET] Failed to set IP");
        close(sock); return;
    }

    // 2. Bring Interface UP
    if (ioctl(sock, SIOCGIFFLAGS, &ifr) < 0) {
        perror("[NET] Failed to get flags");
        close(sock); return;
    }
    ifr.ifr_flags |= (IFF_UP | IFF_RUNNING);
    if (ioctl(sock, SIOCSIFFLAGS, &ifr) < 0) {
        perror("[NET] Failed to bring up eth0");
        close(sock); return;
    }

    // 3. Set Default Gateway (Legacy IOCTL method)
    struct rtentry route;
    memset(&route, 0, sizeof(route));
    
    struct sockaddr_in* dst = (struct sockaddr_in*)&route.rt_dst;
    dst->sin_family = AF_INET;
    dst->sin_addr.s_addr = INADDR_ANY;

    struct sockaddr_in* mask = (struct sockaddr_in*)&route.rt_genmask;
    mask->sin_family = AF_INET;
    mask->sin_addr.s_addr = INADDR_ANY;

    struct sockaddr_in* gw = (struct sockaddr_in*)&route.rt_gateway;
    gw->sin_family = AF_INET;
    inet_pton(AF_INET, GATEWAY, &gw->sin_addr);

    route.rt_flags = RTF_UP | RTF_GATEWAY;
    route.rt_dev = (char*)"eth0"; // Explicitly bind to eth0

    if (ioctl(sock, SIOCADDRT, &route) < 0) {
        if (errno != EEXIST) LOG_DEBUG("Failed to set gateway: " << strerror(errno));
    }

    close(sock);
    std::cout << "[NET] Network Configured: " << MY_IP << std::endl;
}

// Minimal DNS Resolver (UDP to 8.8.8.8)
std::string ResolveDNS(const std::string& host) {
    // Return immediately if it's already an IP
    struct sockaddr_in sa;
    if (inet_pton(AF_INET, host.c_str(), &(sa.sin_addr)) != 0) return host;

    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if(sock < 0) return "";

    struct sockaddr_in dest;
    dest.sin_family = AF_INET;
    dest.sin_port = htons(53);
    inet_pton(AF_INET, DNS_SERVER, &dest.sin_addr);

    // DNS Query Construction (Header + QNAME + QTYPE + QCLASS)
    unsigned char buf[512];
    memset(buf, 0, 512);
    
    // Header: ID=0x1234, Flags=0x0100 (Standard Query), QDCOUNT=1
    buf[0] = 0x12; buf[1] = 0x34; buf[2] = 0x01; buf[5] = 0x01;

    // QNAME: simple www.example.com -> 3www7example3com0
    int pos = 12;
    int start = 0;
    for(int i=0; i <= host.length(); i++) {
        if(i == host.length() || host[i] == '.') {
            buf[pos++] = i - start;
            for(int j=start; j<i; j++) buf[pos++] = host[j];
            start = i + 1;
        }
    }
    buf[pos++] = 0; // Null terminator
    buf[pos++] = 0x00; buf[pos++] = 0x01; // QTYPE=A
    buf[pos++] = 0x00; buf[pos++] = 0x01; // QCLASS=IN

    struct timeval tv = {4, 0}; // 4 second timeout
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    LOG_DEBUG("Sending DNS query to " << DNS_SERVER << "...");
    if (sendto(sock, buf, pos, 0, (struct sockaddr*)&dest, sizeof(dest)) < 0) {
        perror("[ERR] DNS sendto failed");
        close(sock); return "";
    }
    
    int len = recv(sock, buf, 512, 0);
    if (len < 0) {
        if (errno == EINTR || g_stop_sig) {
            // Interrupted by Ctrl+C
        } else {
            perror("[ERR] DNS recv failed (timeout?)");
        }
    } else {
        LOG_DEBUG("DNS response: " << len << " bytes");
        LOG_HEX("HEX", buf, len);
        
        if ((buf[3] & 0x0F) != 0) printf("[ERR] DNS RCODE: %d\n", buf[3] & 0x0F);
    }
    close(sock);
    if(len < 0) return "";

    // Parse Response (Skip Header, Query, find Answer)
    // Simplified: Find the bytes for Type A (00 01) inside answer section
    // This is a hacky educational parser.
    if(len > 12) { 
        // Scan entire packet (skipping 12 byte header) for 00 04 (IPv4 Len)
        // Limit loop to len - 6 to ensure we have 6 bytes (00 04 IP IP IP IP)
        for(int i=12; i <= len - 6; i++) {
            // Look for Data Length = 4 (IPv4)
            if(buf[i] == 0x00 && buf[i+1] == 0x04) {
                char ip[INET_ADDRSTRLEN];
                sprintf(ip, "%d.%d.%d.%d", buf[i+2], buf[i+3], buf[i+4], buf[i+5]);
                return std::string(ip);
            }
        }
    }
    return "";
}

// Helper: Base64 Encoding for Basic Auth
std::string base64_encode(const std::string& in) {
    std::string out;
    std::string val = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int valb = -6;
    for (unsigned char c : in) {
        valb = (valb << 8) + c;
        valb += 8;
        while (valb >= 0) {
            out.push_back(val[(valb >> valb) & 0x3F]);
            valb -= 6;
        }
    }
    if (valb > -6) out.push_back(val[((valb << 8) >> (valb + 8)) & 0x3F]);
    while (out.size() % 4) out.push_back('=');
    return out;
}

bool HttpRequest(const std::string& url_in, std::ostream& out, const HttpOptions& opts) {
    if (opts.max_redirects < 0) {
        if (opts.verbose) std::cerr << "[NET] Max redirects reached" << std::endl;
        return false;
    }

    // 1. Parse Protocol and URL
    std::string protocol = "http";
    std::string url_part = url_in;

    size_t sep = url_in.find("://");
    if (sep != std::string::npos) {
        protocol = url_in.substr(0, sep);
        url_part = url_in.substr(sep + 3);
    } else {
        if (opts.verbose) std::cerr << "[NET] No protocol specified, defaulting to HTTP" << std::endl;
    }

    // 2. Parse Host and Path
    std::string host;
    std::string path;

    size_t slash_pos = url_part.find('/');
    if (slash_pos != std::string::npos) {
        host = url_part.substr(0, slash_pos);
        path = url_part.substr(slash_pos);
    } else {
        host = url_part;
        path = "/";
    }

    // 3. Determine Port and SSL mode
    bool use_ssl = false;
    int port = 80;

    if (protocol == "https") {
        use_ssl = true;
        port = 443;
    } else if (protocol != "http") {
        if (opts.verbose) std::cerr << "[ERR] Unsupported protocol: " << protocol << std::endl;
        return false;
    }

    if (opts.verbose) std::cerr << "[NET] Target: " << host << " (" << protocol << ":" << port << ")" << std::endl;

    // 4. Proxy / DNS Setup
    std::string connect_host = host;
    int connect_port = port;
    std::string proxy_auth_header;

    if (!opts.proxy.empty()) {
        // Parse Proxy: [user:pass@]host:port
        std::string p_host_port = opts.proxy;
        size_t at = opts.proxy.find('@');
        if (at != std::string::npos) {
            std::string p_auth = opts.proxy.substr(0, at);
            p_host_port = opts.proxy.substr(at + 1);
            proxy_auth_header = "Proxy-Authorization: Basic " + base64_encode(p_auth) + "\r\n";
        }
        // Split host:port
        size_t c = p_host_port.find(':');
        if (c != std::string::npos) {
            connect_host = p_host_port.substr(0, c);
            connect_port = std::atoi(p_host_port.substr(c + 1).c_str());
        } else {
            connect_host = p_host_port;
            connect_port = 8080; // Default proxy port
        }
        if (opts.verbose) std::cerr << "[NET] Using Proxy: " << connect_host << ":" << connect_port << std::endl;
    }

    // Resolve Target (Proxy or Host)
    std::string ip = ResolveDNS(connect_host);
    if (ip.empty()) {
        if (opts.verbose) std::cerr << "[ERR] Could not resolve: " << connect_host << std::endl;
        return false;
    }
    if (opts.verbose) std::cerr << "[NET] Connecting to IP: " << ip << std::endl;

    if (g_stop_sig) return false;

    // 5. Socket Connection
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        if (opts.verbose) perror("[ERR] Socket creation failed");
        return false;
    }

    struct sockaddr_in serv_addr;
    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(connect_port);
    inet_pton(AF_INET, ip.c_str(), &serv_addr.sin_addr);

    if (connect(sock, (struct sockaddr*)&serv_addr, sizeof(serv_addr)) < 0) {
        if (opts.verbose) perror("[ERR] Connection failed");
        close(sock);
        return false;
    }

    // 6. SSL Setup (Optional)
    SSL_CTX* ctx = nullptr;
    SSL* ssl = nullptr;

    // Handle HTTPS via Proxy (CONNECT Tunnel)
    if (!opts.proxy.empty() && use_ssl) {
        std::string connect_req = "CONNECT " + host + ":" + std::to_string(port) + " HTTP/1.1\r\n";
        connect_req += "Host: " + host + ":" + std::to_string(port) + "\r\n";
        connect_req += proxy_auth_header;
        connect_req += "\r\n";
        
        if (opts.verbose) std::cerr << "[NET] Sending Proxy CONNECT..." << std::endl;
        write(sock, connect_req.c_str(), connect_req.length());
        
        // Read Proxy Response (Expect HTTP/1.1 200 OK)
        char tmp[1024];
        int len = read(sock, tmp, sizeof(tmp)-1);
        if (len > 0) {
            tmp[len] = 0;
            if (std::string(tmp).find("200") == std::string::npos) {
                if (opts.verbose) std::cerr << "[ERR] Proxy CONNECT failed: " << tmp << std::endl;
                close(sock); return false;
            }
        }
    }

    if (use_ssl) {
        SSL_library_init();
        ctx = SSL_CTX_new(TLS_client_method());
        if (!ctx) {
            if (opts.verbose) std::cerr << "[ERR] SSL Context failed" << std::endl;
            close(sock); return false;
        }
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);

        ssl = SSL_new(ctx);
        SSL_set_tlsext_host_name(ssl, host.c_str());
        SSL_set_fd(ssl, sock);

        if (SSL_connect(ssl) <= 0) {
            if (opts.verbose) ERR_print_errors_fp(stderr);
            SSL_free(ssl); SSL_CTX_free(ctx); close(sock);
            return false;
        }
    }

    // 7. Send Request
    std::string method = opts.method;
    std::string full_path = (!opts.proxy.empty() && !use_ssl) ? url_in : path; // HTTP Proxy expects full URL
    
    std::string req = method + " " + full_path + " HTTP/1.1\r\n";
    req += "Host: " + host + "\r\n";
    req += "User-Agent: " + opts.user_agent + "\r\n";
    req += "Connection: close\r\n"; // Keep it simple for now
    if (!opts.auth.empty()) req += "Authorization: Basic " + base64_encode(opts.auth) + "\r\n";
    if (!opts.proxy.empty() && !use_ssl) req += proxy_auth_header;
    
    if (!opts.data.empty()) req += "Content-Length: " + std::to_string(opts.data.length()) + "\r\n";
    for (const auto& h : opts.headers) req += h + "\r\n";
    req += "\r\n";
    if (!opts.data.empty()) req += opts.data;

    if (opts.verbose) std::cerr << "[NET] Sending Request..." << std::endl;

    if (use_ssl) SSL_write(ssl, req.c_str(), req.length());
    else write(sock, req.c_str(), req.length());

    // 8. Read Response
    char buffer[4096];
    bool header_done = false;
    std::string header_buffer;
    int status_code = 0;

    while (!g_stop_sig) {
        int bytes = 0;
        if (use_ssl) bytes = SSL_read(ssl, buffer, sizeof(buffer));
        else bytes = read(sock, buffer, sizeof(buffer));

        if (bytes <= 0) break;

        if (!header_done) {
            header_buffer.append(buffer, bytes);
            size_t header_end = header_buffer.find("\r\n\r\n");
            if (header_end != std::string::npos) {
                // Basic status check
                if (header_buffer.size() > 12 && header_buffer.substr(0, 4) == "HTTP") {
                    status_code = std::atoi(header_buffer.substr(9, 3).c_str());
                    if (opts.verbose) std::cerr << "[NET] HTTP Status: " << status_code << std::endl;
                }
                
                // Output headers if requested
                if (opts.include_headers || opts.verbose) {
                    if (opts.include_headers) out.write(header_buffer.c_str(), header_end + 4);
                    if (opts.verbose) std::cerr << header_buffer.substr(0, header_end) << std::endl;
                }

                header_done = true;

                // Handle Redirects
                if (opts.follow_location && (status_code >= 301 && status_code <= 308)) {
                    size_t loc = header_buffer.find("Location: ");
                    if (loc != std::string::npos) {
                        size_t eol = header_buffer.find("\r\n", loc);
                        std::string new_url = header_buffer.substr(loc + 10, eol - (loc + 10));
                        if (opts.verbose) std::cerr << "[NET] Redirecting to: " << new_url << std::endl;
                        
                        if (use_ssl) { SSL_free(ssl); SSL_CTX_free(ctx); }
                        close(sock);
                        
                        HttpOptions new_opts = opts;
                        new_opts.max_redirects--;
                        return HttpRequest(new_url, out, new_opts);
                    }
                }

                if (opts.head_only) break; // Stop if HEAD request
                out.write(header_buffer.c_str() + header_end + 4, header_buffer.length() - header_end - 4);
            }
        } else {
            out.write(buffer, bytes);
        }
    }

    if (use_ssl) { SSL_free(ssl); SSL_CTX_free(ctx); }
    close(sock);
    return !g_stop_sig;
}

bool DownloadFile(std::string url, const std::string& dest_path) {
    std::ofstream outfile(dest_path, std::ios::binary);
    if (!outfile) return false;
    
    HttpOptions opts;
    opts.verbose = true;
    opts.follow_location = true;
    return HttpRequest(url, outfile, opts);
}