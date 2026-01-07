#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/reboot.h>
#include <sys/sysinfo.h>
#include <sys/utsname.h>
#include <dirent.h>
#include <cstring>
#include <algorithm>
#include <sstream>
#include <fstream>
#include <termios.h>
#include <csignal>
#include <poll.h>
#include <sys/wait.h> // For waitpid
#include "network.h" // Include networking
#include "debug.h"
#include "signals.h"
#include <fcntl.h> // For open
#include <sys/ioctl.h> // For TIOCSCTTY
#include <cctype> // For isspace
#include "sys_info.h" // System Constants
#include "user_mgmt.h"

// Helper to mount filesystems safely
void mount_fs(const char* source, const char* target, const char* fs_type) {
    mkdir(target, 0755); // Ensure mount point exists
    if (mount(source, target, fs_type, 0, NULL) == 0) {
        std::cout << "[OK] Mounted " << target << std::endl;
    } else {
        perror((std::string("[ERR] Failed to mount ") + target).c_str());
    }
}

// Ensure FHS (Filesystem Hierarchy Standard) directories exist at runtime
void ensure_fhs() {
    const char* dirs[] = {
        "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/media", 
        "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", 
        "/sys", "/tmp", "/usr", "/usr/bin", "/usr/lib", "/usr/local", 
        "/usr/share", "/var", "/var/log", "/var/tmp", "/var/repo",
        "/usr/share/X11", "/usr/share/X11/xkb", "/usr/share/X11/xkb/compiled"
    };
    
    for (const char* d : dirs) {
        mkdir(d, 0755);
    }
    
    // Fix permissions for /tmp
    chmod("/tmp", 01777); // Sticky bit
    chmod("/var/tmp", 01777);
    // Ensure /root is private
    chmod("/root", 0700);
}

// Global Command History
std::vector<std::string> HISTORY;

// Global Signal Flag (Defined in signals.cpp)
// Note: used by readline/signals
volatile pid_t g_foreground_pid = -1;

// Helper for autocomplete to list packages in repo (re-implemented locally)
std::vector<std::string> get_repo_packages() {
    std::vector<std::string> pkgs;
    DIR* dir = opendir("/var/repo/");
    if (dir) {
        struct dirent* entry;
        while ((entry = readdir(dir)) != NULL) {
            std::string name = entry->d_name;
            if (name.length() > 5 && name.substr(name.length() - 5) == ".gpkg") {
                pkgs.push_back(name.substr(0, name.length() - 5));
            }
        }
        closedir(dir);
    }
    return pkgs;
}

// Helper to scan executables in a directory
void scan_executables(const std::string& path, std::vector<std::string>& candidates, const std::string& prefix) {
    DIR* dir = opendir(path.c_str());
    if (!dir) return;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        if (name.find(prefix) == 0) {
            candidates.push_back(name + " ");
        }
    }
    closedir(dir);
}

// Helper to get directories from PATH
std::vector<std::string> get_path_dirs() {
    std::vector<std::string> dirs;
    const char* path_env = getenv("PATH");
    // Fallback path if environment is not set
    std::string path_str = path_env ? path_env : "/bin/apps/system:/bin/apps:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin";
    std::stringstream ss(path_str);
    std::string dir;
    while (std::getline(ss, dir, ':')) {
        if (!dir.empty()) {
            if (dir.back() != '/') dir += "/";
            dirs.push_back(dir);
        } else {
            dirs.push_back("./");
        }
    }
    return dirs;
}

// --- Autocomplete & Raw Mode Logic ---

struct termios orig_termios;

void print_tty_debug(const std::string& ctx) {
#ifdef DEBUG_MODE
    struct termios t;
    if (tcgetattr(STDIN_FILENO, &t) == 0) {
        std::cerr << "[DEBUG] " << ctx << " | LFLAG: " 
                  << ((t.c_lflag & ISIG) ? "ISIG " : "isig ")
                  << ((t.c_lflag & ICANON) ? "ICANON " : "icanon ")
                  << ((t.c_lflag & ECHO) ? "ECHO " : "echo ") 
                  << "| PGRP: " << getpgrp() << " FG: " << tcgetpgrp(STDIN_FILENO) << std::endl;
    }
#endif
}

void disable_raw_mode() {
    // Force enable ISIG (Signals), ICANON (Line buffering), and ECHO
    struct termios term = orig_termios;
    term.c_lflag |= (ECHO | ICANON | ISIG);
    // TCSAFLUSH waits for output and discards pending input (clean state for child)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term);
}

