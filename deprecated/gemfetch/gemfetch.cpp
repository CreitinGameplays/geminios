#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <sys/utsname.h>

// ANSI Colors
#define RESET   "\033[0m"
#define RED     "\033[31m"
#define GREEN   "\033[32m"
#define YELLOW  "\033[33m"
#define BLUE    "\033[34m"
#define MAGENTA "\033[35m"
#define CYAN    "\033[36m"

void print_kv(const std::string& key, const std::string& value) {
    std::cout << GREEN << key << ": " << RESET << value << std::endl;
}

// Read /etc/os-release to get the official OS name
std::string get_os_name() {
    std::ifstream file("/etc/os-release");
    if (!file) return "GeminiOS (Unknown)"; // Fallback
    
    std::string line;
    while (std::getline(file, line)) {
        if (line.find("PRETTY_NAME=") == 0) {
            // Extract value inside quotes: PRETTY_NAME="Value"
            size_t first_quote = line.find('"');
            size_t last_quote = line.rfind('"');
            if (first_quote != std::string::npos && last_quote != std::string::npos && last_quote > first_quote) {
                return line.substr(first_quote + 1, last_quote - first_quote - 1);
            }
        }
    }
    return "GeminiOS (Detected)";
}

std::string get_cpu_model() {
    std::ifstream file("/proc/cpuinfo");
    std::string line;
    while (std::getline(file, line)) {
        if (line.find("model name") != std::string::npos) {
            size_t pos = line.find(':');
            if (pos != std::string::npos) return line.substr(pos + 2);
        }
    }
    return "Unknown CPU";
}

std::string get_memory() {
    long total = 0, free = 0;
    std::ifstream file("/proc/meminfo");
    std::string line;
    while (std::getline(file, line)) {
        if (line.find("MemTotal:") == 0) sscanf(line.c_str(), "MemTotal: %ld", &total);
        if (line.find("MemFree:") == 0) sscanf(line.c_str(), "MemFree: %ld", &free);
    }
    long used = total - free;
    return std::to_string(used / 1024) + "MB / " + std::to_string(total / 1024) + "MB";
}

int main() {
    struct utsname buffer;
    uname(&buffer);

    // ASCII Art Logo
    std::vector<std::string> logo = {
        "   _____                 _       _  ____   _____ ",
        "  / ____|               (_)     (_)/ __ \\ / ____|",
        " | |  __  ___ _ __ ___   _ _ __  _| |  | | (___  ",
        " | | |_ |/ _ \\ '_ ` _ \\ | | '_ \\| | |  | |\\___ \\ ",
        " | |__| |  __/ | | | | || | | | | | |__| |____) |",
        "  \\_____|\\___|_| |_| |_||_|_| |_|_|\\____/|_____/ "
    };

    std::cout << std::endl;
    for (const auto& l : logo) {
        std::cout << BLUE << l << RESET << std::endl;
    }
    std::cout << std::endl;

    print_kv("OS", get_os_name());
    print_kv("Kernel", buffer.release);
    print_kv("Host", "QEMU / KVM");
    print_kv("CPU", get_cpu_model());
    print_kv("Memory", get_memory());
    print_kv("Shell", "Gemini Init (C++)");
    
    std::cout << std::endl;
    
    // Color Palette Demo
    std::cout << "   ";
    std::cout << "\033[41m   \033[0m ";
    std::cout << "\033[42m   \033[0m ";
    std::cout << "\033[43m   \033[0m ";
    std::cout << "\033[44m   \033[0m ";
    std::cout << "\033[45m   \033[0m ";
    std::cout << "\033[46m   \033[0m ";
    std::cout << std::endl << std::endl;

    return 0;
}
