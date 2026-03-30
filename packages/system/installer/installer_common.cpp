#include "installer_common.h"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace installer {

const char* C_RESET = "\033[0m";
const char* C_BOLD = "\033[1m";
const char* C_RED = "\033[31m";
const char* C_GREEN = "\033[32m";
const char* C_YELLOW = "\033[33m";
const char* C_BLUE = "\033[34m";
const char* C_CYAN = "\033[36m";
const char* C_WHITE = "\033[37m";
const char* C_BG_BLUE = "\033[44m";

const std::string kTargetRoot = "/mnt/target";
const std::string kLogPath = "/tmp/geminios-installer.log";

bool g_verbose = false;

std::string trim(const std::string& value) {
    size_t start = 0;
    while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start]))) {
        ++start;
    }

    size_t end = value.size();
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1]))) {
        --end;
    }

    return value.substr(start, end - start);
}

std::string to_lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::string to_upper(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::toupper(c));
    });
    return value;
}

std::string format_bytes(uint64_t bytes) {
    static const char* units[] = {"B", "KiB", "MiB", "GiB", "TiB"};
    double value = static_cast<double>(bytes);
    size_t unit = 0;
    while (value >= 1024.0 && unit < 4) {
        value /= 1024.0;
        ++unit;
    }

    std::ostringstream out;
    out << std::fixed << std::setprecision(unit == 0 ? 0 : 1) << value << " " << units[unit];
    return out.str();
}

std::string join_strings(const std::vector<std::string>& items, const std::string& separator) {
    std::ostringstream out;
    for (size_t i = 0; i < items.size(); ++i) {
        if (i > 0) out << separator;
        out << items[i];
    }
    return out.str();
}

void append_log_line(const std::string& line) {
    std::ofstream log(kLogPath, std::ios::app);
    if (!log) return;
    log << line << "\n";
}

std::string timestamp_string() {
    std::time_t now = std::time(nullptr);
    std::tm tm_now;
    localtime_r(&now, &tm_now);
    char buffer[32];
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", &tm_now);
    return buffer;
}

void log_message(const std::string& level, const std::string& message) {
    const std::string line = "[" + timestamp_string() + "] [" + level + "] " + message;
    append_log_line(line);
    if (g_verbose) {
        std::cerr << line << std::endl;
    }
}

void clear_screen() {
    std::cout << "\033[2J\033[1;1H";
}

void print_header(const std::string& title) {
    clear_screen();
    std::cout << C_BG_BLUE << C_WHITE << C_BOLD;
    std::cout << std::left << std::setw(96) << ("  GeminiOS Installer - " + title);
    std::cout << C_RESET << "\n\n";
}

void print_notice(const std::string& prefix, const char* color, const std::string& message) {
    std::cout << color << prefix << C_RESET << " " << message << std::endl;
}

bool file_exists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

bool directory_exists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool path_is_executable(const std::string& path) {
    return access(path.c_str(), X_OK) == 0;
}

bool mkdir_p(const std::string& path, mode_t mode) {
    if (path.empty()) return false;

    std::string current;
    if (path[0] == '/') current = "/";

    std::stringstream ss(path);
    std::string part;
    while (std::getline(ss, part, '/')) {
        if (part.empty()) continue;

        if (!current.empty() && current.back() != '/') current += "/";
        current += part;

        if (mkdir(current.c_str(), mode) != 0 && errno != EEXIST) {
            log_message("ERROR", "mkdir failed for " + current + ": " + std::strerror(errno));
            return false;
        }
    }

    return true;
}

std::string read_file_trimmed(const std::string& path) {
    std::ifstream input(path);
    if (!input) return "";
    std::ostringstream contents;
    contents << input.rdbuf();
    return trim(contents.str());
}

bool write_text_file(const std::string& path, const std::string& contents, mode_t mode) {
    size_t slash = path.find_last_of('/');
    if (slash != std::string::npos && !mkdir_p(path.substr(0, slash))) {
        return false;
    }

    std::ofstream out(path);
    if (!out) {
        log_message("ERROR", "Failed to open " + path + " for writing.");
        return false;
    }

    out << contents;
    out.close();

    if (chmod(path.c_str(), mode) != 0) {
        log_message("WARN", "chmod failed for " + path + ": " + std::strerror(errno));
    }

    return true;
}

