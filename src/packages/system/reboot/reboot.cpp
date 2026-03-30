#include <sys/reboot.h>
#include <iostream>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: reboot\nRestart the system.\n"; return 0; }
        if (arg == "--version") { std::cout << "reboot (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
    }
    std::cout << "Rebooting..." << std::endl;
    reboot(RB_AUTOBOOT);
    return 0;
}
