#include <sys/sysinfo.h>
#include <iostream>
#include <cstdio>
#include <string>
#include "sys_info.h"

std::string fmt_size(long bytes, bool human, long div, const std::string& suffix) {
    if (human) {
        const char* s[] = {"B", "K", "M", "G", "T"};
        int i=0; double db = bytes;
        while(db >= 1024 && i<4) { db /= 1024; i++; }
        char buf[32]; sprintf(buf, "%.1f%s", db, s[i]); return buf;
    }
    return std::to_string(bytes / div) + suffix;
}

int main(int argc, char* argv[]) {
    bool human = false;
    long div = 1024; // Default KB (proc/meminfo is usually KB, sysinfo is bytes. sysinfo returns bytes)
    std::string suf = ""; // default bytes? No, free default is KB. sysinfo returns bytes.
    
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: free [-h|-b|-k|-m|-g]\n"; return 0; }
        if (arg == "--version") { std::cout << "free (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
        if (arg == "-h") human = true;
        else if (arg == "-b") { div=1; suf=""; }
        else if (arg == "-k") { div=1024; suf="K"; }
        else if (arg == "-m") { div=1024*1024; suf="M"; }
        else if (arg == "-g") { div=1024*1024*1024; suf="G"; }
    }
    struct sysinfo info;
    if (sysinfo(&info) == 0) {
        long total = info.totalram * info.mem_unit;
        long free = info.freeram * info.mem_unit;
        long used = total - free;
        
        std::cout << "              total        used        free\n";
        std::cout << "Mem:    " 
                  << fmt_size(total, human, div, suf) << "    "
                  << fmt_size(used, human, div, suf) << "    "
                  << fmt_size(free, human, div, suf) << "\n";
    }
    return 0;
}
