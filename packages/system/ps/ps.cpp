#include <iostream>
#include <vector>
#include <string>
#include <dirent.h>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>
#include "../../../src/sys_info.h"

struct Process {
    int pid;
    int ppid;
    int uid;
    std::string comm;
    char state;
    unsigned long long utime;
    unsigned long long stime;
    int tty_nr;
    std::string tty_name;
    std::string cmdline;
};

std::string get_tty_name(int nr) {
    if (nr == 0) return "?";
    if ((nr >> 8) == 4) return "tty" + std::to_string(nr & 0xff);
    return "?";
}

std::string get_username(int uid) {
    struct passwd *pw = getpwuid(uid);
    if (pw) return pw->pw_name;
    return std::to_string(uid);
}

Process read_proc(int pid) {
    Process p;
    p.pid = pid;
    p.uid = 0; p.ppid = 0; p.state = '?'; p.utime = 0; p.stime = 0; p.tty_nr = 0;

    std::string stat_path = "/proc/" + std::to_string(pid) + "/stat";
    std::ifstream f(stat_path);
    if (f) {
        std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        size_t r_paren = content.rfind(')');
        if (r_paren != std::string::npos) {
            p.comm = content.substr(content.find('(') + 1, r_paren - content.find('(') - 1);
            std::istringstream iss(content.substr(r_paren + 2));
            iss >> p.state >> p.ppid >> p.ppid; // skip pgrp
            int dummy;
            iss >> dummy >> p.tty_nr;
            p.tty_name = get_tty_name(p.tty_nr);
            for(int i=0; i<7; ++i) iss >> dummy;
            iss >> p.utime >> p.stime;
        }
    }

    std::ifstream f2("/proc/" + std::to_string(pid) + "/status");
    if (f2) {
        std::string line;
        while(std::getline(f2, line)) {
            if (line.find("Uid:") == 0) {
                std::stringstream ss(line.substr(4));
                ss >> p.uid;
                break;
            }
        }
    }

    std::ifstream f3("/proc/" + std::to_string(pid) + "/cmdline");
    if (f3) {
        std::string cmd;
        while(std::getline(f3, cmd, '\0')) p.cmdline += cmd + " ";
    }
    if (p.cmdline.empty()) p.cmdline = "[" + p.comm + "]";
    return p;
}

int main(int argc, char* argv[]) {
    bool full = false;
    for(int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-f") full = true;
    }

    std::vector<Process> procs;
    DIR* dir = opendir("/proc");
    if (!dir) return 1;

    struct dirent* entry;
    while((entry = readdir(dir)) != NULL) {
        if (isdigit(entry->d_name[0])) procs.push_back(read_proc(std::stoi(entry->d_name)));
    }
    closedir(dir);

    if (full) std::cout << std::left << std::setw(10) << "UID" << std::setw(6) << "PID" << std::setw(6) << "PPID" << std::setw(8) << "TIME" << "CMD" << std::endl;
    else std::cout << std::left << std::setw(6) << "PID" << std::setw(8) << "TIME" << "CMD" << std::endl;

    for (const auto& p : procs) {
        unsigned long total_time = (p.utime + p.stime) / sysconf(_SC_CLK_TCK);
        char time_buf[16];
        sprintf(time_buf, "%02lu:%02lu:%02lu", total_time / 3600, (total_time % 3600) / 60, total_time % 60);

        if (full) std::cout << std::left << std::setw(10) << get_username(p.uid) << std::setw(6) << p.pid << std::setw(6) << p.ppid << std::setw(8) << time_buf << p.cmdline << std::endl;
        else std::cout << std::left << std::setw(6) << p.pid << std::setw(8) << time_buf << p.cmdline << std::endl;
    }
    return 0;
}
