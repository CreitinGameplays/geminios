#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <csignal>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/statvfs.h>
#include <sys/sysinfo.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>
#include <vector>
#include "sys_info.h"

// ANSI Colors
#define CLR_RESET "\033[0m"
#define CLR_BOLD "\033[1m"
#define CLR_RED "\033[31m"
#define CLR_GREEN "\033[32m"
#define CLR_YELLOW "\033[33m"
#define CLR_BLUE "\033[34m"
#define CLR_MAGENTA "\033[35m"
#define CLR_CYAN "\033[36m"
#define CLR_WHITE "\033[37m"
#define CLR_HEADER "\033[30;47m" // Black text on White bg
#define CLR_SELECTED "\033[44;37m" // White text on Blue bg
#define CLR_EOL "\033[K"

volatile bool g_running = true;
std::map<int, std::string> g_user_map;
bool g_advanced = false;
int g_delay_ms = 1000;
int g_selected_index = 0;
int g_scroll_offset = 0;

struct termios orig_termios;

void disable_raw_mode() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios);
    std::cout << "\033[?25h"; // Show cursor
}

void enable_raw_mode() {
    tcgetattr(STDIN_FILENO, &orig_termios);
    atexit(disable_raw_mode);
    struct termios raw = orig_termios;
    raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_cflag |= (CS8);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    std::cout << "\033[?25l"; // Hide cursor
}

void handle_sig(int) {
    g_running = false;
}

struct ProcSnapshot {
    int pid;
    std::string name;
    char state;
    unsigned long long total_time; // utime + stime
    long rss;                      // in pages
    int uid;
};

struct SystemSnapshot {
    unsigned long long total_cpu_time;
    unsigned long long idle_cpu_time;
    std::map<int, ProcSnapshot> processes;
    std::vector<unsigned long long> core_total_time;
    std::vector<unsigned long long> core_idle_time;
};

struct CpuFrequencyInfo {
    std::vector<double> current_mhz;
    double average_mhz = 0.0;
    double max_mhz = 0.0;
    bool has_current = false;
    bool has_max = false;
};

struct TemperatureReading {
    double celsius = 0.0;
    std::string label;
    bool available = false;
};

struct GpuMemoryInfo {
    std::string label;
    unsigned long long total_bytes = 0;
    unsigned long long used_bytes = 0;
    bool available = false;
};

struct GpuInfo {
    std::string model = "Unknown GPU";
    std::string driver = "n/a";
    GpuMemoryInfo memory;
    int busy_percent = -1;
    bool available = false;
};

struct LoadAverage {
    double one = 0.0;
    double five = 0.0;
    double fifteen = 0.0;
};

std::string trim_copy(const std::string& input) {
    size_t start = input.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return "";
    size_t end = input.find_last_not_of(" \t\r\n");
    return input.substr(start, end - start + 1);
}

std::string to_lower_copy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

bool starts_with(const std::string& value, const std::string& prefix) {
    return value.rfind(prefix, 0) == 0;
}

