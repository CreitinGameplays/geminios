#include <iostream>
#include <vector>
#include <string>
#include <fstream>
#include <sstream>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <cstring>
#include <algorithm>
#include <sys/stat.h>
#include <ctime>
#include "../../../src/user_mgmt.h"
#include "../../../src/sys_info.h"

// Configuration
const int SUDO_TIMEOUT_MINUTES = 15;
const char* SUDO_TS_DIR = "/run/sudo/ts";

// Helper to read password without echo
std::string get_pass(const std::string& prompt) {
    std::cout << prompt;
    std::cout << std::flush;
    
    struct termios oldt, newt;
    if (tcgetattr(STDIN_FILENO, &oldt) != 0) {
        return "";
    }
    newt = oldt;
    newt.c_lflag &= ~ECHO;
    tcsetattr(STDIN_FILENO, TCSANOW, &newt);
    
    std::string s;
    std::getline(std::cin, s);
    
    tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    std::cout << std::endl;
    return s;
}

void print_usage() {
    std::cout << "Usage: sudo [-u user] <command> [args...]\n";
}

bool check_sudoers(const std::string& user, const std::vector<std::string>& user_groups) {
    std::ifstream f("/etc/sudoers");
    if (!f) {
        std::cerr << "sudo: unable to open /etc/sudoers: " << strerror(errno) << "\n";
        return false;
    }

    std::string line;
    while(std::getline(f, line)) {
        // Strip comments
        size_t comment = line.find('#');
        if(comment != std::string::npos) line = line.substr(0, comment);
        
        if (line.empty()) continue;

        std::stringstream ss(line);
        std::string subject;
        ss >> subject;

        if (subject.empty()) continue;

        if (subject[0] == '%') {
            std::string grp = subject.substr(1);
            for(const auto& g : user_groups) if(g == grp) return true;
        } else {
            if (subject == user) return true;
        }
    }
    return false;
}

std::string get_tty_name() {
    char* tty = ttyname(STDIN_FILENO);
    if (!tty) return "unknown";
    std::string s(tty);
    size_t last_slash = s.find_last_of('/');
    if (last_slash != std::string::npos) return s.substr(last_slash + 1);
    return s;
}

bool check_timestamp(uid_t uid) {
    std::string tty = get_tty_name();
    std::string ts_path = std::string(SUDO_TS_DIR) + "/" + std::to_string(uid) + "_" + tty;
    
    struct stat st;
    if (stat(ts_path.c_str(), &st) == 0) {
        time_t now = time(nullptr);
        if (now - st.st_mtime < SUDO_TIMEOUT_MINUTES * 60) {
            return true;
        }
    }
    return false;
}

void update_timestamp(uid_t uid) {
    mkdir("/run/sudo", 0700);
    mkdir(SUDO_TS_DIR, 0700);
    
    std::string tty = get_tty_name();
    std::string ts_path = std::string(SUDO_TS_DIR) + "/" + std::to_string(uid) + "_" + tty;
    
    std::ofstream f(ts_path);
    f << time(nullptr);
    f.close();
    chmod(ts_path.c_str(), 0600);
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        print_usage();
        return 1;
    }

    int cmd_idx = 1;
    std::string target_username = "root";

    // Argument Parsing
    if (std::string(argv[1]) == "-u" && argc >= 4) {
        target_username = argv[2];
        cmd_idx = 3;
    }

    std::string arg1 = argv[cmd_idx];
    if (arg1 == "--help") {
        print_usage();
        return 0;
    }
    if (arg1 == "--version") {
        std::cout << "sudo (" << OS_NAME << ") " << OS_VERSION << std::endl;
        return 0;
    }

    // 1. Identify the Real User (Caller)
    uid_t real_uid = getuid();
    
    // If already root and NO -u flag, just exec
    if (real_uid == 0 && cmd_idx == 1) {
        execvp(argv[1], &argv[1]);
        perror("sudo: execvp");
        return 1;
    }

    // 2. Load User & Group Database
    std::vector<User> users;
    std::vector<Group> groups;
    if (!UserMgmt::load_users(users) || !UserMgmt::load_groups(groups)) {
        std::cerr << "sudo: Failed to load authentication database.\n";
        return 1;
    }

    // 3. Find the User Object
    User* current_user = nullptr;
    for (auto& u : users) {
        if (u.uid == real_uid) {
            current_user = &u;
            break;
        }
    }

    if (!current_user) {
        std::cerr << "sudo: You do not exist in the passwd file (UID=" << real_uid << ").\n";
        return 1;
    }

    // 4. Find Target User
    User* target_user = nullptr;
    for (auto& u : users) {
        if (u.username == target_username) {
            target_user = &u;
            break;
        }
    }
    if (!target_user) {
        std::cerr << "sudo: unknown user: " << target_username << "\n";
        return 1;
    }

    // 5. Check Permissions (Member of 'sudo' or 'wheel' or 'root' group)
    // Identify all groups user is a member of
    std::vector<std::string> user_groups;
    // Check primary group
    for(const auto& g : groups) {
        if(g.gid == current_user->gid) user_groups.push_back(g.name);
    }
    // Check supplementary
    for (const auto& g : groups) {
        for (const auto& member : g.members) {
            if (member == current_user->username) {
                user_groups.push_back(g.name);
                break;
            }
        }
    }

    if (!check_sudoers(current_user->username, user_groups)) {
        std::cerr << current_user->username << " is not in the sudoers file. This incident will be reported.\n";
        return 1;
    }

    // 6. Authenticate (Ask for CURRENT USER'S password)
    // First, check if we have a valid timestamp
    bool authenticated = check_timestamp(real_uid);

    if (!authenticated) {
        // Allow 3 attempts
        for (int attempt = 0; attempt < 3; ++attempt) {
            std::string prompt = "[sudo] password for " + current_user->username + ": ";
            std::string input = get_pass(prompt);
            
            if (UserMgmt::check_password(input, current_user->password)) {
                authenticated = true;
                update_timestamp(real_uid);
                break;
            } else {
                std::cout << "Sorry, try again.\n";
            }
        }
    } else {
        // Update timestamp even if we didn't ask for password (extend the window)
        update_timestamp(real_uid);
    }

    if (!authenticated) {
        std::cerr << "sudo: 3 incorrect password attempts\n";
        return 1;
    }

    // 7. Change Identity
    if (setgid(target_user->gid) != 0 || setuid(target_user->uid) != 0) {
        perror("sudo: failed to switch user");
        return 1;
    }

    // Update Env Vars
    setenv("HOME", target_user->home.c_str(), 1);
    setenv("USER", target_user->username.c_str(), 1);
    setenv("LOGNAME", target_user->username.c_str(), 1);
    setenv("SHELL", target_user->shell.c_str(), 1);
    // Preserve PATH or set secure path
    setenv("PATH", "/bin/apps/system:/bin/apps:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin", 1);
    setenv("LD_LIBRARY_PATH", "/lib:/usr/lib:/usr/local/lib:/lib64:/usr/lib64", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("LC_ALL", "C.UTF-8", 1);
    setenv("PYTHONUTF8", "1", 1);
    setenv("PYTHONHOME", "/usr", 1);
    // Set SUDO variables
    setenv("SUDO_USER", current_user->username.c_str(), 1);
    setenv("SUDO_UID", std::to_string(real_uid).c_str(), 1);
    setenv("SUDO_GID", std::to_string(current_user->gid).c_str(), 1);

    // 8. Execute
    execvp(argv[cmd_idx], &argv[cmd_idx]);
    
    // If we get here, exec failed
    perror(("sudo: " + std::string(argv[cmd_idx])).c_str());
    return 1;
}