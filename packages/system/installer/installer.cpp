#include <iostream>
#include <vector>
#include <string>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <dirent.h>
#include <cstring>
#include <algorithm>
#include <iomanip>
#include <cstdlib>
#include <fstream> // stop forggeting this
#include "../../../src/sys_info.h"
#include "../../../src/user_mgmt.h"
#include <sys/wait.h>
#include <cerrno>
#include <ctime>

// Global Configuration
bool g_verbose = false;

// Colors
#define C_RESET   "\033[0m"
#define C_BOLD    "\033[1m"
#define C_RED     "\033[31m"
#define C_GREEN   "\033[32m"
#define C_YELLOW  "\033[33m"
#define C_BLUE    "\033[34m"
#define C_CYAN    "\033[36m"
#define C_WHITE   "\033[37m"
#define C_BG_BLUE "\033[44m"

// MBR Structures
struct PartitionEntry {
    uint8_t status;       // 0x80 = active
    uint8_t chs_start[3];
    uint8_t type;         // 0x83 = Linux
    uint8_t chs_end[3];
    uint32_t lba_start;
    uint32_t sector_count;
} __attribute__((packed));

struct MBR {
    uint8_t bootstrap[446];
    PartitionEntry partitions[4];
    uint16_t signature; // 0xAA55
} __attribute__((packed));

// Helpers
void clear_screen() { std::cout << "\033[2J\033[1;1H"; }

// --- Logging ---
void LOG(const std::string& msg) {
    if (!g_verbose) return;

    // Timestamp
    time_t now = time(0);
    struct tm tstruct;
    char buf[80];
    tstruct = *localtime(&now);
    strftime(buf, sizeof(buf), "%H:%M:%S", &tstruct);
    
    std::cout << "[INSTALLER " << buf << "] " << msg << std::endl;
}

void print_header(const std::string& title) {
    clear_screen();
    std::cout << C_BG_BLUE << C_WHITE << C_BOLD;
    std::cout << std::left << std::setw(80) << ("  GeminiOS Installer - " + title);
    std::cout << C_RESET << "\n\n";
}

// Robust Command Execution (replaces system())
bool RunCommand(const std::string& path, const std::vector<std::string>& args) {
    std::string cmd_str = path;
    for(const auto& a : args) cmd_str += " " + a;
    LOG("EXEC: " + cmd_str);

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return false;
    }
    if (pid == 0) {
        // Child
        std::vector<char*> c_args;
        c_args.push_back(const_cast<char*>(path.c_str()));
        for (const auto& arg : args) c_args.push_back(const_cast<char*>(arg.c_str()));
        c_args.push_back(nullptr);

        execv(path.c_str(), c_args.data());
        // If we get here, it failed
        std::cerr << "Failed to exec: " << path << " (" << strerror(errno) << ")" << std::endl;
        exit(1);
    }

    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        int ret = WEXITSTATUS(status);
        LOG("RET: " + std::to_string(ret));
        return ret == 0;
    }
    return false;
}

// Recursive mkdir (mkdir -p)
bool mkdir_p(const std::string& path) {
    LOG("MKDIR: " + path);
    std::string current;
    for (size_t i = 0; i < path.length(); ++i) {
        if (path[i] == '/') {
            if (!current.empty()) {
                if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) {
                    perror(("mkdir " + current).c_str());
                    return false;
                }
            }
        }
        current += path[i];
    }
    if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) {
        perror(("mkdir " + current).c_str());
        return false;
    }
    return true;
}

bool wait_for_device(const std::string& path) {
    LOG("Waiting for device node: " + path);
    int retries = 10; // 5 seconds
    while (retries > 0) {
        if (access(path.c_str(), F_OK) == 0) return true;
        usleep(500000);
        retries--;
        std::cout << "." << std::flush;
    }
    std::cout << std::endl;
    LOG("Device " + path + " not found.");
    return false;
}

// --- Steps ---