bool ends_with(const std::string& value, const std::string& suffix) {
    return value.size() >= suffix.size() &&
           value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool is_all_digits(const std::string& value) {
    return !value.empty() && std::all_of(value.begin(), value.end(), [](unsigned char ch) {
        return std::isdigit(ch);
    });
}

bool contains_icase(const std::string& haystack, const std::string& needle) {
    return to_lower_copy(haystack).find(to_lower_copy(needle)) != std::string::npos;
}

std::string read_first_line(const std::string& path) {
    std::ifstream f(path);
    std::string line;
    std::getline(f, line);
    return trim_copy(line);
}

bool read_long_file(const std::string& path, long& value) {
    std::ifstream f(path);
    return static_cast<bool>(f >> value);
}

bool read_ull_file(const std::string& path, unsigned long long& value) {
    std::ifstream f(path);
    return static_cast<bool>(f >> value);
}

double safe_percentage(double used, double total) {
    return total > 0.0 ? (used * 100.0 / total) : 0.0;
}

std::string format_uptime(long seconds) {
    long days = seconds / 86400;
    seconds %= 86400;
    long hours = seconds / 3600;
    seconds %= 3600;
    long minutes = seconds / 60;
    long secs = seconds % 60;

    std::ostringstream oss;
    if (days > 0) {
        oss << days << "d " << std::setw(2) << std::setfill('0') << hours << "h "
            << std::setw(2) << minutes << "m";
    } else if (hours > 0) {
        oss << hours << "h " << std::setw(2) << std::setfill('0') << minutes << "m "
            << std::setw(2) << secs << "s";
    } else {
        oss << minutes << "m " << std::setw(2) << std::setfill('0') << secs << "s";
    }
    return oss.str();
}

std::string format_frequency_mhz(double mhz) {
    if (mhz <= 0.0) return "n/a";
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(0) << mhz << " MHz";
    return oss.str();
}

std::string format_bytes(unsigned long long bytes) {
    static const std::array<const char*, 5> units = {"B", "KiB", "MiB", "GiB", "TiB"};
    double value = static_cast<double>(bytes);
    size_t unit_index = 0;
    while (value >= 1024.0 && unit_index + 1 < units.size()) {
        value /= 1024.0;
        ++unit_index;
    }

    std::ostringstream oss;
    if (unit_index == 0) {
        oss << static_cast<unsigned long long>(value) << ' ' << units[unit_index];
    } else {
        oss << std::fixed << std::setprecision(1) << value << ' ' << units[unit_index];
    }
    return oss.str();
}

std::string format_meminfo_kib(long kib) {
    if (kib <= 0) return "0 B";
    return format_bytes(static_cast<unsigned long long>(kib) * 1024ULL);
}

std::string format_temperature(const TemperatureReading& reading) {
    if (!reading.available) return "n/a";
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(1) << reading.celsius << " C";
    if (!reading.label.empty()) oss << " (" << reading.label << ")";
    return oss.str();
}

std::string truncate_string(const std::string& value, size_t max_len) {
    if (value.size() <= max_len) return value;
    if (max_len <= 1) return value.substr(0, max_len);
    return value.substr(0, max_len - 1) + "~";
}

void get_system_cpu_times(unsigned long long& total, unsigned long long& idle_total) {
    total = 0;
    idle_total = 0;

    std::ifstream f("/proc/stat");
    std::string line;
    if (!std::getline(f, line)) return;

    std::istringstream iss(line);
    std::string cpu;
    unsigned long long user = 0, nice = 0, system = 0, idle = 0, iowait = 0, irq = 0, softirq = 0, steal = 0;
    iss >> cpu >> user >> nice >> system >> idle >> iowait >> irq >> softirq >> steal;
    total = user + nice + system + idle + iowait + irq + softirq + steal;
    idle_total = idle + iowait;
}

// Load /etc/passwd
void load_user_map() {
    std::ifstream f("/etc/passwd");
    if (!f) return;
    std::string line;
    while(std::getline(f, line)) {
        std::stringstream ss(line);
        std::string segment;
        std::vector<std::string> parts;
        while(std::getline(ss, segment, ':')) parts.push_back(segment);
        if(parts.size() >= 3) {
            try {
                g_user_map[std::stoi(parts[2])] = parts[0];
            } catch(...) {}
        }
    }
}

int get_proc_uid(int pid) {
    std::ifstream f("/proc/" + std::to_string(pid) + "/status");
    if (!f) return 0;
    std::string line;
    while(std::getline(f, line)) {
        if(line.find("Uid:") == 0) {
            std::stringstream ss(line.substr(4));
            int u; ss >> u; return u;
        }
    }
    return 0;
}

void get_core_times(std::vector<unsigned long long>& totals, std::vector<unsigned long long>& idles) {
    std::ifstream f("/proc/stat");
    std::string line;
    totals.clear();
    idles.clear();
    while (std::getline(f, line)) {
        if (line.compare(0, 3, "cpu") == 0 && std::isdigit(static_cast<unsigned char>(line[3]))) {
            std::istringstream iss(line);
            std::string cpu;
            iss >> cpu;
            unsigned long long user, nice, system, idle, iowait, irq, softirq, steal;
            iss >> user >> nice >> system >> idle >> iowait >> irq >> softirq >> steal;
            totals.push_back(user + nice + system + idle + iowait + irq + softirq + steal);
            idles.push_back(idle + iowait);
        }
    }
}

std::map<int, ProcSnapshot> get_processes() {
    std::map<int, ProcSnapshot> procs;
    DIR* dir = opendir("/proc");
    if (!dir) return procs;

    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!isdigit(entry->d_name[0])) continue;
        int pid = std::stoi(entry->d_name);

        std::string stat_path = std::string("/proc/") + entry->d_name + "/stat";
        std::ifstream f(stat_path);
        if (!f) continue;

        std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        size_t last_paren = content.find_last_of(')');
        if (last_paren == std::string::npos) continue;

        ProcSnapshot p;
        p.pid = pid;
        p.name = content.substr(content.find('(') + 1, last_paren - content.find('(') - 1);
        p.uid = get_proc_uid(pid);

        std::istringstream iss(content.substr(last_paren + 2));
        iss >> p.state;

        std::string dummy_str;
        for (int i = 0; i < 10; ++i) iss >> dummy_str;
        unsigned long utime, stime;
        iss >> utime >> stime;
        p.total_time = utime + stime;

        for (int i = 0; i < 8; ++i) iss >> dummy_str;
        iss >> p.rss;
        procs[pid] = p;
    }
    closedir(dir);
    return procs;
}

std::string get_cpu_model() {
    std::ifstream f("/proc/cpuinfo");
    std::string line;
    while (std::getline(f, line)) {
        if (line.find("model name") != std::string::npos || line.find("Hardware") != std::string::npos) {
            size_t pos = line.find(':');
            if (pos != std::string::npos) return trim_copy(line.substr(pos + 1));
        }
    }
    return "Unknown CPU";
}

