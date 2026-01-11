#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>
#include <cstring>
#include <algorithm>
#include <sstream>
#include <fstream>
#include <termios.h>
#include <csignal>
#include <cctype>
#include <glob.h>

#include "signals.h"
#include "sys_info.h"

// Global Command History
std::vector<std::string> HISTORY;

// Global Signal Flag
volatile pid_t g_foreground_pid = -1;

// Original Terminal Settings
struct termios orig_termios;

// Helper for autocomplete to list packages in repo
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
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == -1) {
        perror("enable_raw_mode: tcsetattr");
    }
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
    std::string left_context = buffer.substr(0, cursor_pos);
    
    // Find start of the current word
    size_t last_space = left_context.find_last_of(' ');
    std::string prefix = (last_space == std::string::npos) ? left_context : left_context.substr(last_space + 1);

    // Basic tokenization to determine command context
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
    if (!current_token.empty()) tokens.push_back(current_token);

    bool new_token = (!left_context.empty() && std::isspace(left_context.back()));
    std::string cmd = (tokens.empty()) ? "" : tokens[0];
    bool is_command_pos = (tokens.empty() || (tokens.size() == 1 && !new_token));

    std::vector<std::string> candidates;

    if (is_command_pos) {
        if (std::string("cd").find(prefix) == 0) candidates.push_back("cd ");
        
        for (const auto& path : get_path_dirs()) {
            scan_executables(path, candidates, prefix);
        }
    } 
    else if (cmd == "gpkg") {
        int arg_index = tokens.size() - (new_token ? 0 : 1);

                if (arg_index == 1) { // gpkg <action>

                    std::vector<std::string> actions = {"install ", "remove ", "list ", "download ", "search ", "clean ", "help ", "update ", "upgrade ", "--verbose "};

                    for (const auto& act : actions) {

                        if (act.find(prefix) == 0) candidates.push_back(act);

                    }

                }

         else if (arg_index == 2) { // gpkg <action> <package>
            std::string action = tokens[1];
            if (action == "install" || action == "download") {
                for (const auto& pkg : get_repo_packages()) {
                    if (pkg.find(prefix) == 0) candidates.push_back(pkg + " ");
                }
            } else if (action == "remove") {
                scan_executables("/bin/apps/system/", candidates, prefix);
                scan_executables("/bin/apps/", candidates, prefix);
            }
        }
    } else {
        // Generic path completion
        std::string file_pattern, dir_path;
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
                    if (is_directory(full_match)) full_match += "/";
                    candidates.push_back(full_match);
                }
            }
            closedir(dir);
        }
    }

    if (candidates.empty()) return;
    
    if (candidates.size() == 1) {
        std::string match = candidates[0];
        std::string to_insert;
        if (match.find(prefix) == 0) to_insert = match.substr(prefix.length());
        
        if (!to_insert.empty()) {
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
        std::cout << "\n";
        for (const auto& c : candidates) std::cout << c << "  ";
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
        } else if (c == '\n' || c == '\r') { // Enter
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
        } else if (c == '\t') { // Tab
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

// --- Shell Data Structures ---

struct Redirection {
    int fd;             // Target FD (1=stdout, 2=stderr)
    int source_fd;      // Source FD (for 2>&1, source is 1) or -1 if file
    std::string file;   // Target file
    bool append;        // >> vs >
    int input_fd;       // For input redirection (<), describes which FD reads from the file (usually 0)
};

struct Command {
    std::vector<std::string> args;
    std::vector<Redirection> redirects;
    std::string heredoc_content; // For << or <<<
    bool is_subshell;
    bool is_group; // { cmd; }
    std::string subshell_cmd; // Raw command string for recursive parsing
};

// Logic connectors between commands
enum LogicOp {
    OP_NONE,
    OP_AND, // &&
    OP_OR,  // ||
    OP_SEQ  // ;
};

struct Job {
    std::vector<Command> commands; // Piped commands
    LogicOp next_op; // logic to apply to the NEXT job
    bool background; // & at the end
};

// --- Shell Tokenizer ---

std::vector<std::string> tokenize_input(const std::string& input) {
    std::vector<std::string> tokens;
    std::string current;
    bool in_dquote = false;
    bool in_squote = false;
    bool escaped = false;

    auto push_token = [&]() {
        if (!current.empty()) {
            tokens.push_back(current);
            current.clear();
        }
    };

    for (size_t i = 0; i < input.length(); ++i) {
        char c = input[i];
        char next = (i + 1 < input.length()) ? input[i+1] : '\0';
        char next2 = (i + 2 < input.length()) ? input[i+2] : '\0';
        
        if (escaped) {
            current += c;
            escaped = false;
            continue;
        }
        if (c == '\') {
            escaped = true;
            continue;
        }
        if (c == '"' && !in_squote) {
            in_dquote = !in_dquote;
            continue;
        }
        if (c == '\'' && !in_dquote) {
            in_squote = !in_squote;
            continue;
        }
        if (in_dquote || in_squote) {
            current += c;
            continue;
        }

        if (isdigit(c) && next == '>') {
            if (current.empty()) {
                // Handle file descriptor redirections (e.g., 2>, 2>>, 2>&1)
                push_token();
                current += c;
                i++; // Consume '>'
                current += '>';
                
                if (input[i+1] == '>') {
                     current += '>';
                     i++;
                } else if (input[i+1] == '&') {
                     current += '&';
                     i++;
                     if (isdigit(input[i+1])) {
                         current += input[i+1];
                         i++;
                     } else if (input[i+1] == '-') {
                         current += input[i+1];
                         i++;
                     }
                }
                
                push_token();
                continue;
            }
        }
        
        if (std::isspace(c)) {
            push_token();
        } 
        else if (c == '&') {
            // &, &&, &>
             if (next == '&') {
                push_token(); tokens.push_back("&&"); i++; 
            } else if (next == '>') {
                // &>, &>>
                push_token(); 
                if (next2 == '>') { tokens.push_back("&>>"); i+=2; } 
                else { tokens.push_back("&>"); i++; }
            } else {
                push_token(); tokens.push_back("&");
            }
        }
        else if (c == '|') {
            if (next == '|') {
                push_token(); tokens.push_back("||"); i++;
            } else {
                push_token(); tokens.push_back("|");
            }
        }
        else if (c == '>') {
            // >, >>, >&
            if (next == '>') {
                push_token(); tokens.push_back(">>"); i++;
            } else if (next == '&') {
                push_token(); tokens.push_back(">& "); i++;
            } else {
                push_token(); tokens.push_back(">");
            }
        }
        else if (c == '<') {
            // <, <<, <<<
            if (next == '<') {
                push_token();
                if (next2 == '<') { tokens.push_back("<<<"); i+=2; } 
                else { tokens.push_back("<<"); i++; }
            } else {
                push_token(); tokens.push_back("<");
            }
        }
        else if (c == ';') {
            push_token(); tokens.push_back(";");
        }
        else if (c == '(') {
            push_token(); tokens.push_back("(");
        }
        else if (c == ')') {
             push_token(); tokens.push_back(")");
        }
        else if (c == '{') {
             push_token(); tokens.push_back("{");
        }
        else if (c == '}') {
             push_token(); tokens.push_back("}");
        }
        else {
            current += c;
        }
    }
    push_token();
    return tokens;
}

// --- Expansion Helper ---
std::vector<std::string> expand_arg(const std::string& token) {
    std::string expanded;
    bool has_var = (token.find('$') != std::string::npos);
    
    if (!has_var) expanded = token;
    else {
        for (size_t i = 0; i < token.length(); ++i) {
            if (token[i] == '$') {
                if (i + 1 < token.length()) {
                    std::string var_name;
                    size_t j = i + 1;
                    while (j < token.length() && (isalnum(token[j]) || token[j] == '_')) {
                        var_name += token[j];
                        j++;
                    }
                    const char* val = getenv(var_name.c_str());
                    if (val) expanded += val;
                    i = j - 1;
                } else {
                    expanded += '$';
                }
            } else {
                expanded += token[i];
            }
        }
    }

    // Globbing
    if (expanded.find('*') != std::string::npos || expanded.find('?') != std::string::npos) {
          glob_t glob_result;
          memset(&glob_result, 0, sizeof(glob_result));
          int return_value = glob(expanded.c_str(), GLOB_TILDE, NULL, &glob_result);
          if (return_value == 0) {
               std::vector<std::string> results;
               for(size_t i = 0; i < glob_result.gl_pathc; ++i) {
                   results.push_back(std::string(glob_result.gl_pathv[i]));
               }
               globfree(&glob_result);
               return results;
          } else {
               globfree(&glob_result);
               return {expanded};
          }
    }
    
    return {expanded};
}


// --- Shell Parser ---
std::vector<Job> parse_input(const std::vector<std::string>& tokens) {
    std::vector<Job> jobs;
    Job current_job;
    current_job.next_op = OP_NONE;
    current_job.background = false;
    
    Command current_command;
    current_command.is_subshell = false;
    current_command.is_group = false;

    for (size_t i = 0; i < tokens.size(); ++i) {
        std::string t = tokens[i]; // Value copy for manipulation

        if (t == "&&") {
            if (!current_command.args.empty() || current_command.is_subshell || current_command.is_group) current_job.commands.push_back(current_command);
            current_job.next_op = OP_AND;
            jobs.push_back(current_job);
            current_job = Job();
            current_command = Command();
        } else if (t == "||") {
            if (!current_command.args.empty() || current_command.is_subshell || current_command.is_group) current_job.commands.push_back(current_command);
            current_job.next_op = OP_OR;
            jobs.push_back(current_job);
            current_job = Job();
            current_command = Command();
        } else if (t == ";") {
            if (!current_command.args.empty() || current_command.is_subshell || current_command.is_group) current_job.commands.push_back(current_command);
            current_job.next_op = OP_SEQ;
            jobs.push_back(current_job);
            current_job = Job();
            current_command = Command();
        } else if (t == "&") {
            if (!current_command.args.empty() || current_command.is_subshell || current_command.is_group) current_job.commands.push_back(current_command);
            current_job.background = true;
            current_job.next_op = OP_SEQ;
            jobs.push_back(current_job);
            current_job = Job();
            current_command = Command();
        } else if (t == "|") {
            if (!current_command.args.empty() || current_command.is_subshell || current_command.is_group) current_job.commands.push_back(current_command);
            current_command = Command();
        } else if (t == "(") {
            // Start subshell.
            // Collect tokens until matching )
            int depth = 1;
            std::string subcmd;
            i++;
            bool first = true;
            while (i < tokens.size()) {
                if (tokens[i] == "(") depth++;
                else if (tokens[i] == ")") {
                    depth--;
                    if (depth == 0) break;
                }
                if (!first) subcmd += " "; // Reconstruct roughly
                subcmd += tokens[i];
                first = false;
                i++;
            }
            current_command.is_subshell = true;
            current_command.subshell_cmd = subcmd;
        } 
        else if (t == "{") {
            // Start Group
            int depth = 1;
            std::string subcmd;
            i++;
            bool first = true;
            while (i < tokens.size()) {
                if (tokens[i] == "{") depth++;
                else if (tokens[i] == "}") {
                    depth--;
                    if (depth == 0) break;
                }
                if (!first) subcmd += " ";
                subcmd += tokens[i];
                first = false;
                i++;
            }
            current_command.is_group = true;
            current_command.subshell_cmd = subcmd; // Reuse string field
        }
        else if (t.find(">") != std::string::npos || t.find("<") != std::string::npos) {
            // Handle Redirections
            // Logic to parse N>, >>, <, <<, <<<, &>, 2>&1
            
            Redirection r;
            r.fd = 1; // Default to stdout
            r.input_fd = 0; // Default to stdin
            r.source_fd = -1; // File by default
            
            // Check for Input Redirection
            if (t == "<") {
                 if (i + 1 < tokens.size()) {
                     r.file = tokens[++i];
                     r.fd = 0; // Target is Stdin
                     r.input_fd = 0;
                     // We store input redirect as a redirection with fd=0
                 }
            } else if (t == "<<") {
                 // Here-doc: Currently supports single-line herestrings. Currently not implemented.
                 if (i + 1 < tokens.size()) {
                    current_command.heredoc_content = tokens[++i];
                 }
            } else if (t == "<<<") {
                 if (i + 1 < tokens.size()) {
                    current_command.heredoc_content = tokens[++i]; 
                    // This is string input
                 }
            }
            // Check for Output Redirection with FDs
            else {
                 // > >> &> &>> 2> 2>&1
                 // Parse leading digit
                 if (isdigit(t[0]) && t.find('>') != std::string::npos) {
                     r.fd = t[0] - '0';
                     // Check suffix
                     std::string op = t.substr(1);
                     if (op == ">") r.append = false;
                     else if (op == ">>") r.append = true;
                     else if (op == ">&1") { r.source_fd = 1; r.file = ""; } // 2>&1
                     else if (op == ">&2") { r.source_fd = 2; r.file = ""; } // 1>&2
                 } 
                 else if (t == ">") { r.fd=1; r.append=false; } // >
                 else if (t == ">>") { r.fd=1; r.append=true; } // >>
                 else if (t == "&>" || t == "&>>") { r.fd=-1; r.append = (t=="&>>"); } // &> or &>>
                 else if (t == ">& ") { r.fd=-1; r.append=false; } // Legacy &>
                 
                 // If source_fd is -1, we expect a filename
                 if (r.source_fd == -1 && r.file.empty()) {
                     if (i + 1 < tokens.size()) {
                         r.file = tokens[++i];
                     }
                 }
            }
            // Add redirection to command
            current_command.redirects.push_back(r);
        }
        else {
            // Normal Argument - Expand it!
            std::vector<std::string> expanded = expand_arg(t);
            current_command.args.insert(current_command.args.end(), expanded.begin(), expanded.end());
        }
    }
    
    // Push remaining
    if (!current_command.args.empty() || current_command.is_subshell || current_command.is_group) {
        current_job.commands.push_back(current_command);
    }
    if (!current_job.commands.empty()) {
        current_job.next_op = OP_NONE;
        jobs.push_back(current_job);
    }

    return jobs;
}

// --- Execution Engine ---

int last_exit_code = 0;

void execute_command_string(const std::string& input);

void execute_pipeline(Job& job) {
    if (job.commands.empty()) return;

    // 1. Check for single builtin OR single group (no pipes)
    // If it's a group { ...; }, we execute it recursively in current process.
    if (job.commands.size() == 1) {
        Command& cmd_obj = job.commands[0];
        if (cmd_obj.is_group) {
             execute_command_string(cmd_obj.subshell_cmd);
             return;
        }
        
        if (!cmd_obj.is_subshell) {
            std::string cmd = cmd_obj.args.empty() ? "" : cmd_obj.args[0];
            std::vector<std::string> args = cmd_obj.args;

            if (cmd == "exit") exit(0);
            else if (cmd == "cd") {
                if (args.size() > 1) {
                    if (chdir(args[1].c_str()) != 0) {
                        perror("cd"); last_exit_code=1;
                    } else last_exit_code=0;
                } else {
                    const char* h = getenv("HOME");
                    if (h) chdir(h); else chdir("/");
                    last_exit_code=0;
                }
                return;
            }
            else if (cmd == "export") {
                if (args.size() > 1) {
                    for (size_t i = 1; i < args.size(); ++i) {
                        std::string arg = args[i];
                        size_t pos = arg.find('=');
                        if (pos != std::string::npos) {
                            setenv(arg.substr(0, pos).c_str(), arg.substr(pos+1).c_str(), 1);
                        }
                    }
                } else {
                    extern char** environ;
                    for (char** e = environ; *e; e++) std::cout << "declare -x " << *e << "\n";
                }
                last_exit_code=0;
                return;
            }
            else if (cmd == "source" || cmd == ".") {
                if (args.size() > 1) {
                    std::string filename = args[1];

                    if (filename == "--help") {
                        std::cout << "Usage: source FILENAME [ARGUMENTS]\n"
                                  << "       . FILENAME [ARGUMENTS]\n\n"
                                  << "Execute commands from a file in the current shell environment.\n"
                                  << "If FILENAME does not contain a slash, the PATH is searched.\n";
                        last_exit_code = 0;
                        return;
                    }

                    std::string path_to_open;
                    if (filename.find('/') != std::string::npos) {
                        path_to_open = filename;
                    } else {
                        // Search PATH
                        bool found = false;
                        for (const auto& dir : get_path_dirs()) {
                            std::string p = dir + filename;
                            if (access(p.c_str(), R_OK) == 0) {
                                path_to_open = p;
                                found = true;
                                break;
                            }
                        }
                        if (!found) path_to_open = filename; // Fallback to try current dir
                    }

                    std::ifstream file(path_to_open);
                    if (file) {
                        last_exit_code = 0;
                        std::string line;
                        while (std::getline(file, line)) {
                            size_t first = line.find_first_not_of(" \t");
                            if (first == std::string::npos) continue;
                            if (line[first] == '#') continue;
                            execute_command_string(line);
                        }
                    } else {
                        perror(("source: " + filename).c_str());
                        last_exit_code = 1;
                    }
                } else {
                    std::cerr << "source: filename argument required" << std::endl;
                    last_exit_code = 1;
                }
                return;
            }
        }
    }

    // 2. Pipeline Execution
    size_t num_cmds = job.commands.size();
    int prev_pipe_fd[2] = {-1, -1};
    pid_t last_pid = 0;
    std::vector<pid_t> pids;

    for (size_t i = 0; i < num_cmds; ++i) {
        Command& cmd_obj = job.commands[i];
        
        // Resolve executable if not subshell/group
        std::string executable;
        if (!cmd_obj.is_subshell && !cmd_obj.is_group) {
            std::string cmd_name = cmd_obj.args.empty() ? "" : cmd_obj.args[0];
            if (cmd_name.empty()) continue;
            
            if (cmd_name.find('/') != std::string::npos) {
                if (access(cmd_name.c_str(), X_OK) == 0) executable = cmd_name;
            } else {
                for (const auto& dir : get_path_dirs()) {
                    std::string p = dir + cmd_name;
                    if (access(p.c_str(), X_OK) == 0) { executable = p; break; }
                }
            }
            if (executable.empty()) {
                std::cerr << "Unknown command: " << cmd_name << std::endl;
                last_exit_code = 127;
                continue; 
            }
        }

        int pipe_fd[2] = {-1, -1};
        bool is_last = (i == num_cmds - 1);

        if (!is_last) {
            if (pipe(pipe_fd) < 0) { perror("pipe"); break; }
        }

        pid_t pid = fork();
        if (pid == 0) {
            // Child
            setpgid(0, 0);
            
            // Signals
            struct sigaction dfl; dfl.sa_handler = SIG_DFL; sigemptyset(&dfl.sa_mask); dfl.sa_flags = 0;
            sigaction(SIGINT, &dfl, NULL);

            // Pipe I/O
            if (prev_pipe_fd[0] != -1) {
                dup2(prev_pipe_fd[0], STDIN_FILENO); close(prev_pipe_fd[0]); close(prev_pipe_fd[1]);
            }
            if (!is_last) {
                dup2(pipe_fd[1], STDOUT_FILENO); close(pipe_fd[0]); close(pipe_fd[1]);
            }

            // Heredoc / Herestring
            if (!cmd_obj.heredoc_content.empty()) {
                int p[2]; pipe(p);
                write(p[1], cmd_obj.heredoc_content.c_str(), cmd_obj.heredoc_content.length());
                write(p[1], "\n", 1);
                close(p[1]);
                dup2(p[0], STDIN_FILENO); 
                close(p[0]);
            }

            // Redirections
            for (const auto& r : cmd_obj.redirects) {
                if (r.fd == 0) {
                    // Input Redirect
                     int fd_in = open(r.file.c_str(), O_RDONLY);
                     if (fd_in < 0) { perror(r.file.c_str()); exit(1); }
                     dup2(fd_in, STDIN_FILENO);
                     close(fd_in);
                } else {
                    // Output Redirect
                    if (r.source_fd != -1) {
                        dup2(r.source_fd, r.fd);
                    } else {
                        int flags = O_WRONLY | O_CREAT;
                        if (r.append) flags |= O_APPEND; else flags |= O_TRUNC;
                        int fd_out = open(r.file.c_str(), flags, 0644);
                        if (fd_out < 0) { perror(r.file.c_str()); exit(1); }
                        
                        if (r.fd == -1) {
                            dup2(fd_out, STDOUT_FILENO);
                            dup2(fd_out, STDERR_FILENO);
                        } else {
                            dup2(fd_out, r.fd);
                        }
                        close(fd_out);
                    }
                }
            }

            if (cmd_obj.is_subshell || cmd_obj.is_group) {
                execute_command_string(cmd_obj.subshell_cmd);
                exit(last_exit_code);
            } else {
                std::vector<char*> c_args;
                for (const auto& s : cmd_obj.args) c_args.push_back(const_cast<char*>(s.c_str()));
                c_args.push_back(nullptr);
                execv(executable.c_str(), c_args.data());
                perror("execv");
                exit(127);
            }
        } else if (pid > 0) {
            // Parent
            pids.push_back(pid);
            last_pid = pid;
            if (prev_pipe_fd[0] != -1) { close(prev_pipe_fd[0]); close(prev_pipe_fd[1]); }
            if (!is_last) { prev_pipe_fd[0] = pipe_fd[0]; prev_pipe_fd[1] = pipe_fd[1]; }
        }
    }

    if (!job.background) {
        if (g_foreground_pid == -1) g_foreground_pid = last_pid;
        
        if (isatty(STDIN_FILENO)) {
            tcsetpgrp(STDIN_FILENO, last_pid);
        }

        for (pid_t p : pids) {
            int status;
            while(waitpid(p, &status, 0) < 0 && errno == EINTR);
            if (p == last_pid) {
                if (WIFEXITED(status)) last_exit_code = WEXITSTATUS(status);
                else last_exit_code = 128 + WTERMSIG(status);
            }
        }
        
        if (isatty(STDIN_FILENO)) {
            tcsetpgrp(STDIN_FILENO, getpgrp());
        }

        g_foreground_pid = -1;
    } else {
        std::cout << "[" << last_pid << "]\n";
        last_exit_code = 0;
    }
}

void run_jobs(std::vector<Job>& jobs) {
    bool should_run = true;
    for (auto& job : jobs) {
        if (!should_run) {
            if (job.next_op == OP_OR && last_exit_code != 0) should_run = true;
            else if (job.next_op == OP_AND && last_exit_code == 0) should_run = true;
            else if (job.next_op == OP_SEQ) should_run = true;
            continue;
        }

        execute_pipeline(job);

        if (job.next_op == OP_AND) should_run = (last_exit_code == 0);
        else if (job.next_op == OP_OR) should_run = (last_exit_code != 0);
        else should_run = true;
    }
}

void execute_command_string(const std::string& input) {
    std::vector<std::string> tokens = tokenize_input(input);
    std::vector<Job> jobs = parse_input(tokens);
    run_jobs(jobs);
}

void start_shell(bool clear_on_start = false) {
    char cwd[1024];
    std::string input;

    if (clear_on_start) {
        std::cout << "\033[2J\033[1;1H";
    }

    // Ensure any output from login is flushed
    std::cout << std::flush;
    // Discard any pending input (like extra newlines) to avoid shell glitches
    tcflush(STDIN_FILENO, TCIFLUSH);

    enable_raw_mode();
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
             disable_raw_mode();
             execute_command_string(input);
             std::cout << "\033[?25h"; 
             enable_raw_mode();
             continue; 
        }
         
    }
}

int main(int argc, char* argv[]) {
    if (isatty(STDIN_FILENO)) {
        tcgetattr(STDIN_FILENO, &orig_termios);
    }
    
    struct sigaction sa;
    sa.sa_handler = sigint_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, NULL);
    
    // Ignore SIGTTOU to allow background process management
    signal(SIGTTOU, SIG_IGN); 

    start_shell();
    return 0;
}
