#include <iostream>
#include <vector>
#include <string>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <sys/time.h>
#include <libgen.h>
#include <algorithm>
#include "../../../src/sys_info.h"

// Buffer size for copying data
#define BUF_SIZE 8192

struct CopyOptions {
    bool recursive = false;
    bool interactive = false;
    bool preserve = false;
    bool verbose = false;
};

bool copy_path(const std::string& src, const std::string& dst, const CopyOptions& opts);

// Forward declaration
bool ask_overwrite(const std::string& path);

// Copy Symlink
bool copy_symlink(const std::string& src, const std::string& dst, const CopyOptions& opts, const struct stat& src_st) {
    char link_target[4096];
    ssize_t len = readlink(src.c_str(), link_target, sizeof(link_target)-1);
    if (len < 0) {
        perror(("copy: readlink " + src).c_str());
        return false;
    }
    link_target[len] = '\0';

    // Remove destination if it exists
    if (access(dst.c_str(), F_OK) == 0) {
        if (opts.interactive && !ask_overwrite(dst)) return false;
        unlink(dst.c_str()); // Force remove to create link
    }

    if (symlink(link_target, dst.c_str()) != 0) {
        perror(("copy: symlink " + dst).c_str());
        return false;
    }

    if (opts.preserve) {
        // lchown changes ownership of the link itself
        lchown(dst.c_str(), src_st.st_uid, src_st.st_gid);
    }
    
    if (opts.verbose) std::cout << "'" << src << "' -> '" << dst << "' (link)" << std::endl;
    return true;
}

// Helper to get filename from path
std::string get_basename(const std::string& path) {
    size_t pos = path.find_last_of('/');
    if (pos == std::string::npos) return path;
    return path.substr(pos + 1);
}

// Helper: Prompt overwrite
bool ask_overwrite(const std::string& path) {
    std::cerr << "copy: overwrite '" << path << "'? (y/n) ";
    char c;
    std::cin >> c;
    return (c == 'y' || c == 'Y');
}

// Copy File Content and Metadata
bool copy_file(const std::string& src, const std::string& dst, const CopyOptions& opts, const struct stat& src_st) {
    // Check destination
    struct stat dst_st;
    if (stat(dst.c_str(), &dst_st) == 0) {
        if (opts.interactive) {
            if (!ask_overwrite(dst)) return false;
        }
    }

    int fd_in = open(src.c_str(), O_RDONLY);
    if (fd_in < 0) {
        perror(("copy: cannot open '" + src + "'").c_str());
        return false;
    }

    int fd_out = open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC, src_st.st_mode & 0777);
    if (fd_out < 0) {
        perror(("copy: cannot create '" + dst + "'").c_str());
        close(fd_in);
        return false;
    }

    // Data Transfer
    char buffer[BUF_SIZE];
    ssize_t bytes;
    while ((bytes = read(fd_in, buffer, BUF_SIZE)) > 0) {
        if (write(fd_out, buffer, bytes) != bytes) {
            perror(("copy: write error to '" + dst + "'").c_str());
            close(fd_in);
            close(fd_out);
            return false;
        }
    }

    if (opts.preserve) {
        // Preserve Ownership
        fchown(fd_out, src_st.st_uid, src_st.st_gid);
        
        // Preserve Mode (including SUID/SGID) and Timestamps
        // open() only handles basic permissions masked by umask, so we enforce it here
        fchmod(fd_out, src_st.st_mode & 07777);

        struct timespec times[2];
        times[0] = src_st.st_atim; // Access
        times[1] = src_st.st_mtim; // Modification
        futimens(fd_out, times);
    }

    close(fd_in);
    close(fd_out);

    if (opts.verbose) std::cout << "'" << src << "' -> '" << dst << "'" << std::endl;
    return true;
}