bool read_lines(const std::string& path, std::vector<std::string>& lines) {
    lines.clear();
    std::ifstream input(path);
    if (!input) return false;

    std::string line;
    while (std::getline(input, line)) {
        lines.push_back(line);
    }
    return true;
}

bool write_lines(const std::string& path, const std::vector<std::string>& lines, mode_t mode) {
    std::ostringstream out;
    for (const auto& line : lines) {
        out << line << "\n";
    }
    return write_text_file(path, out.str(), mode);
}

std::vector<std::string> split_preserve_empty(const std::string& line, char delimiter) {
    std::vector<std::string> parts;
    std::string current;
    for (char c : line) {
        if (c == delimiter) {
            parts.push_back(current);
            current.clear();
        } else {
            current += c;
        }
    }
    parts.push_back(current);
    return parts;
}

std::string find_executable(const std::string& name) {
    if (name.empty()) return "";
    if (name.find('/') != std::string::npos) {
        return path_is_executable(name) ? name : "";
    }

    static const std::vector<std::string> paths = {
        "/usr/local/sbin",
        "/usr/local/bin",
        "/usr/sbin",
        "/usr/bin",
        "/sbin",
        "/bin"
    };

    for (const auto& prefix : paths) {
        const std::string candidate = prefix + "/" + name;
        if (path_is_executable(candidate)) return candidate;
    }

    return "";
}

std::string quote_arg(const std::string& arg) {
    if (arg.find_first_of(" \t\n\"'") == std::string::npos) return arg;
    std::string out = "'";
    for (char c : arg) {
        if (c == '\'') out += "'\\''";
        else out += c;
    }
    out += "'";
    return out;
}

std::string format_command(const std::string& path, const std::vector<std::string>& args) {
    std::string command = quote_arg(path);
    for (const auto& arg : args) {
        command += " " + quote_arg(arg);
    }
    return command;
}

CommandResult run_command(const std::string& path, const std::vector<std::string>& args, const std::string& stdin_data) {
    if (path.empty()) {
        return {false, -1, "missing executable path"};
    }

    log_message("INFO", "EXEC " + format_command(path, args));

    int stdin_pipe[2] = {-1, -1};
    if (!stdin_data.empty() && pipe(stdin_pipe) != 0) {
        return {false, -1, "failed to create stdin pipe"};
    }

    pid_t pid = fork();
    if (pid < 0) {
        if (stdin_pipe[0] >= 0) {
            close(stdin_pipe[0]);
            close(stdin_pipe[1]);
        }
        return {false, -1, "fork failed"};
    }

    if (pid == 0) {
        if (!stdin_data.empty()) {
            close(stdin_pipe[1]);
            dup2(stdin_pipe[0], STDIN_FILENO);
            close(stdin_pipe[0]);
        }

        int log_fd = open(kLogPath.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log_fd >= 0) {
            dup2(log_fd, STDOUT_FILENO);
            dup2(log_fd, STDERR_FILENO);
            close(log_fd);
        }

        std::vector<char*> exec_args;
        exec_args.push_back(const_cast<char*>(path.c_str()));
        for (const auto& arg : args) {
            exec_args.push_back(const_cast<char*>(arg.c_str()));
        }
        exec_args.push_back(nullptr);

        execv(path.c_str(), exec_args.data());
        std::cerr << "execv failed for " << path << ": " << std::strerror(errno) << std::endl;
        _exit(127);
    }

    if (!stdin_data.empty()) {
        close(stdin_pipe[0]);
        ssize_t remaining = static_cast<ssize_t>(stdin_data.size());
        const char* cursor = stdin_data.data();
        while (remaining > 0) {
            ssize_t written = write(stdin_pipe[1], cursor, static_cast<size_t>(remaining));
            if (written < 0) break;
            remaining -= written;
            cursor += written;
        }
        close(stdin_pipe[1]);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return {false, -1, "waitpid failed"};
    }

    if (WIFEXITED(status)) {
        const int exit_code = WEXITSTATUS(status);
        const bool ok = exit_code == 0;
        if (!ok) {
            log_message("ERROR", "Command failed with exit code " + std::to_string(exit_code) + ". See " + kLogPath);
        }
        return {ok, exit_code, ok ? "" : "exit code " + std::to_string(exit_code)};
    }

    if (WIFSIGNALED(status)) {
        const int sig = WTERMSIG(status);
        log_message("ERROR", "Command terminated by signal " + std::to_string(sig) + ". See " + kLogPath);
        return {false, 128 + sig, "signal " + std::to_string(sig)};
    }

    return {false, -1, "command did not exit cleanly"};
}

