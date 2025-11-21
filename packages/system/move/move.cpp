#include <iostream>
#include <vector>
#include <string>
#include <unistd.h>
#include <sys/stat.h>
#include <cstdio>
#include <cerrno>
#include <cstdlib>
#include "../../../src/sys_info.h"

struct MoveOptions {
    bool interactive = false;
    bool verbose = false;
};

// Helper to get filename from path
std::string get_basename(const std::string& path) {
    size_t pos = path.find_last_of('/');
    if (pos == std::string::npos) return path;
    return path.substr(pos + 1);
}

bool ask_overwrite(const std::string& path) {
    std::cerr << "move: overwrite '" << path << "'? (y/n) ";
    char c;
    std::cin >> c;
    return (c == 'y' || c == 'Y');
}

bool move_path(const std::string& src, const std::string& dst, const MoveOptions& opts) {
    // Check destination existence for interactive mode
    struct stat dst_st;
    if (lstat(dst.c_str(), &dst_st) == 0) {
        if (opts.interactive) {
            if (!ask_overwrite(dst)) return false;
        }
        // Cannot overwrite dir with file or vice versa easily, let rename() handle errors or warn
    }

    if (rename(src.c_str(), dst.c_str()) == 0) {
        if (opts.verbose) std::cout << "'" << src << "' -> '" << dst << "'" << std::endl;
        return true;
    } else {
        if (errno == EXDEV) {
            // Cross-device link: we need to copy and remove
            // Since we don't want to duplicate the entire Copy logic here,
            // we will call the system 'copy' command and then 'rm'.
            // This relies on 'copy' being installed.
            
            if (opts.verbose) std::cout << "move: cross-device move, falling back to copy+rm" << std::endl;
            
            std::string cmd_cp = "/bin/apps/system/copy -r -p " + src + " " + dst;
            if (opts.verbose) cmd_cp += " -v";
            
            int ret = system(cmd_cp.c_str());
            if (ret == 0) {
                std::string cmd_rm = "/bin/apps/system/rm -r " + src;
                system(cmd_rm.c_str());
                return true;
            } else {
                std::cerr << "move: failed to copy '" << src << "' to '" << dst << "'" << std::endl;
                return false;
            }
        } else {
            perror(("move: cannot move '" + src + "' to '" + dst + "'").c_str());
            return false;
        }
    }
}

int main(int argc, char* argv[]) {
    MoveOptions opts;
    std::vector<std::string> args;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") {
            std::cout << "Usage: move [options] <source>... <dest>\n"
                      << "Options:\n"
                      << "  -i    Prompt before overwrite\n"
                      << "  -v    Verbose\n";
            return 0;
        }
        else if (arg == "--version") {
             std::cout << "move (" << OS_NAME << ") " << OS_VERSION << std::endl;
             return 0;
        }
        else if (arg == "-i") opts.interactive = true;
        else if (arg == "-v") opts.verbose = true;
        else if (arg[0] == '-') {
            for (size_t j = 1; j < arg.length(); ++j) {
                if (arg[j] == 'i') opts.interactive = true;
                else if (arg[j] == 'v') opts.verbose = true;
                else {
                    std::cerr << "move: invalid option -- '" << arg[j] << "'" << std::endl;
                    return 1;
                }
            }
        }
        else {
            args.push_back(arg);
        }
    }

    if (args.size() < 2) {
        std::cerr << "move: missing file operand\nTry 'move --help' for more information.\n";
        return 1;
    }

    std::string dest_path = args.back();
    args.pop_back();

    struct stat dest_st;
    bool dest_is_dir = (stat(dest_path.c_str(), &dest_st) == 0 && S_ISDIR(dest_st.st_mode));

    if (args.size() > 1 && !dest_is_dir) {
        std::cerr << "move: target '" << dest_path << "' is not a directory" << std::endl;
        return 1;
    }

    bool success = true;
    for (const auto& src : args) {
        std::string final_dest = dest_path;
        if (dest_is_dir) {
            final_dest += "/" + get_basename(src);
        }
        if (!move_path(src, final_dest, opts)) success = false;
    }

    return success ? 0 : 1;
}
