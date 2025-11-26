#include <iostream>
#include <string>
#include <sys/stat.h>
#include <cstdlib>
#include <vector>
#include "../../../src/sys_info.h"

int main(int argc, char* argv[]) {
    bool verbose = false;
    bool recursive = false;
    std::vector<std::string> args;

    // Robust Argument Parser
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") {
            std::cout << "Usage: chmod [-R] [-v] <mode> <file...>\n";
            return 0;
        } else if (arg == "--version") {
            std::cout << "chmod (" << OS_NAME << ") " << OS_VERSION << "\n";
            return 0;
        } else if (arg == "-R") {
            recursive = true;
        } else if (arg == "-v" || arg == "--verbose") {
            verbose = true;
        } else {
            args.push_back(arg);
        }
    }

    if (args.size() < 2) {
        std::cerr << "Usage: chmod [-R] [-v] <mode> <file...>\n";
        return 1;
    }

    std::string mode_str = args[0];
    
    // Parse Octal Mode
    char* end;
    long mode = std::strtol(mode_str.c_str(), &end, 8);
    if (*end != '\0') {
        std::cerr << "chmod: invalid mode: " << mode_str << "\n";
        return 1;
    }

    int ret = 0;
    // Iterate over all file arguments (starting from index 1)
    for (size_t i = 1; i < args.size(); ++i) {
        std::string path = args[i];
        
        if (chmod(path.c_str(), (mode_t)mode) != 0) {
            perror(("chmod: " + path).c_str());
            ret = 1;
        } else {
            if (verbose) std::cout << "mode of '" << path << "' changed to " << std::oct << mode << std::dec << "\n";
        }

        if (recursive) {
            // Warn only once if verbose, or just once per execution
            static bool warned = false;
            if (!warned) {
                std::cout << "chmod: -R not fully implemented (only top-level files changed)\n";
                warned = true;
            }
        }
    }

    return ret;
}