CommandResult run_command_capture(const std::string& path, const std::vector<std::string>& args, std::string& output) {
    output.clear();
    if (path.empty()) return {false, -1, "missing executable path"};

    log_message("INFO", "EXEC " + format_command(path, args));

    int out_pipe[2];
    if (pipe(out_pipe) != 0) {
        return {false, -1, "failed to create capture pipe"};
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(out_pipe[0]);
        close(out_pipe[1]);
        return {false, -1, "fork failed"};
    }

    if (pid == 0) {
        close(out_pipe[0]);
        dup2(out_pipe[1], STDOUT_FILENO);
        close(out_pipe[1]);

        int log_fd = open(kLogPath.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log_fd >= 0) {
            dup2(log_fd, STDERR_FILENO);
            close(log_fd);
        }

        std::vector<char*> exec_args;
        exec_args.push_back(const_cast<char*>(path.c_str()));
        for (const auto& arg : args) {
            exec_args.push_back(const_cast<char*>(arg.c_str()));
        }
        exec_args.push_back(nullptr);

        execv(path.c_str(), exec_args.data());
        std::cerr << "execv failed for " << path << ": " << std::strerror(errno) << std::endl;
        _exit(127);
    }

    close(out_pipe[1]);
    char buffer[4096];
    ssize_t read_count = 0;
    while ((read_count = read(out_pipe[0], buffer, sizeof(buffer))) > 0) {
        output.append(buffer, static_cast<size_t>(read_count));
    }
    close(out_pipe[0]);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return {false, -1, "waitpid failed"};
    }

    if (WIFEXITED(status)) {
        const int exit_code = WEXITSTATUS(status);
        return {exit_code == 0, exit_code, exit_code == 0 ? "" : "exit code " + std::to_string(exit_code)};
    }

    if (WIFSIGNALED(status)) {
        return {false, 128 + WTERMSIG(status), "signal " + std::to_string(WTERMSIG(status))};
    }

    return {false, -1, "command did not exit cleanly"};
}

bool prompt_yes_no(const std::string& question, bool default_value) {
    while (true) {
        std::cout << question << (default_value ? " [Y/n]: " : " [y/N]: ");
        std::string input;
        std::getline(std::cin, input);
        input = to_lower(trim(input));
        if (input.empty()) return default_value;
        if (input == "y" || input == "yes") return true;
        if (input == "n" || input == "no") return false;
        print_notice("!", C_YELLOW, "Enter yes or no.");
    }
}

std::string prompt_text(const std::string& question, const std::string& default_value, bool allow_empty) {
    while (true) {
        std::cout << question;
        if (!default_value.empty()) std::cout << " [" << default_value << "]";
        std::cout << ": ";

        std::string input;
        std::getline(std::cin, input);
        input = trim(input);
        if (input.empty()) {
            if (!default_value.empty()) return default_value;
            if (allow_empty) return "";
        } else {
            return input;
        }

        print_notice("!", C_YELLOW, "A value is required.");
    }
}

bool parse_int(const std::string& value, int& out_value) {
    if (value.empty()) return false;
    char* end_ptr = nullptr;
    long parsed = std::strtol(value.c_str(), &end_ptr, 10);
    if (!end_ptr || *end_ptr != '\0') return false;
    if (parsed < INT32_MIN || parsed > INT32_MAX) return false;
    out_value = static_cast<int>(parsed);
    return true;
}