std::map<int, double> get_cpuinfo_current_mhz() {
    std::ifstream f("/proc/cpuinfo");
    std::string line;
    std::map<int, double> result;
    int current_cpu = -1;

    while (std::getline(f, line)) {
        if (starts_with(line, "processor")) {
            size_t pos = line.find(':');
            if (pos == std::string::npos) continue;
            try {
                current_cpu = std::stoi(trim_copy(line.substr(pos + 1)));
            } catch (...) {
                current_cpu = -1;
            }
        } else if (starts_with(line, "cpu MHz") && current_cpu >= 0) {
            size_t pos = line.find(':');
            if (pos == std::string::npos) continue;
            try {
                result[current_cpu] = std::stod(trim_copy(line.substr(pos + 1)));
            } catch (...) {}
        }
    }

    return result;
}

bool read_cpu_freq_mhz_from_sysfs(int core, const std::string& leaf, double& mhz) {
    const std::array<std::string, 2> paths = {
        "/sys/devices/system/cpu/cpu" + std::to_string(core) + "/cpufreq/" + leaf,
        "/sys/devices/system/cpu/cpufreq/policy" + std::to_string(core) + "/" + leaf
    };

    for (const auto& path : paths) {
        long value = 0;
        if (read_long_file(path, value) && value > 0) {
            mhz = static_cast<double>(value) / 1000.0;
            return true;
        }
    }
    return false;
}

CpuFrequencyInfo get_cpu_frequency_info(size_t core_count) {
    CpuFrequencyInfo info;
    info.current_mhz.assign(core_count, -1.0);

    auto cpuinfo_mhz = get_cpuinfo_current_mhz();
    double mhz_sum = 0.0;
    int mhz_count = 0;

    for (size_t core = 0; core < core_count; ++core) {
        double mhz = 0.0;
        if (read_cpu_freq_mhz_from_sysfs(static_cast<int>(core), "scaling_cur_freq", mhz) ||
            read_cpu_freq_mhz_from_sysfs(static_cast<int>(core), "cpuinfo_cur_freq", mhz) ||
            cpuinfo_mhz.count(static_cast<int>(core))) {
            if (!mhz && cpuinfo_mhz.count(static_cast<int>(core))) {
                mhz = cpuinfo_mhz[static_cast<int>(core)];
            }
            info.current_mhz[core] = mhz;
            if (mhz > 0.0) {
                mhz_sum += mhz;
                ++mhz_count;
                info.has_current = true;
            }
        }
    }

    if (mhz_count > 0) info.average_mhz = mhz_sum / mhz_count;

    for (size_t core = 0; core < core_count; ++core) {
        double mhz = 0.0;
        if (read_cpu_freq_mhz_from_sysfs(static_cast<int>(core), "cpuinfo_max_freq", mhz) ||
            read_cpu_freq_mhz_from_sysfs(static_cast<int>(core), "scaling_max_freq", mhz)) {
            info.max_mhz = std::max(info.max_mhz, mhz);
            info.has_max = info.max_mhz > 0.0;
        }
    }

    if (!info.has_max && info.has_current) {
        info.max_mhz = *std::max_element(info.current_mhz.begin(), info.current_mhz.end());
        info.has_max = info.max_mhz > 0.0;
    }

    return info;
}

bool parse_temperature_file(const std::string& path, double& celsius) {
    long raw = 0;
    if (!read_long_file(path, raw)) return false;

    if (raw < -40000 || raw > 150000) return false;
    celsius = (raw > 1000 || raw < -1000) ? (static_cast<double>(raw) / 1000.0) : static_cast<double>(raw);
    return celsius >= -40.0 && celsius <= 150.0;
}

int score_temperature_source(const std::string& source, const std::string& label) {
    std::string combined = to_lower_copy(source + " " + label);
    if (combined.find("gpu") != std::string::npos ||
        combined.find("pch") != std::string::npos ||
        combined.find("nvme") != std::string::npos ||
        combined.find("wifi") != std::string::npos ||
        combined.find("iwlwifi") != std::string::npos ||
        combined.find("battery") != std::string::npos) {
        return -1000;
    }

    int score = 0;
    if (combined.find("coretemp") != std::string::npos ||
        combined.find("k10temp") != std::string::npos ||
        combined.find("zenpower") != std::string::npos ||
        combined.find("cpu_thermal") != std::string::npos ||
        combined.find("x86_pkg_temp") != std::string::npos) {
        score += 100;
    }
    if (combined.find("package") != std::string::npos ||
        combined.find("tdie") != std::string::npos ||
        combined.find("tctl") != std::string::npos) {
        score += 60;
    }
    if (combined.find("cpu") != std::string::npos) score += 40;
    if (combined.find("soc") != std::string::npos) score += 20;
    if (combined.find("core") != std::string::npos) score += 10;
    if (combined.find("acpitz") != std::string::npos) score += 5;
    return score;
}

