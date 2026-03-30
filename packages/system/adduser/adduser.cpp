#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <getopt.h>
#include <grp.h>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <vector>

#include "user_mgmt.h"

namespace {

constexpr const char* kDefaultProfile =
    "if [ -n \"$BASH_VERSION\" ] && [ -f \"$HOME/.bashrc\" ]; then\n"
    "    . \"$HOME/.bashrc\"\n"
    "fi\n";

void print_usage() {
    std::cout << "Usage: adduser [options] user\n"
              << "       adduser [options] user group\n"
              << "\n"
              << "Options:\n"
              << "  --system              create a system account\n"
              << "  --home DIR            use DIR for the home directory\n"
              << "  --shell SHELL         use SHELL for the user's shell\n"
              << "  --gecos GECOS         set the GECOS/full name field\n"
              << "  --uid UID             use UID for the new account\n"
              << "  --ingroup GROUP       use an existing primary group\n"
              << "  --groups LIST         add supplementary groups (comma-separated)\n"
              << "  --admin               also add the new user to sudo\n"
              << "  --disabled-password   create the account with a locked password\n"
              << "  --no-create-home      do not create the user's home directory\n"
              << "  --help                display this help and exit\n";
}

bool is_interactive_terminal() {
    return isatty(STDIN_FILENO) && isatty(STDOUT_FILENO);
}

bool path_exists(const std::string& path) {
    struct stat st {};
    return !path.empty() && stat(path.c_str(), &st) == 0;
}

bool ensure_directory_tree(const std::string& path, mode_t final_mode) {
    if (path.empty()) {
        return false;
    }

    std::string current = path.front() == '/' ? "/" : "";
    size_t index = current == "/" ? 1 : 0;
    while (index <= path.size()) {
        size_t separator = path.find('/', index);
        std::string component = path.substr(index, separator == std::string::npos ? std::string::npos : separator - index);
        if (!component.empty()) {
            if (current.size() > 1 && current.back() != '/') {
                current += "/";
            }
            current += component;
            if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) {
                return false;
            }
        }
        if (separator == std::string::npos) {
            break;
        }
        index = separator + 1;
    }

    if (chmod(path.c_str(), final_mode) != 0 && errno != ENOENT) {
        return false;
    }
    return true;
}

bool write_text_file(const std::string& path, const std::string& contents, mode_t mode) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) {
        return false;
    }
    output << contents;
    output.close();
    if (!output) {
        return false;
    }
    return chmod(path.c_str(), mode) == 0;
}

bool copy_file(const std::string& source, const std::string& destination, mode_t mode) {
    std::ifstream input(source, std::ios::binary);
    if (!input) {
        return false;
    }

    std::ofstream output(destination, std::ios::binary | std::ios::trunc);
    if (!output) {
        return false;
    }

    output << input.rdbuf();
    output.close();
    if (!output) {
        return false;
    }
    return chmod(destination.c_str(), mode) == 0;
}

bool chown_and_chmod(const std::string& path, uid_t uid, gid_t gid, mode_t mode) {
    if (chown(path.c_str(), uid, gid) != 0) {
        return false;
    }
    return chmod(path.c_str(), mode) == 0;
}

std::string prompt_line(const std::string& prompt, const std::string& default_value = "") {
    std::cout << prompt;
    if (!default_value.empty()) {
        std::cout << " [" << default_value << "]";
    }
    std::cout << ": ";
    std::cout.flush();

    std::string value;
    if (!std::getline(std::cin, value)) {
        return default_value;
    }
    return value.empty() ? default_value : value;
}

std::string prompt_hidden(const std::string& prompt) {
    std::cout << prompt;
    std::cout.flush();

    std::string value;
    struct termios original {};
    if (tcgetattr(STDIN_FILENO, &original) != 0) {
        std::getline(std::cin, value);
        std::cout << std::endl;
        return value;
    }

    struct termios muted = original;
    muted.c_lflag &= ~ECHO;
    tcsetattr(STDIN_FILENO, TCSANOW, &muted);
    std::getline(std::cin, value);
    tcsetattr(STDIN_FILENO, TCSANOW, &original);
    std::cout << std::endl;
    return value;
}

