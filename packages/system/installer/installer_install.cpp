#include "installer_common.h"

#include "user_mgmt.h"

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace installer {

namespace {

std::string kernel_root_argument(const InstallArtifacts& artifacts) {
    if (!artifacts.root_partuuid.empty()) {
        return "PARTUUID=" + artifacts.root_partuuid;
    }
    if (!artifacts.root_partition.empty()) {
        return artifacts.root_partition;
    }
    if (!artifacts.root_uuid.empty()) {
        return "UUID=" + artifacts.root_uuid;
    }
    return {};
}

bool remove_path_recursive(const std::string& path) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) {
        return errno == ENOENT;
    }

    if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) {
        DIR* dir = opendir(path.c_str());
        if (!dir) {
            log_message("WARN", "Failed to open " + path + " for cleanup: " + std::strerror(errno));
            return false;
        }

        bool ok = true;
        while (dirent* entry = readdir(dir)) {
            const std::string name = entry->d_name;
            if (name == "." || name == "..") continue;
            if (!remove_path_recursive(path + "/" + name)) ok = false;
        }
        closedir(dir);

        if (rmdir(path.c_str()) != 0) {
            log_message("WARN", "Failed to remove directory " + path + ": " + std::strerror(errno));
            return false;
        }
        return ok;
    }

    if (unlink(path.c_str()) != 0) {
        log_message("WARN", "Failed to remove " + path + ": " + std::strerror(errno));
        return false;
    }
    return true;
}

bool looks_like_live_root(const std::string& candidate) {
    return directory_exists(candidate) &&
           directory_exists(candidate + "/usr") &&
           file_exists(candidate + "/etc/geminios-live");
}

bool path_exists_no_follow(const std::string& path) {
    struct stat st;
    return lstat(path.c_str(), &st) == 0;
}

struct LiveBaseMount {
    std::string temp_dir;
    std::string media_mount;
    std::string root_mount;
    bool media_mounted = false;
    bool root_mounted = false;

    ~LiveBaseMount() {
        if (root_mounted) {
            unmount_path(root_mount);
        }
        if (media_mounted) {
            unmount_path(media_mount);
        }
        if (!temp_dir.empty()) {
            remove_path_recursive(temp_dir);
        }
    }
};

bool try_mount_iso_device_read_only(const std::string& device, const std::string& mountpoint) {
    return mount(device.c_str(), mountpoint.c_str(), "iso9660", MS_RDONLY, nullptr) == 0;
}

bool find_pristine_live_source_root(
    const ToolRegistry& tools,
    LiveBaseMount& mount_state,
    std::string& source_root,
    std::string& error
) {
    source_root.clear();

    static const char* const kDirectCandidates[] = {
        "/mnt/ro",
        "/run/geminios/base-root",
        "/run/geminios/ro-root",
    };
    for (const char* candidate_path : kDirectCandidates) {
        const std::string candidate = candidate_path;
        if (looks_like_live_root(candidate)) {
            source_root = candidate;
            return true;
        }
    }

    if (tools.mount.empty()) {
        error = "mount is required to read the pristine live base image.";
        return false;
    }

    char temp_template[] = "/tmp/geminios-installer-source-XXXXXX";
    char* temp_path = mkdtemp(temp_template);
    if (!temp_path) {
        error = "Failed to allocate a temporary mount directory for the live base image.";
        return false;
    }

    mount_state.temp_dir = temp_path;
    mount_state.media_mount = mount_state.temp_dir + "/media";
    mount_state.root_mount = mount_state.temp_dir + "/root";
    if (!mkdir_p(mount_state.media_mount) || !mkdir_p(mount_state.root_mount)) {
        error = "Failed to create temporary mountpoints for the live base image.";
        return false;
    }

    DIR* dir = opendir("/dev");
    if (!dir) {
        error = "Unable to scan /dev for the live boot media.";
        return false;
    }

    while (dirent* entry = readdir(dir)) {
        const std::string name = entry->d_name;
        if (name == "." || name == "..") continue;

        const bool match =
            name.rfind("sr", 0) == 0 ||
            name.rfind("sd", 0) == 0 ||
            name.rfind("vd", 0) == 0 ||
            name.rfind("hd", 0) == 0 ||
            name.rfind("nvme", 0) == 0 ||
            name.rfind("mmcblk", 0) == 0;
        if (!match) continue;

        const std::string device = "/dev/" + name;
        if (!try_mount_iso_device_read_only(device, mount_state.media_mount)) {
            continue;
        }
        mount_state.media_mounted = true;

        const std::string root_sfs = mount_state.media_mount + "/root.sfs";
        if (file_exists(root_sfs)) {
            CommandResult result = run_command(
                tools.mount,
                {"-t", "squashfs", "-o", "loop,ro", root_sfs, mount_state.root_mount}
            );
            if (result.success && looks_like_live_root(mount_state.root_mount)) {
                closedir(dir);
                mount_state.root_mounted = true;
                source_root = mount_state.root_mount;
                return true;
            }
            if (!result.success) {
                log_message(
                    "WARN",
                    "Failed to mount " + root_sfs + " as squashfs; the installer will fall back to the running live root if needed."
                );
            }
        }

        unmount_path(mount_state.media_mount);
        mount_state.media_mounted = false;
    }
    closedir(dir);

    error = "Unable to locate and mount the pristine live base image (root.sfs).";
    return false;
}

