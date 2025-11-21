#include <iostream>
#include <vector>
#include <algorithm>
#include <unistd.h>
#include <cstdlib>
#include "../../../src/user_mgmt.h"
#include "../../../src/sys_info.h"

// Recursive removal helper (simple wrapper around rm -rf logic would be better, but system() is available)
void remove_home(const std::string& path) {
    if (path.empty() || path == "/") return;
    std::string cmd = "rm -rf " + path;
    system(cmd.c_str()); 
}

int main(int argc, char* argv[]) {
    bool remove_files = false;
    std::string username;
    
    for (int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-r") remove_files = true;
        else username = arg;
    }

    if (username.empty()) {
        std::cout << "Usage: userdel [-r] <username>\n";
        return 1;
    }

    if (username == "gemini" || username == "root") {
        std::cerr << "userdel: refusing to remove root account\n";
        return 1;
    }

    std::vector<User> users;
    UserMgmt::load_users(users);
    
    auto it = std::remove_if(users.begin(), users.end(), [&](const User& u){ return u.username == username; });
    if (it == users.end()) {
        std::cerr << "userdel: user '" << username << "' not found.\n";
        return 1;
    }
    
    std::string home_dir = it->home;
    users.erase(it, users.end());

    if (UserMgmt::save_users(users) && UserMgmt::save_shadow(users)) {
        std::cout << "User " << username << " removed.\n";
        if (remove_files) {
            std::cout << "Removing home directory " << home_dir << "...\n";
            remove_home(home_dir);
        }
    } else {
        std::cerr << "userdel: failed to update database.\n";
        return 1;
    }
    return 0;
}
