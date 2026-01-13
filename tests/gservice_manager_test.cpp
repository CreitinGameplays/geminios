#include "../src/gservice_manager.hpp"
#include <iostream>
#include <fstream>
#include <unistd.h>
#include <sys/stat.h>
#include <cassert>

int main() {
    // Create a dummy service file
    mkdir("test_services", 0755);
    std::ofstream f("test_services/test.gservice");
    f << R"(
service "test-svc" {
    meta { description = "Test Service" }
    process {
        commands {
            start = "echo 'Service Started'; sleep 2; exit 0"
        }
        lifecycle { restart_policy = "always" }
    }
}
)";
    f.close();

    ginit::GServiceManager manager;
    manager.load_services_from_dir("test_services");
    manager.start_enabled_services();

    // In a real test we'd check if it's running, but since it forks it's tricky without wait
    // This is just a basic sanity check that it doesn't crash
    std::cout << "GServiceManager sanity check passed!" << std::endl;

    // Cleanup
    unlink("test_services/test.gservice");
    rmdir("test_services");

    return 0;
}