bool sanitize_target_accounts_after_live_fallback(std::string& error) {
    const std::string passwd_path = kTargetRoot + "/etc/passwd";
    const std::string shadow_path = kTargetRoot + "/etc/shadow";
    const std::string group_path = kTargetRoot + "/etc/group";

    std::vector<std::string> passwd_lines;
    std::vector<std::string> shadow_lines;
    std::vector<std::string> group_lines;
    if (!read_lines(passwd_path, passwd_lines) ||
        !read_lines(shadow_path, shadow_lines) ||
        !read_lines(group_path, group_lines)) {
        error = "Failed to sanitize copied account database files from the live environment.";
        return false;
    }

    std::set<std::string> removed_users;
    std::vector<std::string> sanitized_passwd;
    for (const auto& line : passwd_lines) {
        auto fields = split_preserve_empty(line, ':');
        if (fields.size() < 3) {
            sanitized_passwd.push_back(line);
            continue;
        }

        int uid = -1;
        if (!parse_int(fields[2], uid)) {
            sanitized_passwd.push_back(line);
            continue;
        }

        if (uid >= 1000 && uid != 65534) {
            removed_users.insert(fields[0]);
            continue;
        }
        sanitized_passwd.push_back(line);
    }
    passwd_lines.swap(sanitized_passwd);

    if (!removed_users.empty()) {
        std::vector<std::string> sanitized_shadow;
        for (const auto& line : shadow_lines) {
            auto fields = split_preserve_empty(line, ':');
            if (!fields.empty() && removed_users.count(fields[0]) != 0) continue;
            sanitized_shadow.push_back(line);
        }
        shadow_lines.swap(sanitized_shadow);
    }

    std::vector<std::string> sanitized_group;
    for (const auto& line : group_lines) {
        auto fields = split_preserve_empty(line, ':');
        if (fields.size() < 4) {
            sanitized_group.push_back(line);
            continue;
        }

        int gid = -1;
        const bool has_gid = parse_int(fields[2], gid);
        if (has_gid && gid >= 1000 && gid != 65534) {
            continue;
        }

        std::vector<std::string> kept_members;
        std::stringstream members(fields[3]);
        std::string member;
        while (std::getline(members, member, ',')) {
            member = trim(member);
            if (member.empty() || removed_users.count(member) != 0) continue;
            kept_members.push_back(member);
        }
        fields[3] = join_strings(kept_members, ",");
        sanitized_group.push_back(join_strings(fields, ":"));
    }
    group_lines.swap(sanitized_group);

    if (!write_lines(passwd_path, passwd_lines, 0644) ||
        !write_lines(shadow_path, shadow_lines, 0600) ||
        !write_lines(group_path, group_lines, 0644)) {
        error = "Failed to write sanitized account database files.";
        return false;
    }

    return true;
}

bool sanitize_target_after_live_root_fallback(std::string& error) {
    ensure_file_removed(kTargetRoot + "/etc/geminios-live");
    ensure_file_removed(kTargetRoot + "/etc/machine-id");
    ensure_file_removed(kTargetRoot + "/var/lib/dbus/machine-id");
    ensure_file_removed(kTargetRoot + "/root/.bash_history");

    if (!sanitize_target_accounts_after_live_fallback(error)) {
        return false;
    }

    return true;
}

std::string normalize_machine_id(std::string value) {
    std::string normalized;
    normalized.reserve(value.size());
    for (unsigned char ch : value) {
        if (!std::isxdigit(ch)) continue;
        normalized.push_back(static_cast<char>(std::tolower(ch)));
    }
    return normalized.size() == 32 ? normalized : "";
}

std::string generate_machine_id() {
    std::string machine_id = normalize_machine_id(read_file_trimmed("/proc/sys/kernel/random/uuid"));
    if (!machine_id.empty()) return machine_id;

    unsigned char random_bytes[16] = {};
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return "";

    size_t offset = 0;
    while (offset < sizeof(random_bytes)) {
        ssize_t got = read(fd, random_bytes + offset, sizeof(random_bytes) - offset);
        if (got <= 0) {
            close(fd);
            return "";
        }
        offset += static_cast<size_t>(got);
    }
    close(fd);

    static const char kHexDigits[] = "0123456789abcdef";
    machine_id.reserve(32);
    for (unsigned char byte : random_bytes) {
        machine_id.push_back(kHexDigits[(byte >> 4) & 0x0F]);
        machine_id.push_back(kHexDigits[byte & 0x0F]);
    }
    return machine_id;
}

bool configure_machine_identity(std::string& error) {
    const std::string machine_id = generate_machine_id();
    if (machine_id.empty()) {
        error = "Failed to generate a unique machine-id.";
        return false;
    }

    if (!write_text_file(kTargetRoot + "/etc/machine-id", machine_id + "\n")) {
        error = "Failed to write /etc/machine-id.";
        return false;
    }
    if (!mkdir_p(kTargetRoot + "/var/lib/dbus")) {
        error = "Failed to create /var/lib/dbus.";
        return false;
    }
    if (!ensure_symlink("/etc/machine-id", kTargetRoot + "/var/lib/dbus/machine-id")) {
        error = "Failed to link /var/lib/dbus/machine-id.";
        return false;
    }
    return true;
}