TemperatureReading get_cpu_temperature() {
    TemperatureReading best;
    int best_score = -1001;

    DIR* hwmon_dir = opendir("/sys/class/hwmon");
    if (hwmon_dir) {
        struct dirent* hwmon_entry;
        while ((hwmon_entry = readdir(hwmon_dir)) != NULL) {
            std::string hwmon_name = hwmon_entry->d_name;
            if (!starts_with(hwmon_name, "hwmon")) continue;

            std::string base = "/sys/class/hwmon/" + hwmon_name;
            std::string source_name = read_first_line(base + "/name");

            DIR* sensor_dir = opendir(base.c_str());
            if (!sensor_dir) continue;

            struct dirent* sensor_entry;
            while ((sensor_entry = readdir(sensor_dir)) != NULL) {
                std::string file_name = sensor_entry->d_name;
                if (!starts_with(file_name, "temp") || !ends_with(file_name, "_input")) continue;

                std::string sensor_prefix = file_name.substr(0, file_name.size() - 6);
                double celsius = 0.0;
                if (!parse_temperature_file(base + "/" + file_name, celsius)) continue;

                std::string label = read_first_line(base + "/" + sensor_prefix + "_label");
                int score = score_temperature_source(source_name, label);
                if (score <= -1000 || score < best_score) continue;

                best.available = true;
                best.celsius = celsius;
                best.label = label.empty() ? source_name : label;
                best_score = score;
            }
            closedir(sensor_dir);
        }
        closedir(hwmon_dir);
    }

    DIR* thermal_dir = opendir("/sys/class/thermal");
    if (thermal_dir) {
        struct dirent* thermal_entry;
        while ((thermal_entry = readdir(thermal_dir)) != NULL) {
            std::string zone_name = thermal_entry->d_name;
            if (!starts_with(zone_name, "thermal_zone")) continue;

            std::string base = "/sys/class/thermal/" + zone_name;
            std::string zone_type = read_first_line(base + "/type");
            double celsius = 0.0;
            if (!parse_temperature_file(base + "/temp", celsius)) continue;

            int score = score_temperature_source(zone_type, "");
            if (score <= -1000 || score < best_score) continue;

            best.available = true;
            best.celsius = celsius;
            best.label = zone_type;
            best_score = score;
        }
        closedir(thermal_dir);
    }

    return best;
}

LoadAverage get_load_average() {
    LoadAverage avg;
    std::ifstream f("/proc/loadavg");
    f >> avg.one >> avg.five >> avg.fifteen;
    return avg;
}

bool is_drm_card_entry(const std::string& name) {
    return starts_with(name, "card") && is_all_digits(name.substr(4));
}

std::string get_primary_drm_card_path() {
    DIR* drm_dir = opendir("/sys/class/drm");
    if (!drm_dir) return "";

    std::string best_path;
    struct dirent* entry;
    while ((entry = readdir(drm_dir)) != NULL) {
        std::string name = entry->d_name;
        if (!is_drm_card_entry(name)) continue;

        std::string path = "/sys/class/drm/" + name;
        if (!read_first_line(path + "/device/vendor").empty()) {
            best_path = path;
            break;
        }
    }

    closedir(drm_dir);
    return best_path;
}

std::string get_gpu_vendor_name(const std::string& vendor_id) {
    std::string value = to_lower_copy(vendor_id);
    if (value == "0x1002") return "AMD";
    if (value == "0x10de") return "NVIDIA";
    if (value == "0x8086") return "Intel";
    if (value == "0x1af4") return "Virtio";
    if (value == "0x1234") return "QEMU";
    if (value == "0x15ad") return "VMware";
    return "GPU";
}

