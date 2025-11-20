#include <iostream>
#include <fstream>
#include <string>
#include <vector>

int main(int argc, char* argv[]) {
    int lines = 10;
    std::vector<std::string> files;

    for(int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-n" && i+1 < argc) {
            lines = std::stoi(argv[++i]);
        } else {
            files.push_back(arg);
        }
    }

    if (files.empty()) {
        // Stdin
        std::string line;
        int count = 0;
        while (count < lines && std::getline(std::cin, line)) {
            std::cout << line << "\n";
            count++;
        }
        return 0;
    }

    for (const auto& file : files) {
        if (files.size() > 1) std::cout << "==> " << file << " <==\n";
        std::ifstream f(file);
        if (!f) { perror(file.c_str()); continue; }
        std::string line;
        int count = 0;
        while (count < lines && std::getline(f, line)) {
            std::cout << line << "\n";
            count++;
        }
        if (files.size() > 1 && file != files.back()) std::cout << "\n";
    }
    return 0;
}
