#include <iostream>
#include <vector>
#include <dirent.h>
#include <sys/stat.h>
#include <algorithm>
#include <string>
#include "sys_info.h"
 
bool needs_quoting(const std::string& name) {
    for (char c : name) {
        // Check for spaces and common shell metacharacters
        if (c == ' ' || c == '\'' || c == '"' || c == '\\' || 
            c == '$' || c == '`' || c == '(' || c == ')' || 
            c == '&' || c == ';' || c == '|' || c == '<' || c == '>') {
            return true;
        }
    }
    return false;
}

std::string format_name(const std::string& name) {
    if (!needs_quoting(name)) return name;
    
    std::string out = "'";
    for (char c : name) {
        if (c == '\'') out += "'\\''";
        else out += c;
    }
    out += "'";
    return out;
}

int main(int argc, char* argv[]) {
    std::string path = ".";
    bool show_hidden = false;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") {
            std::cout << "Usage: ls [options] [path]\nOptions:\n  -a  Show hidden files\n";
            return 0;
        }
        if (arg == "--version") {
            std::cout << "ls (" << OS_NAME << ") " << OS_VERSION << std::endl;
            return 0;
        }
        if (arg == "-a") show_hidden = true;
        else path = arg;
    }
    DIR* dir = opendir(path.c_str());
    if (!dir) { perror("ls"); return 1; }
    
    std::vector<std::string> files;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!show_hidden && entry->d_name[0] == '.') continue;
        files.push_back(entry->d_name);
    }

    closedir(dir);
    
    // Sort alphabetically
    std::sort(files.begin(), files.end());

    for (const auto& f : files) {
        std::cout << format_name(f) << "  ";
    }
    std::cout << std::endl;
    return 0;
}