bool auto_partition_disk(const ToolRegistry& tools, const InstallerConfig& config, InstallArtifacts& artifacts, std::string& error) {
    if (tools.sfdisk.empty()) {
        error = "sfdisk is required for automatic partitioning.";
        return false;
    }

    const BootMode boot_mode = effective_boot_mode(config);
    std::string layout;

    if (boot_mode == BootMode::Uefi) {
        layout =
            "label: gpt\n"
            "first-lba: 2048\n\n"
            "size=512MiB, type=U, name=\"EFI System\"\n"
            "type=L, name=\"GeminiOS Root\"\n";
    } else {
        layout =
            "label: dos\n"
            "unit: sectors\n\n"
            "2048,,83,*\n";
    }

    CommandResult result = run_command(tools.sfdisk, {"--wipe", "always", config.disk}, layout);
    if (!result.success) {
        error = "Automatic partitioning failed. See " + kLogPath;
        return false;
    }

    if (!tools.blockdev.empty()) {
        run_command(tools.blockdev, {"--rereadpt", config.disk});
    }
    if (!tools.udevadm.empty()) {
        run_command(tools.udevadm, {"settle"});
    }
    ::sync();

    artifacts.root_partition = partition_path(config.disk, boot_mode == BootMode::Uefi ? 2 : 1);
    artifacts.efi_partition = boot_mode == BootMode::Uefi ? partition_path(config.disk, 1) : "";

    if (!wait_for_path(artifacts.root_partition)) {
        error = "Root partition device did not appear after partitioning.";
        return false;
    }
    if (!artifacts.efi_partition.empty() && !wait_for_path(artifacts.efi_partition)) {
        error = "EFI partition device did not appear after partitioning.";
        return false;
    }

    return true;
}

bool resolve_install_artifacts(const InstallerConfig& config, InstallArtifacts& artifacts, std::string& error) {
    artifacts = {};

    if (config.partition_mode == PartitionMode::AutoWipe) return true;

    artifacts.root_partition = config.root_partition;
    artifacts.efi_partition = config.efi_partition;
    artifacts.swap_partition = config.swap_mode == SwapMode::Partition ? config.swap_partition : "";

    if (!file_exists(artifacts.root_partition)) {
        error = "Configured root partition does not exist: " + artifacts.root_partition;
        return false;
    }
    if (!artifacts.efi_partition.empty() && !file_exists(artifacts.efi_partition)) {
        error = "Configured EFI partition does not exist: " + artifacts.efi_partition;
        return false;
    }
    if (!artifacts.swap_partition.empty() && !file_exists(artifacts.swap_partition)) {
        error = "Configured swap partition does not exist: " + artifacts.swap_partition;
        return false;
    }

    return true;
}

bool format_partitions(const ToolRegistry& tools, const InstallerConfig& config, InstallArtifacts& artifacts, std::string& error) {
    const BootMode boot_mode = effective_boot_mode(config);
    const std::string mkfs_tool = filesystem_mkfs_tool(tools, config.filesystem);

    if (config.partition_mode == PartitionMode::AutoWipe || config.format_root) {
        std::vector<std::string> args;
        if (config.filesystem == FilesystemType::Ext4) {
            args = {"-F", "-L", "GeminiRoot", artifacts.root_partition};
        } else if (config.filesystem == FilesystemType::Xfs) {
            args = {"-f", "-L", "GeminiRoot", artifacts.root_partition};
        } else {
            args = {"-f", "-L", "GeminiRoot", artifacts.root_partition};
        }
        if (!run_command(mkfs_tool, args).success) {
            error = "Formatting root partition failed. See " + kLogPath;
            return false;
        }
    }

    if (boot_mode == BootMode::Uefi && !artifacts.efi_partition.empty() && (config.partition_mode == PartitionMode::AutoWipe || config.format_efi)) {
        if (tools.mkfs_vfat.empty()) {
            error = "mkfs.vfat is required for EFI partition formatting.";
            return false;
        }
        if (!run_command(tools.mkfs_vfat, {"-F", "32", "-n", "EFI", artifacts.efi_partition}).success) {
            error = "Formatting EFI partition failed. See " + kLogPath;
            return false;
        }
    }

    if (config.swap_mode == SwapMode::Partition && !artifacts.swap_partition.empty()) {
        if (!run_command(tools.mkswap, {"-L", "GeminiSwap", artifacts.swap_partition}).success) {
            error = "Formatting swap partition failed. See " + kLogPath;
            return false;
        }
    }

    artifacts.root_uuid = capture_blkid_value(tools, artifacts.root_partition, "UUID");
    artifacts.root_partuuid = capture_blkid_value(tools, artifacts.root_partition, "PARTUUID");
    artifacts.efi_uuid = capture_blkid_value(tools, artifacts.efi_partition, "UUID");
    artifacts.swap_uuid = capture_blkid_value(tools, artifacts.swap_partition, "UUID");
    return true;
}