void enable_raw_mode() {
    // IMPORTANT: Do NOT call tcgetattr here. 
    // We rely on orig_termios being set ONCE in main().
    // This prevents inheriting broken states from crashed programs.
    
    atexit(disable_raw_mode);
    struct termios raw = orig_termios;
    raw.c_lflag &= ~(ECHO | ICANON | ISIG); // Disable signals (Ctrl+C)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
}

// Check if a path is a directory
bool is_directory(const std::string& path) {
    struct stat s;
    if (stat(path.c_str(), &s) == 0) {
        return S_ISDIR(s.st_mode);
    }
    return false;
}

// Find longest common prefix among candidates
std::string find_common_prefix(const std::vector<std::string>& candidates) {
    if (candidates.empty()) return "";
    std::string prefix = candidates[0];
    for (size_t i = 1; i < candidates.size(); ++i) {
        while (candidates[i].find(prefix) != 0) {
            prefix = prefix.substr(0, prefix.length() - 1);
            if (prefix.empty()) return "";
        }
    }
    return prefix;
}

void handle_tab_completion(std::string& buffer, int& cursor_pos) {
    // 1. Parse context up to cursor
    std::string left_context = buffer.substr(0, cursor_pos);
    
    // Find start of the word being completed
    size_t last_space = left_context.find_last_of(' ');
    std::string prefix;
    if (last_space == std::string::npos) {
        prefix = left_context;
    } else {
        prefix = left_context.substr(last_space + 1);
    }

    // Determine command context
    // Simple tokenization of the left context to find which argument we are on
    std::vector<std::string> tokens;
    std::string current_token;
    for (char c : left_context) {
        if (std::isspace(c)) {
            if (!current_token.empty()) {
                tokens.push_back(current_token);
                current_token.clear();
            }
        } else {
            current_token += c;
        }
    }
    // If the last char was not a space, the last token is the one being completed (prefix).
    // We push it to tokens to know the count, but for logic we often look at tokens[0].
    if (!current_token.empty()) tokens.push_back(current_token);

    // Check if we are starting a NEW token (last char was space)
    bool new_token = (!left_context.empty() && std::isspace(left_context.back()));
    
    std::string cmd = (tokens.empty()) ? "" : tokens[0];
    bool is_command_pos = (tokens.empty() || (tokens.size() == 1 && !new_token));

    std::vector<std::string> candidates;

    // 2. Gather Candidates based on Context
    if (is_command_pos) {
        if (std::string("cd").find(prefix) == 0) candidates.push_back("cd ");
        
        // Scan all directories in PATH for command completion
        std::vector<std::string> dirs = get_path_dirs();
        for (const auto& path : dirs) {
            scan_executables(path, candidates, prefix);
        }
    } 
    // Special Autocomplete for 'gpkg'
    else if (cmd == "gpkg") {
        // Arg 1: Action (install, remove, etc.)
        // Arg 2: Package Name
        
        int arg_index = tokens.size() - (new_token ? 0 : 1);

        if (arg_index == 1) { // Action
            std::vector<std::string> actions = {"install ", "remove ", "list ", "download ", "search ", "clean ", "help "};
            for (const auto& act : actions) {
                if (act.find(prefix) == 0) candidates.push_back(act);
            }
        } else if (arg_index == 2) { // Package
            std::string action = tokens[1];
            
            if (action == "install" || action == "download") {
            std::vector<std::string> pkgs = get_repo_packages();
            for (const auto& pkg : pkgs) {
                    if (pkg.find(prefix) == 0) candidates.push_back(pkg + " ");
                }
            } else if (action == "remove") {
                // Autocomplete installed packages
                scan_executables("/bin/apps/system/", candidates, prefix);
                scan_executables("/bin/apps/", candidates, prefix);
            }
        }
    } else {
        // Path completion logic
        std::string file_pattern;
        std::string dir_path;
        
        size_t last_slash = prefix.find_last_of('/');
        if (last_slash == std::string::npos) {
            dir_path = ".";
            file_pattern = prefix;
        } else {
            dir_path = prefix.substr(0, last_slash + 1);
            file_pattern = prefix.substr(last_slash + 1);
            if (dir_path.empty()) dir_path = "/";
        }

        DIR* dir = opendir(dir_path.c_str());
        if (dir) {
            struct dirent* entry;
            while ((entry = readdir(dir)) != NULL) {
                std::string name = entry->d_name;
                if (name == "." || name == "..") continue;

                if (name.find(file_pattern) == 0) {
                    std::string full_match = (dir_path == "." ? "" : dir_path) + name;
                    if (is_directory(full_match)) {
                        full_match += "/";
                    }
                    candidates.push_back(full_match);
                }
            }
            closedir(dir);
        }
    }

    // 3. Apply Completion
    if (candidates.empty()) {
        return; // No match
    } else if (candidates.size() == 1) {
        // Single match
        std::string match = candidates[0];
        
        // Determine suffix to append
        // Match is the FULL string (e.g. "src/init.cpp") or command "ls "
        // Prefix is what user typed: "src/i"
        
        // For paths, match is the full relative path.
        // For commands/args, match is the word.
        
        std::string to_insert;
        if (match.find(prefix) == 0) {
            to_insert = match.substr(prefix.length());
        }
        
        if (!to_insert.empty()) {
            // Smart insertion: Skip characters that already exist in the buffer
            int match_len = 0;
            while (match_len < (int)to_insert.length() && 
                   (cursor_pos + match_len) < (int)buffer.length() &&
                   buffer[cursor_pos + match_len] == to_insert[match_len]) {
                match_len++;
            }
            
            cursor_pos += match_len;
            std::string remaining = to_insert.substr(match_len);
            if (!remaining.empty()) {
                buffer.insert(cursor_pos, remaining);
                cursor_pos += remaining.length();
            }
        }
    } else {
        // Multiple matches
        std::cout << "\n";
        for (const auto& c : candidates) {
            std::cout << c << "  ";
        }
        std::cout << "\n";
    }
}

