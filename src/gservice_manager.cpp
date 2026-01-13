#include "gservice_manager.hpp"
#include <iostream>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <dirent.h>
#include <cstring>
#include <algorithm>

namespace ginit {

GServiceManager::GServiceManager() {}

void GServiceManager::load_services_from_dir(const std::string& dir) {
    DIR* d = opendir(dir.c_str());
    if (!d) return;

    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        std::string filename = entry->d_name;
        if (filename.size() > 9 && filename.substr(filename.size() - 9) == ".gservice") {
            auto config = GServiceParser::parse_file(dir + "/" + filename);
            if (config) {
                std::string name = config->name;
                services[name].config = std::move(config);
                services[name].enabled = true; // For now, auto-enable system services
                std::cout << "[GSERVICE] Loaded " << name << " from " << filename << std::endl;
            }
        }
    }
    closedir(d);
}

void GServiceManager::setup_environment(const GService& config) {
    // Set variables from config
    for (const auto& var : config.env.vars) {
        setenv(var.first.c_str(), var.second.c_str(), 1);
    }
    
    // Set working directory
    if (!config.process.work_dir.empty()) {
        if (chdir(config.process.work_dir.c_str()) != 0) {
            perror("chdir");
        }
    }
}

void GServiceManager::setup_security(const GService& config) {
    // Placeholder for security features (no_new_privileges, protect_system, etc.)
    // These require more complex system calls (prctl, mount namespaces)
}

pid_t GServiceManager::spawn_process(const GService& config) {
    pid_t pid = fork();
    if (pid == 0) {
        // Child process
        setup_environment(config);
        setup_security(config);
        
        // Execute start command
        std::string cmd = config.process.commands.start;
        // Simple command execution (splitting by space for now)
        // Ideally we'd use a more robust shell-like parser or gsh
        execl("/bin/sh", "sh", "-c", cmd.c_str(), nullptr);
        
        perror("exec /bin/sh");
        exit(1);
    }
    return pid;
}

void GServiceManager::start_service(const std::string& name) {
    if (services.find(name) == services.end()) return;
    auto& s = services[name];
    if (s.running) return;

    std::cout << "[GSERVICE] Starting " << name << "..." << std::endl;
    s.pid = spawn_process(*(s.config));
    if (s.pid > 0) {
        s.running = true;
        pid_to_name[s.pid] = name;
    }
}

void GServiceManager::start_enabled_services() {
    for (auto& pair : services) {
        if (pair.second.enabled && !pair.second.running) {
            start_service(pair.first);
        }
    }
}

void GServiceManager::handle_process_death(pid_t pid, int status) {
    if (pid_to_name.find(pid) == pid_to_name.end()) return;

    std::string name = pid_to_name[pid];
    auto& s = services[name];
    s.running = false;
    pid_to_name.erase(pid);

    std::cout << "[GSERVICE] Service " << name << " (pid " << pid << ") exited with status " << status << std::endl;

    // Restart policy check
    if (s.config->process.lifecycle.restart_policy == "on-failure") {
        if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
            start_service(name);
        } else if (WIFSIGNALED(status)) {
            start_service(name);
        }
    } else if (s.config->process.lifecycle.restart_policy == "always") {
        start_service(name);
    }
}

bool GServiceManager::is_managed_process(pid_t pid) const {
    return pid_to_name.find(pid) != pid_to_name.end();
}

void GServiceManager::print_status() {
    std::cout << "Ginit Service Status:" << std::endl;
    std::cout << "---------------------------------------------------" << std::endl;
    for (const auto& pair : services) {
        const auto& s = pair.second;
        std::cout << (s.running ? "[ RUNNING ] " : "[ STOPPED ] ") 
                  << pair.first << " (PID: " << (s.running ? std::to_string(s.pid) : "-") << ")" << std::endl;
        std::cout << "   Description: " << s.config->meta.description << std::endl;
    }
}

} // namespace ginit
