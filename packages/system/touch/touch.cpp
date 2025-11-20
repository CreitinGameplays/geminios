#include <fstream>
#include <iostream>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) return 1;
    std::string arg = argv[1];
    if (arg == "--help") { std::cout << "Usage: touch <file>\nUpdate timestamps or create empty file.\n"; return 0; }
    if (arg == "--version") { std::cout << "touch (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }

    std::ofstream f(argv[1], std::ios::app);
    return 0;
}
