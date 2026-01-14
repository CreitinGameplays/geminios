#include <iostream>
#include <unistd.h>
#include <termios.h>
#include "user_mgmt.h"
#include "sys_info.h"

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
    if (argc > 1 && std::string(argv[1]) == "--help") {
        std::cout << "Usage: passwd [username]\nChange user password.\n";
        return 0;
    }

    std::vector<User> users;
    if (!UserMgmt::load_users(users)) {
        std::cerr << "passwd: Failed to load user database.\n";
        return 1;
    }

    std::string target_user;
    uid_t uid = getuid(); // Likely 0 in this OS
    
    if (argc > 1) {
        target_user = argv[1];
    } else {
        // Find name for current UID (likely 0/gemini)
        for(const auto& u : users) {
            if (u.uid == uid) { target_user = u.username; break; }
        }
        if (target_user.empty()) target_user = "gemini";
    }

    // Find user object
    User* u_ptr = nullptr;
    for (auto& u : users) {
        if (u.username == target_user) {
            u_ptr = &u;
            break;
        }
    }

    if (!u_ptr) {
        std::cerr << "passwd: User '" << target_user << "' not found.\n";
        return 1;
    }

    std::cout << "Changing password for " << target_user << "." << std::endl;
    std::string p1 = get_pass("New password: ");
    std::string p2 = get_pass("Retype new password: ");

    if (p1 != p2) {
        std::cerr << "passwd: Passwords do not match.\n";
        return 1;
    }

    u_ptr->password = UserMgmt::hash_password(p1);

    if (UserMgmt::save_shadow(users)) {
        std::cout << "passwd: password updated successfully\n";
    } else {
        std::cerr << "passwd: failed to update shadow file\n";
        return 1;
    }

    return 0;
}
