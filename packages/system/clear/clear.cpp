#include <iostream>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: clear\nClear the terminal screen.\n"; return 0; }
        if (arg == "--version") { std::cout << "clear (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
    }
    std::cout << "\033[2J\033[1;1H";
    return 0;
}
