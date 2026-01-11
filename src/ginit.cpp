#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/reboot.h>
#include <sys/sysinfo.h>
#include <sys/utsname.h>
#include <dirent.h>
#include <cstring>
#include <algorithm>
#include <sstream>
#include <fstream>
#include <csignal>
#include <sys/wait.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include "network.h"
#include "debug.h"
#include "signals.h"
#include "sys_info.h"
#include "user_mgmt.h"

// Mount filesystems and ensure target directory exists
void mount_fs(const char* source, const char* target, const char* fs_type) {
    mkdir(target, 0755);
    if (mount(source, target, fs_type, 0, NULL) == 0) {
        std::cout << "[OK] Mounted " << target << std::endl;
    } else {
        if (errno == EBUSY) {
            std::cout << "[OK] " << target << " already mounted" << std::endl;
        } else {
            perror((std::string("[ERR] Failed to mount ") + target).c_str());
        }
    }
}

// Ensure FHS directory structure exists
void ensure_fhs() {
    const char* dirs[] = {
        "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/media", 
        "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", 
        "/sys", "/tmp", "/usr", "/usr/bin", "/usr/lib", "/usr/lib/locale", "/usr/lib/gconv", "/usr/local", 
        "/usr/share", "/var", "/var/log", "/var/tmp", "/var/repo",
        "/usr/share/X11", "/usr/share/X11/xkb", "/usr/share/X11/xkb/compiled"
    };
    
    for (const char* d : dirs) {
        mkdir(d, 0755);
    }
    
    chmod("/tmp", 01777);
    chmod("/var/tmp", 01777);
    chmod("/root", 0700);
}

// Generate system information files for other applications (like neofetch, gemfetch)
void generate_os_release() {
    std::ofstream f("/etc/os-release");
    if (f) {
        f << "NAME=\"" << OS_NAME << "\"\n";
        f << "VERSION=\"" << OS_VERSION << " (" << OS_CODENAME << ")\"\n";
        f << "ID=" << OS_ID << "\n";
        f << "ID_LIKE=" << OS_ID_LIKE << "\n";
        f << "PRETTY_NAME=\"" << OS_NAME << " " << OS_VERSION << " (" << OS_CODENAME << ")\"\n";
        f << "VERSION_ID=\"" << OS_VERSION << "\"\n";
        f << "VERSION_CODENAME=" << OS_CODENAME << "\n";
        f << "ANSI_COLOR=\"" << OS_ANSI_COLOR << "\"\n";
        f << "HOME_URL=\"https://github.com/CreitinGameplays/geminios\"\n";
        f << "SUPPORT_URL=\"https://github.com/CreitinGameplays/geminios/issues\"\n";
        f << "BUG_REPORT_URL=\"https://github.com/CreitinGameplays/geminios/issues\"\n";
        f.close();
        std::cout << "[GINIT] Generated /etc/os-release" << std::endl;
    }

    std::ofstream lsb("/etc/lsb-release");
    if (lsb) {
        lsb << "DISTRIB_ID=" << OS_NAME << "\n";
        lsb << "DISTRIB_RELEASE=" << OS_VERSION << "\n";
        lsb << "DISTRIB_CODENAME=" << OS_CODENAME << "\n";
        lsb << "DISTRIB_DESCRIPTION=\"" << OS_NAME << " " << OS_VERSION << " (" << OS_CODENAME << ")\"\n";
        lsb.close();
        std::cout << "[GINIT] Generated /etc/lsb-release" << std::endl;
    }

    if (access("/etc/hostname", F_OK) == -1) {
        std::ofstream hn("/etc/hostname");
        if (hn) {
            hn << "geminios-pc\n";
            hn.close();
            sethostname("geminios-pc", 11);
            std::cout << "[GINIT] Set hostname to geminios-pc" << std::endl;
        }
    } else {
        std::ifstream hn("/etc/hostname");
        std::string name;
        if (hn >> name) sethostname(name.c_str(), name.length());
    }

    std::ofstream issue("/etc/issue");
    if (issue) {
        issue << OS_NAME << " " << OS_VERSION << " (" << OS_CODENAME << ") \n \l\n\n";
        issue.close();
    }
}