// Simple signal handler to catch Ctrl+C during blocking commands
void sigint_handler(int signo) {
    (void)signo;
    g_stop_sig = 1; // Set flag so loops can exit
}

// Custom readline that handles raw input
std::string readline(const std::string& prompt) {
    std::string buffer;
    int history_index = HISTORY.size();
    int cursor_pos = 0; // Cursor position within the buffer

    // Calculate visible prompt length (stripping ANSI codes) for cursor positioning
    int prompt_len = 0;
    bool in_esc = false;
    for (char c : prompt) {
        if (c == '\033') in_esc = true;
        else if (in_esc && c == 'm') in_esc = false;
        else if (!in_esc) prompt_len++;
    }

    std::cout << prompt << std::flush;

    char c;
    while (read(STDIN_FILENO, &c, 1) == 1) {
        if (c == 3 || g_stop_sig) { // Ctrl+C
            std::cout << "^C" << std::endl;
            g_stop_sig = 0; // Reset
            return "";
        } else if (c == '\n' || c == '\r') {
            std::cout << std::endl;
            break;
        } else if (c == 127 || c == 8) { // Backspace (^? or ^H)
            if (cursor_pos > 0) {
                buffer.erase(cursor_pos - 1, 1);
                cursor_pos--;
                // Redraw line
                std::cout << "\r" << prompt << buffer << "\033[K";
                // Restore cursor position
                std::cout << "\r\033[" << (prompt_len + cursor_pos) << "C" << std::flush;
            }
        } else if (c == '\t') {
            // Handle Tab
            handle_tab_completion(buffer, cursor_pos);
            
            // Redraw line and restore cursor
            std::cout << "\r\033[K" << prompt << buffer;
            std::cout << "\r\033[" << (prompt_len + cursor_pos) << "C" << std::flush;
        } else if (c == '\033') { // ANSI Escape Sequence
            char seq[3];
            // Read next 2 bytes to determine key
            if (read(STDIN_FILENO, &seq[0], 1) == 1 && read(STDIN_FILENO, &seq[1], 1) == 1) {
                if (seq[0] == '[') {
                    if (seq[1] >= '0' && seq[1] <= '9') {
                        // Extended sequence (Home/End/Delete often use ~)
                        if (read(STDIN_FILENO, &seq[2], 1) == 1 && seq[2] == '~') {
                            if (seq[1] == '1' || seq[1] == '7') { // Home
                                cursor_pos = 0;
                                std::cout << "\r\033[" << prompt_len << "C" << std::flush;
                            } else if (seq[1] == '4' || seq[1] == '8') { // End
                                cursor_pos = buffer.length();
                                std::cout << "\r\033[" << (prompt_len + cursor_pos) << "C" << std::flush;
                            } else if (seq[1] == '3') { // Delete
                                if (cursor_pos < (int)buffer.length()) {
                                    buffer.erase(cursor_pos, 1);
                                    std::cout << "\r" << prompt << buffer << "\033[K";
                                    std::cout << "\r\033[" << (prompt_len + cursor_pos) << "C" << std::flush;
                                }
                            }
                        }
                    } else {
                        switch (seq[1]) {
                            case 'A': // UP Arrow
                                if (history_index > 0) {
                                    history_index--;
                                    buffer = HISTORY[history_index];
                                    cursor_pos = buffer.length();
                                    std::cout << "\r\033[K" << prompt << buffer << std::flush;
                                }
                                break;
                            case 'B': // DOWN Arrow
                                if (history_index < (int)HISTORY.size()) {
                                    history_index++;
                                    buffer = (history_index == (int)HISTORY.size()) ? "" : HISTORY[history_index];
                                    cursor_pos = buffer.length();
                                    std::cout << "\r\033[K" << prompt << buffer << std::flush;
                                }
                                break;
                            case 'C': // RIGHT Arrow
                                if (cursor_pos < (int)buffer.length()) {
                                    cursor_pos++;
                                    std::cout << "\033[C" << std::flush;
                                }
                                break;
                            case 'D': // LEFT Arrow
                                if (cursor_pos > 0) {
                                    cursor_pos--;
                                    std::cout << "\033[D" << std::flush;
                                }
                                break;
                            case 'H': // Home
                                cursor_pos = 0;
                                std::cout << "\r\033[" << prompt_len << "C" << std::flush;
                                break;
                            case 'F': // End
                                cursor_pos = buffer.length();
                                std::cout << "\r\033[" << (prompt_len + cursor_pos) << "C" << std::flush;
                                break;
                        }
                    }
                } else if (seq[0] == 'O') { // Application Mode
                    if (seq[1] == 'H') { // Home
                        cursor_pos = 0;
                        std::cout << "\r\033[" << prompt_len << "C" << std::flush;
                    } else if (seq[1] == 'F') { // End
                        cursor_pos = buffer.length();
                        std::cout << "\r\033[" << (prompt_len + cursor_pos) << "C" << std::flush;
                    }
                }
            }
        } else if (c >= 32 && c < 127) { // Printable characters
            buffer.insert(cursor_pos, 1, c);
            cursor_pos++;
            // Redraw
            std::cout << "\r" << prompt << buffer << "\033[K";
            // Restore cursor
            std::cout << "\r\033[" << (prompt_len + cursor_pos) << "C" << std::flush;
        }
    }
    return buffer;
}