bool prepare_target_mounts(const InstallerConfig& config, InstallArtifacts& artifacts, InstallState& state, std::string& error) {
    if (!mkdir_p(kTargetRoot)) {
        error = "Failed to create target mount root.";
        return false;
    }

    if (!mount_device(artifacts.root_partition, kTargetRoot, filesystem_label(config.filesystem))) {
        error = "Failed to mount root filesystem.";
        return false;
    }
    state.mounted_paths.push_back(kTargetRoot);

    if (effective_boot_mode(config) == BootMode::Uefi && !artifacts.efi_partition.empty()) {
        const std::string efi_mount = kTargetRoot + "/boot/efi";
        if (!mkdir_p(efi_mount)) {
            error = "Failed to create EFI mountpoint.";
            return false;
        }
        if (!mount_device(artifacts.efi_partition, efi_mount, "vfat")) {
            error = "Failed to mount EFI filesystem.";
            return false;
        }
        state.mounted_paths.push_back(efi_mount);
    }

    return true;
}

bool bootstrap_target_filesystem(const ToolRegistry& tools, std::string& error) {
    const bool is_live = file_exists("/etc/geminios-live");
    std::string base_source_root = "/";
    bool using_live_root_fallback = false;
    LiveBaseMount live_base_mount;
    if (is_live) {
        std::string pristine_error;
        if (!find_pristine_live_source_root(tools, live_base_mount, base_source_root, pristine_error)) {
            using_live_root_fallback = true;
            base_source_root = "/";
            log_message("WARN", pristine_error + " Falling back to the running live root snapshot.");
            print_notice("!", C_YELLOW, "Pristine live image unavailable; installing from the current live root snapshot.");
        }
        log_message(
            "INFO",
            std::string("Installing base system from ") +
                (using_live_root_fallback ? "the running live root at " : "pristine live image at ") +
                base_source_root
        );
    }

    const std::vector<std::string> essential_paths = {
        "/bin",
        "/sbin",
        "/lib",
        "/lib64",
        "/usr",
        "/etc",
        "/boot",
        "/root",
        "/var/lib",
        "/var/cache"
    };

    for (const auto& path : essential_paths) {
        const std::string source_path = base_source_root + path;
        if (!copy_tree(tools, source_path, kTargetRoot + path)) {
            error = "Failed to copy " + source_path + ". See " + kLogPath;
            return false;
        }
    }

    const std::vector<std::string> required_dirs = {
        kTargetRoot + "/dev",
        kTargetRoot + "/proc",
        kTargetRoot + "/sys",
        kTargetRoot + "/run",
        kTargetRoot + "/tmp",
        kTargetRoot + "/mnt",
        kTargetRoot + "/home",
        kTargetRoot + "/var/log",
        kTargetRoot + "/var/tmp",
        kTargetRoot + "/var/repo"
    };

    for (const auto& dir : required_dirs) {
        if (!mkdir_p(dir)) {
            error = "Failed to create target directory " + dir;
            return false;
        }
    }

    ensure_file_removed(kTargetRoot + "/etc/geminios-live");

    if (using_live_root_fallback) {
        if (!sanitize_target_after_live_root_fallback(error)) {
            return false;
        }
    }

    if (!path_exists_no_follow(kTargetRoot + "/lib")) {
        ensure_symlink("usr/lib", kTargetRoot + "/lib");
    }
    if (!path_exists_no_follow(kTargetRoot + "/lib64")) {
        ensure_symlink("lib/x86_64-linux-gnu", kTargetRoot + "/lib64");
    }
    if (!path_exists_no_follow(kTargetRoot + "/bin")) {
        ensure_symlink("usr/bin", kTargetRoot + "/bin");
    }
    if (!path_exists_no_follow(kTargetRoot + "/sbin")) {
        ensure_symlink("usr/sbin", kTargetRoot + "/sbin");
    }

    return true;
}

bool configure_display_stack(const InstallerConfig& config, std::string& error) {
    if (config.profile == InstallProfile::Minimal) return true;

    if (!mkdir_p(kTargetRoot + "/etc/X11/xorg.conf.d")) {
        error = "Failed to create Xorg configuration directory.";
        return false;
    }
    if (!mkdir_p(kTargetRoot + "/var/lib/lightdm/data")) {
        error = "Failed to create LightDM data directory.";
        return false;
    }
    if (!mkdir_p(kTargetRoot + "/var/cache/lightdm")) {
        error = "Failed to create LightDM cache directory.";
        return false;
    }

    const std::string legacy_xorg_conf = kTargetRoot + "/etc/X11/xorg.conf";
    const std::string backup_xorg_conf = legacy_xorg_conf + ".installer-backup";
    if (file_exists(legacy_xorg_conf)) {
        if (!file_exists(backup_xorg_conf)) {
            if (std::rename(legacy_xorg_conf.c_str(), backup_xorg_conf.c_str()) != 0) {
                error = "Failed to back up legacy Xorg configuration.";
                return false;
            }
        } else if (!ensure_file_removed(legacy_xorg_conf)) {
            error = "Failed to remove legacy Xorg configuration.";
            return false;
        }
    }

    const std::string safe_xorg_conf =
        "Section \"Files\"\n"
        "    XkbDir \"/usr/share/X11/xkb\"\n"
        "EndSection\n\n"
        "Section \"ServerFlags\"\n"
        "    Option \"AutoAddDevices\" \"true\"\n"
        "    Option \"AutoEnableDevices\" \"true\"\n"
        "EndSection\n\n"
        "Section \"Device\"\n"
        "    Identifier \"GeminiOS Safe Graphics\"\n"
        "    Driver \"modesetting\"\n"
        "    Option \"AccelMethod\" \"none\"\n"
        "    Option \"ShadowFB\" \"true\"\n"
        "    Option \"SWcursor\" \"on\"\n"
        "EndSection\n";

    if (!write_text_file(kTargetRoot + "/etc/X11/xorg.conf.d/20-geminios-safe-graphics.conf", safe_xorg_conf)) {
        error = "Failed to write safe Xorg fallback configuration.";
        return false;
    }

    return true;
}

