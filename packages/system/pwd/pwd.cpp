#include <iostream>
#include <unistd.h>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") {
            std::cout << "Usage: pwd\nPrint name of current/working directory.\n";
            return 0;
        }
        if (arg == "--version") {
            std::cout << "pwd (" << OS_NAME << ") " << OS_VERSION << std::endl;
            return 0;
        }
    }
    char cwd[1024];
    if (getcwd(cwd, sizeof(cwd))) std::cout << cwd << std::endl;
    else perror("pwd");
    return 0;
}