std::vector<std::string> split_input(const std::string& input) {
    std::vector<std::string> tokens;
    std::string current_token;
    bool in_dquote = false;
    bool in_squote = false;
    bool escaped = false;
    bool token_started = false; // Tracks if we are building a token (handles explicit empty strings like "")

    for (char c : input) {
        if (escaped) {
            current_token += c;
            token_started = true;
            escaped = false;
            continue;
        }

        if (c == '\\') {
            escaped = true;
            continue;
        }

        if (c == '"' && !in_squote) {
            in_dquote = !in_dquote;
            token_started = true;
            continue;
        }

        if (c == '\'' && !in_dquote) {
            in_squote = !in_squote;
            token_started = true;
            continue;
        }

        if (std::isspace(c) && !in_dquote && !in_squote) {
            if (token_started) {
                tokens.push_back(current_token);
                current_token.clear();
                token_started = false;
            }
        } else {
            current_token += c;
            token_started = true;
        }
    }

    if (token_started) {
        tokens.push_back(current_token);
    }

    return tokens;
}

// Generate /etc/os-release for other applications (like gemfetch)
void generate_os_release() {
    std::ofstream f("/etc/os-release");
    if (f) {
        f << "NAME=\"" << OS_NAME << "\"\n";
        f << "VERSION=\"" << OS_VERSION << "\"\n";
        f << "ID=geminios\n";
        f << "PRETTY_NAME=\"" << OS_NAME << " " << OS_VERSION << "\"\n";
        f << "HOME_URL=\"https://github.com/CreitinGameplays/geminios\"\n"; // Placeholder
        f.close();
    }
}

