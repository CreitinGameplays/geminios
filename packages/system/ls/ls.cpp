#include <iostream>
#include <vector>
#include <dirent.h>
#include <sys/stat.h>
#include <algorithm>
#include <string>
#include "sys_info.h"
#include <iomanip>
#include <pwd.h>
#include <grp.h>
#include <ctime>
#include <algorithm>
#include <unistd.h>
bool needs_quoting(const std::string& name) {
    for (char c : name) {
        // Check for spaces and common shell metacharacters
        if (c == ' ' || c == '\'' || c == '"' || c == '\\' || 
            c == '$' || c == '`' || c == '(' || c == ')' || 
            c == '&' || c == ';' || c == '|' || c == '<' || c == '>') {
            return true;
        }
    }
    return false;
}

std::string format_name(const std::string& name) {
    if (!needs_quoting(name)) return name;
    
    std::string out = "'";
    for (char c : name) {
        if (c == '\'') out += "'\\''";
        else out += c;
    }
    out += "'";
    return out;
}

std::string format_size(off_t size) {
    const char* suffixes[] = {"B", "K", "M", "G", "T"};
    int i = 0;
    double s = size;
    while (s >= 1024 && i < 4) { s /= 1024; i++; }
    char buf[32];
    if (i == 0) sprintf(buf, "%ld", size);
    else sprintf(buf, "%.1f%s", s, suffixes[i]);
    return std::string(buf);
}

std::string get_perms(mode_t m) {
    std::string p = "----------";
    if (S_ISDIR(m)) p[0] = 'd';
    else if (S_ISCHR(m)) p[0] = 'c';
    else if (S_ISBLK(m)) p[0] = 'b';
    else if (S_ISFIFO(m)) p[0] = 'p';
    else if (S_ISLNK(m)) p[0] = 'l';
    
    if (m & S_IRUSR) p[1] = 'r';
    if (m & S_IWUSR) p[2] = 'w';
    if (m & S_IXUSR) p[3] = 'x';
    if (m & S_IRGRP) p[4] = 'r';
    if (m & S_IWGRP) p[5] = 'w';
    if (m & S_IXGRP) p[6] = 'x';
    if (m & S_IROTH) p[7] = 'r';
    if (m & S_IWOTH) p[8] = 'w';
    if (m & S_IXOTH) p[9] = 'x';
    return p;
}

struct FileInfo {
    std::string name;
    std::string full_path;
    struct stat st;
    bool valid;
};

bool g_recursive = false;
bool g_show_hidden = false;
bool g_long_fmt = false;
bool g_human = false;
bool g_indicators = false;
bool g_reverse = false;
bool g_inode = false;
bool g_directory = false;
bool g_verbose = false;
enum SortMode { NAME, TIME, SIZE };
SortMode g_sort = NAME;

void list_dir(const std::string& path);

int main(int argc, char* argv[]) {
    std::vector<std::string> paths;
    
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") {
            std::cout << "Usage: ls [options] [path...]\n"
                      << "Options:\n"
                      << "  -a, -all   Show hidden files\n"
                      << "  -l         Long listing\n"
                      << "  -h         Human readable sizes\n"
                      << "  -d         List directories themselves, not contents\n"
                      << "  -i         Print inode number\n"
                      << "  -F         Classify\n"
                      << "  -R         Recursive\n"
                      << "  -r         Reverse order\n"
                      << "  -t         Sort by time\n"
                      << "  -S         Sort by size\n"
                      << "  -v, --verbose Verbose output\n";
            return 0;
        }
        if (arg == "--verbose") {
            g_verbose = true;
            continue;
        }
        if (arg == "--version") {
            std::cout << "ls (" << OS_NAME << ") " << OS_VERSION << std::endl;
            return 0;
        }
        if (arg[0] == '-') {
            for(char c : arg) {
                if (c == '-') continue;
                if (c == 'a') g_show_hidden = true;
                else if (c == 'l') g_long_fmt = true;
                else if (c == 'h') g_human = true;
                else if (c == 'F') g_indicators = true;
                else if (c == 'R') g_recursive = true;
                else if (c == 'r') g_reverse = true;
                else if (c == 'd') g_directory = true;
                else if (c == 'i') g_inode = true;
                else if (c == 't') g_sort = TIME;
                else if (c == 'S') g_sort = SIZE;
                else if (c == 'v') g_verbose = true;
            }
        }
        else paths.push_back(arg);
    }

    if (paths.empty()) paths.push_back(".");

    for (const auto& path : paths) {
        if (paths.size() > 1) std::cout << path << ":\n";
        list_dir(path);
        if (paths.size() > 1 && path != paths.back()) std::cout << "\n";
    }
    return 0;
}