int prompt_choice(const std::string& title, const std::vector<std::string>& options, int default_index) {
    while (true) {
        std::cout << title << "\n";
        for (size_t i = 0; i < options.size(); ++i) {
            std::cout << "  " << (i + 1) << ". " << options[i];
            if (static_cast<int>(i) == default_index) std::cout << " " << C_CYAN << "(default)" << C_RESET;
            std::cout << "\n";
        }
        std::cout << "Choice [" << (default_index + 1) << "]: ";

        std::string input;
        std::getline(std::cin, input);
        input = trim(input);
        if (input.empty()) return default_index;

        int parsed = 0;
        if (!parse_int(input, parsed) || parsed < 1 || parsed > static_cast<int>(options.size())) {
            print_notice("!", C_YELLOW, "Enter a valid menu number.");
            continue;
        }
        return parsed - 1;
    }
}

std::string partition_mode_label(PartitionMode mode) {
    return mode == PartitionMode::AutoWipe ? "Auto wipe and partition" : "Use existing partitions";
}

std::string boot_mode_label(BootMode mode) {
    switch (mode) {
        case BootMode::Auto: return "Auto detect";
        case BootMode::Bios: return "BIOS / Legacy";
        case BootMode::Uefi: return "UEFI";
    }
    return "Unknown";
}

std::string filesystem_label(FilesystemType type) {
    switch (type) {
        case FilesystemType::Ext4: return "ext4";
        case FilesystemType::Xfs: return "xfs";
        case FilesystemType::Btrfs: return "btrfs";
    }
    return "unknown";
}

std::string bootloader_label(BootloaderChoice choice) {
    return choice == BootloaderChoice::Grub ? "GRUB" : "None";
}

std::string profile_label(InstallProfile profile) {
    switch (profile) {
        case InstallProfile::Minimal: return "Minimal";
        case InstallProfile::Desktop: return "Desktop";
        case InstallProfile::Developer: return "Developer";
    }
    return "Unknown";
}

BootMode detect_live_boot_mode() {
    return directory_exists("/sys/firmware/efi") ? BootMode::Uefi : BootMode::Bios;
}

BootMode effective_boot_mode(const InstallerConfig& config) {
    return config.boot_mode == BootMode::Auto ? detect_live_boot_mode() : config.boot_mode;
}

std::string root_disk_name_from_live_system() {
    std::ifstream mounts("/proc/mounts");
    std::string line;
    while (std::getline(mounts, line)) {
        std::istringstream row(line);
        std::string source;
        std::string mountpoint;
        row >> source >> mountpoint;
        if (mountpoint != "/") continue;
        if (source.find("/dev/") != 0) return "";

        std::string device = source.substr(5);
        if (device.rfind("nvme", 0) == 0 || device.rfind("mmcblk", 0) == 0) {
            size_t pos = device.rfind('p');
            if (pos != std::string::npos) device = device.substr(0, pos);
        } else {
            while (!device.empty() && std::isdigit(static_cast<unsigned char>(device.back()))) {
                device.pop_back();
            }
        }
        return device;
    }
    return "";
}

std::vector<DiskInfo> list_disks() {
    std::vector<DiskInfo> disks;
    const std::string current_root_disk = root_disk_name_from_live_system();

    DIR* dir = opendir("/sys/block");
    if (!dir) return disks;

    struct dirent* entry = nullptr;
    while ((entry = readdir(dir)) != nullptr) {
        const std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        if (name.rfind("loop", 0) == 0 || name.rfind("ram", 0) == 0 || name.rfind("sr", 0) == 0) continue;

        DiskInfo info;
        info.name = name;
        info.path = "/dev/" + name;
        info.model = trim(read_file_trimmed("/sys/block/" + name + "/device/model"));
        if (info.model.empty()) info.model = trim(read_file_trimmed("/sys/block/" + name + "/device/vendor"));
        if (info.model.empty()) info.model = "Unknown model";
        info.removable = read_file_trimmed("/sys/block/" + name + "/removable") == "1";
        const std::string sectors_str = read_file_trimmed("/sys/block/" + name + "/size");
        unsigned long long sectors = 0;
        if (!sectors_str.empty()) {
            sectors = std::strtoull(sectors_str.c_str(), nullptr, 10);
        }
        info.bytes = sectors * 512ULL;
        info.current_system_disk = !current_root_disk.empty() && name == current_root_disk;
        disks.push_back(info);
    }

    closedir(dir);
    std::sort(disks.begin(), disks.end(), [](const DiskInfo& left, const DiskInfo& right) {
        return left.name < right.name;
    });
    return disks;
}

