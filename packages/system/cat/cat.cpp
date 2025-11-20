#include <iostream>
#include <fstream>
#include <csignal>
#include <unistd.h>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) { 
        std::cerr << "Usage: cat <file>" << std::endl; 
        return 1; 
    }
    std::string arg = argv[1];
    if (arg == "--help") { std::cout << "Usage: cat <file>\nConcatenate file to standard output.\n"; return 0; }
    if (arg == "--version") { std::cout << "cat (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }

    // Default SIGINT handler terminates, which is what we want.
    std::ifstream file(argv[1], std::ios::binary);
    if (!file) { std::cerr << "cat: " << argv[1] << ": No such file" << std::endl; return 1; }
    std::cout << file.rdbuf() << std::endl;
    return 0;
}
