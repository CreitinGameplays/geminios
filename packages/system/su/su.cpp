#include <iostream>
#include <vector>
#include <unistd.h>
#include <sys/types.h>
#include <termios.h>
#include <cstring>
#include "../../../src/user_mgmt.h"
#include "../../../src/sys_info.h"

// Helper to read password without echo
std::string get_pass(const std::string& prompt) {
    std::cout << prompt;
    struct termios oldt, newt;
    tcgetattr(STDIN_FILENO, &oldt);
    newt = oldt;
    newt.c_lflag &= ~ECHO;
    tcsetattr(STDIN_FILENO, TCSANOW, &newt);
    std::string s;
    std::getline(std::cin, s);
    tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    std::cout << std::endl;
    return s;
}

int main(int argc, char* argv[]) {
    std::string target_user = "gemini"; // Default to root
    
    if (argc > 1) {
        target_user = argv[1];
        if (target_user == "-") target_user = "gemini"; // handle 'su -' partly
    }

    std::vector<User> users;
    if (!UserMgmt::load_users(users)) {
        std::cerr << "su: Failed to load user database.\n";
        return 1;
    }

    User* u_ptr = nullptr;
    for (auto& u : users) {
        if (u.username == target_user) {
            u_ptr = &u;
            break;
        }
    }

    if (!u_ptr) {
        std::cerr << "su: User '" << target_user << "' not found.\n";
        return 1;
    }

    // Authenticate
    uid_t current_uid = getuid();
    if (current_uid != 0) {
        std::string pwd = get_pass("Password: ");
        if (!UserMgmt::check_password(pwd, u_ptr->password)) {
            std::cout << "su: Authentication failure\n";
            return 1;
        }
    }

    // Change Identity
    // We must set GID first, then UID
    if (setgid(u_ptr->gid) != 0) {
        perror("su: setgid");
        return 1;
    }
    
    // Initgroups would go here to set supplementary groups

    if (setuid(u_ptr->uid) != 0) {
        perror("su: setuid");
        return 1;
    }

    // Setup Environment
    setenv("HOME", u_ptr->home.c_str(), 1);
    setenv("USER", u_ptr->username.c_str(), 1);
    setenv("SHELL", u_ptr->shell.c_str(), 1);

    chdir(u_ptr->home.c_str());

    // Execute Shell
    // If shell is /bin/init, our modified init.cpp will handle being run as a shell
    execl(u_ptr->shell.c_str(), u_ptr->shell.c_str(), NULL);
    
    perror("su: exec failed");
    return 1;
}