bool write_selinux_config(const std::string& mode, std::string& error) {
    const std::string config =
        "# GeminiOS SELinux defaults\n"
        "SELINUX=" + mode + "\n"
        "SELINUXTYPE=default\n"
        "SETLOCALDEFS=0\n";

    if (!write_text_file(kTargetRoot + "/etc/selinux/config", config)) {
        error = "Failed to write /etc/selinux/config.";
        return false;
    }

    return true;
}

std::string target_selinux_file_contexts() {
    const std::vector<std::string> candidates = {
        kTargetRoot + "/etc/selinux/default/contexts/files/file_contexts",
        kTargetRoot + "/etc/selinux/targeted/contexts/files/file_contexts",
    };

    for (const auto& candidate : candidates) {
        if (file_exists(candidate)) return candidate;
    }

    return "";
}

bool relabel_selinux_target(const ToolRegistry& tools, std::string& error) {
    if (!file_exists(kTargetRoot + "/etc/selinux/config")) return true;

    if (!write_selinux_config("permissive", error)) return false;

    const std::string file_contexts = target_selinux_file_contexts();
    if (tools.setfiles.empty() || file_contexts.empty()) {
        log_message("WARN", "SELinux relabel skipped because setfiles or file_contexts is unavailable. Leaving target permissive.");
        if (!write_text_file(kTargetRoot + "/.autorelabel", "")) {
            error = "Failed to create /.autorelabel in the target filesystem.";
            return false;
        }
        return true;
    }

    CommandResult relabel = run_command(
        tools.setfiles,
        {"-F", "-r", kTargetRoot, file_contexts, kTargetRoot}
    );
    if (!relabel.success) {
        log_message("WARN", "SELinux relabel failed. Leaving target permissive and scheduling a first-boot relabel.");
        if (!write_text_file(kTargetRoot + "/.autorelabel", "")) {
            error = "Failed to create /.autorelabel after a relabel failure.";
            return false;
        }
        return true;
    }

    ensure_file_removed(kTargetRoot + "/.autorelabel");
    return write_selinux_config("enforcing", error);
}

bool replace_shadow_password(std::vector<std::string>& lines, const std::string& username, const std::string& password_hash) {
    const long now_days = static_cast<long>(std::time(nullptr) / 86400);
    for (auto& line : lines) {
        auto fields = split_preserve_empty(line, ':');
        if (fields.size() < 9 || fields[0] != username) continue;
        fields[1] = password_hash;
        fields[2] = std::to_string(now_days);
        line = join_strings(fields, ":");
        return true;
    }
    return false;
}

int next_passwd_id(const std::vector<std::string>& lines, int floor_value) {
    int next_value = floor_value;
    for (const auto& line : lines) {
        auto fields = split_preserve_empty(line, ':');
        if (fields.size() < 4) continue;
        int parsed = 0;
        if (!parse_int(fields[2], parsed)) continue;
        next_value = std::max(next_value, parsed + 1);
    }
    return next_value;
}

int next_group_id(const std::vector<std::string>& lines, int floor_value) {
    int next_value = floor_value;
    for (const auto& line : lines) {
        auto fields = split_preserve_empty(line, ':');
        if (fields.size() < 3) continue;
        int parsed = 0;
        if (!parse_int(fields[2], parsed)) continue;
        next_value = std::max(next_value, parsed + 1);
    }
    return next_value;
}

bool passwd_contains_user(const std::vector<std::string>& lines, const std::string& username) {
    for (const auto& line : lines) {
        auto fields = split_preserve_empty(line, ':');
        if (!fields.empty() && fields[0] == username) return true;
    }
    return false;
}

bool upsert_passwd_user(std::vector<std::string>& lines, const User& user) {
    const std::string entry =
        user.username + ":x:" + std::to_string(user.uid) + ":" + std::to_string(user.gid) +
        ":" + user.gecos + ":" + user.home + ":" + user.shell;

    for (auto& line : lines) {
        auto fields = split_preserve_empty(line, ':');
        if (!fields.empty() && fields[0] == user.username) {
            line = entry;
            return true;
        }
    }

    lines.push_back(entry);
    return true;
}

bool upsert_shadow_user(std::vector<std::string>& lines, const std::string& username, const std::string& password_hash) {
    const long now_days = static_cast<long>(std::time(nullptr) / 86400);
    const std::string entry =
        username + ":" + password_hash + ":" + std::to_string(now_days) + ":0:99999:7:::";

    for (auto& line : lines) {
        auto fields = split_preserve_empty(line, ':');
        if (!fields.empty() && fields[0] == username) {
            line = entry;
            return true;
        }
    }

    lines.push_back(entry);
    return true;
}

