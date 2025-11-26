#include <fstream>
#include <iostream>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <sys/stat.h>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) return 1;
    bool verbose = false;
    std::vector<std::string> files;

    for(int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") { std::cout << "Usage: touch [-v] <file>...\nUpdate timestamps or create empty file.\n"; return 0; }
        else if (arg == "--version") { std::cout << "touch (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
        else if (arg == "-v" || arg == "--verbose") verbose = true;
        else files.push_back(arg);
    }

    if (files.empty()) return 1;

    for(const auto& file : files) {
        // Try to update timestamp with utimensat (NULL means 'now')
        if (utimensat(AT_FDCWD, file.c_str(), NULL, 0) != 0) {
            if (errno == ENOENT) {
                // File doesn't exist, create it
                std::ofstream f(file);
                if (verbose) std::cout << "touch: created '" << file << "'\n";
            } else {
                perror("touch");
                return 1;
            }
        } else {
            if (verbose) std::cout << "touch: updated '" << file << "'\n";
        }
    }
    return 0;
}
