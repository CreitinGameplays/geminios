#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <iostream>
#include <string>
#include <vector>
#include <fcntl.h>
#include <dirent.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include "stb_image.h"
#include <sys/wait.h> // For waitpid if needed (though we run detached)
#include <signal.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <mutex>
#include <thread>
#include <atomic>
// LVGL Includes
#include "lvgl/lvgl.h"
#include "lv_drivers/display/fbdev.h"
#include "wm.h"
#include "com_proto.h"
#include <fstream>
#include <algorithm>
#include <sys/stat.h>

// App Info Structure
struct AppInfo {
    std::string name;
    std::string path;
};

std::vector<AppInfo> installed_apps;
lv_obj_t * start_menu_container = nullptr;


// Global Clock Label
lv_obj_t * label_clock;
int mouse_fd = -1;
uint32_t screen_width = 0;
uint32_t screen_height = 0;
std::mutex lvgl_mutex; // Protect LVGL API calls

// --- Image Loader Helper ---
// Loads a PNG/JPG from disk and converts it to an LVGL image descriptor
// req_w/req_h: Optional target dimensions. If > 0, image will be resized.
lv_img_dsc_t* load_image(const char* path, int req_w = 0, int req_h = 0) {
    int width, height, channels;
    // Force 4 channels (RGBA)
    unsigned char *data = stbi_load(path, &width, &height, &channels, 4);
    
    if (!data) {
        std::cerr << "[Desktop] Failed to load image: " << path << std::endl;
        return NULL;
    }

    // Resize if requested and dimensions differ
    if (req_w > 0 && req_h > 0 && (width != req_w || height != req_h)) {
        std::cout << "[Desktop] Resizing " << path << " from " << width << "x" << height 
                  << " to " << req_w << "x" << req_h << std::endl;
        
        unsigned char* new_data = (unsigned char*)malloc(req_w * req_h * 4);
        if (new_data) {
            for (int y = 0; y < req_h; y++) {
                for (int x = 0; x < req_w; x++) {
                    // Nearest Neighbor Sampling
                    int src_x = x * width / req_w;
                    int src_y = y * height / req_h;
                    int src_idx = (src_y * width + src_x) * 4;
                    int dst_idx = (y * req_w + x) * 4;
                    
                    // Copy pixel (RGBA)
                    new_data[dst_idx + 0] = data[src_idx + 0];
                    new_data[dst_idx + 1] = data[src_idx + 1];
                    new_data[dst_idx + 2] = data[src_idx + 2];
                    new_data[dst_idx + 3] = data[src_idx + 3];
                }
            }
            stbi_image_free(data);
            data = new_data; // Swap buffers
            width = req_w;
            height = req_h;
        }
    }

    // Convert RGBA (stb) to ARGB (LVGL 32-bit)
    for (int i = 0; i < width * height; ++i) {
        unsigned char r = data[i*4 + 0];
        unsigned char g = data[i*4 + 1];
        unsigned char b = data[i*4 + 2];
        unsigned char a = data[i*4 + 3];

        // Swizzle to BGRA (Standard LVGL 32-bit color)
        data[i*4 + 0] = b;
        data[i*4 + 1] = g;
        data[i*4 + 2] = r;
        data[i*4 + 3] = a;
    }

    lv_img_dsc_t* dsc = new lv_img_dsc_t;
    memset(dsc, 0, sizeof(lv_img_dsc_t));
    dsc->header.always_zero = 0;
    dsc->header.w = width;
    dsc->header.h = height;
    dsc->data_size = width * height * 4;
    dsc->header.cf = LV_IMG_CF_TRUE_COLOR_ALPHA;
    dsc->data = data; // We hand over ownership of the pointer
    
    return dsc;
}

// Restore text mode on exit
void cleanup_tty() {
    int tty = open("/dev/tty0", O_RDWR);
    if(tty >= 0) {
        ioctl(tty, KDSETMODE, KD_TEXT);
        close(tty);
    }
}

