#include "../../../src/network.h"
#include "../../../src/debug.h"
#include "../../../src/signals.h"
#include <iostream>
#include <vector>
#include <string>
#include <fstream>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstring>
#include <algorithm>
#include <csignal>
#include <sstream>
#include <regex>
#include "../../../src/sys_info.h" //

void sig_handler(int) { g_stop_sig = 1; }

// Configuration
const std::string REPO_PATH = "/var/repo/";
const std::string INSTALL_PATH = "/bin/apps/";
const std::string SYSTEM_PATH = "/bin/apps/system/";
const std::string EXTENSION = ".gpkg";
const char MAGIC_HEADER[4] = {'G', 'P', 'K', 'G'};
const std::string CDN_BASE = "https://cdn.rx580iloveyou.qzz.io/geminios/";
const std::string INDEX_FILE = "packages.txt"; // Simple text file with one package name per line

void print_help(const std::string& cmd = "") {
    if (cmd.empty()) {
        std::cout << "Usage: gpkg <command> [args]\n"
                  << "Gemini Package Manager " << OS_VERSION << "\n\n"
                  << "Commands:\n"
                  << "  install <pkg>   Download and install a package\n"
                  << "  remove <pkg>    Remove an installed package\n"
                  << "  list            List downloaded packages\n"
                  << "  download <pkg>  Download without installing\n"
                  << "  search <query>  Search online repository (supports regex)\n"
                  << "  update          Update package index\n"
                  << "  clean           Remove downloaded .gpkg files\n"
                  << "  help [cmd]      Show help for command\n";
    } else if (cmd == "install") {
        std::cout << "Usage: gpkg install <package>\n\nDownloads the package from the remote repository (if not found locally) and installs it to /bin/apps/.\n";
    } else if (cmd == "remove") {
        std::cout << "Usage: gpkg remove <package>\n\nRemoves an installed package from the system.\n";
    } else if (cmd == "search") {
        std::cout << "Usage: gpkg search <query>\n\nSearches the online repository index for packages matching the provided RegEx query.\nExample: gpkg search ^gem.*\n";
    } else if (cmd == "clean") {
        std::cout << "Usage: gpkg clean\n\nRemoves all cached .gpkg files from " << REPO_PATH << " to save space.\n";
    } else {
        std::cout << "Unknown help topic: " << cmd << std::endl;
    }
}

