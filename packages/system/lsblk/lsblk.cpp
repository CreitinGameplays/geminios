#include <iostream>
#include <vector>
#include <string>
#include <fstream>
#include <sstream>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <iomanip>
#include <map>
#include <cstring>
#include <cmath>
#include <cstdint>
#include "../../../src/sys_info.h"

// ANSI Colors
#define CLR_RESET   "\033[0m"
#define CLR_TREE    "\033[90m" // Dark Gray
#define CLR_NAME    "\033[1m"
#define CLR_DEV     "\033[33m" // Yellow/Orange

struct BlockDevice {
    std::string name;       // sda
    std::string kname;      // sda (kernel name)
    std::string type;       // disk, part, rom, loop
    std::string maj_min;    // 8:0
    std::string mountpoint; 
    std::string model;
    uint64_t size;          // in bytes
    bool rm;                // removable
    bool ro;                // read-only
    std::vector<BlockDevice> partitions;
};

bool g_bytes_mode = false;
bool g_all_mode = false; // If false, maybe hide loop? Standard lsblk hides loop unless -a. We'll show all for now or filter empty loops.

// --- Helpers ---

std::string read_sysfs_file(const std::string& path) {
    std::ifstream f(path);
    if (!f) return "";
    std::string line;
    std::getline(f, line);
    // Trim newline
    if (!line.empty() && line.back() == '\n') line.pop_back();
    return line;
}

uint64_t parse_size(const std::string& str) {
    try {
        return std::stoull(str) * 512; // sysfs size is in 512-byte sectors
    } catch (...) {
        return 0;
    }
}

std::string format_size(uint64_t bytes) {
    if (g_bytes_mode) return std::to_string(bytes);
    const char* suffixes[] = {"B", "K", "M", "G", "T", "P"};
    int i = 0;
    double size = bytes;
    while (size >= 1024 && i < 5) {
        size /= 1024;
        i++;
    }
    std::stringstream ss;
    if (i == 0) ss << (int)size << "B";
    else ss << std::fixed << std::setprecision(1) << size << suffixes[i];
    return ss.str();
}

// Load /proc/mounts into a map: device_name -> mountpoint
std::map<std::string, std::string> load_mounts() {
    std::map<std::string, std::string> mounts;
    std::ifstream f("/proc/mounts");
    std::string line;
    while (std::getline(f, line)) {
        std::stringstream ss(line);
        std::string dev, mp;
        ss >> dev >> mp;
        // Dev is usually /dev/sda1. We want just sda1.
        if (dev.find("/dev/") == 0) {
            mounts[dev.substr(5)] = mp;
        } else {
            mounts[dev] = mp; // Fallback
        }
    }
    return mounts;
}

BlockDevice load_device(const std::string& parent_name, const std::string& dev_name, const std::string& base_path, const std::map<std::string, std::string>& mounts) {
    BlockDevice dev;
    dev.name = dev_name;
    dev.kname = dev_name;
    
    std::string sys_path = base_path + "/" + dev_name;

    dev.maj_min = read_sysfs_file(sys_path + "/dev");
    dev.size = parse_size(read_sysfs_file(sys_path + "/size"));
    dev.rm = (read_sysfs_file(sys_path + "/removable") == "1");
    dev.ro = (read_sysfs_file(sys_path + "/ro") == "1");
    
    // Type logic
    if (parent_name.empty()) {
        // It's a parent block device
        // Check if it is loop, sr, etc
        if (dev_name.find("loop") == 0) dev.type = "loop";
        else if (dev_name.find("sr") == 0) dev.type = "rom";
        else if (dev_name.find("ram") == 0) dev.type = "disk"; // ramdisk
        else dev.type = "disk";

        dev.model = read_sysfs_file(sys_path + "/device/model");
        if (dev.model.empty()) dev.model = ""; // Some dont have model
    } else {
        dev.type = "part";
    }

    // Mountpoint
    auto it = mounts.find(dev_name);
    if (it != mounts.end()) dev.mountpoint = it->second;

    return dev;
}

