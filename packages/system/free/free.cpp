#include <sys/sysinfo.h>
#include <iostream>
#include <cstdio>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: free\nDisplay amount of free and used memory.\n"; return 0; }
        if (arg == "--version") { std::cout << "free (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
    }
    struct sysinfo info;
    if (sysinfo(&info) == 0) {
        long mb = 1024 * 1024;
        std::cout << "Total RAM: " << info.totalram / mb << " MB" << std::endl;
        std::cout << "Free RAM:  " << info.freeram / mb << " MB" << std::endl;
        std::cout << "Procs:     " << info.procs << std::endl;
        std::cout << "Uptime:    " << info.uptime << "s" << std::endl;
    }
    return 0;
}