bool valid_hostname(const std::string& hostname) {
    if (hostname.empty() || hostname.size() > 63) return false;
    if (hostname.front() == '-' || hostname.back() == '-') return false;

    for (char c : hostname) {
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-')) {
            return false;
        }
    }
    return true;
}

bool valid_timezone(const std::string& timezone) {
    return file_exists("/usr/share/zoneinfo/" + timezone);
}

std::string filesystem_mkfs_tool(const ToolRegistry& tools, FilesystemType type) {
    switch (type) {
        case FilesystemType::Ext4: return tools.mkfs_ext4;
        case FilesystemType::Xfs: return tools.mkfs_xfs;
        case FilesystemType::Btrfs: return tools.mkfs_btrfs;
    }
    return "";
}

std::string partition_path(const std::string& disk, int partition_number) {
    if (disk.empty()) return "";
    if (std::isdigit(static_cast<unsigned char>(disk.back()))) {
        return disk + "p" + std::to_string(partition_number);
    }
    return disk + std::to_string(partition_number);
}

bool wait_for_path(const std::string& path, int retries, int delay_ms) {
    for (int i = 0; i < retries; ++i) {
        if (file_exists(path)) return true;
        usleep(delay_ms * 1000);
    }
    return false;
}

bool ensure_file_removed(const std::string& path) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) {
        return errno == ENOENT;
    }
    if (unlink(path.c_str()) == 0) return true;
    log_message("WARN", "Failed to remove " + path + ": " + std::strerror(errno));
    return false;
}

bool ensure_symlink(const std::string& target, const std::string& link_path) {
    ensure_file_removed(link_path);
    if (symlink(target.c_str(), link_path.c_str()) != 0) {
        log_message("ERROR", "Failed to create symlink " + link_path + " -> " + target + ": " + std::strerror(errno));
        return false;
    }
    return true;
}

bool mount_device(const std::string& source, const std::string& target, const std::string& fstype, unsigned long flags, const std::string& data) {
    if (!mkdir_p(target)) return false;
    if (mount(source.c_str(), target.c_str(), fstype.c_str(), flags, data.empty() ? nullptr : data.c_str()) != 0) {
        log_message("ERROR", "mount failed for " + source + " on " + target + ": " + std::strerror(errno));
        return false;
    }
    return true;
}

bool unmount_path(const std::string& target) {
    if (umount2(target.c_str(), 0) == 0) return true;
    if (errno == EINVAL || errno == ENOENT) return true;
    log_message("WARN", "umount failed for " + target + ": " + std::strerror(errno));
    return false;
}

void cleanup_install_state(InstallState& state) {
    for (auto it = state.mounted_paths.rbegin(); it != state.mounted_paths.rend(); ++it) {
        unmount_path(*it);
    }
    state.mounted_paths.clear();
}

bool copy_tree(const ToolRegistry& tools, const std::string& source, const std::string& destination_root) {
    if (!file_exists(source)) {
        log_message("WARN", "Skipping missing source path " + source);
        return true;
    }
    CommandResult result = run_command(tools.cp, {"-a", source, destination_root});
    return result.success;
}

std::string capture_blkid_value(const ToolRegistry& tools, const std::string& device, const std::string& key) {
    if (tools.blkid.empty() || device.empty()) return "";

    std::string output;
    CommandResult result = run_command_capture(tools.blkid, {"-s", key, "-o", "value", device}, output);
    if (!result.success) return "";
    return trim(output);
}