void start_shell() {
    char cwd[1024];
    std::string input;

    // 7. Main Shell Loop
    while (true) {
        std::string prompt;
        
        // Determine current user name based on EUID
        std::string user_name = "unknown";
        uid_t uid = geteuid();
        
        // Quick lookup in /etc/passwd
        std::ifstream pf("/etc/passwd");
        if (pf) {
            std::string line;
            while(std::getline(pf, line)) {
                // Format: name:x:uid:...
                std::stringstream ss(line);
                std::string segment;
                std::vector<std::string> parts;
                while(std::getline(ss, segment, ':')) parts.push_back(segment);
                
                if (parts.size() >= 3) {
                    if (std::stoi(parts[2]) == (int)uid) {
                        user_name = parts[0];
                        break;
                    }
                }
            }
        }
        if (user_name == "unknown" && uid == 0) user_name = "root";

        // Get TTY Name
        std::string tty_name = "???";
        if (isatty(STDIN_FILENO)) {
            char* tty = ttyname(STDIN_FILENO);
            if (tty) {
                std::string s(tty);
                if (s.find("/dev/") == 0) s = s.substr(5);
                tty_name = s;
            }
        }

        if (getcwd(cwd, sizeof(cwd)) != NULL) {
            // Prompt: user@ttyX:/path#
            // Use # for root, $ for others
            char terminator = (uid == 0) ? '#' : '$';
            std::string color = (uid == 0) ? "\033[1;31m" : "\033[1;32m"; // Red for root, Green for user
            
            prompt = color + user_name + "@" + tty_name + 
                     "\033[0m:\033[1;34m" + cwd + "\033[0m" + terminator + " ";
        } else {
            prompt = "root# ";
        }
        
        g_stop_sig = 0; // Reset signal flag
        input = readline(prompt);
        
        if (!input.empty()) {
            HISTORY.push_back(input);
        }
        
        std::vector<std::string> args = split_input(input);
        if (args.empty()) continue;

        // Temporarily disable raw mode for command execution
        disable_raw_mode();

        std::string cmd = args[0];

        if (cmd == "exit") {
            break; 
        }
        else if (cmd == "cd") {
            if (args.size() > 1) {
                if (chdir(args[1].c_str()) != 0) perror("cd");
            } else {
                // Go to HOME
                const char* home = getenv("HOME");
                if (home) chdir(home);
                else chdir("/");
            }
        }
        else if (cmd == "export") {
            if (args.size() > 1) {
                for (size_t i = 1; i < args.size(); ++i) {
                    std::string arg = args[i];
                    size_t eq_pos = arg.find('=');
                    if (eq_pos != std::string::npos) {
                        std::string key = arg.substr(0, eq_pos);
                        std::string val = arg.substr(eq_pos + 1);
                        if (setenv(key.c_str(), val.c_str(), 1) != 0) {
                             perror("export");
                        }
                    }
                }
            } else {
                // List exported variables
                // We need to declare environ if we want to iterate it manually, 
                // but usually it's available. To be safe, we declare it inside or use 'extern'
                extern char** environ;
                for (char** env = environ; *env != 0; env++) {
                     std::cout << "declare -x " << *env << "\n";
                }
            }
        }
        else {
            // External Execution
            std::string executable;
            
            if (cmd.find('/') != std::string::npos) {
                // Absolute or relative path (contains a slash)
                if (access(cmd.c_str(), X_OK) == 0) {
                    executable = cmd;
                }
            } else {
                // PATH Lookup
                std::vector<std::string> dirs = get_path_dirs();
                for (const auto& dir : dirs) {
                    std::string full_path = dir + cmd;
                    if (access(full_path.c_str(), X_OK) == 0) {
                        executable = full_path;
                        break;
                    }
                }
            }

            if (!executable.empty()) {
                pid_t pid = fork();
                if (pid == 0) {
                    // Child: Reset signals and group
                    setpgid(0, 0);
                    struct sigaction dfl;
                    dfl.sa_handler = SIG_DFL;
                    sigemptyset(&dfl.sa_mask);
                    dfl.sa_flags = 0;
                    sigaction(SIGINT, &dfl, NULL);
                    sigaction(SIGQUIT, &dfl, NULL);
                    
                    std::vector<char*> c_args;
                    for (const auto& arg : args) c_args.push_back(const_cast<char*>(arg.c_str()));
                    c_args.push_back(nullptr);
                    
                    execv(executable.c_str(), c_args.data());
                    perror("execv");
                    exit(1);
                } else if (pid > 0) {
                    // Parent
                    setpgid(pid, pid);
                    tcsetpgrp(STDIN_FILENO, pid);
                    g_foreground_pid = pid;
                    
                    int status;
                    while (waitpid(pid, &status, 0) < 0 && errno == EINTR);
                    
                    tcsetpgrp(STDIN_FILENO, getpgrp());
                    g_foreground_pid = -1;
                    
                    if (WIFSIGNALED(status) && WTERMSIG(status) == SIGINT) std::cout << std::endl;
                } else {
                    perror("fork");
                }
            } else {
                std::cout << "Unknown command: " << cmd << std::endl;
            }
        }
        
        disable_raw_mode(); // Safety
        std::cout << "\033[?25h"; // Show cursor
        enable_raw_mode();
    }
}

