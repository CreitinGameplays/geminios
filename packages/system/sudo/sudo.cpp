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
#include <cctype>
#include <cstdlib>
#include <sys/stat.h>
#include <ctime>
#include "user_mgmt.h"
#include "sys_info.h"

// Configuration
const double DEFAULT_SUDO_TIMEOUT_MINUTES = 15.0;
const char* SUDO_TS_DIR = "/run/sudo/ts";

std::string trim_copy(const std::string& input) {
    auto begin = std::find_if_not(input.begin(), input.end(), [](unsigned char c) {
        return std::isspace(c);
    });
    auto end = std::find_if_not(input.rbegin(), input.rend(), [](unsigned char c) {
        return std::isspace(c);
    }).base();
    if (begin >= end) {
        return "";
    }
    return std::string(begin, end);
}

std::string strip_comments(const std::string& input) {
    size_t comment = input.find('#');
    if (comment == std::string::npos) {
        return input;
    }
    return input.substr(0, comment);
}

std::vector<std::string> split_string(const std::string& input, char separator) {
    std::vector<std::string> parts;
    std::stringstream ss(input);
    std::string part;
    while (std::getline(ss, part, separator)) {
        parts.push_back(trim_copy(part));
    }
    return parts;
}

bool defaults_line_applies_to_user(const std::string& token, const std::string& user) {
    if (token == "Defaults") {
        return true;
    }

    const std::string prefix = "Defaults:";
    if (token.rfind(prefix, 0) != 0) {
        return false;
    }

    for (const auto& candidate : split_string(token.substr(prefix.size()), ',')) {
        if (candidate == user) {
            return true;
        }
    }
    return false;
}

double get_sudo_timeout_minutes(const std::string& user) {
    std::ifstream f("/etc/sudoers");
    if (!f) {
        return DEFAULT_SUDO_TIMEOUT_MINUTES;
    }

    double timeout_minutes = DEFAULT_SUDO_TIMEOUT_MINUTES;
    std::string raw_line;
    while (std::getline(f, raw_line)) {
        std::string line = trim_copy(strip_comments(raw_line));
        if (line.empty()) {
            continue;
        }

        std::stringstream ss(line);
        std::string token;
        ss >> token;
        if (!defaults_line_applies_to_user(token, user)) {
            continue;
        }

        std::string remainder;
        std::getline(ss, remainder);
        for (const auto& option : split_string(remainder, ',')) {
            const std::string prefix = "timestamp_timeout=";
            if (option.rfind(prefix, 0) != 0) {
                continue;
            }
            const std::string value = trim_copy(option.substr(prefix.size()));
            if (value.empty()) {
                continue;
            }
            char* end_ptr = nullptr;
            const double parsed = std::strtod(value.c_str(), &end_ptr);
            if (end_ptr && *end_ptr == '\0') {
                timeout_minutes = parsed;
            }
        }
    }

    return timeout_minutes;
}

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

bool is_member_of_privileged_group(const std::vector<std::string>& user_groups) {
    for (const auto& group : user_groups) {
        if (group == "root" || group == "sudo" || group == "wheel") {
            return true;
        }
    }
    return false;
}

bool check_sudoers(const std::string& user, const std::vector<std::string>& user_groups) {
    std::ifstream f("/etc/sudoers");
    if (!f) {
        return false;
    }

    bool saw_rule = false;
    std::string line;
    while(std::getline(f, line)) {
        line = trim_copy(strip_comments(line));

        if (line.empty()) continue;

        std::stringstream ss(line);
        std::string subject;
        ss >> subject;

        if (subject.empty()) continue;
        if (subject.rfind("Defaults", 0) == 0) continue;
        saw_rule = true;

        if (subject[0] == '%') {
            std::string grp = subject.substr(1);
            for(const auto& g : user_groups) if(g == grp) return true;
        } else {
            if (subject == user) return true;
        }
    }
    return saw_rule ? false : is_member_of_privileged_group(user_groups);
}

std::string get_tty_name() {
    char* tty = ttyname(STDIN_FILENO);
    if (!tty) return "unknown";
    std::string s(tty);
    size_t last_slash = s.find_last_of('/');
    if (last_slash != std::string::npos) return s.substr(last_slash + 1);
    return s;
}

bool check_timestamp(uid_t uid, double timeout_minutes) {
    if (timeout_minutes == 0.0) {
        return false;
    }

    std::string tty = get_tty_name();
    std::string ts_path = std::string(SUDO_TS_DIR) + "/" + std::to_string(uid) + "_" + tty;
    
    struct stat st;
    if (stat(ts_path.c_str(), &st) == 0) {
        if (timeout_minutes < 0.0) {
            return true;
        }

        const double age_seconds = std::difftime(time(nullptr), st.st_mtime);
        if (age_seconds < timeout_minutes * 60.0) {
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

    if (!is_member_of_privileged_group(user_groups) &&
        !check_sudoers(current_user->username, user_groups)) {
        std::cerr << current_user->username << " is not allowed to use sudo on this system.\n";
        return 1;
    }

    // 6. Authenticate (Ask for CURRENT USER'S password)
    const double timeout_minutes = get_sudo_timeout_minutes(current_user->username);

    // First, check if we have a valid timestamp
    bool authenticated = check_timestamp(real_uid, timeout_minutes);

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
