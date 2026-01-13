#ifndef GSERVICE_MANAGER_HPP
#define GSERVICE_MANAGER_HPP

#include "gservice_parser.hpp"
#include <map>
#include <vector>
#include <string>
#include <memory>
#include <sys/types.h>

namespace ginit {

struct ServiceState {
    std::unique_ptr<GService> config;
    pid_t pid = -1;
    int restart_count = 0;
    bool enabled = false;
    bool running = false;
};

class GServiceManager {
public:
    GServiceManager();
    
    void load_services_from_dir(const std::string& dir);
    void start_service(const std::string& name);
    void stop_service(const std::string& name);
    void restart_service(const std::string& name);
    
    void start_enabled_services();
    
    // Process supervision
    void handle_process_death(pid_t pid, int status);
    bool is_managed_process(pid_t pid) const;

    // CLI Actions
    void print_status();
    void print_service_status(const std::string& name);

private:
    std::map<std::string, ServiceState> services;
    std::map<pid_t, std::string> pid_to_name;

    pid_t spawn_process(const GService& config);
    void setup_environment(const GService& config);
    void setup_security(const GService& config);
};

} // namespace ginit

#endif // GSERVICE_MANAGER_HPP