std::string select_disk() {
    print_header("Select Target Disk");
    
    std::vector<std::string> disks;
    DIR* dir = opendir("/sys/block");
    if (dir) {
        struct dirent* ent;
        while ((ent = readdir(dir))) {
            std::string name = ent->d_name;
            // Filter out loop, ram, sr (cdrom)
            if (name.find("loop") == 0 || name.find("ram") == 0 || name.find("sr") == 0) continue;
            disks.push_back(name);
        }
        closedir(dir);
    }
    std::sort(disks.begin(), disks.end());

    if (disks.empty()) {
        std::cout << C_RED << "No suitable disks found!" << C_RESET << std::endl;
        return "";
    }

    std::cout << "Available Disks:\n";
    for (const auto& d : disks) {
        // Get Size
        std::string size_path = "/sys/block/" + d + "/size";
        std::ifstream f(size_path);
        long sectors = 0;
        f >> sectors;
        double gb = (sectors * 512) / (1024.0 * 1024.0 * 1024.0);
        
        std::cout << "  " << C_BOLD << d << C_RESET << "\t" << std::fixed << std::setprecision(1) << gb << " GB" << std::endl;
    }

    std::cout << "\nEnter disk name to install to (e.g. sda): ";
    std::string sel;
    std::cin >> sel;
    
    // Validate
    bool valid = false;
    for (const auto& d : disks) if (d == sel) valid = true;
    
    if (!valid) {
        std::cout << C_RED << "Invalid selection." << C_RESET << std::endl;
        sleep(1);
        return "";
    }
    return "/dev/" + sel;
}

struct InstallConfig {
    std::string device;
    std::string username;
    std::string password;
};

InstallConfig get_config() {
    InstallConfig cfg;
    while (cfg.device.empty()) cfg.device = select_disk();

    print_header("User Configuration");
    std::cout << "Create default user account for the new system.\n\n";
    
    while (cfg.username.empty()) {
        std::cout << "Username: ";
        std::cin >> cfg.username;
    }

    std::cout << "Password: ";
    std::cin >> cfg.password; // Simple cin for now
    
    return cfg;
}

bool partition_disk(const std::string& dev_path) {
    LOG("Partitioning " + dev_path + "...");
    
    int fd = open(dev_path.c_str(), O_RDWR);
    if (fd < 0) { perror("open"); return false; }

    uint64_t size = 0;
    ioctl(fd, BLKGETSIZE64, &size);
    uint32_t total_sectors = size / 512;
    LOG("Disk Size: " + std::to_string(size) + " bytes (" + std::to_string(total_sectors) + " sectors)");

    // Wiping old metadata (MBR, GPT headers at start and end)
    // GRUB fails if it detects conflicting partition tables (e.g. MBR + leftover GPT)
    LOG("Wiping old partition tables...");
    std::vector<char> zero_buf(1024 * 1024, 0); // 1MB buffer
    
    // Wipe Start (First 1MB)
    lseek(fd, 0, SEEK_SET);
    write(fd, zero_buf.data(), zero_buf.size());

    // Wipe End (Last 1MB) - Cleans GPT Backup Header
    if (size > zero_buf.size()) {
        lseek(fd, size - zero_buf.size(), SEEK_SET);
        write(fd, zero_buf.data(), zero_buf.size());
    }
    fsync(fd);

    // Create simple MBR
    MBR mbr;
    memset(&mbr, 0, sizeof(mbr));
    
    // Partition 1: Linux, Active, Start Sector 2048, End at disk end
    mbr.partitions[0].status = 0x80;
    mbr.partitions[0].type = 0x83;
    mbr.partitions[0].lba_start = 2048;
    mbr.partitions[0].sector_count = total_sectors - 2048;
    mbr.signature = 0xAA55;
    LOG("Created Partition Entry: Start=2048, Count=" + std::to_string(mbr.partitions[0].sector_count));

    lseek(fd, 0, SEEK_SET);
    if (write(fd, &mbr, sizeof(mbr)) != 512) {
        perror("write mbr");
        close(fd);
        return false;
    }
    LOG("Written new MBR");

    // Re-read partition table
    if (ioctl(fd, BLKRRPART, NULL) < 0) {
        // This often fails if device is in use, but here it might just be busy.
        // We log but don't strictly fail if we can verify the node later.
        LOG("Warning: BLKRRPART ioctl failed (device busy?).");
    }
    fsync(fd);
    close(fd);
    
    // Wait handled by wait_for_device later
    return true;
}

