#ifndef GEMINIOS_INSTALLER_COMMON_H
#define GEMINIOS_INSTALLER_COMMON_H

#include <stdint.h>
#include <sys/types.h>

#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace installer {

extern const char* C_RESET;
extern const char* C_BOLD;
extern const char* C_RED;
extern const char* C_GREEN;
extern const char* C_YELLOW;
extern const char* C_BLUE;
extern const char* C_CYAN;
extern const char* C_WHITE;
extern const char* C_BG_BLUE;

extern const std::string kTargetRoot;
extern const std::string kLogPath;

extern bool g_verbose;

enum class PartitionMode {
    AutoWipe,
    Existing
};

enum class BootMode {
    Auto,
    Bios,
    Uefi
};

enum class FilesystemType {
    Ext4,
    Xfs,
    Btrfs,
    F2fs
};

enum class SwapMode {
    None,
    Swapfile,
    Partition
};

enum class BootloaderChoice {
    Grub,
    None
};

enum class InstallProfile {
    Minimal,
    Desktop,
    Developer
};

struct DiskInfo {
    std::string name;
    std::string path;
    std::string model;
    uint64_t bytes = 0;
    bool removable = false;
    bool current_system_disk = false;
};

struct UserConfig {
    bool create = true;
    std::string username = "gemini";
    std::string password;
    bool sudo = true;
    bool autologin = false;
};

struct InstallerConfig {
    PartitionMode partition_mode = PartitionMode::AutoWipe;
    BootMode boot_mode = BootMode::Auto;
    FilesystemType filesystem = FilesystemType::Ext4;
    SwapMode swap_mode = SwapMode::Swapfile;
    BootloaderChoice bootloader = BootloaderChoice::Grub;
    InstallProfile profile = InstallProfile::Desktop;

    std::string disk;
    std::string root_partition;
    bool format_root = true;
    std::string efi_partition;
    bool format_efi = true;
    std::string swap_partition;
    int swap_size_mb = 2048;

    std::string hostname = "geminios-pc";
    std::string timezone = "UTC";
    std::string locale = "en_US.UTF-8";
    std::string keyboard_layout = "us";
    std::string root_password;
    UserConfig user;
};

struct ToolRegistry {
    std::string cp;
    std::string mount;
    std::string unsquashfs;
    std::string sfdisk;
    std::string mkfs_ext4;
    std::string mkfs_xfs;
    std::string mkfs_btrfs;
    std::string mkfs_f2fs;
    std::string mkfs_vfat;
    std::string mkswap;
    std::string blkid;
    std::string grub_install;
    std::string udevadm;
    std::string blockdev;
    std::string setfiles;
};

struct CommandResult {
    bool success = false;
    int exit_code = -1;
    std::string message;
};

struct InstallArtifacts {
    std::string root_partition;
    std::string efi_partition;
    std::string swap_partition;
    std::string root_uuid;
    std::string root_partuuid;
    std::string efi_uuid;
    std::string swap_uuid;
};

struct InstallState {
    std::vector<std::string> mounted_paths;
};

std::string trim(const std::string& value);
std::string to_lower(std::string value);
std::string to_upper(std::string value);
std::string format_bytes(uint64_t bytes);
std::string join_strings(const std::vector<std::string>& items, const std::string& separator = ", ");
void append_log_line(const std::string& line);
std::string timestamp_string();
void log_message(const std::string& level, const std::string& message);
void clear_screen();
void print_header(const std::string& title);
void print_notice(const std::string& prefix, const char* color, const std::string& message);
bool file_exists(const std::string& path);
bool directory_exists(const std::string& path);
bool path_is_executable(const std::string& path);
bool mkdir_p(const std::string& path, mode_t mode = 0755);
std::string read_file_trimmed(const std::string& path);
bool write_text_file(const std::string& path, const std::string& contents, mode_t mode = 0644);
bool read_lines(const std::string& path, std::vector<std::string>& lines);
bool write_lines(const std::string& path, const std::vector<std::string>& lines, mode_t mode = 0644);
std::vector<std::string> split_preserve_empty(const std::string& line, char delimiter);
std::string find_executable(const std::string& name);
std::string quote_arg(const std::string& arg);
std::string format_command(const std::string& path, const std::vector<std::string>& args);
CommandResult run_command(const std::string& path, const std::vector<std::string>& args = {}, const std::string& stdin_data = "");
CommandResult run_command_capture(const std::string& path, const std::vector<std::string>& args, std::string& output);
bool prompt_yes_no(const std::string& question, bool default_value);
std::string prompt_text(const std::string& question, const std::string& default_value = "", bool allow_empty = false);
bool parse_int(const std::string& value, int& out_value);
int prompt_choice(const std::string& title, const std::vector<std::string>& options, int default_index = 0);
int prompt_choice(
    const std::string& title,
    const std::vector<std::string>& options,
    int default_index,
    const std::vector<std::pair<std::string, int>>& aliases,
    const std::function<void()>& redraw
);
std::string partition_mode_label(PartitionMode mode);
std::string boot_mode_label(BootMode mode);
std::string filesystem_label(FilesystemType type);
std::string filesystem_grub_module(FilesystemType type);
std::string bootloader_label(BootloaderChoice choice);
std::string profile_label(InstallProfile profile);
BootMode detect_live_boot_mode();
BootMode effective_boot_mode(const InstallerConfig& config);
std::string root_disk_name_from_live_system();
std::vector<DiskInfo> list_disks();
bool valid_hostname(const std::string& hostname);
bool valid_timezone(const std::string& timezone);
std::string filesystem_mkfs_tool(const ToolRegistry& tools, FilesystemType type);
std::string partition_path(const std::string& disk, int partition_number);
bool wait_for_path(const std::string& path, int retries = 30, int delay_ms = 250);
bool ensure_file_removed(const std::string& path);
bool ensure_symlink(const std::string& target, const std::string& link_path);
bool mount_device(const std::string& source, const std::string& target, const std::string& fstype, unsigned long flags = 0, const std::string& data = "");
bool unmount_path(const std::string& target);
void cleanup_install_state(InstallState& state);
bool copy_tree(const ToolRegistry& tools, const std::string& source, const std::string& destination_path);
std::string capture_blkid_value(const ToolRegistry& tools, const std::string& device, const std::string& key);
bool create_swapfile(const ToolRegistry& tools, const InstallerConfig& config);
ToolRegistry detect_tools();
void print_environment_summary(const ToolRegistry& tools);

bool configure_installer(InstallerConfig& config, const ToolRegistry& tools);
bool perform_install(const ToolRegistry& tools, const InstallerConfig& config, std::string& error);

}  // namespace installer

#endif
