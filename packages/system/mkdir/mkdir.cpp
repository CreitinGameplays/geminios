#include <sys/stat.h>
#include <iostream>
#include <cstdio>
#include <string>
#include <vector>
#include <cstdlib>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) return 1;
    
    bool parents = false;
    bool verbose = false;
    mode_t mode = 0755;
    std::vector<std::string> dirs;

    for(int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") { std::cout << "Usage: mkdir [-p] [-v] [-m mode] <dir>...\n"; return 0; }
        else if (arg == "--version") { std::cout << "mkdir (" << OS_NAME << ") " << OS_VERSION << "\n"; return 0; }
        else if (arg == "-p") parents = true;
        else if (arg == "-v") verbose = true;
        else if (arg == "-m" && i+1 < argc) {
            mode = std::strtol(argv[++i], nullptr, 8);
        }
        else if (arg[0] != '-') dirs.push_back(arg);
    }

    for(const auto& dir : dirs) {
        if (parents) {
            std::string current;
            for(size_t j=0; j<dir.length(); ++j) {
                if(dir[j] == '/') {
                    if(!current.empty()) {
                        if(mkdir(current.c_str(), mode) == 0) {
                            if(verbose) std::cout << "mkdir: created directory '" << current << "'\n";
                        }
                    }
                }
                current += dir[j];
            }
            if(!current.empty()) {
                 if(mkdir(current.c_str(), mode) == 0) {
                     if(verbose) std::cout << "mkdir: created directory '" << current << "'\n";
                 }
            }
        } else {
            if(mkdir(dir.c_str(), mode) != 0) {
                perror(("mkdir: " + dir).c_str());
            } else {
                if(verbose) std::cout << "mkdir: created directory '" << dir << "'\n";
            }
        }
    }
    return 0;
}
