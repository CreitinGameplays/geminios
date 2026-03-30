#include "installer_common.h"

#include "user_mgmt.h"

#include <iostream>
#include <vector>

namespace installer {

namespace {

std::string swap_mode_label(const InstallerConfig& config) {
    switch (config.swap_mode) {
        case SwapMode::None:
            return "Disabled";
        case SwapMode::Swapfile:
            return "Swapfile (" + std::to_string(config.swap_size_mb) + " MiB)";
        case SwapMode::Partition:
            return config.swap_partition.empty() ? "Existing swap partition (not set)" : "Partition (" + config.swap_partition + ")";
    }
    return "Unknown";
}

bool validate_partition_path(const std::string& path) {
    return path.rfind("/dev/", 0) == 0 && file_exists(path);
}

std::vector<std::string> validate_configuration(const InstallerConfig& config, const ToolRegistry& tools, std::vector<std::string>& warnings) {
    warnings.clear();
    std::vector<std::string> errors;

    const BootMode boot_mode = effective_boot_mode(config);
    if (config.partition_mode == PartitionMode::AutoWipe) {
        if (config.disk.empty() || !validate_partition_path(config.disk)) {
            errors.push_back("Select a valid target disk for automatic partitioning.");
        }
        if (!tools.sfdisk.empty()) {
            const std::string live_root_disk = "/dev/" + root_disk_name_from_live_system();
            if (!live_root_disk.empty() && config.disk == live_root_disk) {
                warnings.push_back("The selected disk appears to host the currently running system.");
            }
        }
    } else {
        if (config.root_partition.empty() || !validate_partition_path(config.root_partition)) {
            errors.push_back("Select a valid existing root partition.");
        }
        if (boot_mode == BootMode::Uefi && (config.efi_partition.empty() || !validate_partition_path(config.efi_partition))) {
            errors.push_back("UEFI installs require a valid EFI system partition.");
        }
        if (config.swap_mode == SwapMode::Partition && (config.swap_partition.empty() || !validate_partition_path(config.swap_partition))) {
            errors.push_back("Swap partition mode requires a valid swap partition path.");
        }
    }

    if (!valid_hostname(config.hostname)) {
        errors.push_back("Hostname must be 1-63 characters, alphanumeric or hyphen, and cannot start/end with a hyphen.");
    }
    if (!valid_timezone(config.timezone)) {
        errors.push_back("Timezone was not found under /usr/share/zoneinfo.");
    }
    if (config.locale.empty()) {
        errors.push_back("Locale cannot be empty.");
    }
    if (config.keyboard_layout.empty()) {
        errors.push_back("Keyboard layout cannot be empty.");
    }
    if (config.root_password.size() < 4) {
        errors.push_back("Root password must be at least 4 characters.");
    }
    if (config.user.create) {
        if (!UserMgmt::is_valid_username(config.user.username)) {
            errors.push_back("User name must follow GeminiOS account naming rules.");
        }
        if (config.user.password.size() < 4) {
            errors.push_back("User password must be at least 4 characters.");
        }
    }
    if (config.swap_mode == SwapMode::Swapfile && config.swap_size_mb < 256) {
        errors.push_back("Swapfile size must be at least 256 MiB.");
    }
    if (config.swap_mode == SwapMode::Swapfile &&
        (config.filesystem == FilesystemType::Btrfs || config.filesystem == FilesystemType::F2fs)) {
        errors.push_back(filesystem_label(config.filesystem) + " installs cannot use a swapfile yet. Select a swap partition or disable swap.");
    }
    if (config.partition_mode == PartitionMode::AutoWipe && config.swap_mode == SwapMode::Partition) {
        errors.push_back("Automatic partitioning cannot use an existing swap partition.");
    }

    if (filesystem_mkfs_tool(tools, config.filesystem).empty()) {
        errors.push_back("No mkfs tool is available for the selected filesystem.");
    }
    if (config.partition_mode == PartitionMode::AutoWipe && tools.sfdisk.empty()) {
        errors.push_back("Automatic partitioning requires sfdisk.");
    }
    if (boot_mode == BootMode::Uefi && (config.partition_mode == PartitionMode::AutoWipe || config.format_efi) && tools.mkfs_vfat.empty()) {
        errors.push_back("UEFI installs require mkfs.vfat.");
    }
    if (config.swap_mode != SwapMode::None && tools.mkswap.empty()) {
        errors.push_back("Swap configuration requires mkswap.");
    }
    if (tools.cp.empty()) {
        errors.push_back("cp is required to populate the target filesystem.");
    }
    if (config.bootloader == BootloaderChoice::Grub && tools.grub_install.empty()) {
        errors.push_back("GRUB was selected but grub-install is unavailable.");
    }

    if (boot_mode == BootMode::Uefi && config.bootloader == BootloaderChoice::None) {
        warnings.push_back("No bootloader will be installed. The target may not boot until configured manually.");
    }
    if (!config.user.create) {
        warnings.push_back("No regular user account will be created.");
    }
    if (config.profile == InstallProfile::Minimal && config.user.autologin) {
        warnings.push_back("Autologin was requested with the minimal profile. This assumes LightDM is installed in the copied system.");
    }

    return errors;
}

void select_disk_menu(InstallerConfig& config) {
    print_header("Target Disk");
    const std::vector<DiskInfo> disks = list_disks();
    if (disks.empty()) {
        print_notice("!", C_RED, "No installable disks were found.");
        std::cout << "Press ENTER to continue.";
        std::string unused;
        std::getline(std::cin, unused);
        return;
    }

    std::vector<std::string> options;
    for (const auto& disk : disks) {
        std::string line = disk.path + "  " + format_bytes(disk.bytes) + "  " + disk.model;
        if (disk.removable) line += "  [removable]";
        if (disk.current_system_disk) line += "  [running system]";
        options.push_back(line);
    }

    const int selected = prompt_choice("Select the target disk:", options, 0);
    config.disk = disks[selected].path;
}

void configure_partitioning(InstallerConfig& config) {
    print_header("Partitioning");
    const int choice = prompt_choice(
        "Select partitioning mode:",
        {
            "Auto wipe disk and create fresh partitions",
            "Use existing partitions"
        },
        config.partition_mode == PartitionMode::AutoWipe ? 0 : 1
    );

    config.partition_mode = choice == 0 ? PartitionMode::AutoWipe : PartitionMode::Existing;
    if (config.partition_mode == PartitionMode::AutoWipe) {
        select_disk_menu(config);
        config.root_partition.clear();
        config.efi_partition.clear();
        config.swap_partition.clear();
        config.format_root = true;
        config.format_efi = true;
        return;
    }

    config.root_partition = prompt_text("Existing root partition", config.root_partition.empty() ? "/dev/sda1" : config.root_partition);
    config.format_root = prompt_yes_no("Format the root partition?", config.format_root);
    if (effective_boot_mode(config) == BootMode::Uefi) {
        config.efi_partition = prompt_text("EFI system partition", config.efi_partition.empty() ? "/dev/sda2" : config.efi_partition);
        config.format_efi = prompt_yes_no("Format the EFI partition?", config.format_efi);
    } else {
        config.efi_partition.clear();
        config.format_efi = false;
    }
}

void configure_boot_mode_menu(InstallerConfig& config) {
    print_header("Boot Mode");
    const int choice = prompt_choice(
        "Select boot mode:",
        {
            "Auto detect from current session",
            "BIOS / Legacy",
            "UEFI"
        },
        config.boot_mode == BootMode::Auto ? 0 : (config.boot_mode == BootMode::Bios ? 1 : 2)
    );

    if (choice == 0) config.boot_mode = BootMode::Auto;
    if (choice == 1) config.boot_mode = BootMode::Bios;
    if (choice == 2) config.boot_mode = BootMode::Uefi;

    if (effective_boot_mode(config) != BootMode::Uefi) {
        config.efi_partition.clear();
        config.format_efi = false;
    }
}

void configure_filesystem_menu(InstallerConfig& config, const ToolRegistry& tools) {
    print_header("Filesystem");

    std::vector<FilesystemType> available;
    std::vector<std::string> options;
    const std::vector<FilesystemType> all_types = {
        FilesystemType::Ext4,
        FilesystemType::Xfs,
        FilesystemType::Btrfs,
        FilesystemType::F2fs
    };
    for (FilesystemType type : all_types) {
        if (filesystem_mkfs_tool(tools, type).empty()) continue;
        available.push_back(type);
        options.push_back(filesystem_label(type));
    }

    if (available.empty()) {
        print_notice("!", C_RED, "No supported filesystem tools are available.");
        std::cout << "Press ENTER to continue.";
        std::string unused;
        std::getline(std::cin, unused);
        return;
    }

    int default_index = 0;
    for (size_t i = 0; i < available.size(); ++i) {
        if (available[i] == config.filesystem) {
            default_index = static_cast<int>(i);
            break;
        }
    }

    config.filesystem = available[prompt_choice("Select the root filesystem:", options, default_index)];
}

void configure_swap_menu(InstallerConfig& config) {
    print_header("Swap");

    std::vector<std::string> options = {
        "No swap",
        "Create a swapfile on the target root filesystem"
    };
    if (config.partition_mode == PartitionMode::Existing) {
        options.push_back("Use an existing swap partition");
    }

    int default_index = 0;
    if (config.swap_mode == SwapMode::Swapfile) default_index = 1;
    if (config.swap_mode == SwapMode::Partition && config.partition_mode == PartitionMode::Existing) default_index = 2;

    const int choice = prompt_choice("Select swap configuration:", options, default_index);
    if (choice == 0) {
        config.swap_mode = SwapMode::None;
        config.swap_partition.clear();
        return;
    }

    if (choice == 1) {
        config.swap_mode = SwapMode::Swapfile;
        std::string swap_size = prompt_text("Swapfile size in MiB", std::to_string(config.swap_size_mb));
        int parsed = config.swap_size_mb;
        if (parse_int(swap_size, parsed) && parsed > 0) config.swap_size_mb = parsed;
        config.swap_partition.clear();
        return;
    }

    config.swap_mode = SwapMode::Partition;
    config.swap_partition = prompt_text("Existing swap partition", config.swap_partition.empty() ? "/dev/sda3" : config.swap_partition);
}

void configure_identity_menu(InstallerConfig& config) {
    print_header("System Identity");
    config.hostname = prompt_text("Hostname", config.hostname);
    config.timezone = prompt_text("Timezone (for example UTC or America/New_York)", config.timezone);
    config.locale = prompt_text("Locale", config.locale);
    config.keyboard_layout = prompt_text("Keyboard layout", config.keyboard_layout);
}

std::string prompt_password_with_confirmation(const std::string& label, const std::string& current_password = "") {
    while (true) {
        std::string password = prompt_text(label, current_password.empty() ? "" : "<unchanged>", current_password.empty());
        if (password == "<unchanged>") return current_password;
        if (password.empty() && !current_password.empty()) return current_password;
        std::string confirm = prompt_text("Confirm " + label, "", false);
        if (password == confirm) return password;
        print_notice("!", C_YELLOW, "Passwords did not match.");
    }
}

void configure_accounts_menu(InstallerConfig& config) {
    print_header("Accounts");
    config.root_password = prompt_password_with_confirmation("Root password", config.root_password);

    config.user.create = prompt_yes_no("Create a regular user account?", config.user.create);
    if (!config.user.create) {
        config.user.username.clear();
        config.user.password.clear();
        config.user.autologin = false;
        return;
    }

    config.user.username = prompt_text("Username", config.user.username);
    config.user.password = prompt_password_with_confirmation("User password", config.user.password);
    config.user.sudo = prompt_yes_no("Grant sudo access to this user?", config.user.sudo);
    config.user.autologin = prompt_yes_no("Enable automatic graphical login for this user?", config.user.autologin);
}

void configure_bootloader_menu(InstallerConfig& config) {
    print_header("Bootloader");
    const int choice = prompt_choice(
        "Select bootloader handling:",
        {
            "Install GRUB automatically",
            "Skip bootloader installation"
        },
        config.bootloader == BootloaderChoice::Grub ? 0 : 1
    );
    config.bootloader = choice == 0 ? BootloaderChoice::Grub : BootloaderChoice::None;
}

void configure_profile_menu(InstallerConfig& config) {
    print_header("Install Profile");
    const int choice = prompt_choice(
        "Select the installation profile:",
        {
            "Minimal - conservative groups and no desktop assumptions",
            "Desktop - add desktop-friendly groups and allow autologin",
            "Developer - desktop groups plus developer-friendly access such as kvm"
        },
        config.profile == InstallProfile::Minimal ? 0 : (config.profile == InstallProfile::Desktop ? 1 : 2)
    );

    if (choice == 0) config.profile = InstallProfile::Minimal;
    if (choice == 1) config.profile = InstallProfile::Desktop;
    if (choice == 2) config.profile = InstallProfile::Developer;
}

void print_configuration_summary(const InstallerConfig& config) {
    std::cout << C_BOLD << "Current configuration" << C_RESET << "\n";
    std::cout << "  1. Partitioning:   " << partition_mode_label(config.partition_mode) << "\n";
    std::cout << "  2. Disk / Root:    " << (config.partition_mode == PartitionMode::AutoWipe ? config.disk : config.root_partition) << "\n";
    if (effective_boot_mode(config) == BootMode::Uefi) {
        std::cout << "  3. EFI Partition:  " << (config.partition_mode == PartitionMode::AutoWipe ? "(auto)" : config.efi_partition) << "\n";
    } else {
        std::cout << "  3. EFI Partition:  (not used)\n";
    }
    std::cout << "  4. Boot Mode:      " << boot_mode_label(config.boot_mode) << " -> " << boot_mode_label(effective_boot_mode(config)) << "\n";
    std::cout << "  5. Filesystem:     " << filesystem_label(config.filesystem) << "\n";
    std::cout << "  6. Swap:           " << swap_mode_label(config) << "\n";
    std::cout << "  7. Hostname:       " << config.hostname << "\n";
    std::cout << "  8. Timezone:       " << config.timezone << "\n";
    std::cout << "  9. Locale:         " << config.locale << "\n";
    std::cout << " 10. Keyboard:       " << config.keyboard_layout << "\n";
    std::cout << " 11. Root Password:  " << (config.root_password.empty() ? "not set" : "set") << "\n";
    std::cout << " 12. User Account:   ";
    if (!config.user.create) {
        std::cout << "disabled\n";
    } else {
        std::cout << config.user.username << " (sudo=" << (config.user.sudo ? "yes" : "no")
                  << ", autologin=" << (config.user.autologin ? "yes" : "no") << ")\n";
    }
    std::cout << " 13. Bootloader:     " << bootloader_label(config.bootloader) << "\n";
    std::cout << " 14. Profile:        " << profile_label(config.profile) << "\n";
}

}  // namespace

bool configure_installer(InstallerConfig& config, const ToolRegistry& tools) {
    while (true) {
        auto render_configuration_screen = [&config]() {
            print_header("Configuration");
            print_configuration_summary(config);
            std::cout << "\n";
        };
        const int choice = prompt_choice(
            "Select an option:",
            {
                "Partitioning mode and target disk / partitions",
                "Boot mode",
                "Filesystem",
                "Swap configuration",
                "System identity (hostname / timezone / locale / keyboard)",
                "Accounts",
                "Bootloader",
                "Install profile",
                "Review and begin installation",
                "Reset to defaults",
                "Quit installer"
            },
            8,
            {
                {"q", 10},
                {"quit", 10}
            },
            render_configuration_screen
        );

        if (choice == 0) configure_partitioning(config);
        if (choice == 1) configure_boot_mode_menu(config);
        if (choice == 2) configure_filesystem_menu(config, tools);
        if (choice == 3) configure_swap_menu(config);
        if (choice == 4) configure_identity_menu(config);
        if (choice == 5) configure_accounts_menu(config);
        if (choice == 6) configure_bootloader_menu(config);
        if (choice == 7) configure_profile_menu(config);

        if (choice == 8) {
            std::vector<std::string> warnings;
            std::vector<std::string> errors = validate_configuration(config, tools, warnings);

            print_header("Review");
            print_configuration_summary(config);
            std::cout << "\n";

            if (!errors.empty()) {
                print_notice("Error:", C_RED, "The installer configuration is not ready.");
                for (const auto& error : errors) {
                    std::cout << "  - " << error << "\n";
                }
                std::cout << "\nPress ENTER to return to configuration.";
                std::string unused;
                std::getline(std::cin, unused);
                continue;
            }

            if (!warnings.empty()) {
                print_notice("Warning:", C_YELLOW, "Review these warnings before continuing.");
                for (const auto& warning : warnings) {
                    std::cout << "  - " << warning << "\n";
                }
                std::cout << "\n";
            }

            std::cout << C_RED << C_BOLD << "This installation will make destructive changes to the selected target." << C_RESET << "\n";
            std::cout << "Type INSTALL to confirm: ";
            std::string confirm;
            std::getline(std::cin, confirm);
            if (to_upper(trim(confirm)) == "INSTALL") return true;
            print_notice("!", C_YELLOW, "Installation confirmation not accepted.");
        }

        if (choice == 9) {
            config = InstallerConfig{};
        }

        if (choice == 10) {
            return false;
        }
    }
}

}  // namespace installer
