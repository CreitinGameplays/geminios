#include <fstream>
#include <iostream>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) return 1;
    std::string arg = argv[1];
    if (arg == "--help") { std::cout << "Usage: touch <file>\nUpdate timestamps or create empty file.\n"; return 0; }
    if (arg == "--version") { std::cout << "touch (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }

    // Try to update timestamp with utimensat (NULL means 'now')
    if (utimensat(AT_FDCWD, argv[1], NULL, 0) != 0) {
        if (errno == ENOENT) {
            // File doesn't exist, create it
            std::ofstream f(argv[1]);
        } else {
            perror("touch");
            return 1;
        }
    }
    return 0;
}
