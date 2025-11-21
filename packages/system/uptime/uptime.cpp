#include <iostream>
#include <fstream>
#include <sys/sysinfo.h>
#include <iomanip>
#include <unistd.h>
#include "../../../src/sys_info.h"

int main(int argc, char* argv[]) {
    if (argc > 1 && std::string(argv[1]) == "--version") {
        std::cout << "uptime (" << OS_NAME << ") " << OS_VERSION << "\n";
        return 0;
    }

    struct sysinfo info;
    if (sysinfo(&info) != 0) {
        perror("sysinfo");
        return 1;
    }

    long uptime = info.uptime;
    long days = uptime / 86400;
    long hours = (uptime % 86400) / 3600;
    long minutes = (uptime % 3600) / 60;
    
    std::cout << " up ";
    if (days > 0) std::cout << days << " days, ";
    std::cout << hours << ":" << std::setfill('0') << std::setw(2) << minutes;
    
    // Load averages
    double loads[3];
    if (getloadavg(loads, 3) != -1) {
        std::cout << ",  load average: " << loads[0] << ", " << loads[1] << ", " << loads[2];
    }
    std::cout << std::endl;
    return 0;
}
