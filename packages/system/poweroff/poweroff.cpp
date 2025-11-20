#include <sys/reboot.h>
#include <iostream>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: poweroff\nPower off the system.\n"; return 0; }
        if (arg == "--version") { std::cout << "poweroff (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
    }
    std::cout << "Powering off..." << std::endl;
    reboot(RB_POWER_OFF);
    return 0;
}
