#include <iostream>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/stat.h>
#include "../../../src/user_mgmt.h"
#include "../../../src/sys_info.h"

int main(int argc, char* argv[]) {
    bool verbose = false;
    std::vector<std::string> args;
    
    for(int i=1; i<argc; ++i) {
        std::string arg = argv[i];
        if(arg == "-v" || arg == "--verbose") verbose = true;
        else args.push_back(arg);
    }

    if (args.size() < 2) {
        std::cerr << "Usage: chown [-v] <user[:group]> <file>\n";
        return 1;
    }

    std::string owner_str = args[0];
    std::string path = args[1];
    
    std::string user_name, group_name;
    size_t colon = owner_str.find(':');
    if (colon != std::string::npos) {
        user_name = owner_str.substr(0, colon);
        group_name = owner_str.substr(colon + 1);
    } else {
        user_name = owner_str;
    }

    std::vector<User> users;
    std::vector<Group> groups;
    
    if (!UserMgmt::load_users(users)) {
        std::cerr << "chown: failed to load user database\n";
        return 1;
    }

    uid_t uid = -1;
    gid_t gid = -1;

    // Resolve User
    if (!user_name.empty()) {
        bool found = false;
        for (const auto& u : users) {
            if (u.username == user_name) {
                uid = u.uid;
                found = true;
                break;
            }
        }
        if (!found) {
            try { uid = std::stoi(user_name); } catch(...) {
                std::cerr << "chown: invalid user: " << user_name << "\n";
                return 1;
            }
        }
    }

    // Resolve Group
    if (!group_name.empty()) {
        UserMgmt::load_groups(groups);
        bool found = false;
        for (const auto& g : groups) {
            if (g.name == group_name) {
                gid = g.gid;
                found = true;
                break;
            }
        }
        if (!found) {
            try { gid = std::stoi(group_name); } catch(...) {
                std::cerr << "chown: invalid group: " << group_name << "\n";
                return 1;
            }
        }
    }

    if (chown(path.c_str(), uid, gid) != 0) {
        perror(("chown: " + path).c_str());
        return 1;
    } else {
        if (verbose) std::cout << "changed ownership of '" << path << "' to " << owner_str << "\n";
    }

    return 0;
}
