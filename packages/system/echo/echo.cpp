#include <iostream>
#include <string>
#include <cstring>

int main(int argc, char* argv[]) {
    bool newline = true;
    int start_idx = 1;

    if (argc > 1 && strcmp(argv[1], "-n") == 0) {
        newline = false;
        start_idx = 2;
    }

    for (int i = start_idx; i < argc; ++i) {
        std::cout << argv[i] << (i == argc - 1 ? "" : " ");
    }

    if (newline) std::cout << std::endl;
    return 0;
}