// --- Getty / Login Logic ---

// Prompts for credentials and returns authenticated User object.
// Does NOT drop privileges.
User attempt_login() {
    disable_raw_mode(); 
    struct termios t;
    tcgetattr(STDIN_FILENO, &t);
    t.c_lflag |= (ICANON | ECHO | ISIG);
    tcsetattr(STDIN_FILENO, TCSANOW, &t);

    while (true) {
        std::cout << "\033[2J\033[1;1H"; // Clear Screen
        std::cout << "GeminiOS " << OS_VERSION << " (" << OS_ARCH << ")" << std::endl;
        std::cout << "Login to " << OS_NAME << std::endl << std::endl;

        std::string username;
        std::cout << "login: ";
        std::getline(std::cin, username);
        
        // Handle Ctrl+C or Stream Errors to prevent infinite loop
        if (g_stop_sig || std::cin.fail() || std::cin.eof()) {
            if (g_stop_sig) std::cout << "^C" << std::endl;
            std::cin.clear(); // Clear error flags
            g_stop_sig = 0;
            // If we caught a signal, we just restart the loop (redraw login)
            // Sleep slightly to prevent CPU spinning if input is totally broken
            if (std::cin.eof()) usleep(100000); 
            continue; 
        }

        if (username.empty()) continue;

        // Disable Echo for password
        struct termios oldt = t;
        t.c_lflag &= ~ECHO;
        tcsetattr(STDIN_FILENO, TCSANOW, &t);

        std::string password;
        std::cout << "Password: ";
        std::getline(std::cin, password);

        tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
        std::cout << std::endl;

        std::vector<User> users;
        if (UserMgmt::load_users(users)) {
            for (const auto& u : users) {
                if (u.username == username && UserMgmt::check_password(password, u.password)) {
                    return u;
                }
            }
        }
        std::cout << "\nLogin incorrect" << std::endl;
        sleep(2);
    }
}

// Map to track TTY Supervisor PIDs
// PID -> TTY Device Path
std::map<pid_t, std::string> g_tty_pids;

// Forward declaration
void run_shell(const std::string& tty_dev);

// Helper to detect Live ISO mode (no root= in cmdline)
bool is_live_mode() {
    std::ifstream cmdline("/proc/cmdline");
    std::string line;
    if (std::getline(cmdline, line)) {
        // If root= is present, we are likely installed (booting from disk)
        if (line.find("root=") != std::string::npos) return false;
    }
    return true;
}

