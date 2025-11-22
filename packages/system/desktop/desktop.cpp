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

// LVGL Includes
#include "lvgl/lvgl.h"
#include "lv_drivers/display/fbdev.h"
#include "wm.h"

// Global Clock Label
lv_obj_t * label_clock;
int mouse_fd = -1;
uint32_t screen_width = 0;
uint32_t screen_height = 0;

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

void custom_mouse_read(lv_indev_drv_t * drv, lv_indev_data_t * data) {
    if (mouse_fd < 0) return;

    struct input_event in;
    while (read(mouse_fd, &in, sizeof(struct input_event)) > 0) {
        if (in.type == EV_REL) {
            if (in.code == REL_X) g_mouse_x += in.value;
            else if (in.code == REL_Y) g_mouse_y += in.value;
        } else if (in.type == EV_KEY) {
            if (in.code == BTN_LEFT) {
                data->state = (in.value) ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
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
        // Launch a Demo Window
        lv_obj_t * content = create_window("Gemini File Explorer", 400, 300);
        
        // Add some dummy content
        lv_obj_t * label = lv_label_create(content);
        lv_label_set_text(label, "Welcome to GeminiOS!\n\nThis is a movable window.\nTry the buttons on top.");
        lv_obj_center(label);
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

int main(void) {
    // 0. Sanity Checks
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

    // 6. Main Loop
    while(1) {
        lv_timer_handler();
        usleep(5000);
    }

    return 0;
}
