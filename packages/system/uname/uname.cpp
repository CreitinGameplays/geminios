#include <sys/utsname.h>
#include <iostream>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    bool all = false;
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: uname\nPrint system information.\n"; return 0; }
        if (arg == "--version") { std::cout << "uname (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
        if (arg == "-a") all = true;
    }
    struct utsname buffer;
    if (uname(&buffer) == 0) {
        std::cout << buffer.sysname << " " << buffer.nodename << " " << buffer.release << " " 
                  << buffer.version << " " << buffer.machine;
        if(all) std::cout << " " << OS_NAME;
        std::cout << std::endl;
    }
    return 0;
}
