#include "installer_common.h"

#include "sys_info.h"

#include <iostream>
#include <string>
#include <sys/reboot.h>
#include <unistd.h>

int main(int argc, char* argv[]) {
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "-v" || arg == "--verbose") installer::g_verbose = true;
    }

    installer::write_text_file(installer::kLogPath, "");

    installer::print_header("Welcome");
    std::cout << "Welcome to the " << OS_NAME << " installer.\n";
    std::cout << "This installer uses a reviewed configuration flow similar to modern guided installers.\n\n";
    std::cout << installer::C_YELLOW << installer::C_BOLD
              << "Warning: destructive actions are available and can erase the selected disk."
              << installer::C_RESET << "\n\n";

    if (geteuid() != 0) {
        installer::print_notice("Error:", installer::C_RED, "The installer must be run as root.");
        return 1;
    }

    const installer::ToolRegistry tools = installer::detect_tools();
    installer::print_environment_summary(tools);
    std::cout << "\nPress ENTER to continue or Ctrl+C to abort.";
    std::string unused;
    std::getline(std::cin, unused);

    installer::InstallerConfig config;
    if (!installer::configure_installer(config, tools)) {
        installer::print_notice("!", installer::C_YELLOW, "Installation cancelled by user.");
        return 0;
    }

    installer::print_header("Installing");
    std::cout << "Installing " << OS_NAME << " with the reviewed configuration.\n";
    std::cout << "Detailed command output is being written to " << installer::kLogPath << ".\n\n";

    std::string error;
    if (!installer::perform_install(tools, config, error)) {
        installer::print_notice("Error:", installer::C_RED, error.empty() ? "Installation failed." : error);
        std::cout << "\nReview " << installer::kLogPath << " for the failing command.\n";
        return 1;
    }

    installer::print_header("Complete");
    installer::print_notice("Success:", installer::C_GREEN, "Installation completed successfully.");
    std::cout << "Target root: " << installer::kTargetRoot << "\n";
    std::cout << "Log file:    " << installer::kLogPath << "\n\n";

    if (installer::prompt_yes_no("Reboot now?", true)) {
        ::sync();
        reboot(RB_AUTOBOOT);
        installer::print_notice("Warning:", installer::C_YELLOW, "Reboot request failed.");
        return 1;
    }

    return 0;
}
