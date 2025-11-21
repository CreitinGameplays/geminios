#include <iostream>
#include <vector>
#include <string>
#include <fstream>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <algorithm>
#include <cctype>
#include <sys/stat.h>
#include <cstring>
#include <dirent.h>
#include "../../../src/sys_info.h"

// Global verbose flag
bool g_verbose = false;

struct Layout {
    std::string code;
    std::string name;
};

// A selection of common layouts
std::vector<Layout> layouts = {
    {"us", "English (US)"},
    {"uk", "English (UK)"},
    {"bg-cp1251", "Bulgarian"},
    {"br-abnt2", "Portuguese (Brazil)"},
    {"by", "Belarusian"},
    {"ca", "English (Canada)"},
    {"sg", "Swiss German"},
    {"cz", "Czech"},
    {"de", "German"},
    {"dk", "Danish"},
    {"et", "Estonian"},
    {"es", "Spanish"},
    {"fi", "Finnish"},
    {"fr", "French"},
    {"gr", "Greek"},
    {"croat", "Croatian"},
    {"hu", "Hungarian"},
    {"ie", "Irish"},
    {"il", "Hebrew"},
    {"is-latin1", "Icelandic"},
    {"it", "Italian"},
    {"jp106", "Japanese"},
    {"la-latin1", "Latin American"},
    {"lt", "Lithuanian"},
    {"lv", "Latvian"},
    {"mk", "Macedonian"},
    {"nl", "Dutch"},
    {"no", "Norwegian"},
    {"pl", "Polish"},
    {"pt", "Portuguese"},
    {"ro", "Romanian"},
    {"ru", "Russian"},
    {"se-lat6", "Swedish"},
    {"slovene", "Slovenian"},
    {"sk-qwerty", "Slovak"},
    {"trq", "Turkish"},
    {"ua", "Ukrainian"},
};

// Terminal control
void clear_screen() { std::cout << "\033[2J\033[H"; }
void hide_cursor() { std::cout << "\033[?25l"; }
void show_cursor() { std::cout << "\033[?25h"; }

int get_term_height() {
    struct winsize w;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0) return w.ws_row;
    return 24;
}

// Raw mode
struct termios orig_termios;
void disable_raw_mode() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios);
    show_cursor();
}
void enable_raw_mode() {
    tcgetattr(STDIN_FILENO, &orig_termios);
    atexit(disable_raw_mode);
    struct termios raw = orig_termios;
    raw.c_lflag &= ~(ECHO | ICANON);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    hide_cursor();
}

// Helper to find keymap file recursively
std::string find_keymap_path(const std::string& dir_path, const std::string& code) {
    if (g_verbose) std::cout << "[DEBUG] Scanning directory: " << dir_path << "\n";
    DIR* dir = opendir(dir_path.c_str());
    if (!dir) {
        if (g_verbose) std::cout << "[DEBUG] Failed to open directory: " << dir_path << "\n";
        return "";
    }
    
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        
        std::string full_path = dir_path + "/" + name;
        struct stat st;
        if (stat(full_path.c_str(), &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                std::string res = find_keymap_path(full_path, code);
                if (!res.empty()) { closedir(dir); return res; }
            } else {
                // Check for code.bmap
                if (g_verbose) std::cout << "[DEBUG] Checking file: " << name << "\n";
                if (name == code + ".bmap") {
                    if (g_verbose) std::cout << "[DEBUG] Found match: " << full_path << "\n";
                    closedir(dir);
                    return full_path;
                }
            }
        }
    }
    closedir(dir);
    return "";
}

