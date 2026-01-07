#include <iostream>
#include <unistd.h>
#include <vector>

extern char** environ;

int main(int argc, char* argv[]) {
    if (argc == 1) {
        // Behaves like 'export' (no args) -> List environment
        for (char** env = environ; *env != 0; env++) {
            std::cout << "declare -x " << *env << "\n";
        }
        return 0;
    } else {
        // User tried 'export VAR=VAL' via the external binary
        std::cerr << "Warning: 'export' as an external command cannot modify the parent shell environment.\n";
        std::cerr << "Please use the shell built-in 'export' command directly.\n";
        return 1;
    }
}
