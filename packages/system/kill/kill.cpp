#include <iostream>
#include <string>
#include <csignal>
#include <vector>
#include "../../../src/sys_info.h"

void list_signals() {
    std::cout << " 1) SIGHUP       2) SIGINT       3) SIGQUIT      4) SIGILL\n"
              << " 5) SIGTRAP      6) SIGABRT      7) SIGBUS       8) SIGFPE\n"
              << " 9) SIGKILL     10) SIGUSR1     11) SIGSEGV     12) SIGUSR2\n"
              << "13) SIGPIPE     14) SIGALRM     15) SIGTERM     17) SIGCHLD\n"
              << "18) SIGCONT     19) SIGSTOP     20) SIGTSTP     21) SIGTTIN\n"
              << "22) SIGTTOU\n";
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cout << "Usage: kill [options] <pid>...\n";
        return 1;
    }

    int sig = SIGTERM;
    std::vector<int> pids;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-l") {
            list_signals();
            return 0;
        } else if (arg == "--help") {
            std::cout << "Usage: kill [options] <pid>...\n"
                      << "Options:\n"
                      << "  -<sig>    Signal number (e.g., -9)\n"
                      << "  -l        List signals\n";
            return 0;
        } else if (arg[0] == '-') {
            try { sig = std::stoi(arg.substr(1)); } catch(...) {}
        } else {
            try { pids.push_back(std::stoi(arg)); } catch(...) {}
        }
    }

    int ret = 0;
    for (int pid : pids) {
        if (kill(pid, sig) != 0) {
            perror(("kill " + std::to_string(pid)).c_str());
            ret = 1;
        }
    }
    return ret;
}