int main(int argc, char* argv[]) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") {
            std::cout << "Usage: keymap [-v|--verbose]\nInteractive keyboard layout selector.\n";
            return 0;
        } else if (arg == "--verbose" || arg == "-v") {
            g_verbose = true;
        }
    }

    if (g_verbose) {
        std::cout << "[DEBUG] Starting keymap selector in verbose mode.\n";
        std::cout << "[DEBUG] Terminal height: " << get_term_height() << "\n";
    }

    enable_raw_mode();
    
    int selection = 0;
    int scroll_offset = 0;
    std::string type_buffer;

    while (true) {
        int height = get_term_height();
        if (height < 10) height = 10;
        int list_height = height - 5; // Header (2) + Footer (3)

        // Adjust Scroll
        if (selection < scroll_offset) scroll_offset = selection;
        if (selection >= scroll_offset + list_height) scroll_offset = selection - list_height + 1;

        clear_screen();
        std::cout << "  Select Keyboard Layout\n";
        std::cout << "---------------------------------------------------\n";

        for (int i = 0; i < list_height; ++i) {
            int idx = scroll_offset + i;
            if (idx >= (int)layouts.size()) break;

            if (idx == selection) std::cout << "\033[7m"; // Invert
            std::cout << (idx + 1) << ". " << layouts[idx].name << " [" << layouts[idx].code << "]";
            if (idx == selection) std::cout << "\033[0m";
            std::cout << "\n";
        }

        std::cout << "---------------------------------------------------\n";
        std::cout << "UP/DOWN: Scroll | ENTER: Select | Q: Quit\n";
        std::cout << "Jump to number: " << type_buffer << "\n";

        // Input
        char c;
        if (read(STDIN_FILENO, &c, 1) != 1) break;

        if (c == '\033') {
            char seq[2];
            if (read(STDIN_FILENO, &seq, 2) == 2) {
                if (seq[0] == '[') {
                    if (seq[1] == 'A') { // Up
                        if (selection > 0) selection--;
                    } else if (seq[1] == 'B') { // Down
                        if (selection < (int)layouts.size() - 1) selection++;
                    }
                }
            }
        } else if (c == '\n' || c == '\r') {
            // Save
            struct stat st;
            if (stat("/etc/default", &st) != 0) {
                if (mkdir("/etc/default", 0755) != 0) {
                    disable_raw_mode();
                    perror("Error creating /etc/default");
                    return 1;
                }
            }

            if (g_verbose) std::cout << "\r\n[DEBUG] Writing configuration to /etc/default/keyboard...";

            std::ofstream f("/etc/default/keyboard");
            if (f) {
                f << "XKBLAYOUT=\"" << layouts[selection].code << "\"\n";
                f.close();
            } else {
                disable_raw_mode();
                perror("Error writing to /etc/default/keyboard");
                return 1;
            }
            disable_raw_mode();
            std::cout << "\nSelected: " << layouts[selection].name << " [" << layouts[selection].code << "]\n";
            std::cout << "Configuration saved to /etc/default/keyboard\n";
            
            std::cout << "NOTE: Keyboard layout change is currently unsupported on TTY mode.\n";
            std::cout << "The default layout (US) will be used.\n";
            std::cout << "Your selection has been saved for future Desktop UI support.\n";

            /*
            std::cout << "Applying keymap...\n";
            
            // Find the absolute path to the keymap file
            if (g_verbose) std::cout << "[DEBUG] Searching for " << layouts[selection].code << ".bmap in /usr/share/keymaps...\n";
            std::string map_file = find_keymap_path("/usr/share/keymaps", layouts[selection].code);

            if (map_file.empty()) {
                std::cout << "Error: Keymap file '" << layouts[selection].code << ".bmap' not found.\n";
                if (g_verbose) std::cout << "[DEBUG] Search failed. Ensure /usr/share/keymaps is populated correctly.\n";
                return 1;
            }

            std::string cmd = "/bin/apps/system/loadkmap " + map_file;
            if (g_verbose) std::cout << "[DEBUG] Executing: " << cmd << "\n";

            if (system(cmd.c_str()) == 0) {
                std::cout << "Keymap applied successfully.\n";
            } else {
                std::cout << "Error applying keymap (check if '" << layouts[selection].code << "' exists in /usr/share/keymaps).\n";
                if (g_verbose) std::cout << "[DEBUG] 'loadkmap' command returned non-zero exit code.\n";
            }
            */
            return 0;
        } else if (isdigit(c)) {
            type_buffer += c;
            try {
                int val = std::stoi(type_buffer);
                if (val > 0 && val <= (int)layouts.size()) {
                    selection = val - 1;
                }
            } catch(...) { type_buffer = ""; }
        } else if (c == 127 || c == '\b') { // Backspace
            if (!type_buffer.empty()) type_buffer.pop_back();
        } else if (c == 'q' || c == 'Q') {
            break;
        }
    }

    return 0;
}
