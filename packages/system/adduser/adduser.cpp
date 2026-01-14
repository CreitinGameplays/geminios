#include <iostream>
#include <vector>
#include <string>
#include <getopt.h>
#include <sys/stat.h>
#include <unistd.h>
#include "user_mgmt.h"

void print_usage() {
    std::cout << "Usage: adduser [options] user\n"
              << "       adduser [options] user group\n"
              << "\n"
              << "Options:\n"
              << "  --system              create a system account\n"
              << "  --home DIR            use DIR for the home directory\n"
              << "  --shell SHELL         use SHELL for the user's shell\n"
              << "  --gecos GECOS         set the GECOS field for the new entry\n"
              << "  --help                display this help and exit\n";
}

int main(int argc, char* argv[]) {
    bool system_account = false;
    std::string home_dir = "";
    std::string shell = "";
    std::string gecos = "";

    static struct option long_options[] = {
        {"system", no_argument, 0, 'S'},
        {"home", required_argument, 0, 'H'},
        {"shell", required_argument, 0, 's'},
        {"gecos", required_argument, 0, 'g'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "SH:s:g:h", long_options, NULL)) != -1) {
        switch (opt) {
            case 'S': system_account = true; break;
            case 'H': home_dir = optarg; break;
            case 's': shell = optarg; break;
            case 'g': gecos = optarg; break;
            case 'h': print_usage(); return 0;
            default: print_usage(); return 1;
        }
    }

    if (optind >= argc) {
        print_usage();
        return 1;
    }

    std::string username = argv[optind++];

    // Case: adduser user group
    if (optind < argc) {
        std::string group_name = argv[optind];
        std::vector<Group> groups;
        if (!UserMgmt::load_groups(groups)) {
            std::cerr << "adduser: failed to load groups\n";
            return 1;
        }
        
        bool found = false;
        for (auto& g : groups) {
            if (g.name == group_name) {
                // Check if user exists
                std::vector<User> users;
                UserMgmt::load_users(users);
                bool user_exists = false;
                for (const auto& u : users) {
                    if (u.username == username) {
                        user_exists = true;
                        break;
                    }
                }
                if (!user_exists) {
                    std::cerr << "adduser: user '" << username << "' does not exist\n";
                    return 1;
                }

                // Check if already member
                for (const auto& m : g.members) {
                    if (m == username) {
                        std::cout << "The user '" << username << "' is already a member of '" << group_name << "'.\n";
                        return 0;
                    }
                }
                g.members.push_back(username);
                found = true;
                break;
            }
        }

        if (!found) {
            std::cerr << "adduser: group '" << group_name << "' does not exist\n";
            return 1;
        }

        if (UserMgmt::save_groups(groups)) {
            std::cout << "Adding user '" << username << "' to group '" << group_name << "' ...\n";
            std::cout << "Done.\n";
            return 0;
        } else {
            std::cerr << "adduser: failed to save groups\n";
            return 1;
        }
    }

    // Case: adduser user
    if (!UserMgmt::is_valid_username(username)) {
        std::cerr << "adduser: invalid username '" << username << "'\n";
        return 1;
    }

    std::vector<User> users;
    UserMgmt::load_users(users);
    for (const auto& u : users) {
        if (u.username == username) {
            std::cerr << "adduser: user '" << username << "' already exists\n";
            return 0; // Debian's adduser exits with 0 if user already exists sometimes, or we can just exit
        }
    }

    // Prepare arguments for useradd call or implement directly
    // Let's implement directly to avoid dependency on useradd being in path during build if needed
    // But since we are building both, we can use the library logic.
    
    User new_user;
    new_user.username = username;
    
    if (system_account) {
        int next_uid = 100;
        bool found = false;
        while (!found) {
            found = true;
            for (const auto& u : users) {
                if (u.uid == next_uid) {
                    next_uid++;
                    found = false;
                    break;
                }
            }
        }
        new_user.uid = next_uid;
        if (shell.empty()) new_user.shell = "/bin/false";
        else new_user.shell = shell;
        if (home_dir.empty()) new_user.home = "/var/lib/" + username;
        else new_user.home = home_dir;
    } else {
        new_user.uid = UserMgmt::get_next_uid(users);
        if (shell.empty()) new_user.shell = "/bin/bash";
        else new_user.shell = shell;
        if (home_dir.empty()) new_user.home = "/home/" + username;
        else new_user.home = home_dir;
    }
    
    new_user.gid = new_user.uid;
    new_user.gecos = gecos;

    // Create group
    std::vector<Group> groups;
    UserMgmt::load_groups(groups);
    Group new_group;
    new_group.name = username;
    new_group.gid = new_user.uid;
    new_group.members.push_back(username);
    groups.push_back(new_group);

    users.push_back(new_user);

    if (UserMgmt::save_users(users) && UserMgmt::save_shadow(users) && UserMgmt::save_groups(groups)) {
        std::cout << "Adding user '" << username << "' ...\n";
        std::cout << "Adding new group '" << username << "' (" << new_user.gid << ") ...\n";
        std::cout << "Adding new user '" << username << "' (" << new_user.uid << ") with group '" << username << "' ...\n";
        
        // Create home
        if (system_account && home_dir.empty()) {
             // System accounts might not need home created by default if not specified
             // but Debian adduser --system usually doesn't create home unless --create-home is given
             // wait, Debian adduser --system creates home if it doesn't exist?
             // Actually it depends on configuration.
             // Let's create it if it's a system user too, for compatibility with the lightdm builder expectations.
             mkdir(new_user.home.c_str(), 0755);
             chown(new_user.home.c_str(), new_user.uid, new_user.gid);
        } else {
             mkdir(new_user.home.c_str(), 0755);
             chown(new_user.home.c_str(), new_user.uid, new_user.gid);
        }
        std::cout << "Creating home directory '" << new_user.home << "' ...\n";
    } else {
        std::cerr << "adduser: failed to save configuration\n";
        return 1;
    }

    return 0;
}