// Custom Mouse Driver
static int g_mouse_x = 0;
static int g_mouse_y = 0;
static lv_indev_state_t g_mouse_btn_state = LV_INDEV_STATE_RELEASED;

void custom_mouse_read(lv_indev_drv_t * drv, lv_indev_data_t * data) {
    if (mouse_fd < 0) return;

    struct input_event in;
    while (read(mouse_fd, &in, sizeof(struct input_event)) > 0) {
        if (in.type == EV_REL) {
            if (in.code == REL_X) g_mouse_x += in.value;
            else if (in.code == REL_Y) g_mouse_y += in.value;
        } else if (in.type == EV_KEY) {
            if (in.code == BTN_LEFT) {
                g_mouse_btn_state = (in.value) ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
            }
        }
    }

    // Clamp to screen
    if (g_mouse_x < 0) g_mouse_x = 0;
    if (g_mouse_y < 0) g_mouse_y = 0;
    if (g_mouse_x >= (int)screen_width) g_mouse_x = screen_width - 1;
    if (g_mouse_y >= (int)screen_height) g_mouse_y = screen_height - 1;

    data->point.x = g_mouse_x;
    data->point.y = g_mouse_y;
    data->state = g_mouse_btn_state;
}

// Detect Mouse Device
std::string find_mouse_dev() {
    for(int i=0; i<10; ++i) {
        std::string path = "/dev/input/event" + std::to_string(i);
        int fd = open(path.c_str(), O_RDONLY | O_NONBLOCK);
        if(fd >= 0) {
            unsigned long evbit = 0;
            ioctl(fd, EVIOCGBIT(0, sizeof(evbit)), &evbit);
            bool has_rel = (evbit & (1 << EV_REL));
            bool has_key = (evbit & (1 << EV_KEY));
            close(fd);
            
            if(has_rel && has_key) return path;
        }
    }
    return "";
}

void update_clock(lv_timer_t * timer) {
    time_t rawtime;
    struct tm * timeinfo;
    char buffer[80];

    time(&rawtime);
    timeinfo = localtime(&rawtime);

    strftime(buffer, sizeof(buffer), "%H:%M:%S", timeinfo);
    lv_label_set_text(label_clock, buffer);
}

static void start_btn_event_handler(lv_event_t * e) {
    lv_event_code_t code = lv_event_get_code(e);
    if(code == LV_EVENT_CLICKED) {
        if (start_menu_container) {
            if (lv_obj_has_flag(start_menu_container, LV_OBJ_FLAG_HIDDEN)) {
                lv_obj_clear_flag(start_menu_container, LV_OBJ_FLAG_HIDDEN);
                lv_obj_move_foreground(start_menu_container);
            } else {
                lv_obj_add_flag(start_menu_container, LV_OBJ_FLAG_HIDDEN);
            }
        }
    }
}

// --- Application Discovery ---

bool is_gui_app(const std::string& path) {
    // Whitelist specific TTY apps that we want to show in menu
    if (path.find("snake") != std::string::npos) return true;
    if (path.find("gemfetch") != std::string::npos) return true;

    std::ifstream file(path, std::ios::binary);
    if (!file) return false;

    // Read file content (limit to first 2MB to avoid huge reads on huge binaries, if any)
    // Most system apps are small static binaries.
    std::string content;
    content.resize(2 * 1024 * 1024); 
    file.read(&content[0], content.size());
    size_t read_count = file.gcount();
    content.resize(read_count);
    
    // Search for the socket path string which indicates it links to our WM protocol
    // This is a heuristic but effective for this environment
    return content.find(WM_SOCKET_PATH) != std::string::npos;
}

