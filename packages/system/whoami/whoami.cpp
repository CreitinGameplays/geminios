#include <iostream>
#include <unistd.h>
#include <pwd.h>

int main() {
    struct passwd *pw = getpwuid(geteuid());
    if (pw) std::cout << pw->pw_name << "\n";
    else std::cout << geteuid() << "\n";
    return 0;
}