GpuInfo get_gpu_info() {
    GpuInfo info;
    std::string card_path = get_primary_drm_card_path();
    if (card_path.empty()) return info;

    std::string vendor = read_first_line(card_path + "/device/vendor");
    std::string device = read_first_line(card_path + "/device/device");
    std::string driver = read_first_line(card_path + "/device/driver/module/drivers");
    if (driver.empty()) {
        char link_target[512];
        ssize_t len = readlink((card_path + "/device/driver").c_str(), link_target, sizeof(link_target) - 1);
        if (len > 0) {
            link_target[len] = '\0';
            std::string link = link_target;
            size_t slash = link.find_last_of('/');
            if (slash != std::string::npos) driver = link.substr(slash + 1);
        }
    }

    std::string vendor_name = get_gpu_vendor_name(vendor);
    std::ostringstream model;
    model << vendor_name;
    if (!driver.empty()) model << ' ' << driver;
    if (!vendor.empty() || !device.empty()) {
        model << " [" << (vendor.empty() ? "?" : vendor) << ":" << (device.empty() ? "?" : device) << "]";
    }

    info.model = model.str();
    info.driver = driver.empty() ? "n/a" : driver;
    info.available = true;

    struct MemoryCandidate {
        const char* label;
        const char* total_file;
        const char* used_file;
    };
    const std::array<MemoryCandidate, 3> candidates = {{
        {"VRAM", "mem_info_vram_total", "mem_info_vram_used"},
        {"Visible VRAM", "mem_info_vis_vram_total", "mem_info_vis_vram_used"},
        {"GTT", "mem_info_gtt_total", "mem_info_gtt_used"}
    }};

    for (const auto& candidate : candidates) {
        unsigned long long total = 0;
        unsigned long long used = 0;
        if (read_ull_file(card_path + "/device/" + candidate.total_file, total) &&
            read_ull_file(card_path + "/device/" + candidate.used_file, used) &&
            total > 0) {
            info.memory.available = true;
            info.memory.label = candidate.label;
            info.memory.total_bytes = total;
            info.memory.used_bytes = used;
            break;
        }
    }

    long busy = 0;
    if (read_long_file(card_path + "/device/gpu_busy_percent", busy) && busy >= 0) {
        info.busy_percent = static_cast<int>(busy);
    }

    return info;
}

void get_mem_info(long &total, long &used, long &free, long &avail, long &s_total, long &s_free) {
    std::ifstream f("/proc/meminfo");
    std::string line, key;
    long val;
    total = used = free = avail = s_total = s_free = 0;
    while (f >> key >> val >> line) {
        if (key == "MemTotal:") total = val;
        else if (key == "MemFree:") free = val;
        else if (key == "MemAvailable:") avail = val;
        else if (key == "SwapTotal:") s_total = val;
        else if (key == "SwapFree:") s_free = val;
    }
    used = total - avail;
}

void get_net_usage(unsigned long long &rx, unsigned long long &tx) {
    std::ifstream f("/proc/net/dev");
    std::string line;
    rx = tx = 0;
    std::getline(f, line); // header
    std::getline(f, line); // header
    while (std::getline(f, line)) {
        size_t colon = line.find(':');
        if (colon == std::string::npos) continue;
        std::string iface = line.substr(0, colon);
        iface.erase(0, iface.find_first_not_of(" "));
        if (iface == "lo") continue;
        std::istringstream iss(line.substr(colon + 1));
        unsigned long long r_bytes, r_pkt, r_err, r_drp, r_fifo, r_frame, r_comp, r_multi;
        unsigned long long t_bytes;
        iss >> r_bytes >> r_pkt >> r_err >> r_drp >> r_fifo >> r_frame >> r_comp >> r_multi >> t_bytes;
        rx += r_bytes;
        tx += t_bytes;
    }
}

void get_disk_usage(double &total, double &used) {
    struct statvfs vfs;
    if (statvfs("/", &vfs) == 0) {
        total = (double)vfs.f_blocks * vfs.f_frsize / (1024.0 * 1024.0 * 1024.0);
        used = (double)(vfs.f_blocks - vfs.f_bfree) * vfs.f_frsize / (1024.0 * 1024.0 * 1024.0);
    } else {
        total = used = 0;
    }
}

std::string draw_bar(double percentage, int width) {
    int filled = (int)(percentage * width / 100.0);
    if (filled < 0) filled = 0;
    if (filled > width) filled = width;
    
    std::string bar = std::string(CLR_WHITE) + "[" + CLR_RESET;
    if (percentage > 80) bar += CLR_RED;
    else if (percentage > 50) bar += CLR_YELLOW;
    else bar += CLR_GREEN;

    for (int i = 0; i < width; ++i) {
        if (i < filled) bar += "|";
        else bar += " ";
    }
    bar += std::string(CLR_RESET) + CLR_WHITE + "]" + CLR_RESET + " " + std::to_string((int)percentage) + "%";
    return bar;
}

struct ProcDisplay {
    int pid;
    std::string name;
    char state;
    std::string user;
    double cpu_usage;
    double mem_usage_mb;
};

int get_terminal_height() {
    struct winsize w;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == -1) return 24;
    return w.ws_row;
}

