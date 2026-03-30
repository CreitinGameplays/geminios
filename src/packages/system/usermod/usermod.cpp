#include <algorithm>
#include <getopt.h>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

#include "user_mgmt.h"

namespace {
void print_usage() {
    std::cout << "Usage: usermod [options] <username>\n"
              << "\n"
              << "Options:\n"
              << "  -l NEW_NAME              change the login name\n"
              << "  -d NEW_HOME              change the home directory path\n"
              << "  -aG GROUP[,GROUP...]     append the user to supplementary groups\n"
              << "  -G GROUP[,GROUP...]      replace supplementary groups\n"
              << "  -h                       display this help and exit\n";
}

std::vector<std::string> split_csv(const std::string& value) {
    std::vector<std::string> items;
    std::stringstream ss(value);
    std::string item;
    while (std::getline(ss, item, ',')) {
        if (!item.empty()) items.push_back(item);
    }
    return items;
}

bool group_exists(const std::vector<Group>& groups, const std::string& name) {
    for (const auto& group : groups) {
        if (group.name == name) return true;
    }
    return false;
}
}

int main(int argc, char* argv[]) {
    std::string new_name;
    std::string new_home;
    std::string group_list;
    bool append_groups = false;

    int opt = 0;
    while ((opt = getopt(argc, argv, "l:d:aG:h")) != -1) {
        switch (opt) {
            case 'l':
                new_name = optarg;
                break;
            case 'd':
                new_home = optarg;
                break;
            case 'a':
                append_groups = true;
                break;
            case 'G':
                group_list = optarg;
                break;
            case 'h':
                print_usage();
                return 0;
            default:
                print_usage();
                return 1;
        }
    }

    if (optind >= argc) {
        print_usage();
        return 1;
    }

    if (append_groups && group_list.empty()) {
        std::cerr << "usermod: -a must be used together with -G.\n";
        return 1;
    }

    std::string username = argv[optind++];
    if (optind != argc) {
        print_usage();
        return 1;
    }

    std::vector<User> users;
    std::vector<Group> groups;
    if (!UserMgmt::load_users(users) || !UserMgmt::load_groups(groups)) {
        std::cerr << "usermod: failed to load account database.\n";
        return 1;
    }

    auto user_it = std::find_if(users.begin(), users.end(), [&](const User& user) {
        return user.username == username;
    });
    if (user_it == users.end()) {
        std::cerr << "usermod: user '" << username << "' does not exist.\n";
        return 1;
    }

    bool user_modified = false;
    bool groups_modified = false;
    std::string effective_username = user_it->username;

    if (!new_name.empty()) {
        if (!UserMgmt::is_valid_username(new_name)) {
            std::cerr << "usermod: invalid new username '" << new_name << "'.\n";
            return 1;
        }

        auto duplicate = std::find_if(users.begin(), users.end(), [&](const User& user) {
            return user.username == new_name && &user != &(*user_it);
        });
        if (duplicate != users.end()) {
            std::cerr << "usermod: user '" << new_name << "' already exists.\n";
            return 1;
        }

        std::cout << "Changing name: " << user_it->username << " -> " << new_name << "\n";
        for (auto& group : groups) {
            for (auto& member : group.members) {
                if (member == effective_username) {
                    member = new_name;
                    groups_modified = true;
                }
            }
        }
        user_it->username = new_name;
        effective_username = new_name;
        user_modified = true;
    }

    if (!new_home.empty() && user_it->home != new_home) {
        std::cout << "Changing home: " << user_it->home << " -> " << new_home << "\n";
        // TODO: actually move the directory contents when requested.
        user_it->home = new_home;
        user_modified = true;
    }

    if (!group_list.empty()) {
        std::vector<std::string> requested_groups = split_csv(group_list);
        if (requested_groups.empty()) {
            std::cerr << "usermod: no groups specified for -G.\n";
            return 1;
        }

        for (const auto& group_name : requested_groups) {
            if (!group_exists(groups, group_name)) {
                std::cerr << "usermod: group '" << group_name << "' does not exist.\n";
                return 1;
            }
        }

        if (!append_groups) {
            for (auto& group : groups) {
                auto old_end = std::remove(group.members.begin(), group.members.end(), effective_username);
                if (old_end != group.members.end()) {
                    group.members.erase(old_end, group.members.end());
                    groups_modified = true;
                }
            }
        }

        for (const auto& group_name : requested_groups) {
            for (auto& group : groups) {
                if (group.name != group_name) continue;
                if (std::find(group.members.begin(), group.members.end(), effective_username) == group.members.end()) {
                    group.members.push_back(effective_username);
                    groups_modified = true;
                }
                break;
            }
        }
    }

    if (!user_modified && !groups_modified) {
        std::cout << "usermod: nothing to do\n";
        return 0;
    }

    if (!UserMgmt::save_users(users) || !UserMgmt::save_shadow(users) || !UserMgmt::save_groups(groups)) {
        std::cerr << "usermod: failed to save\n";
        return 1;
    }

    std::cout << "usermod: success\n";
    return 0;
}
