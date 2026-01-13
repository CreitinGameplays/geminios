#include <sys/reboot.h>
#include <iostream>
#include <string>
#include <random>
#include <thread>
#include <chrono>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: poweroff\nPower off the system.\n"; return 0; }
        if (arg == "--version") { std::cout << "poweroff (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
    }

    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> distrib(1, 1000);

    // Print the message first
    if (distrib(gen) <= 3) {
        std::cout << "Never gonna give you up..." << std::endl;
        std::this_thread::sleep_for(std::chrono::seconds(3));
    } else {
        std::cout << "Powering off..." << std::endl;
    }

    // Execute shutdown
    reboot(RB_POWER_OFF);
    return 0;
}