bool prompt_yes_no(const std::string& prompt, bool default_yes) {
    std::cout << prompt << (default_yes ? " [Y/n]: " : " [y/N]: ");
    std::cout.flush();

    std::string value;
    if (!std::getline(std::cin, value) || value.empty()) {
        return default_yes;
    }

    const char first = static_cast<char>(std::tolower(static_cast<unsigned char>(value.front())));
    return first == 'y';
}

bool prompt_for_password_hash(std::string& hashed_password) {
    for (int attempt = 0; attempt < 3; ++attempt) {
        const std::string first = prompt_hidden("New password: ");
        if (first.empty()) {
            std::cerr << "adduser: password cannot be empty.\n";
            continue;
        }

        const std::string second = prompt_hidden("Retype new password: ");
        if (first != second) {
            std::cerr << "adduser: passwords do not match.\n";
            continue;
        }

        hashed_password = UserMgmt::hash_password(first);
        return true;
    }

    return false;
}

bool parse_int(const std::string& value, int& parsed) {
    if (value.empty()) {
        return false;
    }

    char* end = nullptr;
    errno = 0;
    long raw = std::strtol(value.c_str(), &end, 10);
    if (errno != 0 || !end || *end != '\0' || raw < 0 || raw > 65534) {
        return false;
    }
    parsed = static_cast<int>(raw);
    return true;
}

std::vector<std::string> split_csv(const std::string& value) {
    std::vector<std::string> items;
    std::stringstream ss(value);
    std::string item;
    while (std::getline(ss, item, ',')) {
        if (!item.empty()) {
            items.push_back(item);
        }
    }
    return items;
}

std::string join(const std::vector<std::string>& items, const std::string& delimiter) {
    std::ostringstream out;
    for (size_t index = 0; index < items.size(); ++index) {
        if (index != 0) {
            out << delimiter;
        }
        out << items[index];
    }
    return out.str();
}

Group* find_group_by_name(std::vector<Group>& groups, const std::string& name) {
    for (auto& group : groups) {
        if (group.name == name) {
            return &group;
        }
    }
    return nullptr;
}

bool group_has_member(const Group& group, const std::string& username) {
    return std::find(group.members.begin(), group.members.end(), username) != group.members.end();
}

void add_member_if_missing(Group& group, const std::string& username) {
    if (!group_has_member(group, username)) {
        group.members.push_back(username);
    }
}

void add_unique(std::vector<std::string>& items, const std::string& value) {
    if (value.empty()) {
        return;
    }
    if (std::find(items.begin(), items.end(), value) == items.end()) {
        items.push_back(value);
    }
}

int allocate_system_uid(const std::vector<User>& users) {
    int next_uid = 100;
    while (next_uid < 1000) {
        bool in_use = false;
        for (const auto& user : users) {
            if (user.uid == static_cast<uid_t>(next_uid)) {
                in_use = true;
                break;
            }
        }
        if (!in_use) {
            return next_uid;
        }
        ++next_uid;
    }
    return UserMgmt::get_next_uid(users);
}

int allocate_system_gid(const std::vector<Group>& groups) {
    int next_gid = 100;
    while (next_gid < 1000) {
        bool in_use = false;
        for (const auto& group : groups) {
            if (group.gid == static_cast<gid_t>(next_gid)) {
                in_use = true;
                break;
            }
        }
        if (!in_use) {
            return next_gid;
        }
        ++next_gid;
    }
    return UserMgmt::get_next_gid(groups);
}

bool gid_in_use(const std::vector<Group>& groups, gid_t gid) {
    for (const auto& group : groups) {
        if (group.gid == gid) {
            return true;
        }
    }
    return false;
}

std::string find_restorecon_binary() {
    static const char* candidates[] = {
        "/usr/sbin/restorecon",
        "/sbin/restorecon",
    };

    for (const char* candidate : candidates) {
        if (access(candidate, X_OK) == 0) {
            return candidate;
        }
    }
    return "";
}

void best_effort_restorecon(const std::string& path, bool recursive) {
    const std::string restorecon = find_restorecon_binary();
    if (restorecon.empty() || path.empty()) {
        return;
    }

    const pid_t child = fork();
    if (child == 0) {
        if (recursive) {
            execl(restorecon.c_str(), restorecon.c_str(), "-F", "-R", path.c_str(), nullptr);
        } else {
            execl(restorecon.c_str(), restorecon.c_str(), "-F", path.c_str(), nullptr);
        }
        _exit(127);
    }
    if (child < 0) {
        return;
    }

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            return;
        }
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        std::cerr << "adduser: warning: failed to relabel " << path << "\n";
    }
}