// Map to track TTY Supervisor PIDs: PID -> TTY Device Path
std::map<pid_t, std::string> g_tty_pids;

pid_t spawn_getty(const std::string& tty) {
    pid_t pid = fork();
    if (pid == 0) {
        // Child: Exec getty
        char* const argv[] = { (char*)"/sbin/getty", (char*)tty.c_str(), nullptr };
        execv("/sbin/getty", argv);
        perror("execv /sbin/getty");
        exit(1);
    }
    return pid;
}

int main(int argc, char* argv[]) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    if (getpid() != 1) {
        std::cerr << "ginit must be run as PID 1" << std::endl;
        return 1;
    }

    // Setup basic environment
    setenv("PATH", "/bin/apps/system:/bin/apps:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin", 1);
    
    std::cout << "\033[2J\033[1;1H"; 
    std::cout << "Welcome to " << OS_NAME << " " << OS_VERSION << std::endl;     
    
    ConfigureNetwork();
    
mount_fs("none", "/proc", "proc");
mount_fs("none", "/sys", "sysfs");
mount_fs("devtmpfs", "/dev", "devtmpfs");
mount_fs("devpts", "/dev/pts", "devpts");
mount_fs("tmpfs", "/dev/shm", "tmpfs");
mount_fs("tmpfs", "/tmp", "tmpfs");
mount_fs("tmpfs", "/run", "tmpfs");
mount_fs("tmpfs", "/var/log", "tmpfs");
mount_fs("tmpfs", "/var/tmp", "tmpfs");
mount_fs("tmpfs", "/usr/share/X11/xkb/compiled", "tmpfs");

    if (fork() == 0) {
        execl("/usr/sbin/udevd", "udevd", "--daemon", nullptr);
        exit(0);
    }
    system("/usr/bin/udevadm trigger --action=add");
    system("/usr/bin/udevadm settle");
    
    ensure_fhs();

    mkdir("/var/lib/dbus", 0755);
    system("/usr/bin/dbus-uuidgen --ensure");
    mkdir("/run/dbus", 0755);
    if (fork() == 0) {
        execl("/usr/bin/dbus-daemon", "dbus-daemon", "--system", "--nofork", "--nopidfile", nullptr);
        exit(0);
    }

    symlink("/proc/self/fd", "/dev/fd");
    symlink("/proc/self/fd/0", "/dev/stdin");
    symlink("/proc/self/fd/1", "/dev/stdout");
    symlink("/proc/self/fd/2", "/dev/stderr");

    UserMgmt::initialize_defaults();
    generate_os_release();

    std::vector<std::string> terminals = {"/dev/tty1", "/dev/tty2", "/dev/tty3", "/dev/ttyS0"};
    
    for (const auto& tty : terminals) {
        pid_t pid = spawn_getty(tty);
        if (pid > 0) g_tty_pids[pid] = tty;
    }

    // Supervisor Loop: Reap and respawn processes
    while (true) {
        int status;
        pid_t pid = wait(&status);

        if (pid > 0) {
            auto it = g_tty_pids.find(pid);
            if (it != g_tty_pids.end()) {
                std::string tty = it->second;
                g_tty_pids.erase(it);
                
                std::cerr << "[GINIT] TTY " << tty << " respawning..." << std::endl;
                
                pid_t new_pid = spawn_getty(tty);
                if (new_pid > 0) {
                    g_tty_pids[new_pid] = tty;
                }
            } else {
                // Not a tracked getty. Might be a service (udevd, dbus-daemon).
                // In a more complete init, we would track these too.
            }
        }
    }
}