void scan_apps() {
    installed_apps.clear();
    std::cout << "[Desktop] Scanning for applications..." << std::endl;

    // 1. User Apps (/bin/apps) - Include All Executables
    // We assume anything the user puts here is meant to be seen.
    std::string user_path = "/bin/apps";
    DIR *dir = opendir(user_path.c_str());
    if (dir) {
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] == '.') continue;
            
            std::string full_path = user_path + "/" + entry->d_name;
            struct stat st;
            
            // Check if it is a regular file and executable
            if (stat(full_path.c_str(), &st) == 0 && S_ISREG(st.st_mode)) {
                if (access(full_path.c_str(), X_OK) == 0) {
                    std::cout << "[Desktop] Adding User App: " << entry->d_name << std::endl;
                    installed_apps.push_back({entry->d_name, full_path});
                }
            }
        }
        closedir(dir);
    }

    // 2. System Apps (/bin/apps/system) - Filter for GUI or Whitelist
    // We don't want to list 'ls', 'cp', 'mv' etc. in the Start Menu.
    std::string sys_path = "/bin/apps/system";
    dir = opendir(sys_path.c_str());
    if (dir) {
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] == '.') continue;
            if (std::string(entry->d_name) == "desktop") continue; // Don't list self

            std::string full_path = sys_path + "/" + entry->d_name;
            struct stat st;
            if (stat(full_path.c_str(), &st) == 0 && S_ISREG(st.st_mode)) {
                if (access(full_path.c_str(), X_OK) == 0) {
                    if (is_gui_app(full_path)) {
                        std::cout << "[Desktop] Found System GUI App: " << entry->d_name << std::endl;
                        installed_apps.push_back({entry->d_name, full_path});
                    }
                }
            }
        }
        closedir(dir);
    }
    
    // Sort alphabetically
    std::sort(installed_apps.begin(), installed_apps.end(), 
        [](const AppInfo& a, const AppInfo& b) { return a.name < b.name; });
}

static void app_btn_event_handler(lv_event_t * e) {
    lv_event_code_t code = lv_event_get_code(e);
    if(code == LV_EVENT_CLICKED) {
        AppInfo* app = (AppInfo*)lv_event_get_user_data(e);
        if (app) {
            std::cout << "[Desktop] Launching " << app->name << "..." << std::endl;
            
            pid_t pid = fork();
            if (pid == 0) {
                // Child process
                // Restore default signal handlers
                signal(SIGINT, SIG_DFL);
                signal(SIGQUIT, SIG_DFL);
                
                execl(app->path.c_str(), app->name.c_str(), NULL);
                perror("execl failed");
                exit(1);
            }
            
            // Close start menu after launch
            if (start_menu_container) {
                lv_obj_add_flag(start_menu_container, LV_OBJ_FLAG_HIDDEN);
            }
        }
    }
}

void create_start_menu() {
    if (start_menu_container) return;

    // Create Container
    start_menu_container = lv_obj_create(lv_scr_act());
    lv_obj_set_size(start_menu_container, 200, 300);
    lv_obj_align(start_menu_container, LV_ALIGN_BOTTOM_LEFT, 5, -50); // Above Start Button
    lv_obj_set_style_bg_color(start_menu_container, lv_color_hex(0x303030), 0);
    lv_obj_set_style_border_color(start_menu_container, lv_color_hex(0x505050), 0);
    lv_obj_set_style_radius(start_menu_container, 5, 0);
    
    // Initially Hidden
    lv_obj_add_flag(start_menu_container, LV_OBJ_FLAG_HIDDEN);

    // Title
    lv_obj_t * title = lv_label_create(start_menu_container);
    lv_label_set_text(title, "Applications");
    lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 5);

    // List of Apps
    lv_obj_t * list = lv_list_create(start_menu_container);
    lv_obj_set_size(list, LV_PCT(100), LV_PCT(85));
    lv_obj_align(list, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_set_style_bg_color(list, lv_color_hex(0x404040), 0);
    lv_obj_set_style_border_width(list, 0, 0);

    for (auto& app : installed_apps) {
        lv_obj_t * btn = lv_list_add_btn(list, LV_SYMBOL_FILE, app.name.c_str());
        lv_obj_add_event_cb(btn, app_btn_event_handler, LV_EVENT_CLICKED, &app);
        lv_obj_set_style_bg_color(btn, lv_color_hex(0x404040), 0);
        lv_obj_set_style_text_color(btn, lv_color_hex(0xFFFFFF), 0);
    }
}