void run_shell(const std::string& tty_dev) {
    // 1. Open the TTY Device
    int fd = open(tty_dev.c_str(), O_RDWR);
    if (fd < 0) {
        perror(("Failed to open " + tty_dev).c_str());
        sleep(5); // Prevent rapid respawn loops if device is missing
        exit(1);
    }

    // 2. Create a new Session (Setsid)
    // This detaches us from the old process group/session and makes us the leader
    setsid();

    // 3. Set Controlling Terminal
    // This ensures we receive signals (Ctrl+C) from this TTY
    if (ioctl(fd, TIOCSCTTY, 1) < 0) {
        perror("ioctl TIOCSCTTY");
    }

    // 4. Redirect Standard I/O to the TTY
    dup2(fd, STDIN_FILENO);
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    if (fd > 2) close(fd);

    // 5. Initialize Terminal Settings for this specific TTY
    tcgetattr(STDIN_FILENO, &orig_termios);
    orig_termios.c_lflag |= (ISIG | ICANON | ECHO); // Ensure sane defaults
    
    enable_raw_mode();

    // 6. Register Signal Handlers for this shell
    struct sigaction sa;
    sa.sa_handler = sigint_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, NULL);
    
    // Ignore TTY background write signals
    signal(SIGTTOU, SIG_IGN); 

    // Clear Screen
    std::cout << "\033[2J\033[1;1H"; 
    std::cout << OS_NAME << " " << OS_VERSION << " - " << tty_dev << std::endl;

    bool live = is_live_mode();

    // TTY Supervisor Loop
    while (true) {
        // 1. Authenticate (As Root)
        User u;
        if (live) {
            // Live Mode: Auto-login as root
            std::vector<User> users;
            if (UserMgmt::load_users(users)) {
                bool found = false;
                for (const auto& user : users) {
                    if (user.username == "root") { u = user; found = true; break; }
                }
                if (!found && !users.empty()) u = users[0];
            }
            // Fallback if load failed
            if (u.username.empty()) {
                u.username = "root"; u.uid = 0; u.gid = 0; 
                u.home = "/root"; u.shell = "/bin/init";
            }
        } else {
            // Installed Mode: Force Login
            u = attempt_login();
        }

        // 2. Spawn User Session
        pid_t session_pid = fork();
        
        if (session_pid == 0) {
            // --- CHILD (User Session) ---
            
            // Apply Privileges
            setgid(u.gid);
            setuid(u.uid);
            
            // Apply Environment
            setenv("USER", u.username.c_str(), 1);
            setenv("HOME", u.home.c_str(), 1);
            setenv("SHELL", u.shell.c_str(), 1);
            
            // PATH and basic env are already global from main(), but we ensure library paths
            setenv("LD_LIBRARY_PATH", "/usr/lib:/usr/local/lib:/usr/lib64:/lib:/lib64", 1);
            
            // Python specifics
            setenv("PYTHONUTF8", "1", 1); setenv("PYTHONHOME", "/usr", 1);
            
            if (chdir(u.home.c_str()) != 0) {
                std::cerr << "Could not enter home directory: " << u.home << std::endl;
                if (chdir("/") != 0) perror("chdir /");
            }
            
            // Start Shell (Blocking)
            start_shell();
            
            // Shell exited (logout)
            exit(0);
        } else if (session_pid > 0) {
            // --- PARENT (TTY Supervisor) ---
            // Wait for session to end
            int status;
            while (waitpid(session_pid, &status, 0) < 0 && errno == EINTR);
        }
    }
}

void load_keymap() {
    std::ifstream f("/etc/default/keyboard");
    if (!f) return;
    
    std::string line;
    while (std::getline(f, line)) {
        if (line.find("XKBLAYOUT=") == 0) {
            size_t first = line.find('"');
            size_t last = line.rfind('"');
            if (first != std::string::npos && last > first) {
                std::string layout = line.substr(first + 1, last - first - 1);
                std::cout << "[INIT] Loading keymap: " << layout << std::endl;
                
                // Find the file (Assuming it exists in standard path based on keymap.cpp logic, 
                // but init might need to search or assume a path.
                // For robustness, we assume keymap.cpp saved the short code, but loadkmap needs full path or we search.
                // Let's try standard path construction:
                std::string path = "/usr/share/keymaps/" + layout + ".bmap";
                // Check if exists, if not try search (omitted for brevity, assuming flat structure or careful user)
                // Actually, build.sh flattened the structure? No, it kept structure? 
                // The build.sh find command outputted to rootfs/usr/share/keymaps/$NAME.bmap (FLAT structure)
                // So we can just do:

                std::string cmd = "/bin/apps/system/loadkmap /usr/share/keymaps/" + layout + ".bmap";
                int ret = system(cmd.c_str());
                if (ret != 0) std::cerr << "[ERR] Failed to load keymap." << std::endl;
            }
        }
    }
}

