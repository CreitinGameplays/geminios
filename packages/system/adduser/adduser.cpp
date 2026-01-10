#include <iostream>
#include <sys/stat.h>
#include <unistd.h>
#include "../../../src/user_mgmt.h"
#include "../../../src/sys_info.h"

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cout << "Usage: adduser <username>\n";
        return 1;
    }
    std::string username = argv[1];
    
    if (!UserMgmt::is_valid_username(username)) {
        std::cerr << "adduser: invalid username '" << username << "'.\n";
        std::cerr << "Usernames must be 4-16 characters long and contain only lowercase letters and numbers.\n";
        return 1;
    }

    std::vector<User> users;
    UserMgmt::load_users(users);
    
    for(const auto& u : users) {
        if (u.username == username) {
            std::cerr << "adduser: user '" << username << "' already exists.\n";
            return 1;
        }
    }

    User new_user;
    new_user.username = username;
    new_user.uid = UserMgmt::get_next_uid(users);
    new_user.gid = new_user.uid; // Create group with same ID
    new_user.home = "/home/" + username;
    new_user.shell = "/bin/init"; // Default shell
    new_user.gecos = "";
    
    // Update Groups
    std::vector<Group> groups;
    UserMgmt::load_groups(groups);
    Group new_group;
    new_group.name = username;
    new_group.gid = new_user.uid;
    new_group.members.push_back(username);
    groups.push_back(new_group);

    users.push_back(new_user);

    if (UserMgmt::save_users(users) && UserMgmt::save_shadow(users) && UserMgmt::save_groups(groups)) {
        std::cout << "Created user " << username << " (UID " << new_user.uid << ")\n";
        // Create Home
        mkdir("/home", 0755);
        if (mkdir(new_user.home.c_str(), 0700) == 0) {
            if (chown(new_user.home.c_str(), new_user.uid, new_user.gid) != 0) {
                perror("adduser: failed to set home directory ownership");
            }
            std::cout << "Created home directory " << new_user.home << "\n";
        } else {
            perror("adduser: failed to create home");
        }
    } else {
        std::cerr << "adduser: failed to write configuration.\n";
        return 1;
    }
    return 0;
}
