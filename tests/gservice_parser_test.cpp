#include "../src/gservice_parser.hpp"
#include <iostream>
#include <cassert>

int main() {
    std::string content = R"(
service "dummy-app" {
    // Metadata and Dependencies (single line comment)
    meta {
        description = "Dummy High-Performance Backend Application"
        docs = "https://dummy-app.com/docs"
        
        // Dependency chain
        deps {
            after    = ["network-online.target", "postgresql.service"]
            wants    = ["redis.service"]
            requires = ["postgresql.service"]
        }
    }

    // Main Service Logic
    process {
        type = "notify"
        user = "dummy-user"
        group = "dummy-group"
        work_dir = "/opt/dummy-app"

        commands {
            start_pre = "/opt/dummy-app/bin/cleanup.sh"
            start     = "/opt/dummy-app/bin/server --config /etc/dummy.conf"
            reload    = "/bin/kill -HUP $MAINPID"
            stop      = "/opt/dummy-app/bin/shutdown.sh"
        }

        lifecycle {
            restart_policy = "on-failure"
            restart_delay  = "5s"
            stop_timeout   = "10s"
        }
    }

    // Environment Configuration
    env {
        load_file = "/etc/default/dummy-app"
        vars = {
            NODE_ENV = "production"
            PORT     = 8080
        }
    }

    // Security Sandbox
    security {
        no_new_privileges = true
        protect_system    = "full"
        protect_home      = true
        private_tmp       = true
        rw_paths          = ["/var/log/dummy-app", "/run/dummy-app"]
    }

    // Resource Constraints
    resources {
        ulimit_nofile = 65536
        memory_max    = "1G"
        cpu_quota     = "50%"
    }

    // Installation Targets
    install {
        wanted_by = ["multi-user.target"]
        alias     = "dummy.service"
    }
}
)";

    auto service = ginit::GServiceParser::parse_string(content);

    assert(service != nullptr);
    assert(service->name == "dummy-app");
    assert(service->meta.description == "Dummy High-Performance Backend Application");
    assert(service->meta.deps.after.size() == 2);
    assert(service->meta.deps.after[0] == "network-online.target");
    assert(service->process.user == "dummy-user");
    assert(service->process.commands.start == "/opt/dummy-app/bin/server --config /etc/dummy.conf");
    assert(service->env.vars["NODE_ENV"] == "production");
    assert(service->env.vars["PORT"] == "8080");
    assert(service->security.no_new_privileges == true);
    assert(service->security.rw_paths.size() == 2);
    assert(service->resources.ulimit_nofile == 65536);
    assert(service->install.alias == "dummy.service");

    std::cout << "GServiceParser test passed!" << std::endl;

    return 0;
}