int main(int argc, char* argv[]) {
    // Disable output buffering to ensure logs are visible immediately
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    
    // 0. Setup Global Environment (Locales and System Paths)
    // This ensures everything GeminiOS spawns understands en_US.UTF-8
    setenv("PATH", "/bin/apps/system:/bin/apps:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin", 1);
    setenv("LANG", "en_US.UTF-8", 1);
    setenv("LC_ALL", "en_US.UTF-8", 1);
    setenv("LANGUAGE", "en_US.UTF-8", 1);
    setenv("LOCPATH", "/usr/lib/locale", 1);
    setenv("GCONV_PATH", "/usr/lib/gconv", 1);
    setenv("TERM", "linux", 1);
    setenv("EDITOR", "nano", 1);
    setenv("PAGER", "cat", 1);
    setenv("HOME", "/root", 0); // Default home
    
    if (getpid() == 1) std::cout << "[INIT] Starting GeminiOS Init..." << std::endl;
    // Check if we are being run as a shell (not PID 1)
    if (getpid() != 1) {
        // Initialize terminal for interactive use
        if (isatty(STDIN_FILENO)) {
             tcgetattr(STDIN_FILENO, &orig_termios);
             enable_raw_mode();
        }
        // Handle signal handlers for shell
        signal(SIGINT, sigint_handler);

        start_shell();
        return 0;
    }

    // 1. Kernel Hands over control here.
    // Clear screen (ANSI escape)
    std::cout << "\033[2J\033[1;1H"; 
    std::cout << "Welcome to " << OS_NAME << " " << OS_VERSION << std::endl;     
    
    // 1.1 Configure Networking (Eth0)
    // Network is shared across the system, so we configure it once in Init
    ConfigureNetwork();
    
    // 2. Mount essential filesystems
    mount_fs("none", "/proc", "proc");
    mount_fs("none", "/sys", "sysfs");
    mount_fs("devtmpfs", "/dev", "devtmpfs");
    mount_fs("devpts", "/dev/pts", "devpts");
    mount_fs("tmpfs", "/dev/shm", "tmpfs");

    // Mount tmpfs on writable directories to prevent "No space left on device" errors
    mount_fs("tmpfs", "/tmp", "tmpfs");
    mount_fs("tmpfs", "/run", "tmpfs");
    mount_fs("tmpfs", "/var/log", "tmpfs");
    mount_fs("tmpfs", "/var/tmp", "tmpfs");
    mount_fs("tmpfs", "/usr/share/X11/xkb/compiled", "tmpfs");

    // Start udevd to manage device nodes
    if (fork() == 0) {
        execl("/usr/sbin/udevd", "udevd", "--daemon", nullptr);
        exit(0);
    }
    // Trigger udev to populate devices
    system("/usr/bin/udevadm trigger --action=add");
    system("/usr/bin/udevadm settle");
    
    // 2.0.1 Ensure Directory Structure
    ensure_fhs();

    // Start D-Bus Daemon (Required for XFCE)
    mkdir("/var/lib/dbus", 0755);
    system("/usr/bin/dbus-uuidgen --ensure");
    mkdir("/run/dbus", 0755);
    if (fork() == 0) {
        execl("/usr/bin/dbus-daemon", "dbus-daemon", "--system", "--address=systemd:", nullptr);
        // Fallback if systemd address fails (we don't have systemd but some configs expect it)
        execl("/usr/bin/dbus-daemon", "dbus-daemon", "--system", nullptr);
        exit(0);
    }

    // Create standard symlinks for shell scripts
    symlink("/proc/self/fd", "/dev/fd");
    symlink("/proc/self/fd/0", "/dev/stdin");
    symlink("/proc/self/fd/1", "/dev/stdout");
    symlink("/proc/self/fd/2", "/dev/stderr");

    // 2.1 Generate System Info File (The core source of truth for userspace)
    UserMgmt::initialize_defaults(); // Create /etc/passwd with 'gemini' if missing
    
    // 2.2 Load Keyboard Layout
    // load_keymap(); // Disabled: TTY uses default US layout.

    generate_os_release();
    // 3. Spawn Terminals
    // Init Process becomes a Supervisor
    // We include ttyS0 for serial console access (QEMU stdio)
    std::vector<std::string> terminals = {"/dev/tty1", "/dev/tty2", "/dev/tty3", "/dev/ttyS0"};
    
    for (const auto& tty : terminals) {
        pid_t pid = fork(); 
        if (pid == 0) { 
            run_shell(tty); 
            exit(0); 
        } 
        if (pid > 0) g_tty_pids[pid] = tty;
    }

    // 4. Supervisor Loop (Reap Zombies)
    while (true) {
        int status;
        pid_t pid = wait(&status); // Wait for any child (shell) to die

        if (pid > 0) {
            // Check if it was a TTY supervisor
            auto it = g_tty_pids.find(pid);
            if (it != g_tty_pids.end()) {
                std::string tty = it->second;
                g_tty_pids.erase(it);
                
                std::cerr << "[INIT] TTY " << tty << " (PID " << pid << ") exited unexpectedly. Respawning..." << std::endl;
                
                // Respawn
                pid_t new_pid = fork();
                if (new_pid == 0) {
                    run_shell(tty);
                    exit(0);
                }
                if (new_pid > 0) {
                    g_tty_pids[new_pid] = tty;
                }
            } else {
                 // Just a regular zombie reap (orphaned grandchildren, etc)
                 // In a real init, we might want to log this.
            }
        }
    }
}