bool create_swapfile(const ToolRegistry& tools, const InstallerConfig& config) {
    if (config.swap_mode != SwapMode::Swapfile || config.swap_size_mb <= 0) return true;
    if (config.filesystem == FilesystemType::Btrfs) {
        log_message("ERROR", "Swapfiles on Btrfs are not supported by this installer yet. Use a swap partition instead.");
        return false;
    }

    const std::string swapfile = kTargetRoot + "/swapfile";
    int fd = open(swapfile.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (fd < 0) {
        log_message("ERROR", "Failed to create swapfile: " + std::string(std::strerror(errno)));
        return false;
    }

    const off_t size = static_cast<off_t>(config.swap_size_mb) * 1024 * 1024;
    const int fallocate_result = posix_fallocate(fd, 0, size);
    if (fallocate_result != 0) {
        log_message("ERROR", "Failed to allocate swapfile blocks: " + std::string(std::strerror(fallocate_result)));
        close(fd);
        ensure_file_removed(swapfile);
        return false;
    }

    if (fsync(fd) != 0) {
        log_message("ERROR", "Failed to flush swapfile to disk: " + std::string(std::strerror(errno)));
        close(fd);
        ensure_file_removed(swapfile);
        return false;
    }

    close(fd);

    if (chmod(swapfile.c_str(), 0600) != 0) {
        log_message("WARN", "chmod failed for swapfile: " + std::string(std::strerror(errno)));
    }

    CommandResult result = run_command(tools.mkswap, {"-L", "GeminiSwap", swapfile});
    if (!result.success) {
        ensure_file_removed(swapfile);
        return false;
    }

    return true;
}

ToolRegistry detect_tools() {
    ToolRegistry tools;
    tools.cp = find_executable("cp");
    tools.mount = find_executable("mount");
    tools.unsquashfs = find_executable("unsquashfs");
    tools.sfdisk = find_executable("sfdisk");
    tools.mkfs_ext4 = find_executable("mkfs.ext4");
    tools.mkfs_xfs = find_executable("mkfs.xfs");
    tools.mkfs_btrfs = find_executable("mkfs.btrfs");
    tools.mkfs_vfat = find_executable("mkfs.vfat");
    tools.mkswap = find_executable("mkswap");
    tools.blkid = find_executable("blkid");
    tools.grub_install = find_executable("grub-install");
    tools.udevadm = find_executable("udevadm");
    tools.blockdev = find_executable("blockdev");
    tools.setfiles = find_executable("setfiles");
    return tools;
}

void print_environment_summary(const ToolRegistry& tools) {
    std::cout << C_BOLD << "Installer environment" << C_RESET << "\n";
    std::cout << "  Log file:       " << kLogPath << "\n";
    std::cout << "  Session boot:   " << boot_mode_label(detect_live_boot_mode()) << "\n";
    std::cout << "  mount:          " << (tools.mount.empty() ? "missing" : tools.mount) << "\n";
    std::cout << "  unsquashfs:     " << (tools.unsquashfs.empty() ? "missing" : tools.unsquashfs) << "\n";
    std::cout << "  sfdisk:         " << (tools.sfdisk.empty() ? "missing" : tools.sfdisk) << "\n";
    std::cout << "  GRUB:           " << (tools.grub_install.empty() ? "missing" : tools.grub_install) << "\n";
    std::cout << "  blkid:          " << (tools.blkid.empty() ? "missing" : tools.blkid) << "\n";
    std::cout << "  setfiles:       " << (tools.setfiles.empty() ? "missing" : tools.setfiles) << "\n";
    std::cout << "  ext4 support:   " << (tools.mkfs_ext4.empty() ? "missing" : "available") << "\n";
    std::cout << "  xfs support:    " << (tools.mkfs_xfs.empty() ? "missing" : "available") << "\n";
    std::cout << "  btrfs support:  " << (tools.mkfs_btrfs.empty() ? "missing" : "available") << "\n";
    std::cout << "  vfat support:   " << (tools.mkfs_vfat.empty() ? "missing" : "available") << "\n";
}

}  // namespace installer
