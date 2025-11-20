#include <iostream>
#include <unistd.h>

extern char** environ;

int main() {
    for (char** env = environ; *env != 0; env++) {
        std::cout << *env << "\n";
    }
    return 0;
}
