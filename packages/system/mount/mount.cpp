#include <sys/mount.h>
#include <iostream>
#include <string>
#include <unistd.h>
#include "../../../src/sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) {
        execl("/bin/apps/system/cat", "cat", "/proc/mounts", NULL);
        return 0;
    }

    std::string device, dir, type;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-t" && i + 1 < argc) {
            type = argv[++i];
        } else if (device.empty()) {
            device = arg;
        } else {
            dir = arg;
        }
    }

    if (device.empty() || dir.empty()) {
        std::cout << "Usage: mount -t <type> <device> <dir>\n";
        return 1;
    }

    if (type.empty()) type = "ext4"; // Default assumption

    if (mount(device.c_str(), dir.c_str(), type.c_str(), 0, NULL) == 0) {
        return 0;
    } else {
        perror("mount");
        return 1;
    }
}
