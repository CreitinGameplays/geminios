#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <deque>

void tail_file(std::istream& in, int n) {
    std::deque<std::string> buffer;
    std::string line;
    while (std::getline(in, line)) {
        buffer.push_back(line);
        if (buffer.size() > n) buffer.pop_front();
    }
    for (const auto& l : buffer) std::cout << l << "\n";
}

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
        tail_file(std::cin, lines);
        return 0;
    }

    for (const auto& file : files) {
        if (files.size() > 1) std::cout << "==> " << file << " <==\n";
        std::ifstream f(file);
        if (!f) { perror(file.c_str()); continue; }
        tail_file(f, lines);
        if (files.size() > 1 && file != files.back()) std::cout << "\n";
    }
    return 0;
}