static void logout_btn_event_handler(lv_event_t * e) {
    lv_event_code_t code = lv_event_get_code(e);
    if(code == LV_EVENT_CLICKED) {
        cleanup_tty();
        exit(0);
    }
}

void debug_dev() {
    std::cout << "Listing /dev/:" << std::endl;
    DIR *d;
    struct dirent *dir;
    d = opendir("/dev");
    if (d) {
        while ((dir = readdir(d)) != NULL) {
            if (strncmp(dir->d_name, "fb", 2) == 0 || strncmp(dir->d_name, "event", 5) == 0)
                std::cout << "  " << dir->d_name << std::endl;
        }
        closedir(d);
    }
}

// --- Compositor Server ---

void handle_client(int client_fd) {
    std::cout << "[Compositor] Client connected (FD: " << client_fd << ")" << std::endl;

    lv_obj_t* win = nullptr;
    lv_obj_t* img_obj = nullptr;
    lv_img_dsc_t* img_dsc = nullptr;
    uint8_t* img_buffer = nullptr;

    while (true) {
        MsgHeader hdr;
        ssize_t n = read(client_fd, &hdr, sizeof(hdr));
        if (n <= 0) break;

        if (hdr.type == MSG_HELLO) {
            HelloPayload hello;
            if (hdr.len != sizeof(HelloPayload)) {
                 std::cerr << "[Compositor] Invalid Hello payload size" << std::endl;
                 break;
            }
            read(client_fd, &hello, sizeof(hello));
            std::cout << "[Compositor] Hello from: " << hello.title << " (" << hello.width << "x" << hello.height << ")" << std::endl;

            std::lock_guard<std::mutex> lock(lvgl_mutex);
            
            // Allocate buffer for the window content
            // ARGB8888 = 4 bytes
            size_t buf_size = hello.width * hello.height * 4;
            img_buffer = (uint8_t*)malloc(buf_size);
            if (!img_buffer) {
                std::cerr << "[Compositor] Failed to allocate buffer" << std::endl;
                break;
            }
            memset(img_buffer, 0xFF, buf_size); // White background

            // Create LVGL Image Descriptor
            img_dsc = new lv_img_dsc_t;
            memset(img_dsc, 0, sizeof(lv_img_dsc_t));
            img_dsc->header.always_zero = 0;
            img_dsc->header.w = hello.width;
            img_dsc->header.h = hello.height;
            img_dsc->data_size = buf_size;
            img_dsc->header.cf = LV_IMG_CF_TRUE_COLOR_ALPHA; 
            img_dsc->data = img_buffer;

            // Get Client PID
            struct ucred ucred;
            socklen_t len = sizeof(struct ucred);
            pid_t client_pid = 0;
            if (getsockopt(client_fd, SOL_SOCKET, SO_PEERCRED, &ucred, &len) == 0) {
                client_pid = ucred.pid;
                std::cout << "[Compositor] Client PID: " << client_pid << std::endl;
            }

            // Create Window
            win = create_client_window(hello.title, hello.width + 10, hello.height + 50, &img_obj, client_pid);
            if (img_obj) {
                lv_img_set_src(img_obj, img_dsc);
                
                // Add event callback to forward input to client
                lv_obj_add_flag(img_obj, LV_OBJ_FLAG_CLICKABLE);
            }

        } else if (hdr.type == MSG_FRAME) {
            FramePayload frame;
            if (hdr.len < sizeof(FramePayload)) {
                std::cerr << "[Compositor] Invalid Frame payload size" << std::endl;
                break;
            }
            read(client_fd, &frame, sizeof(frame));
            
            uint32_t data_len = hdr.len - sizeof(FramePayload);
            
            // Validate frame dimensions
            if (!img_dsc || frame.x + frame.w > img_dsc->header.w || frame.y + frame.h > img_dsc->header.h) {
                 std::cerr << "[Compositor] Invalid frame dimensions or window not created" << std::endl;
                 break;
            }

            // Validate data length
            if (data_len != frame.w * frame.h * 4) {
                 std::cerr << "[Compositor] Data length mismatch" << std::endl;
                 break;
            }

            std::vector<uint8_t> chunk(data_len);
            size_t total_read = 0;
            while (total_read < data_len) {
                ssize_t r = read(client_fd, chunk.data() + total_read, data_len - total_read);
                if (r <= 0) break;
                total_read += r;
            }

            if (total_read == data_len && img_buffer) {
                std::lock_guard<std::mutex> lock(lvgl_mutex);
                
                uint32_t bpp = 4; // ARGB
                uint32_t stride = img_dsc->header.w * bpp;
                
                const uint8_t* src = chunk.data();
                for (int y = 0; y < frame.h; ++y) {
                    int dst_offset = ((frame.y + y) * stride) + (frame.x * bpp);
                    // Double check bounds just in case
                    if (dst_offset + (frame.w * bpp) <= img_dsc->data_size) {
                        memcpy(img_buffer + dst_offset, src + (y * frame.w * bpp), frame.w * bpp);
                    }
                }
                
                if (img_obj) lv_obj_invalidate(img_obj);
            }
        }
    }

    std::cout << "[Compositor] Client disconnected." << std::endl;
    {
        std::lock_guard<std::mutex> lock(lvgl_mutex);
        if (win && wm_is_window_valid(win)) lv_obj_del(win);
        if (img_dsc) delete img_dsc;
        if (img_buffer) free(img_buffer);
    }
    close(client_fd);
}

