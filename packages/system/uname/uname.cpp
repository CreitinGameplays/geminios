#include <sys/utsname.h>
#include <iostream>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: uname\nPrint system information.\n"; return 0; }
        if (arg == "--version") { std::cout << "uname (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
    }
    struct utsname buffer;
    if (uname(&buffer) == 0) {
        std::cout << buffer.sysname << " " << buffer.release << " " 
                  << buffer.version << " " << buffer.machine << std::endl;
    }
    return 0;
}