int main(int argc, char* argv[]) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            std::cout << "Usage: gtop [options]\nOptions:\n  -h, --help      Show this help\n  -v, --version   Show version\n  -adv, --advanced Enable advanced display mode\n  -d, --delay MS   Set update delay in milliseconds\n";
            return 0;
        }
        if (arg == "--version" || arg == "-v") {
            std::cout << "gtop (" << OS_NAME << ") " << OS_VERSION << std::endl;
            return 0;
        }
        if (arg == "-adv" || arg == "--advanced") g_advanced = true;
        if ((arg == "-d" || arg == "--delay") && i + 1 < argc) g_delay_ms = std::stoi(argv[++i]);
    }

    signal(SIGINT, handle_sig);
    enable_raw_mode();
    long page_size = sysconf(_SC_PAGESIZE);
    int num_procs_conf = get_nprocs_conf();
    std::string cpu_model = get_cpu_model();
    load_user_map();

    SystemSnapshot prev, curr;
    get_system_cpu_times(prev.total_cpu_time, prev.idle_cpu_time);
    prev.processes = get_processes();
    get_core_times(prev.core_total_time, prev.core_idle_time);
    
    unsigned long long prev_rx, prev_tx, curr_rx, curr_tx;
    get_net_usage(prev_rx, prev_tx);
    curr_rx = prev_rx; curr_tx = prev_tx;

    std::vector<ProcDisplay> display_list;
    CpuFrequencyInfo cpu_freq_info;
    TemperatureReading cpu_temp_info;
    GpuInfo gpu_info;
    LoadAverage load_avg;
    double total_cpu_usage = 0.0;
    double rx_rate_kib = 0.0;
    double tx_rate_kib = 0.0;
    bool have_usage_window = false;
    bool needs_redraw = true;
    auto last_update_time = std::chrono::steady_clock::now();

    while (g_running) {
        auto now = std::chrono::steady_clock::now();
        auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_update_time).count();

        if (elapsed_ms >= g_delay_ms || display_list.empty()) {
            bool is_initial_sample = display_list.empty();
            get_system_cpu_times(curr.total_cpu_time, curr.idle_cpu_time);
            curr.processes = get_processes();
            get_core_times(curr.core_total_time, curr.core_idle_time);
            get_net_usage(curr_rx, curr_tx);

            unsigned long long sys_delta = curr.total_cpu_time - prev.total_cpu_time;
            if (sys_delta == 0) sys_delta = 1;

            cpu_freq_info = get_cpu_frequency_info(curr.core_total_time.size());
            cpu_temp_info = get_cpu_temperature();
            gpu_info = get_gpu_info();
            load_avg = get_load_average();

            if (is_initial_sample) {
                total_cpu_usage = 0.0;
                rx_rate_kib = 0.0;
                tx_rate_kib = 0.0;
                have_usage_window = false;
            } else {
                unsigned long long idle_delta = curr.idle_cpu_time - prev.idle_cpu_time;
                total_cpu_usage = safe_percentage(static_cast<double>(sys_delta - idle_delta), static_cast<double>(sys_delta));

                double interval_seconds = elapsed_ms > 0 ? (elapsed_ms / 1000.0) : (g_delay_ms / 1000.0);
                if (interval_seconds <= 0.0) interval_seconds = 1.0;
                rx_rate_kib = static_cast<double>(curr_rx - prev_rx) / interval_seconds / 1024.0;
                tx_rate_kib = static_cast<double>(curr_tx - prev_tx) / interval_seconds / 1024.0;
                have_usage_window = true;
            }

            display_list.clear();
            for (const auto& [pid, curr_proc] : curr.processes) {
                ProcDisplay pd;
                pd.pid = pid; pd.name = curr_proc.name; pd.state = curr_proc.state;
                pd.user = g_user_map.count(curr_proc.uid) ? g_user_map[curr_proc.uid] : std::to_string(curr_proc.uid);
                pd.mem_usage_mb = (curr_proc.rss * page_size) / (1024.0 * 1024.0);
                if (!is_initial_sample && prev.processes.count(pid)) {
                    unsigned long long proc_delta = curr_proc.total_time - prev.processes.at(pid).total_time;
                    pd.cpu_usage = 100.0 * ((double)proc_delta / (double)sys_delta) * num_procs_conf;
                } else pd.cpu_usage = 0.0;
                display_list.push_back(pd);
            }

            std::sort(display_list.begin(), display_list.end(), [](const ProcDisplay& a, const ProcDisplay& b) {
                return a.cpu_usage > b.cpu_usage;
            });

            needs_redraw = true;
        }

        if (needs_redraw) {
            if (g_selected_index >= (int)display_list.size()) g_selected_index = display_list.size() - 1;
            if (g_selected_index < 0) g_selected_index = 0;

            int term_height = get_terminal_height();
            struct sysinfo si;
            sysinfo(&si);
            int header_lines = 0;
            
            std::stringstream header_ss;
            header_ss << "\033[H" << CLR_HEADER << " GeminiOS gtop " << CLR_RESET
                      << CLR_BOLD << " | Uptime: " << format_uptime(si.uptime) << CLR_RESET
                      << " | Procs: " << CLR_YELLOW << si.procs << CLR_RESET
                      << " | " << CLR_CYAN << "['q' to exit, Arrows to scroll]" << CLR_RESET << CLR_EOL << "\n";
            header_lines++;

            if (g_advanced) {
                header_ss << CLR_CYAN << "-- CPU " << std::string(43, '-') << CLR_RESET << CLR_EOL << "\n";
                header_ss << CLR_BOLD << " Model: " << CLR_RESET << truncate_string(cpu_model, 60) << CLR_EOL << "\n";
                header_ss << "  Total " << draw_bar(total_cpu_usage, 20)
                          << " " << CLR_CYAN << "Avg " << (cpu_freq_info.has_current ? format_frequency_mhz(cpu_freq_info.average_mhz) : "n/a") << CLR_RESET
                          << " | " << CLR_MAGENTA << "Max " << (cpu_freq_info.has_max ? format_frequency_mhz(cpu_freq_info.max_mhz) : "n/a") << CLR_RESET
                          << " | " << CLR_YELLOW << "Temp " << format_temperature(cpu_temp_info) << CLR_RESET << CLR_EOL << "\n";
                header_ss << "  Load  " << CLR_BOLD << std::fixed << std::setprecision(2)
                          << load_avg.one << ' ' << load_avg.five << ' ' << load_avg.fifteen
                          << CLR_RESET << CLR_EOL << "\n";
                header_lines += 4;
                
                for (size_t i = 0; i < curr.core_total_time.size(); ++i) {
                    double usage = 0.0;
                    if (have_usage_window && i < prev.core_total_time.size() && i < prev.core_idle_time.size()) {
                        unsigned long long total_d = curr.core_total_time[i] - prev.core_total_time[i];
                        unsigned long long idle_d = curr.core_idle_time[i] - prev.core_idle_time[i];
                        usage = total_d > 0 ? 100.0 * (total_d - idle_d) / total_d : 0.0;
                    }
                    std::string freq_text = (i < cpu_freq_info.current_mhz.size() && cpu_freq_info.current_mhz[i] > 0.0)
                        ? format_frequency_mhz(cpu_freq_info.current_mhz[i])
                        : "n/a";

                    header_ss << "  Core " << std::setw(2) << i << " " << draw_bar(usage, 15)
                              << " " << CLR_CYAN << freq_text << CLR_RESET << CLR_EOL << "\n";
                    header_lines++;
                }

                header_ss << CLR_CYAN << "-- MEMORY " << std::string(40, '-') << CLR_RESET << CLR_EOL << "\n";
                long m_total, m_used, m_free, m_avail, s_total, s_free;
                get_mem_info(m_total, m_used, m_free, m_avail, s_total, s_free);
                header_ss << "  RAM  " << draw_bar(safe_percentage(static_cast<double>(m_used), static_cast<double>(m_total)), 25)
                          << " " << CLR_BOLD << format_meminfo_kib(m_used) << CLR_RESET << " / "
                          << format_meminfo_kib(m_total) << " | Avail " << format_meminfo_kib(m_avail)
                          << CLR_EOL << "\n";
                header_lines += 2;
                
                if (s_total > 0) {
                    long s_used = s_total - s_free;
                    header_ss << "  Swap " << draw_bar(safe_percentage(static_cast<double>(s_used), static_cast<double>(s_total)), 25)
                              << " " << CLR_BOLD << format_meminfo_kib(s_used) << CLR_RESET << " / "
                              << format_meminfo_kib(s_total) << CLR_EOL << "\n";
                    header_lines++;
                }

                header_ss << CLR_CYAN << "-- STORAGE & NETWORK " << std::string(29, '-') << CLR_RESET << CLR_EOL << "\n";
                double d_total, d_used;
                get_disk_usage(d_total, d_used);
                header_ss << "  Disk " << draw_bar(safe_percentage(d_used, d_total), 25)
                          << " " << CLR_BOLD << std::fixed << std::setprecision(1) << d_used << CLR_RESET << " / " << d_total << " GB" << CLR_EOL << "\n";
                
                header_ss << "  Net  " << CLR_GREEN << "RX: " << std::fixed << std::setprecision(1) << rx_rate_kib << " KiB/s" << CLR_RESET
                          << " | " << CLR_YELLOW << "TX: " << tx_rate_kib << " KiB/s" << CLR_RESET << CLR_EOL << "\n";
                header_lines += 3;

                header_ss << CLR_CYAN << "-- GPU " << std::string(43, '-') << CLR_RESET << CLR_EOL << "\n";
                header_ss << "  Model: " << CLR_BOLD << truncate_string(gpu_info.model, 60) << CLR_RESET << CLR_EOL << "\n";
                header_ss << "  Driver: " << CLR_CYAN << gpu_info.driver << CLR_RESET
                          << " | " << CLR_YELLOW << "Busy: "
                          << (gpu_info.busy_percent >= 0 ? std::to_string(gpu_info.busy_percent) + "%" : "n/a")
                          << CLR_RESET << CLR_EOL << "\n";
                if (gpu_info.memory.available) {
                    header_ss << "  " << gpu_info.memory.label << " " << draw_bar(
                        safe_percentage(static_cast<double>(gpu_info.memory.used_bytes), static_cast<double>(gpu_info.memory.total_bytes)), 20)
                              << " " << format_bytes(gpu_info.memory.used_bytes)
                              << " / " << format_bytes(gpu_info.memory.total_bytes) << CLR_EOL << "\n";
                } else {
                    header_ss << "  Memory: n/a (driver/VM does not expose dedicated GPU memory)" << CLR_EOL << "\n";
                }
                header_ss << CLR_CYAN << std::string(72, '-') << CLR_RESET << CLR_EOL << "\n";
                header_lines += 4;
            } else {
                long total_ram, used_ram, free_ram, avail_ram, swap_total, swap_free;
                get_mem_info(total_ram, used_ram, free_ram, avail_ram, swap_total, swap_free);
                header_ss << " CPU: " << draw_bar(total_cpu_usage, 18)
                          << " " << CLR_CYAN << (cpu_freq_info.has_current ? format_frequency_mhz(cpu_freq_info.average_mhz) : "n/a") << CLR_RESET
                          << " | " << CLR_YELLOW << format_temperature(cpu_temp_info) << CLR_RESET << CLR_EOL << "\n";
                header_ss << " RAM: " << CLR_YELLOW << format_meminfo_kib(used_ram) << CLR_RESET
                          << " / " << format_meminfo_kib(total_ram) << " "
                          << draw_bar(safe_percentage(static_cast<double>(used_ram), static_cast<double>(total_ram)), 18)
                          << " | Avail " << format_meminfo_kib(avail_ram) << CLR_EOL << "\n";
                header_ss << " GPU: " << truncate_string(gpu_info.model, 36);
                if (gpu_info.memory.available) {
                    header_ss << " | " << gpu_info.memory.label << ' '
                              << format_bytes(gpu_info.memory.used_bytes) << " / "
                              << format_bytes(gpu_info.memory.total_bytes);
                } else {
                    header_ss << " | Memory n/a";
                }
                header_ss << CLR_EOL << "\n";
                header_ss << std::string(72, '-') << CLR_EOL << "\n";
                header_lines += 4;
            }

            header_ss << CLR_HEADER << std::left << std::setw(6) << " PID " << std::setw(10) << " USER " << std::setw(4) << " S " << std::setw(8) << " %CPU " << std::setw(10) << " MEM(MB) " << " COMMAND " << CLR_RESET << CLR_EOL << "\n";
            header_lines++;

            int row_limit = term_height - header_lines - 1;
            if (row_limit < 1) row_limit = 1;

            if (g_selected_index < g_scroll_offset) g_scroll_offset = g_selected_index;
            if (g_selected_index >= g_scroll_offset + row_limit) g_scroll_offset = g_selected_index - row_limit + 1;

            std::cout << "\033[H" << header_ss.str();

            for (int i = g_scroll_offset; i < std::min((int)display_list.size(), g_scroll_offset + row_limit); ++i) {
                const auto& p = display_list[i];
                if (i == g_selected_index) std::cout << CLR_SELECTED;
                
                std::cout << std::left << std::setw(6) << p.pid << std::setw(10) << p.user.substr(0, 9) << std::setw(4) << p.state;
                if (i != g_selected_index) {
                    if (p.cpu_usage > 50.0) std::cout << CLR_RED;
                    else if (p.cpu_usage > 10.0) std::cout << CLR_YELLOW;
                    else std::cout << CLR_GREEN;
                }
                std::cout << std::fixed << std::setprecision(1) << std::setw(8) << p.cpu_usage;
                if (i != g_selected_index) std::cout << CLR_RESET;
                std::cout << std::fixed << std::setprecision(1) << std::setw(10) << p.mem_usage_mb << p.name.substr(0, 30) << CLR_RESET << CLR_EOL << "\n";
            }
            // Clear remaining lines if any
            for (int i = header_lines + std::min((int)display_list.size() - g_scroll_offset, row_limit); i < term_height - 1; ++i) {
                std::cout << "\033[K\n";
            }
            std::cout << std::flush;
            needs_redraw = false;
        }

        if (elapsed_ms >= g_delay_ms) {
            prev = curr; prev_rx = curr_rx; prev_tx = curr_tx;
            last_update_time = now;
        }

        // Wait for input with timeout
        char c;
        struct timeval tv; tv.tv_sec = 0; tv.tv_usec = 50000; // 50ms responsiveness
        fd_set fds; FD_ZERO(&fds); FD_SET(STDIN_FILENO, &fds);
        if (select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0) {
            if (read(STDIN_FILENO, &c, 1) == 1) {
                if (c == 'q') { g_running = false; break; }
                if (c == '\033') { // Escape sequence
                    char seq[3];
                    if (read(STDIN_FILENO, &seq[0], 1) == 1 && read(STDIN_FILENO, &seq[1], 1) == 1) {
                        if (seq[0] == '[') {
                            if (seq[1] == 'A') { // Up
                                if (g_selected_index > 0) g_selected_index--;
                                needs_redraw = true;
                            } else if (seq[1] == 'B') { // Down
                                if (g_selected_index < (int)display_list.size() - 1) g_selected_index++;
                                needs_redraw = true;
                            }
                        }
                    }
                }
            }
        }
    }
    return 0;
}
