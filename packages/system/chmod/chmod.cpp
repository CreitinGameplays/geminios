#include <iostream>
#include <string>
#include <sys/stat.h>
#include <cstdlib>
#include "../../../src/sys_info.h"

int main(int argc, char* argv[]) {
    bool recursive = false;
    int path_idx = 1;

    if (argc < 2) {
        std::cerr << "Usage: chmod [-R] <mode> <file>\n";
        return 1;
    }

    if (std::string(argv[1]) == "-R") {
        recursive = true;
        path_idx = 2;
    }

    if (argc < path_idx + 2) {
        std::cerr << "chmod: missing operand\n";
        return 1;
    }

    std::string mode_str = argv[path_idx];
    std::string path = argv[path_idx + 1];

    // Parse Octal Mode
    char* end;
    long mode = std::strtol(mode_str.c_str(), &end, 8);
    if (*end != '\0') {
        std::cerr << "chmod: invalid mode: " << mode_str << " (only octal supported for now)\n";
        return 1;
    }

    if (chmod(path.c_str(), (mode_t)mode) != 0) {
        perror(("chmod: " + path).c_str());
        return 1;
    }

    // TODO: Implement recursive logic if -R (requires directory traversal similar to copy/rm)
    if (recursive) {
        std::cout << "chmod: -R not yet fully implemented in this version (applied to top level only)\n";
    }

    return 0;
}
