#include <iostream>
#include <dirent.h>
#include <vector>
#include <string>
#include <algorithm>
#include "sys_info.h"

void scan_dir(const std::string& path, std::vector<std::string>& cmds) {
    DIR* dir = opendir(path.c_str());
    if (!dir) return;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        cmds.push_back(entry->d_name);
    }
    closedir(dir);
}

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: help\nList available commands.\n"; return 0; }
        if (arg == "--version") { std::cout << "help (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
    }
    std::vector<std::string> cmds;
    cmds.push_back("cd"); 
    scan_dir("/bin/apps/system/", cmds);
    scan_dir("/bin/apps/", cmds);
    
    std::sort(cmds.begin(), cmds.end());
    
    std::cout << "Available Commands:" << std::endl;
    for (const auto& cmd : cmds) {
        std::cout << cmd << "  ";
    }
    std::cout << std::endl;
    return 0;
}
