#include <iostream>
#include <fstream>
#include <csignal>
#include <unistd.h>
#include <string>
#include "sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) { 
        std::cerr << "Usage: cat <file>" << std::endl; 
        return 1; 
    }
    
    bool number = false;
    std::string file_path;
    
    for(int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") { std::cout << "Usage: cat [-n] <file>\n"; return 0; }
        else if (arg == "-n") number = true;
        else file_path = arg;
    }

    std::ifstream file(file_path);
    if (!file) { std::cerr << "cat: " << file_path << ": No such file" << std::endl; return 1; }
    
    std::string line;
    int lineno = 1;
    while(std::getline(file, line)) {
        if(number) std::cout << lineno++ << "\t";
        std::cout << line << std::endl;
    }
    return 0;
}