int main(int argc, char* argv[]) {
    signal(SIGINT, sig_handler);
    
    std::vector<std::string> args(argv, argv + argc);
    if (args.size() < 2) {
        print_help();
        return 1;
    }

    std::string action = args[1];
    bool verbose = false;
    
    // Scan for verbose flag
    for (const auto& arg : args) {
        if (arg == "-v" || arg == "--verbose") verbose = true;
    }

    // Enforce Root for system modifications
    if (action == "install" || action == "remove" || action == "clean" || action == "download" || action == "update") {
        if (geteuid() != 0) {
            std::cerr << "[ERR] Permission denied. You must run '" << action << "' as root (use sudo)." << std::endl;
            return 1;
        }
    }

    if (action == "help") {
        if (args.size() > 2) print_help(args[2]);
        else print_help();
    }
    else if (action == "list") {
        std::cout << "Available packages (.gpkg) in " << REPO_PATH << ":" << std::endl;
        DIR* dir = opendir(REPO_PATH.c_str());
        if (dir) {
            struct dirent* entry;
            while ((entry = readdir(dir)) != NULL) {
                std::string name = entry->d_name;
                if (name.length() > EXTENSION.length() && 
                    name.substr(name.length() - EXTENSION.length()) == EXTENSION) {
                    std::cout << " - " << name << std::endl;
                }
            }
            closedir(dir);
        } else {
            perror("[ERR] Failed to open repo directory");
        }
    }
    else if (action == "install" && args.size() > 2) {
        std::string pkg_name = args[2];
        std::string src_path = REPO_PATH + pkg_name + EXTENSION;
        // Install to /bin/apps/ by default for user packages
        std::string dest_path = INSTALL_PATH + pkg_name;

        // Auto-download if not found locally
        if (access(src_path.c_str(), F_OK) != 0) {
            std::cout << "[GPKG] '" << pkg_name << "' not found locally. Attempting to download..." << std::endl;
            std::string url = CDN_BASE + pkg_name + EXTENSION;
            if (!DownloadFile(url, src_path, verbose)) {
                std::cerr << "[ERR] Package download failed. Installation aborted." << std::endl;
                return 1;
            }
        }

        std::ifstream src(src_path, std::ios::binary);
        if (!src) {
            std::cerr << "[ERR] Failed to open package: " << src_path << std::endl;
            return 1;
        }

        char header[4];
        src.read(header, 4);
        if (src.gcount() < 4 || memcmp(header, MAGIC_HEADER, 4) != 0) {
             std::cerr << "[ERR] Invalid package format. Missing 'GPKG' magic header." << std::endl;
             src.close();
             return 1;
        }

        std::cout << "Installing " << pkg_name << " to " << dest_path << "..." << std::endl;

        std::ofstream dst(dest_path, std::ios::binary);
        if (!dst) {
            std::cerr << "[ERR] Failed to write to " << dest_path << std::endl;
            return 1;
        }

        dst << src.rdbuf(); 
        src.close();
        dst.close();

        if (chmod(dest_path.c_str(), 0755) != 0) {
             perror("[ERR] chmod failed");
        }

        std::cout << "[SUCCESS] Installed " << pkg_name << "." << std::endl;
    }
    else if (action == "remove" && args.size() > 2) {
        std::string pkg_name = args[2];
        // Check both locations
        std::string target = INSTALL_PATH + pkg_name;
        if (access(target.c_str(), F_OK) != 0) {
            target = SYSTEM_PATH + pkg_name;
            if (access(target.c_str(), F_OK) != 0) {
                std::cerr << "[ERR] Package not found: " << pkg_name << std::endl;
                return 1;
            }
             std::cout << "[WARN] Removing system package: " << target << std::endl;
        }

        if (remove(target.c_str()) == 0) {
            std::cout << "[SUCCESS] Removed " << pkg_name << std::endl;
        } else {
            perror("[ERR] remove");
        }
    }
    else if (action == "download" && args.size() > 2) {
        std::string pkg_name = args[2];
        std::string url = CDN_BASE + pkg_name + EXTENSION;
        std::string dest = REPO_PATH + pkg_name + EXTENSION;

        std::cout << "[GPKG] Downloading " << pkg_name << " from " << url << "..." << std::endl;
        
        if (DownloadFile(url, dest, verbose)) {
            std::cout << "[SUCCESS] Downloaded to " << dest << ". Run 'gpkg install " << pkg_name << "' to install." << std::endl;
        } else {
            std::cout << "[ERR] Download failed." << std::endl;
        }
    }
    else if (action == "clean") {
        std::cout << "[GPKG] Cleaning " << REPO_PATH << "..." << std::endl;
        DIR* dir = opendir(REPO_PATH.c_str());
        int count = 0;
        if (dir) {
            struct dirent* entry;
            while ((entry = readdir(dir)) != NULL) {
                std::string name = entry->d_name;
                if (name.length() > EXTENSION.length() && 
                    name.substr(name.length() - EXTENSION.length()) == EXTENSION) {
                    std::string path = REPO_PATH + name;
                    if (remove(path.c_str()) == 0) {
                        count++;
                    } else {
                        perror(("Failed to remove " + name).c_str());
                    }
                }
            }
            closedir(dir);
            std::cout << "[SUCCESS] Removed " << count << " package files." << std::endl;
        } else {
            perror("opendir");
        }
    }
    else if (action == "search" && args.size() > 2) {
        std::string query = args[2];
        std::cout << "[GPKG] Fetching package index..." << std::endl;
        
        std::stringstream ss;
        HttpOptions opts;
        opts.verbose = verbose;
        
        if (HttpRequest(CDN_BASE + INDEX_FILE, ss, opts)) {
            std::string line;
            std::regex pattern(query, std::regex_constants::icase);
            bool found = false;
            
            std::cout << "Search results for '" << query << "':" << std::endl;
            while (std::getline(ss, line)) {
                if (line.empty()) continue;
                if (std::regex_search(line, pattern)) {
                    std::cout << " - " << line << std::endl;
                    found = true;
                }
            }
            if (!found) std::cout << "No matching packages found." << std::endl;
        } else {
            std::cerr << "[ERR] Failed to retrieve package index from server." << std::endl;
        }
    }
    else if (action == "update") {
        std::cout << "[GPKG] Updating package index..." << std::endl;
        std::string url = CDN_BASE + INDEX_FILE;
        std::string dest = REPO_PATH + INDEX_FILE;
        
        if (DownloadFile(url, dest, verbose)) {
            std::cout << "[SUCCESS] Package index updated." << std::endl;
        } else {
            std::cerr << "[ERR] Failed to update package index." << std::endl;
        }
    }
    else {
        std::cout << "Invalid gpkg command." << std::endl;
        print_help();
    }
    
    return 0;
}