int main(int argc, char* argv[]) {
    // Argument Parsing
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--verbose" || arg == "-v") {
            g_verbose = true;
        }
    }

    print_header("Welcome");
    std::cout << "Welcome to the " << OS_NAME << " Installer.\n";
    std::cout << "This wizard will install the OS to your hard disk.\n\n";
    std::cout << C_YELLOW << "WARNING: ALL DATA ON TARGET DISK WILL BE ERASED!" << C_RESET << "\n\n";
    std::cout << "Press ENTER to continue or Ctrl+C to abort.";
    std::cin.ignore();
    std::cin.get();

    InstallConfig cfg = get_config();

    print_header("Confirmation");
    std::cout << "Target: " << C_RED << cfg.device << C_RESET << "\n";
    std::cout << "User:   " << C_GREEN << cfg.username << C_RESET << "\n\n";
    std::cout << "Are you sure you want to install? Type 'YES' to confirm: ";
    std::string confirm;
    std::cin >> confirm;

    if (confirm != "YES") {
        std::cout << "Aborted.\n";
        return 1;
    }

    print_header("Installing...");

    // 1. Partition
    if (!partition_disk(cfg.device)) return 1;
    
    std::string part_dev = cfg.device;
    // Check if device ends in digit (nvme0n1 -> nvme0n1p1, sda -> sda1)
    if (isdigit(part_dev.back())) part_dev += "p1";
    else part_dev += "1";

    LOG("Target Partition: " + part_dev);
    
    if (!wait_for_device(part_dev)) {
        std::cerr << "Partition device node failed to appear.\n";
        return 1;
    }

    // 2. Format
    std::cout << "[1/5] Formatting (Ext2)...\n";
    // Execute mkfs directly
    std::vector<std::string> mkfs_args = {"-L", "GeminiRoot", part_dev};
    if (g_verbose) mkfs_args.insert(mkfs_args.begin(), "-v");
    else mkfs_args.insert(mkfs_args.begin(), ""); 

    if (!RunCommand("/bin/apps/system/mkfs", mkfs_args)) {
        std::cerr << "Format failed.\n";
        return 1;
    }

    // 3. Mount
    std::cout << "[2/5] Mounting...\n";
    mkdir_p("/mnt/target");
    // Run mount tool
    if (!RunCommand("/bin/apps/system/mount", {"-t", "ext2", part_dev, "/mnt/target"})) {
        std::cerr << "Mount failed.\n";
        return 1;
    }

    // 4. Copy System
    std::cout << "[3/5] Copying System Files...\n";
    
    // Create directory structure
    mkdir_p("/mnt/target/bin/apps/system");
    mkdir_p("/mnt/target/etc");
    mkdir_p("/mnt/target/var/repo");
    mkdir_p("/mnt/target/boot/grub");
    mkdir_p("/mnt/target/dev");
    mkdir_p("/mnt/target/proc");
    mkdir_p("/mnt/target/sys");
    mkdir_p("/mnt/target/tmp");
    mkdir_p("/mnt/target/mnt");
    mkdir_p("/mnt/target/home");
    mkdir_p("/mnt/target/root");

    // Copy Files
    // Note: wildcards (*) won't work without a shell. 
    // We use recursive copy on the parent directories.
    // 'copy -r /source /dest' -> copies contents of source into dest if dest exists?
    // Our copy tool: copies 'source' directory INTO 'dest' if dest is a dir.
    
    RunCommand("/bin/apps/system/copy", {"-r", "-p", "/bin/apps", "/mnt/target/bin/"});
    RunCommand("/bin/apps/system/copy", {"-p", "/bin/init", "/mnt/target/bin/"});
    
    // Copy Bash and Sh
    RunCommand("/bin/apps/system/copy", {"-p", "/bin/bash", "/mnt/target/bin/"});
    RunCommand("/bin/apps/system/copy", {"-p", "/bin/sh", "/mnt/target/bin/"});
    RunCommand("/bin/apps/system/copy", {"-p", "/bin/nano", "/mnt/target/bin/"});
    RunCommand("/bin/apps/system/copy", {"-p", "/bin/grep", "/mnt/target/bin/"});
    RunCommand("/bin/apps/system/copy", {"-p", "/bin/sed", "/mnt/target/bin/"});
    RunCommand("/bin/apps/system/copy", {"-p", "/bin/gawk", "/mnt/target/bin/"});
    RunCommand("/bin/apps/system/copy", {"-p", "/bin/awk", "/mnt/target/bin/"});

    // For /etc and /boot, we want to copy contents. 
    // copy -r /etc /mnt/target/ -> creates /mnt/target/etc filled with content.
    RunCommand("/bin/apps/system/copy", {"-r", "-p", "/etc", "/mnt/target/"});
    RunCommand("/bin/apps/system/copy", {"-r", "-p", "/boot", "/mnt/target/"});
    
    // Copy Terminfo (Required for Nano)
    // We need to create /usr/share structure on target
    mkdir_p("/mnt/target/usr/share");
    RunCommand("/bin/apps/system/copy", {"-r", "-p", "/usr/share/terminfo", "/mnt/target/usr/share/"});
    // 5. Configure
    std::cout << "[4/5] Configuring User...\n";
    
    // Load existing users (likely default gemini) to get structure, but we want a fresh start usually.
    // We will create a new user list file in the target.
    
    std::vector<User> new_users;
    // Root
    User root;
    root.username = "root";
    root.uid = 0; root.gid = 0;
    root.home = "/root"; root.shell = "/bin/init";
    root.password = UserMgmt::hash_password(cfg.password); // Root gets same pass? Or ask? Let's give same.
    new_users.push_back(root);

    // New User
    User u;
    u.username = cfg.username;
    u.uid = 1000; u.gid = 1000;
    u.home = "/home/" + cfg.username;
    u.shell = "/bin/init";
    u.password = UserMgmt::hash_password(cfg.password);
    new_users.push_back(u);

    // Groups
    std::vector<Group> new_groups;
    
    Group g_root;
    g_root.name = "root"; g_root.password = "x"; g_root.gid = 0; g_root.members = {"root"};

    Group g_sudo;
    g_sudo.name = "sudo"; g_sudo.password = "x"; g_sudo.gid = 27; g_sudo.members = {"root", cfg.username};

    Group g_user;
    g_user.name = cfg.username; g_user.password = "x"; g_user.gid = 1000; g_user.members = {cfg.username};

    new_groups.push_back(g_root);
    new_groups.push_back(g_sudo);
    new_groups.push_back(g_user);

    // Write /etc/passwd
    
    std::ofstream passwd("/mnt/target/etc/passwd");
    for(auto& usr : new_users) {
        passwd << usr.username << ":x:" << usr.uid << ":" << usr.gid << "::" << usr.home << ":" << usr.shell << "\n";
    }
    passwd.close();

    std::ofstream shadow("/mnt/target/etc/shadow");
    long now = time(0) / 86400;
    for(auto& usr : new_users) {
        shadow << usr.username << ":" << usr.password << ":" << now << ":0:99999:7:::\n";
    }
    shadow.close();
    chmod("/mnt/target/etc/shadow", 0600);

    std::ofstream group("/mnt/target/etc/group");
    for(auto& grp : new_groups) {
        group << grp.name << ":x:" << grp.gid << ":";
        for(size_t i = 0; i < grp.members.size(); ++i) {
            group << grp.members[i] << (i == grp.members.size() - 1 ? "" : ",");
        }
        group << "\n";
    }
    group.close();

    // Create Home Dir
    mkdir(("/mnt/target/home/" + cfg.username).c_str(), 0700);
    if (chown(("/mnt/target/home/" + cfg.username).c_str(), 1000, 1000) != 0) {
        perror("chown home");
    }

    // 6. Bootloader
    std::cout << "[5/5] Setting up Bootloader...\n";
    // Warning: We cannot install GRUB to MBR without grub binaries.
    // Create a default grub.cfg just in case
    std::ofstream grub("/mnt/target/boot/grub/grub.cfg");
    if (grub) {
        grub << "set timeout=5\nset default=0\n";
        grub << "menuentry \"GeminiOS (HD)\" {\n";
        grub << "  linux /boot/kernel root=" << part_dev << " rw quiet\n";
        grub << "}\n";
        grub.close();
    }

    // Check if we have the tools to install GRUB
    if (access("/bin/grub-install", X_OK) == 0) {
        LOG("Found grub-install, attempting automatic installation...");
        std::cout << "Installing GRUB to " << cfg.device << "...\n";
        
        // Command: grub-install --target=i386-pc --boot-directory=/mnt/target/boot /dev/sda
        if (RunCommand("/bin/grub-install", {"--target=i386-pc", "--boot-directory=/mnt/target/boot", "--directory=/usr/lib/grub/i386-pc", "--force", cfg.device})) {
            std::cout << C_GREEN << "GRUB installed successfully!" << C_RESET << "\n";
        } else {
            std::cerr << C_RED << "GRUB installation failed." << C_RESET << "\n";
        }
    } else {
        std::cout << C_YELLOW << "\n[NOTE] Bootloader (GRUB) installation skipped (tool missing).\n";
        std::cout << "The filesystem is ready, but the disk is not bootable yet.\n";
        std::cout << "You need to install GRUB to the MBR manually using a live USB tool.\n" << C_RESET;
    }
    
    std::cout << "\nInstallation Complete!\n";
    std::cout << "Press ENTER to reboot.";
    std::cin.ignore();
    std::cin.get();

    reboot(RB_AUTOBOOT);
    return 0;
}