int find_group_gid(const std::vector<std::string>& lines, const std::string& group_name) {
    for (const auto& line : lines) {
        auto fields = split_preserve_empty(line, ':');
        if (fields.size() < 3 || fields[0] != group_name) continue;
        int gid = -1;
        if (parse_int(fields[2], gid)) return gid;
    }
    return -1;
}

void add_group_member(std::vector<std::string>& lines, const std::string& group_name, int gid, const std::string& member) {
    for (auto& line : lines) {
        auto fields = split_preserve_empty(line, ':');
        if (fields.size() < 4 || fields[0] != group_name) continue;

        std::set<std::string> members;
        std::stringstream ss(fields[3]);
        std::string entry;
        while (std::getline(ss, entry, ',')) {
            entry = trim(entry);
            if (!entry.empty()) members.insert(entry);
        }
        if (!member.empty()) members.insert(member);

        std::vector<std::string> ordered(members.begin(), members.end());
        fields[3] = join_strings(ordered, ",");
        line = join_strings(fields, ":");
        return;
    }

    std::string members = member.empty() ? "" : member;
    lines.push_back(group_name + ":x:" + std::to_string(gid) + ":" + members);
}

bool configure_accounts(const InstallerConfig& config, std::string& error) {
    const std::string passwd_path = kTargetRoot + "/etc/passwd";
    const std::string shadow_path = kTargetRoot + "/etc/shadow";
    const std::string group_path = kTargetRoot + "/etc/group";

    std::vector<std::string> passwd_lines;
    std::vector<std::string> shadow_lines;
    std::vector<std::string> group_lines;

    if (!read_lines(passwd_path, passwd_lines) || !read_lines(shadow_path, shadow_lines) || !read_lines(group_path, group_lines)) {
        error = "Failed to read target account database files.";
        return false;
    }

    if (!replace_shadow_password(shadow_lines, "root", UserMgmt::hash_password(config.root_password))) {
        upsert_shadow_user(shadow_lines, "root", UserMgmt::hash_password(config.root_password));
    }

    if (config.user.create) {
        if (passwd_contains_user(passwd_lines, config.user.username)) {
            error = "The target already contains a user named '" + config.user.username + "'.";
            return false;
        }

        const int uid = next_passwd_id(passwd_lines, 1000);
        int gid = find_group_gid(group_lines, config.user.username);
        if (gid < 0) gid = next_group_id(group_lines, 1000);

        User user;
        user.username = config.user.username;
        user.password = UserMgmt::hash_password(config.user.password);
        user.uid = uid;
        user.gid = gid;
        user.gecos = "";
        user.home = "/home/" + config.user.username;
        user.shell = "/bin/bash";

        upsert_passwd_user(passwd_lines, user);
        upsert_shadow_user(shadow_lines, user.username, user.password);
        add_group_member(group_lines, user.username, gid, user.username);
        add_group_member(group_lines, "users", find_group_gid(group_lines, "users") >= 0 ? find_group_gid(group_lines, "users") : next_group_id(group_lines, 1001), user.username);

        if (config.user.sudo) {
            int sudo_gid = find_group_gid(group_lines, "sudo");
            if (sudo_gid < 0) sudo_gid = next_group_id(group_lines, 1002);
            add_group_member(group_lines, "sudo", sudo_gid, user.username);
        }

        if (config.profile != InstallProfile::Minimal) {
            const std::vector<std::string> desktop_groups = {"audio", "video", "input", "render", "storage"};
            for (const auto& group_name : desktop_groups) {
                int gid_value = find_group_gid(group_lines, group_name);
                if (gid_value < 0) gid_value = next_group_id(group_lines, 1003);
                add_group_member(group_lines, group_name, gid_value, user.username);
            }
        }

        if (config.profile == InstallProfile::Developer) {
            int kvm_gid = find_group_gid(group_lines, "kvm");
            if (kvm_gid < 0) kvm_gid = next_group_id(group_lines, 1004);
            add_group_member(group_lines, "kvm", kvm_gid, user.username);
        }

        const std::string home_dir = kTargetRoot + user.home;
        if (!mkdir_p(home_dir, 0700)) {
            error = "Failed to create home directory " + home_dir;
            return false;
        }
        chmod(home_dir.c_str(), 0700);

        const std::string skeleton = file_exists(kTargetRoot + "/etc/skel/.bashrc")
            ? kTargetRoot + "/etc/skel/.bashrc"
            : kTargetRoot + "/root/.bashrc";
        if (file_exists(skeleton)) {
            std::ifstream src(skeleton);
            std::ostringstream contents;
            contents << src.rdbuf();
            if (!write_text_file(home_dir + "/.bashrc", contents.str(), 0644)) {
                error = "Failed to write user shell profile.";
                return false;
            }
        }

        if (chown(home_dir.c_str(), uid, gid) != 0) {
            log_message("WARN", "Failed to chown " + home_dir + ": " + std::strerror(errno));
        }
        if (chown((home_dir + "/.bashrc").c_str(), uid, gid) != 0 && errno != ENOENT) {
            log_message("WARN", "Failed to chown user bashrc: " + std::string(std::strerror(errno)));
        }
    }

    if (!write_lines(passwd_path, passwd_lines, 0644) ||
        !write_lines(shadow_path, shadow_lines, 0600) ||
        !write_lines(group_path, group_lines, 0644)) {
        error = "Failed to write target account database files.";
        return false;
    }

    if (!write_text_file(kTargetRoot + "/etc/sudoers", "root ALL=(ALL:ALL) ALL\n%sudo ALL=(ALL:ALL) ALL\n", 0440)) {
        error = "Failed to write /etc/sudoers.";
        return false;
    }

    return true;
}