void list_dir(const std::string& path) {
    if (g_verbose) std::cout << "Listing directory: " << path << std::endl;
    if (g_directory) {
        FileInfo fi;
        fi.name = path;
        fi.full_path = path;
        if (lstat(path.c_str(), &fi.st) != 0) {
            perror(("ls: " + path).c_str());
            return;
        }
        fi.valid = true;

        // Print just this entry
        if (g_long_fmt) {
            struct passwd* pw = getpwuid(fi.st.st_uid);
            struct group* gr = getgrgid(fi.st.st_gid);
            std::string u = pw ? pw->pw_name : std::to_string(fi.st.st_uid);
            std::string g = gr ? gr->gr_name : std::to_string(fi.st.st_gid);
            char timebuf[64];
            strftime(timebuf, sizeof(timebuf), "%b %d %H:%M", localtime(&fi.st.st_mtime));
            std::string size_str = g_human ? format_size(fi.st.st_size) : std::to_string(fi.st.st_size);
            
            if (g_inode) std::cout << std::setw(8) << fi.st.st_ino << " ";
            std::cout << get_perms(fi.st.st_mode) << " " 
                      << std::left << std::setw(4) << fi.st.st_nlink << " "
                      << std::setw(8) << u << " " << std::setw(8) << g << " "
                      << std::right << std::setw(8) << size_str << " "
                      << timebuf << " " << format_name(fi.name) << std::endl;
        } else {
            if (g_inode) std::cout << fi.st.st_ino << " ";
            std::cout << format_name(fi.name) << std::endl;
        }
        return;
    }

    DIR* dir = opendir(path.c_str());
    if (!dir) { perror(("ls: " + path).c_str()); return; }
    
    std::vector<FileInfo> files;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!g_show_hidden && entry->d_name[0] == '.') continue;
        FileInfo fi;
        fi.name = entry->d_name;
        fi.full_path = path + "/" + fi.name;
        fi.valid = (lstat(fi.full_path.c_str(), &fi.st) == 0);
        files.push_back(fi);
    }
    closedir(dir);
    
    // Sort
    std::sort(files.begin(), files.end(), [](const FileInfo& a, const FileInfo& b) {
        if (g_sort == TIME) {
            if (a.st.st_mtime != b.st.st_mtime) return a.st.st_mtime > b.st.st_mtime;
        } else if (g_sort == SIZE) {
            if (a.st.st_size != b.st.st_size) return a.st.st_size > b.st.st_size;
        }
        return a.name < b.name; // Default name
    });

    if (g_reverse) std::reverse(files.begin(), files.end());

    if (g_long_fmt) {
        for (const auto& f : files) {
            if (!f.valid) continue;

            struct passwd* pw = getpwuid(f.st.st_uid);
            struct group* gr = getgrgid(f.st.st_gid);
            std::string u = pw ? pw->pw_name : std::to_string(f.st.st_uid);
            std::string g = gr ? gr->gr_name : std::to_string(f.st.st_gid);
            
            char timebuf[64];
            strftime(timebuf, sizeof(timebuf), "%b %d %H:%M", localtime(&f.st.st_mtime));

            std::string size_str = g_human ? format_size(f.st.st_size) : std::to_string(f.st.st_size);
            std::string suffix = "";
            if (g_indicators) {
                if (S_ISDIR(f.st.st_mode)) suffix = "/";
                else if (f.st.st_mode & S_IXUSR) suffix = "*";
                else if (S_ISLNK(f.st.st_mode)) suffix = "@";
            }

            if (g_inode) std::cout << std::setw(8) << f.st.st_ino << " ";
            std::cout << get_perms(f.st.st_mode) << " " 
                      << std::left << std::setw(4) << f.st.st_nlink << " "
                      << std::setw(8) << u << " " << std::setw(8) << g << " "
                      << std::right << std::setw(8) << size_str << " "
                      << timebuf << " " << format_name(f.name) << suffix;
            
            if (S_ISLNK(f.st.st_mode)) {
                char link_target[1024];
                ssize_t len = readlink(f.full_path.c_str(), link_target, sizeof(link_target)-1);
                if (len != -1) {
                    link_target[len] = '\0';
                    std::cout << " -> " << link_target;
                }
            }
            std::cout << std::endl;
        }
    } else {
        for (const auto& f : files) {
            std::string suffix = "";
            if (g_indicators && f.valid) {
                if (S_ISDIR(f.st.st_mode)) suffix = "/";
                else if (f.st.st_mode & S_IXUSR) suffix = "*";
                else if (S_ISLNK(f.st.st_mode)) suffix = "@";
            }
            if (g_inode) std::cout << f.st.st_ino << " ";
            std::cout << format_name(f.name) << suffix << "  ";
        }
        std::cout << std::endl;
    }

    if (g_recursive) {
        for (const auto& f : files) {
            if (f.valid && S_ISDIR(f.st.st_mode) && f.name != "." && f.name != "..") {
                std::cout << "\n" << f.full_path << ":\n";
                list_dir(f.full_path);
            }
        }
    }
}