bool install_shell_file(const std::string& destination,
                        const std::vector<std::string>& candidates,
                        uid_t uid,
                        gid_t gid,
                        mode_t mode) {
    if (path_exists(destination)) {
        return chown_and_chmod(destination, uid, gid, mode);
    }

    for (const auto& candidate : candidates) {
        if (!candidate.empty() && path_exists(candidate) && copy_file(candidate, destination, mode)) {
            return chown_and_chmod(destination, uid, gid, mode);
        }
    }

    return false;
}

bool seed_home_layout(const User& user) {
    if (!ensure_directory_tree(user.home, 0700)) {
        return false;
    }
    if (!chown_and_chmod(user.home, user.uid, user.gid, 0700)) {
        return false;
    }

    const std::vector<std::pair<std::string, mode_t>> config_dirs = {
        {user.home + "/.config", 0700},
        {user.home + "/.cache", 0700},
        {user.home + "/.local", 0700},
        {user.home + "/.local/share", 0700},
        {user.home + "/.local/state", 0700},
        {user.home + "/.local/bin", 0755},
    };
    for (const auto& [path, mode] : config_dirs) {
        if (!ensure_directory_tree(path, mode) || !chown_and_chmod(path, user.uid, user.gid, mode)) {
            return false;
        }
    }

    const std::vector<std::pair<std::string, mode_t>> user_dirs = {
        {user.home + "/Desktop", 0755},
        {user.home + "/Documents", 0755},
        {user.home + "/Downloads", 0755},
        {user.home + "/Music", 0755},
        {user.home + "/Pictures", 0755},
        {user.home + "/Public", 0755},
        {user.home + "/Templates", 0755},
        {user.home + "/Videos", 0755},
    };
    for (const auto& [path, mode] : user_dirs) {
        if (!ensure_directory_tree(path, mode) || !chown_and_chmod(path, user.uid, user.gid, mode)) {
            return false;
        }
    }

    if (!install_shell_file(user.home + "/.bashrc", {"/etc/skel/.bashrc", "/root/.bashrc"}, user.uid, user.gid, 0644)) {
        return false;
    }

    if (!path_exists(user.home + "/.profile")) {
        bool copied_profile = install_shell_file(user.home + "/.profile", {"/etc/skel/.profile"}, user.uid, user.gid, 0644);
        if (!copied_profile) {
            if (!write_text_file(user.home + "/.profile", kDefaultProfile, 0644)) {
                return false;
            }
            if (chown((user.home + "/.profile").c_str(), user.uid, user.gid) != 0) {
                return false;
            }
        }
    } else if (!chown_and_chmod(user.home + "/.profile", user.uid, user.gid, 0644)) {
        return false;
    }

    if (path_exists("/etc/skel/.bash_profile")) {
        if (!install_shell_file(user.home + "/.bash_profile", {"/etc/skel/.bash_profile"}, user.uid, user.gid, 0644)) {
            return false;
        }
    }

    if (path_exists("/etc/skel/.bash_logout")) {
        if (!install_shell_file(user.home + "/.bash_logout", {"/etc/skel/.bash_logout"}, user.uid, user.gid, 0644)) {
            return false;
        }
    }

    best_effort_restorecon(user.home, true);
    return true;
}

}  // namespace

