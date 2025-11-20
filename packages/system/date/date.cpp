#include <iostream>
#include <ctime>
#include <string>

int main(int argc, char* argv[]) {
    time_t now = time(0);
    struct tm* t = localtime(&now);
    char buf[128];
    
    const char* fmt = "%a %b %d %H:%M:%S %Z %Y"; // Default
    if (argc > 1 && argv[1][0] == '+') {
        fmt = argv[1] + 1;
    }

    strftime(buf, sizeof(buf), fmt, t);
    std::cout << buf << "\n";
    return 0;
}
