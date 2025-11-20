#include <sys/stat.h>
#include <iostream>
#include <cstdio>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) return 1;
    std::string arg = argv[1];
    if (arg == "--help") { std::cout << "Usage: mkdir <directory>\nCreate a directory.\n"; return 0; }
    if (arg == "--version") { std::cout << "mkdir (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }

    if (mkdir(argv[1], 0755) != 0) { perror("mkdir"); return 1; }
    return 0;
}
