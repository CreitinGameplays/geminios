#include <iostream>
#include <vector>
#include <string>
#include <csignal>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <chrono>
#include "../../../src/sys_info.h"

volatile bool running = true;
void sig_handler(int) { running = false; }

size_t parse_size(const std::string& s) {
    size_t mult = 1;
    std::string num = s;
    if (s.back() == 'K') { mult = 1024; num.pop_back(); }
    else if (s.back() == 'M') { mult = 1024*1024; num.pop_back(); }
    else if (s.back() == 'G') { mult = 1024*1024*1024; num.pop_back(); }
    try { return std::stoull(num) * mult; } catch(...) { return 0; }
}

int main(int argc, char* argv[]) {
    if (argc < 2) { std::cerr << "Usage: dd if=<in> of=<out> [bs=N] [count=N]\n"; return 1; }

    std::string if_path, of_path;
    size_t bs = 512;
    size_t count = 0;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg.find("if=") == 0) if_path = arg.substr(3);
        else if (arg.find("of=") == 0) of_path = arg.substr(3);
        else if (arg.find("bs=") == 0) bs = parse_size(arg.substr(3));
        else if (arg.find("count=") == 0) count = std::stoull(arg.substr(6));
    }

    if (if_path.empty() || of_path.empty()) {
        std::cerr << "dd: missing operand\n"; return 1;
    }

    int fd_in = open(if_path.c_str(), O_RDONLY);
    if (fd_in < 0) { perror("dd input"); return 1; }

    int flags = O_CREAT | O_WRONLY;
    struct stat st;
    if (stat(of_path.c_str(), &st) == 0 && S_ISREG(st.st_mode)) flags |= O_TRUNC;
    
    int fd_out = open(of_path.c_str(), flags, 0644);
    if (fd_out < 0) { perror("dd output"); close(fd_in); return 1; }

    signal(SIGINT, sig_handler);

    std::vector<char> buffer(bs);
    size_t total_bytes = 0;
    size_t blocks = 0;
    auto start = std::chrono::steady_clock::now();

    while (running && (count == 0 || blocks < count)) {
        ssize_t r = read(fd_in, buffer.data(), bs);
        if (r <= 0) break;

        ssize_t w = write(fd_out, buffer.data(), r);
        if (w < 0) { perror("write"); break; }
        
        total_bytes += w;
        blocks++;
        if (w < r) break;
    }

    auto end = std::chrono::steady_clock::now();
    close(fd_in); close(fd_out);

    double sec = std::chrono::duration<double>(end - start).count();
    double mb = total_bytes / (1024.0 * 1024.0);
    std::cerr << total_bytes << " bytes (" << mb << " MB) copied, " 
              << sec << " s, " << (mb/sec) << " MB/s\n";
    return 0;
}
