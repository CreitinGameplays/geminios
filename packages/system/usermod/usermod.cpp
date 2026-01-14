#include <iostream>
#include <unistd.h>
#include "user_mgmt.h"

int main(int argc, char* argv[]) {
    std::string new_name, new_home;
    std::string username;

    for (int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-l" && i+1 < argc) new_name = argv[++i];
        else if (arg == "-d" && i+1 < argc) new_home = argv[++i];
        else username = arg;
    }

    if (username.empty()) {
        std::cout << "Usage: usermod [-l new_name] [-d new_home] <username>\n";
        return 1;
    }

    std::vector<User> users;
    if (!UserMgmt::load_users(users)) return 1;

    bool modified = false;
    for (auto& u : users) {
        if (u.username == username) {
            if (!new_name.empty()) {
                if (!UserMgmt::is_valid_username(new_name)) {
                    std::cerr << "usermod: invalid new username '" << new_name << "'.\n";
                    return 1;
                }
                std::cout << "Changing name: " << u.username << " -> " << new_name << "\n";
                u.username = new_name;
                modified = true;
            }
            if (!new_home.empty()) {
                std::cout << "Changing home: " << u.home << " -> " << new_home << "\n";
                // TODO: actually move directory
                u.home = new_home;
                modified = true;
            }
        }
    }

    if (modified) {
        if (UserMgmt::save_users(users) && UserMgmt::save_shadow(users)) {
            std::cout << "usermod: success\n";
        } else {
            std::cerr << "usermod: failed to save\n";
        }
    } else {
        std::cerr << "usermod: user not found or nothing to do.\n";
    }
    return 0;
}
