#include <iostream>
#include <vector>
#include <string>
#include <cstring>
#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>
#include <cstdio>
#include "sys_info.h"

// Global flags
bool g_recursive = false;
bool g_force = false;
bool g_interactive = false;
bool g_verbose = false;
bool g_dir = false;

bool remove_path(const std::string& path);

// Helper: Ask user for confirmation if -i is set
bool ask_confirmation(const std::string& path) {
    if (!g_interactive) return true;
    std::string response;
    std::cout << "rm: remove '" << path << "'? ";
    std::getline(std::cin, response);
    return (response == "y" || response == "Y" || response == "yes");
}

bool remove_directory_recursive(const std::string& path) {
    DIR* dir = opendir(path.c_str());
    if (!dir) {
        if (!g_force) perror(("rm: cannot open directory '" + path + "'").c_str());
        return false;
    }

    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        
        std::string full_path = path + "/" + name;
        if (!remove_path(full_path)) {
            closedir(dir);
            return false;
        }
    }
    closedir(dir);

    // Now remove the directory itself
    if (!ask_confirmation(path)) return false;

    if (rmdir(path.c_str()) == 0) {
        if (g_verbose) std::cout << "removed directory '" << path << "'" << std::endl;
        return true;
    } else {
        if (!g_force) perror(("rm: cannot remove '" + path + "'").c_str());
        return false;
    }
}

bool remove_path(const std::string& path) {
    // Safety check
    if (path == "." || path == "..") {
        std::cerr << "rm: refusing to remove '.' or '..'" << std::endl;
        return false;
    }

    struct stat s;
    // lstat is important to NOT follow symlinks (we want to delete the link, not target)
    if (lstat(path.c_str(), &s) != 0) {
        if (g_force) return true; // -f ignores missing files
        perror(("rm: cannot remove '" + path + "'").c_str());
        return false;
    }

    if (S_ISDIR(s.st_mode)) {
        if (g_recursive) {
            return remove_directory_recursive(path);
        } else if (g_dir) {
            // Try to remove empty directory
            if (!ask_confirmation(path)) return false;
            if (rmdir(path.c_str()) == 0) {
                if (g_verbose) std::cout << "removed directory '" << path << "'" << std::endl;
                return true;
            } else {
                if (!g_force) perror(("rm: cannot remove '" + path + "'").c_str());
                return false;
            }
        } else {
            std::cerr << "rm: cannot remove '" << path << "': Is a directory" << std::endl;
            return false;
        }
    } else {
        // It is a file or symlink
        if (!ask_confirmation(path)) return false;
        if (unlink(path.c_str()) == 0) {
            if (g_verbose) std::cout << "removed '" << path << "'" << std::endl;
            return true;
        } else {
            if (!g_force) perror(("rm: cannot remove '" + path + "'").c_str());
            return false;
        }
    }
}

int main(int argc, char* argv[]) {
    std::vector<std::string> targets;
    
    // Argument Parsing
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") {
            std::cout << "Usage: rm [options] <file>...\nOptions:\n  -r  Recursive\n  -f  Force\n  -i  Interactive\n  -v  Verbose\n  -d  Remove empty dirs\n";
            return 0;
        }
        if (arg == "--version") {
            std::cout << "rm (" << OS_NAME << ") " << OS_VERSION << std::endl;
            return 0;
        }
        if (arg.length() > 0 && arg[0] == '-') {
            for (size_t j = 1; j < arg.length(); ++j) {
                switch (arg[j]) {
                    case 'r': g_recursive = true; break;
                    case 'R': g_recursive = true; break;
                    case 'f': g_force = true; break;
                    case 'i': g_interactive = true; break;
                    case 'v': g_verbose = true; break;
                    case 'd': g_dir = true; break;
                    default: 
                        std::cerr << "rm: invalid option -- '" << arg[j] << "'" << std::endl;
                        return 1;
                }
            }
        } else {
            targets.push_back(arg);
        }
    }

    if (targets.empty()) {
        std::cout << "rm: missing operand" << std::endl;
        return 1;
    }

    int ret = 0;
    for (const auto& t : targets) {
        if (!remove_path(t)) ret = 1;
    }

    return ret;
}
