#include "network.h"
#include "signals.h"
#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <csignal>
#include <cstring>
#include <cstdlib>
#include "sys_info.h"

void sig_handler(int) { g_stop_sig = 1; }

int main(int argc, char* argv[]) {
    signal(SIGINT, sig_handler);
    
    if (argc < 2) {
        std::cout << "Usage: greq <url> [-o file] [-v]" << std::endl;
        return 1;
    }

    std::string url;
    std::string output_file;
    bool remote_name = false;
    HttpOptions opts;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];

        if (arg == "--help") {
            std::cout << "Usage: greq [options] <url>\n"
                      << "Options:\n"
                      << "  -o <file>    Write output to file\n"
                      << "  -O           Write output to local file named like remote file\n"
                      << "  -v           Verbose\n"
                      << "  -i           Include headers in output\n"
                      << "  -I           Fetch headers only (HEAD)\n"
                      << "  -L           Follow redirects\n"
                      << "  -X <method>  Specify request method\n"
                      << "  -H <header>  Add custom header\n"
                      << "  -d <data>    HTTP POST data\n"
                      << "  -u <u:p>     Server user and password\n"
                      << "  -A <agent>   User-Agent\n"
                      << "  -x <proxy>   [protocol://]host:port or user:pass@host:port\n"
                      << "  -k           Insecure (Skip SSL verification)\n";
            return 0;
        }
        else if (arg == "--version") {
             std::cout << "greq (" << OS_NAME << ") " << OS_VERSION << std::endl;
             return 0;
        }
        else if (arg == "-v") opts.verbose = true;
        else if (arg == "-i") opts.include_headers = true;
        else if (arg == "-I") { opts.head_only = true; opts.method = "HEAD"; opts.include_headers = true; }
        else if (arg == "-L") opts.follow_location = true;
        else if (arg == "-k" || arg == "--insecure") opts.insecure = true;
        else if (arg == "-O") remote_name = true;
        else if (arg == "-o" && i + 1 < argc) output_file = argv[++i];
        else if (arg == "-X" && i + 1 < argc) opts.method = argv[++i];
        else if (arg == "-d" && i + 1 < argc) { opts.data = argv[++i]; if (opts.method == "GET") opts.method = "POST"; }
        else if (arg == "-u" && i + 1 < argc) opts.auth = argv[++i];
        else if (arg == "-A" && i + 1 < argc) opts.user_agent = argv[++i];
        else if (arg == "-H" && i + 1 < argc) opts.headers.push_back(argv[++i]);
        else if ((arg == "-x" || arg == "--proxy") && i + 1 < argc) {
            std::string p = argv[++i];
            // Strip protocol if present for now
            if (p.find("://") != std::string::npos) p = p.substr(p.find("://") + 3);
            opts.proxy = p;
        }
        else if (arg == "-F" && i + 1 < argc) {
             // Very basic multipart simulation: just send as body (Not spec compliant but a start)
             std::string val = argv[++i];
             opts.data += val + "\n";
             opts.method = "POST";
        }
        else if (arg[0] != '-') {
            url = arg;
        }
    }

    if (url.empty()) {
        std::cerr << "greq: no URL specified!" << std::endl;
        return 1;
    }

    // Handle -O (Remote Name)
    if (remote_name && output_file.empty()) {
        // Extract filename from URL
        size_t last_slash = url.find_last_of('/');
        if (last_slash != std::string::npos && last_slash < url.length() - 1) {
            output_file = url.substr(last_slash + 1);
            // Strip query parameters
            size_t q = output_file.find('?');
            if (q != std::string::npos) output_file = output_file.substr(0, q);
        } else {
             // Fallback or index
             output_file = "index.html";
        }
        if (opts.verbose) std::cout << "[GREQ] Saving to: " << output_file << std::endl;
    }

    if (!output_file.empty()) {
        std::ofstream f(output_file, std::ios::binary);
        if (!f) { perror(("greq: " + output_file).c_str()); return 1; }
        if (!HttpRequest(url, f, opts)) {
            std::cerr << "greq: operation failed" << std::endl;
            // Remove partial file
            f.close();
            remove(output_file.c_str());
            return 1;
        }
    } else {
        if (!HttpRequest(url, std::cout, opts)) {
            std::cerr << "greq: operation failed" << std::endl;
            return 1;
        }
        // Ensure newline at end of terminal output if body didn't have it
        if (!opts.head_only) std::cout << std::flush; 
    }
    return 0;
}