bool configure_identity(const InstallerConfig& config, const InstallArtifacts& artifacts, std::string& error) {
    if (!write_text_file(kTargetRoot + "/etc/hostname", config.hostname + "\n")) {
        error = "Failed to write hostname.";
        return false;
    }

    std::ostringstream hosts;
    hosts << "127.0.0.1\tlocalhost\n";
    hosts << "::1\tlocalhost ip6-localhost ip6-loopback\n";
    hosts << "127.0.1.1\t" << config.hostname << ".localdomain " << config.hostname << "\n";
    if (!write_text_file(kTargetRoot + "/etc/hosts", hosts.str())) {
        error = "Failed to write hosts file.";
        return false;
    }

    if (!configure_machine_identity(error)) {
        return false;
    }

    if (!write_text_file(kTargetRoot + "/etc/default/locale", "LANG=" + config.locale + "\n")) {
        error = "Failed to write default locale.";
        return false;
    }
    if (!write_text_file(kTargetRoot + "/etc/locale.conf", "LANG=" + config.locale + "\n")) {
        error = "Failed to write locale.conf.";
        return false;
    }
    if (!write_text_file(kTargetRoot + "/etc/timezone", config.timezone + "\n")) {
        error = "Failed to write timezone.";
        return false;
    }
    if (!write_text_file(kTargetRoot + "/etc/vconsole.conf", "KEYMAP=" + config.keyboard_layout + "\n")) {
        error = "Failed to write vconsole.conf.";
        return false;
    }
    if (!write_text_file(kTargetRoot + "/etc/default/keyboard", "XKBLAYOUT=\"" + config.keyboard_layout + "\"\n")) {
        error = "Failed to write keyboard config.";
        return false;
    }

    const std::string timezone_target = "/usr/share/zoneinfo/" + config.timezone;
    if (!ensure_symlink(timezone_target, kTargetRoot + "/etc/localtime")) {
        error = "Failed to set localtime.";
        return false;
    }

    if (config.user.create && config.user.autologin && config.profile != InstallProfile::Minimal) {
        const std::string autologin_conf =
            "[Seat:*]\n"
            "autologin-user=" + config.user.username + "\n"
            "autologin-user-timeout=0\n";
        if (!write_text_file(kTargetRoot + "/etc/lightdm/lightdm.conf.d/60-installer-autologin.conf", autologin_conf)) {
            error = "Failed to write LightDM autologin config.";
            return false;
        }
    } else {
        ensure_file_removed(kTargetRoot + "/etc/lightdm/lightdm.conf.d/60-installer-autologin.conf");
    }

    std::ostringstream marker;
    marker << "PROFILE=" << profile_label(config.profile) << "\n";
    marker << "BOOT_MODE=" << boot_mode_label(effective_boot_mode(config)) << "\n";
    marker << "FILESYSTEM=" << filesystem_label(config.filesystem) << "\n";
    marker << "ROOT_PARTITION=" << artifacts.root_partition << "\n";
    if (!artifacts.root_partuuid.empty()) marker << "ROOT_PARTUUID=" << artifacts.root_partuuid << "\n";
    marker << "EFI_PARTITION=" << artifacts.efi_partition << "\n";
    if (config.user.create) marker << "USER=" << config.user.username << "\n";

    if (!write_text_file(kTargetRoot + "/etc/geminios-installer.conf", marker.str())) {
        error = "Failed to write installer metadata.";
        return false;
    }

    return true;
}

bool write_fstab(const InstallerConfig& config, const InstallArtifacts& artifacts, std::string& error) {
    std::ostringstream fstab;
    const std::string root_source = !artifacts.root_uuid.empty() ? "UUID=" + artifacts.root_uuid : artifacts.root_partition;
    fstab << root_source << " / " << filesystem_label(config.filesystem) << " defaults 0 1\n";

    if (!artifacts.efi_partition.empty()) {
        const std::string efi_source = !artifacts.efi_uuid.empty() ? "UUID=" + artifacts.efi_uuid : artifacts.efi_partition;
        fstab << efi_source << " /boot/efi vfat umask=0077 0 2\n";
    }

    if (config.swap_mode == SwapMode::Partition && !artifacts.swap_partition.empty()) {
        const std::string swap_source = !artifacts.swap_uuid.empty() ? "UUID=" + artifacts.swap_uuid : artifacts.swap_partition;
        fstab << swap_source << " none swap sw 0 0\n";
    } else if (config.swap_mode == SwapMode::Swapfile) {
        fstab << "/swapfile none swap defaults 0 0\n";
    }

    fstab << "proc /proc proc nosuid,noexec,nodev 0 0\n";

    if (!write_text_file(kTargetRoot + "/etc/fstab", fstab.str())) {
        error = "Failed to write fstab.";
        return false;
    }
    return true;
}

