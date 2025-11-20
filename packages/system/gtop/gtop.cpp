#include <algorithm>
#include <csignal>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <sys/sysinfo.h>
#include <unistd.h>
#include <vector>
#include "sys_info.h"

// ANSI Colors
#define CLR_RESET "\033[0m"
#define CLR_BOLD "\033[1m"
#define CLR_RED "\033[31m"
#define CLR_GREEN "\033[32m"
#define CLR_YELLOW "\033[33m"
#define CLR_BLUE "\033[34m"
#define CLR_CYAN "\033[36m"
#define CLR_WHITE "\033[37m"
#define CLR_HEADER "\033[30;47m" // Black text on White bg

volatile bool g_running = true;

void handle_sig(int) {
    g_running = false;
    const char* msg = "\n[GTOP] Caught Signal. Exiting...\n";
    write(STDOUT_FILENO, msg, strlen(msg));
}

struct ProcSnapshot {
    int pid;
    std::string name;
    char state;
    unsigned long long total_time; // utime + stime
    long rss;                      // in pages
};

struct SystemSnapshot {
    unsigned long long total_cpu_time;
    std::map<int, ProcSnapshot> processes;
};

// Helpers to read /proc
unsigned long long get_system_cpu_time() {
    std::ifstream f("/proc/stat");
    std::string line;
    if (std::getline(f, line)) { // "cpu  ..."
        std::istringstream iss(line);
        std::string cpu;
        iss >> cpu;
        unsigned long long sum = 0, val;
        while (iss >> val)
            sum += val;
        return sum;
    }
    return 0;
}

std::map<int, ProcSnapshot> get_processes() {
    std::map<int, ProcSnapshot> procs;
    DIR* dir = opendir("/proc");
    if (!dir)
        return procs;

    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!isdigit(entry->d_name[0]))
            continue;
        int pid = std::stoi(entry->d_name);

        std::string stat_path = std::string("/proc/") + entry->d_name + "/stat";
        std::ifstream f(stat_path);
        if (!f)
            continue;

        // Format of /proc/pid/stat: 123 (comm) S ...
        // Reliable parsing finds the last ')' to handle spaces in process names
        std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        size_t last_paren = content.find_last_of(')');
        if (last_paren == std::string::npos)
            continue;

        ProcSnapshot p;
        p.pid = pid;
        p.name = content.substr(content.find('(') + 1, last_paren - content.find('(') - 1);

        std::istringstream iss(content.substr(last_paren + 2));

        iss >> p.state; // Field 3

        // Skip 4-13 (10 fields)
        std::string dummy_str;
        for (int i = 0; i < 10; ++i)
            iss >> dummy_str;

        unsigned long utime, stime;
        iss >> utime >> stime; // Fields 14, 15
        p.total_time = utime + stime;

        // Skip 16-23 (8 fields)
        for (int i = 0; i < 8; ++i)
            iss >> dummy_str;

        iss >> p.rss; // Field 24

        procs[pid] = p;
    }
    closedir(dir);
    return procs;
}

struct ProcDisplay {
    int pid;
    std::string name;
    char state;
    double cpu_usage;
    double mem_usage_mb;
};

int main(int argc, char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help") { std::cout << "Usage: gtop\nDisplay system processes and resource usage.\n"; return 0; }
        if (arg == "--version") { std::cout << "gtop (" << OS_NAME << ") " << OS_VERSION << std::endl; return 0; }
    }
    signal(SIGINT, handle_sig);
    long page_size = sysconf(_SC_PAGESIZE);
    int num_procs = get_nprocs();

    std::cout << "\033[?25l"; // Hide cursor

    SystemSnapshot prev;
    prev.total_cpu_time = get_system_cpu_time();
    prev.processes = get_processes();

    while (g_running) {
        usleep(1000000); // Update every 1s

        SystemSnapshot curr;
        curr.total_cpu_time = get_system_cpu_time();
        curr.processes = get_processes();

        unsigned long long sys_delta = curr.total_cpu_time - prev.total_cpu_time;
        if (sys_delta == 0)
            sys_delta = 1;

        std::vector<ProcDisplay> display_list;
        struct sysinfo si;
        sysinfo(&si);

        for (const auto& [pid, curr_proc] : curr.processes) {
            ProcDisplay pd;
            pd.pid = pid;
            pd.name = curr_proc.name;
            pd.state = curr_proc.state;
            pd.mem_usage_mb = (curr_proc.rss * page_size) / (1024.0 * 1024.0);

            if (prev.processes.count(pid)) {
                unsigned long long proc_delta = curr_proc.total_time - prev.processes.at(pid).total_time;
                // Normalize: (proc_ticks / sys_ticks) * 100 * num_cores
                pd.cpu_usage = 100.0 * ((double)proc_delta / (double)sys_delta) * num_procs;
            } else {
                pd.cpu_usage = 0.0;
            }
            display_list.push_back(pd);
        }

        std::sort(display_list.begin(), display_list.end(), [](const ProcDisplay& a, const ProcDisplay& b) {
            return a.cpu_usage > b.cpu_usage;
        });

        std::cout << "\033[H\033[2J"; // Home and Clear

        long total_ram = si.totalram * si.mem_unit / (1024 * 1024);
        long free_ram = si.freeram * si.mem_unit / (1024 * 1024);
        long used_ram = total_ram - free_ram;

        std::cout << CLR_BOLD << CLR_CYAN << "GeminiOS gtop" << CLR_RESET
                  << " | " << CLR_GREEN << "Uptime: " << si.uptime << "s" << CLR_RESET
                  << " | Procs: " << si.procs << std::endl;

        std::cout << "RAM: " << CLR_YELLOW << used_ram << "MB" << CLR_RESET
                  << " / " << total_ram << "MB" << std::endl;
        std::cout << std::string(50, '-') << std::endl;

        std::cout << CLR_HEADER
                  << std::left << std::setw(6) << "PID"
                  << std::setw(10) << "USER"
                  << std::setw(4) << "S"
                  << std::setw(8) << "%CPU"
                  << std::setw(10) << "MEM(MB)"
                  << "COMMAND" << CLR_RESET << std::endl;

        int row_limit = 20;
        for (int i = 0; i < std::min((int)display_list.size(), row_limit); ++i) {
            const auto& p = display_list[i];
            std::cout << std::left << std::setw(6) << p.pid
                      << std::setw(10) << "root" // Placeholder
                      << std::setw(4) << p.state;

            if (p.cpu_usage > 50.0)
                std::cout << CLR_RED;
            else if (p.cpu_usage > 10.0)
                std::cout << CLR_YELLOW;
            else
                std::cout << CLR_GREEN;

            std::cout << std::fixed << std::setprecision(1) << std::setw(8) << p.cpu_usage << CLR_RESET;
            std::cout << std::fixed << std::setprecision(1) << std::setw(10) << p.mem_usage_mb
                      << p.name << std::endl;
        }

        prev = curr;
    }

    std::cout << "\033[?25h"; // Show cursor
    return 0;
}