void print_tree_node(const BlockDevice& dev, const std::string& prefix, bool is_last) {
    std::cout << prefix;
    if (prefix.empty()) {
        // Root node
    } else {
        std::cout << CLR_TREE << (is_last ? "`-" : "|-") << CLR_RESET;
    }
    
    // Output Name
    std::cout << CLR_NAME << std::left << std::setw(10) << dev.name << CLR_RESET;

    // Maj:Min
    std::cout << std::left << std::setw(8) << dev.maj_min;

    // RM
    std::cout << std::setw(4) << (dev.rm ? "1" : "0");

    // Size
    std::cout << std::setw(10) << format_size(dev.size);

    // RO
    std::cout << std::setw(4) << (dev.ro ? "1" : "0");

    // Type
    std::cout << std::setw(6) << dev.type;

    // Mountpoint
    if (!dev.mountpoint.empty()) {
        std::cout << dev.mountpoint;
    }
    
    // Model (only for disks usually)
    if (!dev.model.empty()) {
        // If mountpoint printed, add space
        if (!dev.mountpoint.empty()) std::cout << " ";
        // std::cout << "(" << dev.model << ")"; // Optional: Print model
    }

    std::cout << std::endl;

    // Children
    std::string new_prefix = prefix;
    if (!prefix.empty()) {
        new_prefix += (is_last ? "   " : "|  ");
    }

    for (size_t i = 0; i < dev.partitions.size(); ++i) {
        print_tree_node(dev.partitions[i], new_prefix, i == dev.partitions.size() - 1);
    }
}

int main(int argc, char* argv[]) {
    // Argument Parsing
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help") {
            std::cout << "Usage: lsblk [options] [device...]\n"
                      << "List information about block devices.\n\n"
                      << "Options:\n"
                      << "  -a, --all     Print all devices (even empty loops)\n"
                      << "  -b, --bytes   Print SIZE in bytes rather than human readable format\n"
                      << "      --version Output version info\n";
            return 0;
        }
        else if (arg == "--version") {
            std::cout << "lsblk (" << OS_NAME << ") " << OS_VERSION << std::endl;
            return 0;
        }
        else if (arg == "-b" || arg == "--bytes") g_bytes_mode = true;
        else if (arg == "-a" || arg == "--all") g_all_mode = true;
    }

    auto mounts = load_mounts();
    std::vector<BlockDevice> disks;

    DIR* dir = opendir("/sys/block");
    if (!dir) {
        perror("lsblk: cannot open /sys/block");
        return 1;
    }

    struct dirent* entry;
    std::vector<std::string> disk_names;

    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        disk_names.push_back(entry->d_name);
    }
    closedir(dir);

    std::sort(disk_names.begin(), disk_names.end());

    for (const auto& name : disk_names) {
        // If it's a loop device and size is 0 and not -a, skip
        if (!g_all_mode && name.find("loop") == 0) {
             std::string sz = read_sysfs_file("/sys/block/" + name + "/size");
             if (sz == "0") continue;
        }

        BlockDevice disk = load_device("", name, "/sys/block", mounts);

        // Scan for partitions
        // Partitions usually appear as subdirectories in /sys/block/<disk>/<disk><n>
        // e.g. /sys/block/sda/sda1
        
        DIR* disk_dir = opendir(("/sys/block/" + name).c_str());
        if (disk_dir) {
            struct dirent* sub;
            std::vector<std::string> part_names;
            while ((sub = readdir(disk_dir)) != NULL) {
                if (sub->d_name[0] == '.') continue;
                // Check if it starts with disk name (simple heuristic)
                // Also verify it has a 'partition' file inside to be sure
                std::string subname = sub->d_name;
                if (subname.find(name) == 0 && subname != name) {
                     struct stat st;
                     std::string part_flag = "/sys/block/" + name + "/" + subname + "/partition";
                     if (stat(part_flag.c_str(), &st) == 0) {
                         part_names.push_back(subname);
                     }
                }
            }
            closedir(disk_dir);
            std::sort(part_names.begin(), part_names.end());

            for (const auto& pname : part_names) {
                disk.partitions.push_back(load_device(name, pname, "/sys/block/" + name, mounts));
            }
        }

        disks.push_back(disk);
    }

    // Header
    std::cout << std::left << std::setw(10) << "NAME"
              << std::setw(8) << "MAJ:MIN"
              << std::setw(4) << "RM"
              << std::setw(10) << "SIZE"
              << std::setw(4) << "RO"
              << std::setw(6) << "TYPE"
              << "MOUNTPOINT" << std::endl;

    for (const auto& d : disks) {
        print_tree_node(d, "", false);
    }

    return 0;
}