bool write_grub_config(const InstallerConfig& config, const InstallArtifacts& artifacts, std::string& error) {
    const BootMode boot_mode = effective_boot_mode(config);
    if (!mkdir_p(kTargetRoot + "/boot/grub")) {
        error = "Failed to create GRUB config directory.";
        return false;
    }

    const std::string kernel_root = kernel_root_argument(artifacts);
    if (kernel_root.empty()) {
        error = "Unable to determine kernel root device argument.";
        return false;
    }
    std::ostringstream grub;
    const std::string base_kernel_args =
        "root=" + kernel_root + " rootfstype=" + filesystem_label(config.filesystem) + " rootwait rw security=selinux selinux=1";
    grub << "set timeout=5\n";
    grub << "set default=0\n";
    grub << "insmod part_msdos\n";
    grub << "insmod part_gpt\n";
    grub << "insmod ext2\n";
    grub << "insmod fat\n";
    if (!artifacts.root_uuid.empty()) {
        grub << "search --no-floppy --fs-uuid --set=root " << artifacts.root_uuid << "\n";
    } else {
        grub << "set root=" << (boot_mode == BootMode::Uefi ? "(hd0,gpt2)" : "(hd0,msdos1)") << "\n";
    }
    grub << "menuentry \"GeminiOS\" {\n";
    grub << "  linux /boot/kernel " << base_kernel_args << " quiet\n";
    grub << "}\n";
    grub << "menuentry \"GeminiOS (Verbose Boot)\" {\n";
    grub << "  linux /boot/kernel " << base_kernel_args << " loglevel=7 ignore_loglevel\n";
    grub << "}\n";

    if (!write_text_file(kTargetRoot + "/boot/grub/grub.cfg", grub.str())) {
        error = "Failed to write grub.cfg.";
        return false;
    }
    return true;
}

bool install_bootloader(const ToolRegistry& tools, const InstallerConfig& config, const InstallArtifacts& artifacts, std::string& error) {
    if (config.bootloader == BootloaderChoice::None) return true;
    if (tools.grub_install.empty()) {
        error = "GRUB was selected, but grub-install is not available.";
        return false;
    }

    std::vector<std::string> args;
    if (effective_boot_mode(config) == BootMode::Uefi) {
        if (artifacts.efi_partition.empty()) {
            error = "UEFI installs require an EFI system partition.";
            return false;
        }
        args = {
            "--target=x86_64-efi",
            "--efi-directory=" + kTargetRoot + "/boot/efi",
            "--boot-directory=" + kTargetRoot + "/boot",
            "--bootloader-id=GeminiOS",
            "--removable",
            "--recheck"
        };
    } else {
        args = {
            "--target=i386-pc",
            "--boot-directory=" + kTargetRoot + "/boot",
            "--recheck",
            config.disk
        };
    }

    if (!run_command(tools.grub_install, args).success) {
        error = "grub-install failed. See " + kLogPath;
        return false;
    }

    return true;
}

}  // namespace

bool perform_install(const ToolRegistry& tools, const InstallerConfig& config, std::string& error) {
    InstallArtifacts artifacts;
    InstallState state;

    if (!resolve_install_artifacts(config, artifacts, error)) {
        return false;
    }

    if (config.partition_mode == PartitionMode::AutoWipe) {
        print_notice("->", C_CYAN, "Partitioning target disk");
        if (!auto_partition_disk(tools, config, artifacts, error)) {
            cleanup_install_state(state);
            return false;
        }
    }

    print_notice("->", C_CYAN, "Formatting selected partitions");
    if (!format_partitions(tools, config, artifacts, error)) {
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Mounting target filesystems");
    if (!prepare_target_mounts(config, artifacts, state, error)) {
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Copying GeminiOS base system");
    if (!bootstrap_target_filesystem(tools, error)) {
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Creating swap configuration");
    if (!create_swapfile(tools, config)) {
        error = "Failed to create the requested swapfile.";
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Configuring system identity");
    if (!configure_identity(config, artifacts, error)) {
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Hardening display configuration");
    if (!configure_display_stack(config, error)) {
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Configuring user accounts");
    if (!configure_accounts(config, error)) {
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Writing fstab");
    if (!write_fstab(config, artifacts, error)) {
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Writing GRUB configuration");
    if (!write_grub_config(config, artifacts, error)) {
        cleanup_install_state(state);
        return false;
    }

    print_notice("->", C_CYAN, "Applying SELinux labels");
    if (!relabel_selinux_target(tools, error)) {
        cleanup_install_state(state);
        return false;
    }

    if (config.bootloader == BootloaderChoice::Grub) {
        print_notice("->", C_CYAN, "Installing bootloader");
        if (!install_bootloader(tools, config, artifacts, error)) {
            cleanup_install_state(state);
            return false;
        }
    }

    ::sync();
    cleanup_install_state(state);
    ::sync();
    return true;
}

}  // namespace installer
