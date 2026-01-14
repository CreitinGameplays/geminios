#include <iostream>
#include <vector>
#include <string>
#include <getopt.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <sstream>
#include "user_mgmt.h"

void print_usage() {
    std::cout << "Usage: useradd [options] LOGIN\n"
              << "\n"
              << "Options:\n"
              << "  -c, --comment COMMENT         GECOS field of the new account\n"
              << "  -d, --home-dir HOME_DIR       home directory of the new account\n"
              << "  -g, --gid GROUP               name or ID of the primary group of the new account\n"
              << "  -G, --groups GROUPS           list of supplementary groups of the new account\n"
              << "  -m, --create-home             create the user's home directory\n"
              << "  -r, --system                  create a system account\n"
              << "  -s, --shell SHELL             login shell of the new account\n"
              << "  -u, --uid UID                 user ID of the new account\n"
              << "  -h, --help                    display this help message and exit\n";
}

int main(int argc, char* argv[]) {
    std::string comment = "";
    std::string home_dir = "";
    std::string gid_str = "";
    std::string groups_str = "";
    bool create_home = false;
    bool system_account = false;
    std::string shell = "/bin/bash";
    int uid = -1;

    static struct option long_options[] = {
        {"comment", required_argument, 0, 'c'},
        {"home-dir", required_argument, 0, 'd'},
        {"gid", required_argument, 0, 'g'},
        {"groups", required_argument, 0, 'G'},
        {"create-home", no_argument, 0, 'm'},
        {"system", no_argument, 0, 'r'},
        {"shell", required_argument, 0, 's'},
        {"uid", required_argument, 0, 'u'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "c:d:g:G:mrs:u:h", long_options, NULL)) != -1) {
        switch (opt) {
            case 'c': comment = optarg; break;
            case 'd': home_dir = optarg; break;
            case 'g': gid_str = optarg; break;
            case 'G': groups_str = optarg; break;
            case 'm': create_home = true; break;
            case 'r': system_account = true; break;
            case 's': shell = optarg; break;
            case 'u': uid = std::stoi(optarg); break;
            case 'h': print_usage(); return 0;
            default: print_usage(); return 1;
        }
    }

    if (optind >= argc) {
        std::cerr << "useradd: login name missing\n";
        print_usage();
        return 1;
    }

    std::string username = argv[optind];

    if (!UserMgmt::is_valid_username(username)) {
        std::cerr << "useradd: invalid username '" << username << "'\n";
        return 1;
    }

    std::vector<User> users;
    if (!UserMgmt::load_users(users)) {
        std::cerr << "useradd: failed to load users\n";
        return 1;
    }

    for (const auto& u : users) {
        if (u.username == username) {
            std::cerr << "useradd: user '" << username << "' already exists\n";
            return 1;
        }
    }

    User new_user;
    new_user.username = username;
    
    if (uid != -1) {
        new_user.uid = uid;
    } else {
        if (system_account) {
            // Find next system UID (usually < 1000)
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
        } else {
            new_user.uid = UserMgmt::get_next_uid(users);
        }
    }

    // Default home directory
    if (home_dir.empty()) {
        if (system_account) {
            new_user.home = "/var/lib/" + username;
        } else {
            new_user.home = "/home/" + username;
        }
    } else {
        new_user.home = home_dir;
    }

    new_user.shell = shell;
    new_user.gecos = comment;

    // Groups management
    std::vector<Group> groups;
    UserMgmt::load_groups(groups);

    if (gid_str.empty()) {
        // Create a new group with the same name and GID as the user
        new_user.gid = new_user.uid;
        Group new_group;
        new_group.name = username;
        new_group.gid = new_user.uid;
        new_group.members.push_back(username);
        groups.push_back(new_group);
    } else {
        // Try to find group by name or ID
        bool group_found = false;
        try {
            int gid = std::stoi(gid_str);
            for (auto& g : groups) {
                if (g.gid == (gid_t)gid) {
                    new_user.gid = g.gid;
                    g.members.push_back(username);
                    group_found = true;
                    break;
                }
            }
        } catch (...) {
            for (auto& g : groups) {
                if (g.name == gid_str) {
                    new_user.gid = g.gid;
                    g.members.push_back(username);
                    group_found = true;
                    break;
                }
            }
        }
        if (!group_found) {
            std::cerr << "useradd: group '" << gid_str << "' does not exist\n";
            return 1;
        }
    }

    // Supplementary groups
    if (!groups_str.empty()) {
        std::stringstream ss(groups_str);
        std::string group_name;
        while (std::getline(ss, group_name, ',')) {
            bool found = false;
            for (auto& g : groups) {
                if (g.name == group_name) {
                    g.members.push_back(username);
                    found = true;
                    break;
                }
            }
            if (!found) {
                std::cerr << "useradd: supplementary group '" << group_name << "' does not exist\n";
                // We could choose to fail or just warn. useradd usually fails.
                return 1;
            }
        }
    }

    users.push_back(new_user);

    if (UserMgmt::save_users(users) && UserMgmt::save_shadow(users) && UserMgmt::save_groups(groups)) {
        std::cout << "useradd: created user " << username << " (UID " << new_user.uid << ")\n";
        
        if (create_home) {
            if (mkdir(new_user.home.c_str(), 0700) == 0) {
                if (chown(new_user.home.c_str(), new_user.uid, new_user.gid) != 0) {
                    perror("useradd: failed to set home directory ownership");
                }
                std::cout << "useradd: created home directory " << new_user.home << "\n";
            } else {
                perror("useradd: failed to create home");
            }
        }
    } else {
        std::cerr << "useradd: failed to save configuration\n";
        return 1;
    }

    return 0;
}
