#include <algorithm>
#include <csignal>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <sys/sysinfo.h>
#include <sys/statvfs.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>
#include <vector>
#include <fcntl.h>
#include <chrono>
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
    std::map<int, ProcSnapshot> processes;
    std::vector<unsigned long long> core_total_time;
    std::vector<unsigned long long> core_idle_time;
};

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

unsigned long long get_system_cpu_time() {
    std::ifstream f("/proc/stat");
    std::string line;
    if (std::getline(f, line)) {
        std::istringstream iss(line);
        std::string cpu;
        iss >> cpu;
        unsigned long long sum = 0, val;
        while (iss >> val) sum += val;
        return sum;
    }
    return 0;
}

void get_core_times(std::vector<unsigned long long>& totals, std::vector<unsigned long long>& idles) {
    std::ifstream f("/proc/stat");
    std::string line;
    totals.clear();
    idles.clear();
    while (std::getline(f, line)) {
        if (line.compare(0, 3, "cpu") == 0 && isdigit(line[3])) {
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
        if (line.find("model name") != std::string::npos) {
            size_t pos = line.find(':');
            if (pos != std::string::npos) return line.substr(pos + 2);
        }
    }
    return "Unknown CPU";
}

long get_cpu_max_freq() {
    std::ifstream f("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq");
    if (!f) return 0;
    long freq;
    f >> freq;
    return freq / 1000;
}

long get_cpu_cur_freq(int core) {
    std::ifstream f("/sys/devices/system/cpu/cpu" + std::to_string(core) + "/cpufreq/scaling_cur_freq");
    if (!f) return 0;
    long freq;
    f >> freq;
    return freq / 1000;
}

int get_cpu_temp(int core) {
    for (int i = 0; i < 10; ++i) {
        std::ifstream f("/sys/class/thermal/thermal_zone" + std::to_string(i) + "/temp");
        if (f) {
            int temp; f >> temp; return temp / 1000;
        }
    }
    return 0;
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

std::string get_gpu_model() {
    FILE* pipe = popen("lspci 2>/dev/null | grep -i vga", "r");
    if (pipe) {
        char buffer[128];
        std::string result = "";
        while (fgets(buffer, sizeof buffer, pipe) != NULL) result += buffer;
        pclose(pipe);
        size_t colon = result.find_last_of(':');
        if (colon != std::string::npos) {
            std::string model = result.substr(colon + 2);
            if (!model.empty() && model.back() == '\n') model.pop_back();
            if (!model.empty()) return model;
        }
    }
    std::ifstream fv("/sys/class/drm/card0/device/vendor");
    std::ifstream fd("/sys/class/drm/card0/device/device");
    if (fv && fd) {
        std::string v, d;
        fv >> v; fd >> d;
        return "GPU [" + v + ":" + d + "]";
    }
    return "Unknown GPU";
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
    load_user_map();

    SystemSnapshot prev, curr;
    prev.total_cpu_time = get_system_cpu_time();
    prev.processes = get_processes();
    get_core_times(prev.core_total_time, prev.core_idle_time);
    
    unsigned long long prev_rx, prev_tx, curr_rx, curr_tx;
    get_net_usage(prev_rx, prev_tx);
    curr_rx = prev_rx; curr_tx = prev_tx;

    std::vector<ProcDisplay> display_list;
    bool needs_redraw = true;
    auto last_update_time = std::chrono::steady_clock::now();

    while (g_running) {
        auto now = std::chrono::steady_clock::now();
        auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_update_time).count();

        if (elapsed_ms >= g_delay_ms || display_list.empty()) {
            curr.total_cpu_time = get_system_cpu_time();
            curr.processes = get_processes();
            get_core_times(curr.core_total_time, curr.core_idle_time);
            get_net_usage(curr_rx, curr_tx);

            unsigned long long sys_delta = curr.total_cpu_time - prev.total_cpu_time;
            if (sys_delta == 0) sys_delta = 1;

            display_list.clear();
            for (const auto& [pid, curr_proc] : curr.processes) {
                ProcDisplay pd;
                pd.pid = pid; pd.name = curr_proc.name; pd.state = curr_proc.state;
                pd.user = g_user_map.count(curr_proc.uid) ? g_user_map[curr_proc.uid] : std::to_string(curr_proc.uid);
                pd.mem_usage_mb = (curr_proc.rss * page_size) / (1024.0 * 1024.0);
                if (prev.processes.count(pid)) {
                    unsigned long long proc_delta = curr_proc.total_time - prev.processes.at(pid).total_time;
                    pd.cpu_usage = 100.0 * ((double)proc_delta / (double)sys_delta) * num_procs_conf;
                } else pd.cpu_usage = 0.0;
                display_list.push_back(pd);
            }

            std::sort(display_list.begin(), display_list.end(), [](const ProcDisplay& a, const ProcDisplay& b) {
                return a.cpu_usage > b.cpu_usage;
            });

            needs_redraw = true;
            // Note: We don't update 'prev' yet if we want to calculate rate over g_delay_ms accurately,
            // but actually we should update it to make it a sliding window.
            // Actually, gtop usually does it per-interval.
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
                      << CLR_BOLD << " | Uptime: " << si.uptime << "s" << CLR_RESET
                      << " | Procs: " << CLR_YELLOW << si.procs << CLR_RESET
                      << " | " << CLR_CYAN << "['q' to exit, Arrows to scroll]" << CLR_RESET << CLR_EOL << "\n";
            header_lines++;

            if (g_advanced) {
                header_ss << CLR_CYAN << "-- CPU " << std::string(43, '-') << CLR_RESET << CLR_EOL << "\n";
                header_ss << CLR_BOLD << " Model: " << CLR_RESET << get_cpu_model().substr(0, 40) 
                          << " (" << CLR_MAGENTA << get_cpu_max_freq() << " MHz" << CLR_RESET << " max)" << CLR_EOL << "\n";
                header_lines += 2;
                
                for (size_t i = 0; i < curr.core_total_time.size(); ++i) {
                    unsigned long long total_d = (i < prev.core_total_time.size()) ? curr.core_total_time[i] - prev.core_total_time[i] : 1;
                    unsigned long long idle_d = (i < prev.core_idle_time.size()) ? curr.core_idle_time[i] - prev.core_idle_time[i] : 0;
                    double usage = total_d > 0 ? 100.0 * (total_d - idle_d) / total_d : 0.0;

                    header_ss << "  Core " << std::setw(2) << i << " " << draw_bar(usage, 15)
                              << " " << CLR_CYAN << std::setw(4) << get_cpu_cur_freq(i) << " MHz" << CLR_RESET
                              << " " << CLR_YELLOW << std::setw(3) << get_cpu_temp(i) << "°C" << CLR_RESET << CLR_EOL << "\n";
                    header_lines++;
                }

                header_ss << CLR_CYAN << "-- MEMORY " << std::string(40, '-') << CLR_RESET << CLR_EOL << "\n";
                long m_total, m_used, m_free, m_avail, s_total, s_free;
                get_mem_info(m_total, m_used, m_free, m_avail, s_total, s_free);
                header_ss << "  RAM  " << draw_bar((double)m_used * 100.0 / m_total, 25)
                          << " " << CLR_BOLD << m_used/1024 << CLR_RESET << " / " << m_total/1024 << " MB" << CLR_EOL << "\n";
                header_lines += 2;
                
                if (s_total > 0) {
                    long s_used = s_total - s_free;
                    header_ss << "  Swap " << draw_bar((double)s_used * 100.0 / s_total, 25)
                              << " " << CLR_BOLD << s_used/1024 << CLR_RESET << " / " << s_total/1024 << " MB" << CLR_EOL << "\n";
                    header_lines++;
                }

                header_ss << CLR_CYAN << "-- STORAGE & NETWORK " << std::string(29, '-') << CLR_RESET << CLR_EOL << "\n";
                double d_total, d_used;
                get_disk_usage(d_total, d_used);
                header_ss << "  Disk " << draw_bar(d_used * 100.0 / d_total, 25)
                          << " " << CLR_BOLD << std::fixed << std::setprecision(1) << d_used << CLR_RESET << " / " << d_total << " GB" << CLR_EOL << "\n";

                double rx_rate = (double)(curr_rx - prev_rx) / (elapsed_ms / 1000.0) / 1024.0;
                double tx_rate = (double)(curr_tx - prev_tx) / (elapsed_ms / 1000.0) / 1024.0;
                if (elapsed_ms == 0) rx_rate = tx_rate = 0;
                
                header_ss << "  Net  " << CLR_GREEN << "RX: " << std::fixed << std::setprecision(1) << rx_rate << " KB/s" << CLR_RESET
                          << " | " << CLR_YELLOW << "TX: " << tx_rate << " KB/s" << CLR_RESET << CLR_EOL << "\n";
                header_lines += 3;

                header_ss << CLR_CYAN << "-- GPU " << std::string(43, '-') << CLR_RESET << CLR_EOL << "\n";
                header_ss << "  Model: " << CLR_BOLD << get_gpu_model().substr(0, 40) << CLR_RESET << CLR_EOL << "\n";
                header_ss << CLR_CYAN << std::string(50, '-') << CLR_RESET << CLR_EOL << "\n";
                header_lines += 3;
            } else {
                long total_ram = si.totalram * si.mem_unit / (1024 * 1024);
                long used_ram = total_ram - (si.freeram * si.mem_unit / (1024 * 1024));
                header_ss << " RAM: " << CLR_YELLOW << used_ram << "MB" << CLR_RESET
                          << " / " << total_ram << "MB " << draw_bar((double)used_ram*100/total_ram, 20) << CLR_EOL << "\n";
                header_ss << std::string(50, '-') << CLR_EOL << "\n";
                header_lines += 2;
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