// Recursive Directory Copy
bool copy_dir(const std::string& src, const std::string& dst, const CopyOptions& opts, const struct stat& src_st) {
    if (!opts.recursive) {
        std::cerr << "copy: -r not specified; omitting directory '" << src << "'" << std::endl;
        return false;
    }

    // Create Dest Dir
    if (mkdir(dst.c_str(), src_st.st_mode & 0777) != 0) {
        if (errno != EEXIST) {
            perror(("copy: cannot create directory '" + dst + "'").c_str());
            return false;
        }
    }

    // Iterate
    DIR* dir = opendir(src.c_str());
    if (!dir) {
        perror(("copy: cannot open directory '" + src + "'").c_str());
        return false;
    }

    struct dirent* entry;
    bool success = true;
    while ((entry = readdir(dir)) != NULL) {
        std::string name = entry->d_name;
        if (name == "." || name == "..") continue;

        std::string sub_src = src + "/" + name;
        std::string sub_dst = dst + "/" + name;

        if (!copy_path(sub_src, sub_dst, opts)) success = false;
    }
    closedir(dir);

    if (opts.preserve) {
        // Apply metadata to directory after contents are copied
        chown(dst.c_str(), src_st.st_uid, src_st.st_gid);
        // Timestamps on dirs are tricky because creating files inside updates mtime.
        // We set it last.
        struct timespec times[2];
        times[0] = src_st.st_atim;
        times[1] = src_st.st_mtim;
        utimensat(AT_FDCWD, dst.c_str(), times, 0);
    }

    if (opts.verbose) std::cout << "'" << src << "' -> '" << dst << "'" << std::endl;
    return success;
}

bool copy_path(const std::string& src, const std::string& dst, const CopyOptions& opts) {
    struct stat src_st;
    if (lstat(src.c_str(), &src_st) != 0) {
        perror(("copy: cannot stat '" + src + "'").c_str());
        return false;
    }

    if (S_ISDIR(src_st.st_mode)) {
        return copy_dir(src, dst, opts, src_st);
    } else if (S_ISLNK(src_st.st_mode)) {
        return copy_symlink(src, dst, opts, src_st);
    } else {
        return copy_file(src, dst, opts, src_st);
    }
}

int main(int argc, char* argv[]) {
    CopyOptions opts;
    std::vector<std::string> args;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") {
            std::cout << "Usage: copy [options] <source>... <dest>\n"
                      << "Options:\n"
                      << "  -r, -R    Recursive copy\n"
                      << "  -i        Prompt before overwrite\n"
                      << "  -p        Preserve mode, ownership, timestamps\n"
                      << "  -v        Verbose\n";
            return 0;
        }
        else if (arg == "--version") {
             std::cout << "copy (" << OS_NAME << ") " << OS_VERSION << std::endl;
             return 0;
        }
        else if (arg == "-r" || arg == "-R") opts.recursive = true;
        else if (arg == "-i") opts.interactive = true;
        else if (arg == "-p") opts.preserve = true;
        else if (arg == "-v" || arg == "--verbose") opts.verbose = true;
        else if (arg[0] == '-') {
            // Handle combined args like -rv
            for (size_t j = 1; j < arg.length(); ++j) {
                if (arg[j] == 'r' || arg[j] == 'R') opts.recursive = true;
                else if (arg[j] == 'i') opts.interactive = true;
                else if (arg[j] == 'p') opts.preserve = true;
                else if (arg[j] == 'v') opts.verbose = true;
                else {
                    std::cerr << "copy: invalid option -- '" << arg[j] << "'" << std::endl;
                    return 1;
                }
            }
        }
        else {
            args.push_back(arg);
        }
    }

    if (args.size() < 2) {
        std::cerr << "copy: missing file operand\nTry 'copy --help' for more information.\n";
        return 1;
    }

    std::string dest_path = args.back();
    args.pop_back(); // Remove dest from sources

    // Check if destination is a directory
    struct stat dest_st;
    bool dest_is_dir = (stat(dest_path.c_str(), &dest_st) == 0 && S_ISDIR(dest_st.st_mode));

    if (args.size() > 1 && !dest_is_dir) {
        std::cerr << "copy: target '" << dest_path << "' is not a directory" << std::endl;
        return 1;
    }

    bool success = true;
    for (const auto& src : args) {
        std::string final_dest = dest_path;
        if (dest_is_dir) {
            final_dest += "/" + get_basename(src);
        }
        if (!copy_path(src, final_dest, opts)) success = false;
    }

    return success ? 0 : 1;
}
