#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <sys/statvfs.h>
#include <iomanip>
#include "../../../src/sys_info.h"

std::string format_size(unsigned long long bytes) {
    const char* suffixes[] = {"B", "K", "M", "G", "T"};
    int i = 0;
    double size = bytes;
    while (size >= 1024 && i < 4) {
        size /= 1024;
        i++;
    }
    std::stringstream ss;
    ss << std::fixed << std::setprecision(1) << size << suffixes[i];
    return ss.str();
}

int main(int argc, char* argv[]) {
    bool human = false;
    if (argc > 1 && std::string(argv[1]) == "-h") human = true;

    std::ifstream mounts("/proc/mounts");
    if (!mounts) {
        std::cerr << "df: cannot open /proc/mounts (is /proc mounted?)\n";
        return 1;
    }

    std::cout << std::left << std::setw(20) << "Filesystem"
              << std::setw(10) << "Size"
              << std::setw(10) << "Used"
              << std::setw(10) << "Avail"
              << std::setw(6) << "Use%"
              << "Mounted on" << std::endl;

    std::string line;
    while (std::getline(mounts, line)) {
        std::stringstream ss(line);
        std::string device, mountpoint, type, opts;
        ss >> device >> mountpoint >> type >> opts;

        struct statvfs stats;
        if (statvfs(mountpoint.c_str(), &stats) == 0) {
            unsigned long long total = stats.f_blocks * stats.f_frsize;
            unsigned long long avail = stats.f_bavail * stats.f_frsize;
            unsigned long long free_root = stats.f_bfree * stats.f_frsize;
            unsigned long long used = total - free_root;
            
            int percent = 0;
            if (total > 0) {
                 percent = (int)((used * 100) / (used + avail));
            }

            std::cout << std::left << std::setw(20) << device;
            if (human) {
                std::cout << std::setw(10) << format_size(total)
                          << std::setw(10) << format_size(used)
                          << std::setw(10) << format_size(avail);
            } else {
                std::cout << std::setw(10) << (total / 1024)
                          << std::setw(10) << (used / 1024)
                          << std::setw(10) << (avail / 1024);
            }
            std::cout << std::setw(5) << std::to_string(percent) + "%"
                      << mountpoint << std::endl;
        }
    }
    return 0;
}
