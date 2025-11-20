#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <iomanip>
#include <sstream>

struct Counts {
    long lines = 0;
    long words = 0;
    long bytes = 0;
};

Counts count_stream(std::istream& in) {
    Counts c;
    char ch;
    bool in_word = false;
    while (in.get(ch)) {
        c.bytes++;
        if (ch == '\n') c.lines++;
        if (isspace(ch)) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            c.words++;
        }
    }
    return c;
}

int main(int argc, char* argv[]) {
    std::vector<std::string> files;
    bool l=false, w=false, c=false;
    
    for(int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if (arg[0] == '-') {
            for(char ch : arg) {
                if (ch == 'l') l=true;
                if (ch == 'w') w=true;
                if (ch == 'c') c=true;
            }
        } else files.push_back(arg);
    }
    
    if (!l && !w && !c) { l=true; w=true; c=true; } // Default

    auto print_counts = [&](const Counts& cnt, const std::string& name) {
        if (l) std::cout << std::setw(8) << cnt.lines;
        if (w) std::cout << std::setw(8) << cnt.words;
        if (c) std::cout << std::setw(8) << cnt.bytes;
        if (!name.empty()) std::cout << " " << name;
        std::cout << "\n";
    };

    if (files.empty()) {
        print_counts(count_stream(std::cin), "");
    } else {
        Counts total;
        for (const auto& f : files) {
            std::ifstream fs(f);
            if (!fs) { perror(f.c_str()); continue; }
            Counts cnt = count_stream(fs);
            print_counts(cnt, f);
            total.lines += cnt.lines;
            total.words += cnt.words;
            total.bytes += cnt.bytes;
        }
        if (files.size() > 1) print_counts(total, "total");
    }
    return 0;
}