void compositor_thread() {
    int server_fd;
    struct sockaddr_un address;

    if ((server_fd = socket(AF_UNIX, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        return;
    }

    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, WM_SOCKET_PATH, sizeof(address.sun_path)-1);
    unlink(WM_SOCKET_PATH);

    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        return;
    }

    if (listen(server_fd, 5) < 0) {
        perror("listen");
        return;
    }

    std::cout << "[Compositor] Listening on " << WM_SOCKET_PATH << std::endl;

    while (true) {
        struct sockaddr_un client_addr;
        socklen_t len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &len);
        if (client_fd >= 0) {
            std::thread t(handle_client, client_fd);
            t.detach();
        }
    }
}

int main(void) {
    // 0. Single Instance Check
    int lock_fd = open("/tmp/desktop.lock", O_CREAT | O_EXCL, 0644);
    if (lock_fd < 0) {
        std::cerr << "[Desktop] Another instance is already running. Exiting." << std::endl;
        return 1;
    }
    // We don't need to keep the fd open, just the file existence is enough for this simple check.
    // But keeping it open and locking it would be more robust. 
    // For now, just existence check as requested.
    close(lock_fd);
    
    // Ensure lock file is removed on exit
    atexit([]{
        unlink("/tmp/desktop.lock");
    });

    // 0.1 Sanity Checks
    if (access("/dev/fb0", F_OK) != 0) {
        std::cerr << "\n[ERROR] /dev/fb0 not found!" << std::endl;
        std::cerr << "Possible causes:" << std::endl;
        std::cerr << "1. Kernel missing Framebuffer support." << std::endl;
        std::cerr << "2. QEMU missing graphics option (try -vga std)." << std::endl;
        if (access("/dev/dri", F_OK) == 0) {
            std::cerr << "3. DRM driver is loaded but CONFIG_DRM_FBDEV_EMULATION is disabled in kernel!" << std::endl;
        }
        debug_dev();
        return 1;
    }
    
    // 1. Initialize LVGL
    lv_init();

    // 2. Initialize Drivers
    fbdev_init();
    
    // Query Framebuffer for Size
    int fbfd = open("/dev/fb0", O_RDWR);
    if (fbfd >= 0) {
        struct fb_var_screeninfo vinfo;
        ioctl(fbfd, FBIOGET_VSCREENINFO, &vinfo);
        screen_width = vinfo.xres;
        screen_height = vinfo.yres;
        close(fbfd);
    } else {
        screen_width = 1024;
        screen_height = 768;
    }
    std::cout << "[Desktop] Resolution: " << screen_width << "x" << screen_height << std::endl;
    
    // Only init custom mouse if it exists
    std::string mouse_dev = find_mouse_dev();
    if (!mouse_dev.empty()) {
        mouse_fd = open(mouse_dev.c_str(), O_RDONLY | O_NONBLOCK);
        std::cout << "[Desktop] Found mouse at " << mouse_dev << std::endl;
    } else {
        std::cout << "[WARN] No mouse input found!" << std::endl;
    }
    
    // Switch TTY to Graphics Mode (Hides blinking cursor)
    int tty = open("/dev/tty0", O_RDWR);
    if (tty >= 0) {
        ioctl(tty, KDSETMODE, KD_GRAPHICS);
        close(tty);
    }
    atexit(cleanup_tty); // Ensure we restore text mode on crash/exit

    // 3. Register Display Driver
    static lv_disp_draw_buf_t disp_buf;
    uint32_t buf_size = screen_width * (screen_height / 10);
    lv_color_t* buf = new lv_color_t[buf_size];
    lv_disp_draw_buf_init(&disp_buf, buf, NULL, buf_size);

    static lv_disp_drv_t disp_drv;
    lv_disp_drv_init(&disp_drv);
    disp_drv.draw_buf = &disp_buf;
    disp_drv.flush_cb = fbdev_flush;
    disp_drv.hor_res = screen_width;
    disp_drv.ver_res = screen_height;
    lv_disp_drv_register(&disp_drv);

    // 4. Register Input Driver (Mouse)
    // We protect input read with mutex? No, LVGL calls read_cb from the timer handler
    // which we will wrap in the main loop.
    // But wait, custom_mouse_read is called by LVGL.    

    if (mouse_fd >= 0) {
        static lv_indev_drv_t indev_drv;
        lv_indev_drv_init(&indev_drv);
        indev_drv.type = LV_INDEV_TYPE_POINTER;
        indev_drv.read_cb = custom_mouse_read;
        lv_indev_t * my_indev = lv_indev_drv_register(&indev_drv);

        // Create Cursor
        lv_obj_t * cursor_obj = lv_img_create(lv_scr_act());
        // Force cursor to be 24x24 pixels
        lv_img_dsc_t* cursor_img = load_image("/usr/share/icons/cursor.png", 24, 24);
        if (cursor_img) {
            lv_img_set_src(cursor_obj, cursor_img);
        } else {
            // Fallback Cursor (Red Square)
            static lv_color_t cbuf[16*16];
            for(int i=0; i<256; ++i) cbuf[i] = lv_color_hex(0xFF0000);
            
            static lv_img_dsc_t fallback;
            memset(&fallback, 0, sizeof(lv_img_dsc_t));
            fallback.header.cf = LV_IMG_CF_TRUE_COLOR;
            fallback.header.w = 16;
            fallback.header.h = 16;
            fallback.data_size = 16*16*4;
            fallback.data = (const uint8_t*)cbuf;
            
            lv_img_set_src(cursor_obj, &fallback);
        }
        lv_indev_set_cursor(my_indev, cursor_obj);
    }

    // 5. Create Desktop UI
    // Background (Wallpaper)
    lv_obj_t * bg = lv_img_create(lv_scr_act());
    lv_obj_set_size(bg, LV_PCT(100), LV_PCT(100));
    lv_obj_clear_flag(lv_scr_act(), LV_OBJ_FLAG_SCROLLABLE); // Prevent desktop from scrolling
    
    // Load wallpaper without resizing (0,0) so it fills or centers naturally
    lv_img_dsc_t* wallpaper = load_image("/usr/share/wallpapers/default.png", 0, 0);
    if (wallpaper) {
        lv_img_set_src(bg, wallpaper);
        lv_obj_align(bg, LV_ALIGN_CENTER, 0, 0);
    } else {
        // Fallback Color
        lv_obj_set_style_bg_color(bg, lv_color_hex(0x008080), 0);
        lv_obj_set_style_bg_opa(bg, LV_OPA_COVER, 0);
        
        lv_obj_t * bg_label = lv_label_create(bg);
        lv_label_set_text(bg_label, "GeminiOS Desktop Environment");
        lv_obj_align(bg_label, LV_ALIGN_CENTER, 0, 0);
        lv_obj_set_style_text_color(bg_label, lv_color_hex(0xFFFFFF), 0);
    }
    
    // Taskbar
    lv_obj_t * taskbar = lv_obj_create(lv_scr_act());
    lv_obj_set_size(taskbar, LV_PCT(100), 48);
    lv_obj_align(taskbar, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_set_style_bg_color(taskbar, lv_color_hex(0x202020), 0);
    lv_obj_set_style_border_width(taskbar, 0, 0);
    lv_obj_set_style_radius(taskbar, 0, 0);
    lv_obj_clear_flag(taskbar, LV_OBJ_FLAG_SCROLLABLE);

    // Start Button
    lv_obj_t * btn1 = lv_btn_create(taskbar);
    lv_obj_align(btn1, LV_ALIGN_LEFT_MID, -10, 0);
    lv_obj_add_event_cb(btn1, start_btn_event_handler, LV_EVENT_CLICKED, NULL);

    // Make button transparent
    lv_obj_set_style_bg_opa(btn1, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(btn1, 0, 0);
    lv_obj_set_style_shadow_width(btn1, 0, 0);
    lv_obj_set_style_pad_all(btn1, 0, 0);

    // Force Start Icon to be 32x32 pixels (fits nicely in 48px taskbar)
    lv_img_dsc_t* start_img = load_image("/usr/share/icons/start.png", 32, 32);
    if (start_img) {
        lv_obj_t * icon = lv_img_create(btn1);
        lv_img_set_src(icon, start_img);
        lv_obj_center(icon);
    } else {
        lv_obj_t * label1 = lv_label_create(btn1);
        lv_label_set_text(label1, "Gemini");
        lv_obj_center(label1);
    }

    // Logout Button (Right side)
    lv_obj_t * btn3 = lv_btn_create(taskbar);
    lv_obj_align(btn3, LV_ALIGN_RIGHT_MID, -100, 0);
    lv_obj_add_event_cb(btn3, logout_btn_event_handler, LV_EVENT_CLICKED, NULL);
    lv_obj_set_style_bg_color(btn3, lv_color_hex(0xA00000), 0); // Red
    lv_obj_t * label3 = lv_label_create(btn3);
    lv_label_set_text(label3, "Exit");
    lv_obj_center(label3);

    // Clock
    label_clock = lv_label_create(taskbar);
    lv_obj_align(label_clock, LV_ALIGN_RIGHT_MID, -10, 0);
    lv_label_set_text(label_clock, "00:00:00");
    lv_obj_set_style_text_color(label_clock, lv_color_hex(0xFFFFFF), 0);

    // Clock Timer
    lv_timer_create(update_clock, 1000, NULL);

    // Scan Apps & Create Menu
    scan_apps();
    create_start_menu();

    // 6. Start Compositor Server
    std::thread comp_thread(compositor_thread);
    comp_thread.detach();

    // 7. Main Loop
    while(1) {
        {
            std::lock_guard<std::mutex> lock(lvgl_mutex);
            lv_timer_handler();
        }
        usleep(5000); // 5ms
    }

    return 0;
}