int main(int argc, char* argv[]) {
    bool system_account = false;
    bool create_home = true;
    bool disabled_password = false;
    bool admin = false;
    std::string home_dir;
    std::string shell;
    std::string gecos;
    std::string primary_group_name;
    std::string extra_groups_csv;
    int requested_uid = -1;

    static struct option long_options[] = {
        {"system", no_argument, nullptr, 'S'},
        {"home", required_argument, nullptr, 'H'},
        {"shell", required_argument, nullptr, 's'},
        {"gecos", required_argument, nullptr, 'g'},
        {"uid", required_argument, nullptr, 'u'},
        {"ingroup", required_argument, nullptr, 'i'},
        {"groups", required_argument, nullptr, 'G'},
        {"admin", no_argument, nullptr, 'a'},
        {"disabled-password", no_argument, nullptr, 'D'},
        {"no-create-home", no_argument, nullptr, 'M'},
        {"help", no_argument, nullptr, 'h'},
        {nullptr, 0, nullptr, 0}
    };

    int opt = 0;
    while ((opt = getopt_long(argc, argv, "SH:s:g:u:i:G:aDMh", long_options, nullptr)) != -1) {
        switch (opt) {
            case 'S':
                system_account = true;
                break;
            case 'H':
                home_dir = optarg;
                break;
            case 's':
                shell = optarg;
                break;
            case 'g':
                gecos = optarg;
                break;
            case 'u':
                if (!parse_int(optarg, requested_uid)) {
                    std::cerr << "adduser: invalid UID '" << optarg << "'.\n";
                    return 1;
                }
                break;
            case 'i':
                primary_group_name = optarg;
                break;
            case 'G':
                extra_groups_csv = optarg;
                break;
            case 'a':
                admin = true;
                break;
            case 'D':
                disabled_password = true;
                break;
            case 'M':
                create_home = false;
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

    if (geteuid() != 0) {
        std::cerr << "adduser: this command must be run as root.\n";
        return 1;
    }

    const std::string username = argv[optind++];

    if (optind < argc) {
        const std::string group_name = argv[optind++];
        if (optind != argc) {
            print_usage();
            return 1;
        }

        std::vector<User> users;
        std::vector<Group> groups;
        if (!UserMgmt::load_users(users) || !UserMgmt::load_groups(groups)) {
            std::cerr << "adduser: failed to load account database.\n";
            return 1;
        }

        const auto user_it = std::find_if(users.begin(), users.end(), [&](const User& user) {
            return user.username == username;
        });
        if (user_it == users.end()) {
            std::cerr << "adduser: user '" << username << "' does not exist\n";
            return 1;
        }

        Group* group = find_group_by_name(groups, group_name);
        if (!group) {
            std::cerr << "adduser: group '" << group_name << "' does not exist\n";
            return 1;
        }

        if (group_has_member(*group, username)) {
            std::cout << "The user '" << username << "' is already a member of '" << group_name << "'.\n";
            return 0;
        }

        add_member_if_missing(*group, username);
        if (!UserMgmt::save_groups(groups)) {
            std::cerr << "adduser: failed to save groups\n";
            return 1;
        }

        std::cout << "Adding user '" << username << "' to group '" << group_name << "' ...\n";
        std::cout << "Done.\n";
        return 0;
    }

    if (!UserMgmt::is_valid_username(username)) {
        std::cerr << "adduser: invalid username '" << username << "'\n";
        return 1;
    }

    std::vector<User> users;
    std::vector<Group> groups;
    if (!UserMgmt::load_users(users) || !UserMgmt::load_groups(groups)) {
        std::cerr << "adduser: failed to load account database.\n";
        return 1;
    }

    for (const auto& user : users) {
        if (user.username == username) {
            std::cerr << "adduser: user '" << username << "' already exists\n";
            return 0;
        }
        if (requested_uid >= 0 && user.uid == static_cast<uid_t>(requested_uid)) {
            std::cerr << "adduser: UID '" << requested_uid << "' is already in use.\n";
            return 1;
        }
    }

    const bool interactive = is_interactive_terminal();
    if (!system_account && gecos.empty() && interactive) {
        gecos = prompt_line("Full name");
    }

    if (!system_account && interactive && !admin && find_group_by_name(groups, "sudo") != nullptr) {
        admin = prompt_yes_no("Add " + username + " to sudo", false);
    }

    User new_user;
    new_user.username = username;
    new_user.uid = requested_uid >= 0
        ? requested_uid
        : (system_account ? allocate_system_uid(users) : UserMgmt::get_next_uid(users));
    new_user.shell = shell.empty() ? (system_account ? "/bin/false" : "/bin/bash") : shell;
    new_user.home = home_dir.empty() ? (system_account ? "/var/lib/" + username : "/home/" + username) : home_dir;
    new_user.gecos = gecos;
    new_user.password = "!";

    Group* primary_group = nullptr;
    bool created_primary_group = false;
    if (!primary_group_name.empty()) {
        primary_group = find_group_by_name(groups, primary_group_name);
        if (!primary_group) {
            std::cerr << "adduser: group '" << primary_group_name << "' does not exist.\n";
            return 1;
        }
    } else {
        primary_group = find_group_by_name(groups, username);
    }

    if (!primary_group) {
        Group new_group;
        new_group.name = username;
        if (!primary_group_name.empty()) {
            new_group.gid = UserMgmt::get_next_gid(groups);
        } else if (!gid_in_use(groups, static_cast<gid_t>(new_user.uid))) {
            new_group.gid = new_user.uid;
        } else {
            new_group.gid = system_account ? allocate_system_gid(groups) : UserMgmt::get_next_gid(groups);
        }
        add_member_if_missing(new_group, username);
        groups.push_back(new_group);
        primary_group = &groups.back();
        created_primary_group = true;
    }

    new_user.gid = primary_group->gid;
    add_member_if_missing(*primary_group, username);

    std::vector<std::string> supplementary_groups = split_csv(extra_groups_csv);
    if (!system_account) {
        if (find_group_by_name(groups, "users")) {
            add_unique(supplementary_groups, "users");
        }
        for (const std::string& group_name : {"audio", "video", "input", "render", "storage"}) {
            if (find_group_by_name(groups, group_name)) {
                add_unique(supplementary_groups, group_name);
            }
        }
        if (admin && find_group_by_name(groups, "sudo")) {
            add_unique(supplementary_groups, "sudo");
        }
    }

    for (const auto& group_name : supplementary_groups) {
        Group* group = find_group_by_name(groups, group_name);
        if (!group) {
            std::cerr << "adduser: supplementary group '" << group_name << "' does not exist.\n";
            return 1;
        }
        if (group->gid == new_user.gid) {
            continue;
        }
        add_member_if_missing(*group, username);
    }

    if (!system_account && !disabled_password && interactive) {
        if (!prompt_for_password_hash(new_user.password)) {
            std::cerr << "adduser: failed to collect a valid password.\n";
            return 1;
        }
    }

    if (interactive) {
        std::cout << "\nCreating account with these settings:\n";
        std::cout << "  Username: " << new_user.username << "\n";
        std::cout << "  UID/GID:  " << new_user.uid << "/" << new_user.gid << "\n";
        std::cout << "  Home:     " << new_user.home << "\n";
        std::cout << "  Shell:    " << new_user.shell << "\n";
        std::cout << "  Full name:" << (new_user.gecos.empty() ? " (empty)" : " " + new_user.gecos) << "\n";
        if (!supplementary_groups.empty()) {
            std::cout << "  Extra groups: " << join(supplementary_groups, ", ") << "\n";
        }
        if (new_user.password == "!") {
            std::cout << "  Password: locked\n";
        }
        std::cout << std::endl;

        if (!prompt_yes_no("Proceed with account creation", true)) {
            std::cout << "Aborted.\n";
            return 1;
        }
    }

    users.push_back(new_user);
    if (!UserMgmt::save_users(users) || !UserMgmt::save_shadow(users) || !UserMgmt::save_groups(groups)) {
        std::cerr << "adduser: failed to save configuration\n";
        return 1;
    }

    std::cout << "Adding user '" << username << "' ...\n";
    if (created_primary_group) {
        std::cout << "Adding new group '" << primary_group->name << "' (" << primary_group->gid << ") ...\n";
    }
    std::cout << "Adding new user '" << username << "' (" << new_user.uid
              << ") with group '" << primary_group->name << "' ...\n";

    if (create_home) {
        std::cout << "Creating home directory '" << new_user.home << "' ...\n";
        if (!seed_home_layout(new_user)) {
            std::cerr << "adduser: failed to initialize the home directory '" << new_user.home
                      << "': " << std::strerror(errno) << "\n";
            return 1;
        }
        std::cout << "Copying default files and desktop directories into '" << new_user.home << "' ...\n";
    }

    if (!supplementary_groups.empty()) {
        std::cout << "Adding user '" << username << "' to supplementary groups '" << join(supplementary_groups, ", ")
                  << "' ...\n";
    }

    if (new_user.password == "!") {
        std::cout << "The account is locked. Run 'passwd " << username << "' to set a password.\n";
    }

    std::cout << "Done.\n";
    return 0;
}
